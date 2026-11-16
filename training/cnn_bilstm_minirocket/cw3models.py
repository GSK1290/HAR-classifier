"""
The two social-signal models used in the app, behind one common interface (Engine) so they
are trained, cross-validated and exported the same way:

  bilstm      multibranch CNN-BiLSTM                                         -> social_bilstm.tflite
  minirocket  MiniRocket random convolution features + linear softmax head   -> social_minirocket.tflite

Both take raw g [1, 125, 3] and return 4 softmax probabilities. The shared pipeline (data, folds,
augmentation, training, logit offsets, export) is in cw3lib.py.
"""
from __future__ import annotations

import itertools
from pathlib import Path

import numpy as np
import keras
from keras import layers, ops

import cw3lib as L

reg = L.reg


# ======================================================================================
# 1. MiniRocket (Dempster, Schmidt & Webb 2021) as a Keras layer -> builtin TFLite ops
# ======================================================================================
_MR_KERNELS = np.array([[2.0 if i in idx else -1.0 for i in range(9)]
                        for idx in itertools.combinations(range(9), 3)], np.float32)   # (84, 9)


def _mr_dilations(window: int, n_features: int, max_dil_per_kernel: int = 32):
    per_kernel = max(1, n_features // 84)
    true_max = min(per_kernel, max_dil_per_kernel)
    mult = per_kernel / true_max
    max_exp = np.log2((window - 1) / 8)
    dil, counts = np.unique(np.floor(np.logspace(0, max_exp, true_max, base=2)).astype(int),
                            return_counts=True)
    nq = (counts * mult).astype(int)
    rem = per_kernel - nq.sum()
    i = 0
    while rem > 0:
        nq[i] += 1; rem -= 1; i = (i + 1) % len(nq)
    return dil.tolist(), nq.tolist()


@reg
class MiniRocketFeatures(layers.Layer):
    """(B, W, C) -> (B, 84 * sum(n_quantiles)) "proportion of positive values" features.
    84 fixed kernels (weights -1/2), several dilations, a random channel subset per
    kernel/dilation, and biases taken from quantiles of training convolution outputs.
    Only Conv / Greater / Cast / Mean ops, so it converts to builtin TFLite."""

    def __init__(self, n_channels, dilations, n_quantiles, channel_masks, biases, **kw):
        super().__init__(**kw)
        self.n_channels, self.dilations, self.n_quantiles = n_channels, list(dilations), list(n_quantiles)
        self.channel_masks = [np.asarray(m, np.float32).tolist() for m in channel_masks]
        self.bias_values = [np.asarray(b, np.float32).tolist() for b in biases]

    def build(self, input_shape):
        self.kern, self.bias = [], []
        for i, (d, nq) in enumerate(zip(self.dilations, self.n_quantiles)):
            mask = np.asarray(self.channel_masks[i], np.float32)                     # (84, C)
            w = _MR_KERNELS.T[:, None, :] * mask.T[None, :, :]                       # (9, C, 84)
            self.kern.append(self.add_weight(name=f"k{d}", shape=w.shape, trainable=False,
                                             initializer=keras.initializers.Constant(w)))
            b = np.asarray(self.bias_values[i], np.float32).reshape(1, 1, 84, nq)
            self.bias.append(self.add_weight(name=f"b{d}", shape=b.shape, trainable=False,
                                             initializer=keras.initializers.Constant(b)))

    def conv(self, x, i):
        return ops.conv(x, self.kern[i], strides=1, padding="same", dilation_rate=self.dilations[i])

    def call(self, x):
        out = []
        for i, nq in enumerate(self.n_quantiles):
            c = ops.expand_dims(self.conv(x, i), -1)                                 # (B, W, 84, 1)
            ppv = ops.mean(ops.cast(ops.greater(c, self.bias[i]), "float32"), axis=1)
            out.append(ops.reshape(ppv, (-1, 84 * nq)))
        return ops.concatenate(out, axis=-1)

    def get_config(self):
        return {**super().get_config(), "n_channels": self.n_channels, "dilations": self.dilations,
                "n_quantiles": self.n_quantiles, "channel_masks": self.channel_masks,
                "biases": self.bias_values}


def fit_minirocket(sig: np.ndarray, n_features: int, seed: int = 0) -> MiniRocketFeatures:
    """Choose dilations, channel subsets and biases from training signals sig (n, W, C)."""
    rng = np.random.default_rng(seed)
    n, W, C = sig.shape
    dil, nq = _mr_dilations(W, n_features)
    phi = (np.sqrt(5) + 1) / 2
    q_all = (np.arange(1, 84 * sum(nq) + 1) * phi) % 1                # low-discrepancy quantiles
    masks, biases, qi = [], [], 0
    for d, k in zip(dil, nq):
        m = np.zeros((84, C), np.float32)
        for j in range(84):
            nc = int(2 ** rng.uniform(0, np.log2(min(C, 9) + 1)))
            m[j, rng.choice(C, size=max(1, min(nc, C)), replace=False)] = 1
        masks.append(m)
        biases.append(np.zeros((84, k), np.float32))
    layer = MiniRocketFeatures(C, dil, nq, masks, biases)
    layer.build((None, W, C))
    for i, (d, k) in enumerate(zip(dil, nq)):
        ex = sig[rng.integers(0, n, size=84)]                             # one random example per kernel
        c = keras.ops.convert_to_numpy(layer.conv(ex, i))                 # (84, W, 84)
        own = c[np.arange(84), :, np.arange(84)]                          # example j through kernel j
        b = np.stack([np.quantile(own[j], q_all[qi + j * k: qi + (j + 1) * k]) for j in range(84)])
        qi += 84 * k
        biases[i] = b.astype(np.float32)
    return MiniRocketFeatures(C, dil, nq, masks, biases, name="minirocket")


# ======================================================================================
# 2. Multibranch CNN-BiLSTM (after Challa et al., "A multibranch CNN-BiLSTM model for human
#    activity recognition using wearable sensor data"), adapted to the RESpeck / app contract
# ======================================================================================
BILSTM_KERNELS = (3, 7, 11)


def build_cnn_bilstm(X_train: np.ndarray, cfg: L.TaskConfig, filters: int = 32,
                     lstm_units=(64, 32)) -> keras.Model:
    """Parallel conv branches with small / medium / large kernels (multi-scale local patterns),
    concatenated and fed to two stacked BiLSTMs (long-range temporal context).
    Adaptations: gravity removed (posture-invariant), normalisation inside the model (raw g in),
    pooling 125 -> 31 steps and unrolled LSTMs so the model converts to builtin TFLite ops."""
    inp = keras.Input(shape=(cfg.window, 3), name="window")
    ch = L.DynamicChannels(name="remove_gravity")
    sig = ch(inp)
    x = L._adapted_norm("normalize", L._eager(ch, X_train))(sig)
    branches = []
    for k in BILSTM_KERNELS:
        b = x
        for j in (1, 2):
            b = layers.Conv1D(filters, k, padding="same", use_bias=False, name=f"k{k}_conv{j}")(b)
            b = layers.BatchNormalization(name=f"k{k}_bn{j}")(b)
            b = layers.ReLU(name=f"k{k}_relu{j}")(b)
        branches.append(layers.MaxPooling1D(2, name=f"k{k}_pool")(b))
    x = layers.Concatenate(name="branches")(branches)
    x = layers.MaxPooling1D(2, name="pool2")(x)           # 125 -> 62 -> 31 time steps
    x = layers.Dropout(0.2)(x)
    x = layers.Bidirectional(layers.LSTM(lstm_units[0], return_sequences=True, unroll=True), name="bilstm1")(x)
    x = layers.Bidirectional(layers.LSTM(lstm_units[1], unroll=True), name="bilstm2")(x)
    x = layers.Dropout(0.3)(x)
    x = layers.Dense(64, activation="relu", name="head_dense")(x)
    x = layers.Dropout(0.3)(x)
    out = layers.Dense(len(cfg.classes), activation="softmax", name="probabilities")(x)
    return keras.Model(inp, out, name="social_cnn_bilstm")


# ======================================================================================
# 3. Engines: fit / predict_proba / export with one interface
# ======================================================================================
class Engine:
    kind = "?"
    exportable = True

    def __init__(self, cfg: L.TaskConfig, args):
        self.cfg, self.args = cfg, args

    def fit(self, X_tr, y_tr, X_va=None, y_va=None, epochs=None) -> int: ...
    def predict_proba(self, X) -> np.ndarray: ...
    def export(self, out_dir: Path, name: str, offsets, extra_meta: dict, X_chk, y_chk) -> Path: ...


class CNNBiLSTMEngine(Engine):
    """Multibranch CNN-BiLSTM: augmentation, early stopping, logit offsets; exported to TFLite."""
    kind = "bilstm"

    def fit(self, X_tr, y_tr, X_va=None, y_va=None, epochs=None):
        self.model, best = L.train_model(self.cfg, X_tr, y_tr, X_va, y_va, epochs=epochs or self.args.epochs,
                                         batch_size=self.args.batch, seed=self.args.seed,
                                         verbose=getattr(self.args, "verbose", 0), builder=build_cnn_bilstm)
        return best

    def predict_proba(self, X):
        return self.model.predict(X, batch_size=1024, verbose=0)

    def export(self, out_dir, name, offsets, extra_meta, X_chk, y_chk):
        model = L.with_offsets(self.model, offsets) if offsets is not None else self.model
        model.save(Path(out_dir) / f"{name}.keras")
        path = L.convert_to_tflite(model, name, self.cfg, out_dir, quantize=self.args.quantize,
                                   extra_meta=extra_meta)
        L.verify_tflite(path, model, X_chk, y_chk, self.cfg, name)
        return path


class MiniRocketEngine(Engine):
    """MiniRocket features + softmax regression (the paper's logistic-regression variant for
    large training sets), trained with Adam and early stopping on the validation fold."""
    kind = "minirocket"

    def _features(self, X):
        out = []
        for i in range(0, len(X), 256):
            out.append(keras.ops.convert_to_numpy(self.mr(self.ch(X[i:i + 256]))))
        return np.concatenate(out)

    def fit(self, X_tr, y_tr, X_va=None, y_va=None, epochs=None):
        L.set_seed(self.args.seed)
        self.ch = L.DynamicChannels(name="remove_gravity")
        sig = keras.ops.convert_to_numpy(self.ch(X_tr[:4096]))
        self.mr = fit_minirocket(sig, self.args.mr_features, self.args.seed)
        F_tr = self._features(X_tr)
        n_cls = len(self.cfg.classes)
        self.norm = layers.Normalization(name="normalize_features"); self.norm.adapt(F_tr)
        self.drop = layers.Dropout(0.2)
        self.dense = layers.Dense(n_cls, activation="softmax", name="probabilities",
                                  kernel_regularizer=keras.regularizers.l2(1e-4))
        fin = keras.Input(shape=(F_tr.shape[1],))
        head = keras.Model(fin, self.dense(self.drop(self.norm(fin))))
        head.compile(keras.optimizers.Adam(1e-3), "sparse_categorical_crossentropy", metrics=["accuracy"])
        cw = L.balanced_weights(y_tr, n_cls, self.cfg.weight_power)
        val, cbs = None, []
        if X_va is not None and len(X_va):
            val = (self._features(X_va), y_va, cw[y_va])
            cbs = [keras.callbacks.EarlyStopping(monitor="val_loss", patience=5, restore_best_weights=True),
                   keras.callbacks.ReduceLROnPlateau(monitor="val_loss", factor=0.5, patience=2)]
        ep = epochs or self.args.epochs
        h = head.fit(F_tr, y_tr, sample_weight=cw[y_tr], batch_size=256, epochs=ep,
                     validation_data=val, callbacks=cbs, verbose=getattr(self.args, "verbose", 0), shuffle=True)
        best = int(np.argmin(h.history["val_loss"])) + 1 if val else ep
        self.head = head
        return best

    def full_model(self):
        inp = keras.Input(shape=(self.cfg.window, 3), name="window")
        out = self.dense(self.norm(self.mr(self.ch(inp))))           # dropout is a no-op at inference
        return keras.Model(inp, out, name="minirocket")

    def predict_proba(self, X):
        return self.head.predict(self._features(X), batch_size=2048, verbose=0)

    def export(self, out_dir, name, offsets, extra_meta, X_chk, y_chk):
        model = self.full_model()
        if offsets is not None:
            model = L.with_offsets(model, offsets)
        model.save(Path(out_dir) / f"{name}.keras")
        path = L.convert_to_tflite(model, name, self.cfg, out_dir, quantize=self.args.quantize,
                                   extra_meta=extra_meta)
        L.verify_tflite(path, model, X_chk, y_chk, self.cfg, name)
        return path


ENGINES = {"bilstm": CNNBiLSTMEngine, "minirocket": MiniRocketEngine}
