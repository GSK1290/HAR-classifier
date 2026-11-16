"""
PDIoT Coursework 3 – shared training pipeline for the social-signal models
CNN + BiLSTM and MiniRocket (the models themselves are in cw3models.py).

Contents: data loading and windowing, the official folds, augmentation, training,
per-class logit offsets, the CW3 metric, and TFLite export.

Each exported model takes RAW accelerometer values in g, shape [1, WINDOW, 3]
(accelX, accelY, accelZ, oldest sample first), and returns softmax probabilities
[1, n_classes] – the contract the app expects. Recurrent layers are unrolled so the
models convert to standard TFLite operators (no Select TF ops / Flex delegate needed).
"""
from __future__ import annotations

import contextlib
import io
import json
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd
import keras
from keras import layers, ops

# --------------------------------------------------------------------------------------
# Configuration (class order is FIXED – output index i means CLASSES[i] in the app)
# --------------------------------------------------------------------------------------
SAMPLING_FREQ = 12.5
AXES = ["accelX", "accelY", "accelZ"]

SOCIAL_CLASSES = ["breathingNormally", "coughing", "hyperventilation", "other"]
# The app only shows a social-signal result while the activity model predicts one of these
STATIC_CLASSES = ["sittingStanding", "lyingBack", "lyingLeft", "lyingRight", "lyingStomach"]


@dataclass
class TaskConfig:
    name: str                 # "social"
    folder: str               # dataset sub-folder
    classes: list
    window: int               # samples per window (app contract)
    step: int                 # samples between app predictions (app contract)
    train_step: int           # samples between training windows
    max_windows_per_rec: int  # cap so a few very long recordings do not dominate
    rot_deg: float            # max random rotation for augmentation
    groups: dict = field(default_factory=dict)  # class groups used for the CW3 summary
    weight_power: float = 1.0  # class-weight strength (1 balanced, 0.5 sqrt, 0 none)
    calibrate: bool = False    # fit per-class logit offsets on validation subjects
    calib_min_weight: float = 0.5  # calibration score = mean acc + w * worst-class acc


TASKS = {
    "social": TaskConfig("social", "social_signal", SOCIAL_CLASSES,
                         window=125, step=25, train_step=25, max_windows_per_rec=20, rot_deg=20.0,
                         groups={"social": SOCIAL_CLASSES},
                         weight_power=0.0, calibrate=True),
}


def set_seed(seed: int = 0):
    keras.utils.set_random_seed(seed)
    np.random.seed(seed)


# --------------------------------------------------------------------------------------
# Data loading and cleaning
# --------------------------------------------------------------------------------------
def subject_id(path: Path) -> str:
    """Subject key, unique only within one class: N_12.csv -> '12' (as in Lab 3).
    Files without an N_ id (e.g. 'running (26).csv') are treated as their own subject."""
    m = re.fullmatch(r"N_(\d+)\.csv", Path(path).name)
    return m.group(1) if m else Path(path).stem


def list_recordings(data_dir: Path, cfg: TaskConfig) -> pd.DataFrame:
    rows = []
    for i, c in enumerate(cfg.classes):
        folder = Path(data_dir) / cfg.folder / c
        if not folder.is_dir():
            raise FileNotFoundError(f"missing class folder {folder}")
        for p in sorted(folder.glob("*.csv")):
            rows.append({"path": p, "file": p.name, "label": c, "y": i, "subject": subject_id(p)})
    return pd.DataFrame(rows)


def load_recording(path) -> np.ndarray:
    """Load the three acceleration axes in g (extra columns such as 'timestamp' are ignored).
    Isolated NaNs are interpolated; anything still missing is dropped."""
    df = pd.read_csv(path)
    df = df[[c for c in AXES if c in df.columns]]
    if list(df.columns) != AXES:
        raise ValueError(f"{path}: expected columns {AXES}, got {list(df.columns)}")
    df = df.apply(pd.to_numeric, errors="coerce").interpolate(limit_direction="both").dropna()
    return df.to_numpy(dtype=np.float32)


def make_windows(signal: np.ndarray, window: int, step: int, max_windows: int | None = None) -> np.ndarray:
    n = len(signal)
    if n < window:
        return np.empty((0, window, 3), np.float32)
    starts = np.arange(0, n - window + 1, step)
    if max_windows and len(starts) > max_windows:       # keep evenly spaced windows
        starts = starts[np.linspace(0, len(starts) - 1, max_windows).round().astype(int)]
    return np.stack([signal[s:s + window] for s in starts])


_CACHE: dict = {}


def windows_from_recordings(recs: pd.DataFrame, cfg: TaskConfig, step: int | None = None):
    """Window every recording; returns X (n, W, 3), y (n,), rec index (n,)."""
    step = step or cfg.train_step
    X, y, rid = [], [], []
    for i, r in recs.iterrows():
        key = (str(r.path), cfg.window, step, cfg.max_windows_per_rec)
        if key not in _CACHE:
            _CACHE[key] = make_windows(load_recording(r.path), cfg.window, step, cfg.max_windows_per_rec)
        w = _CACHE[key]
        X.append(w); y += [r.y] * len(w); rid += [i] * len(w)
    return np.concatenate(X).astype(np.float32), np.array(y, np.int64), np.array(rid)


# --------------------------------------------------------------------------------------
# Folds: the official subject-wise assignment from Learn (folds_social_signal.csv)
# --------------------------------------------------------------------------------------
def load_folds(recs: pd.DataFrame, folds_csv: str) -> pd.Series:
    """Fold per recording from the Learn file (one row per recording: activity, file, fold).
    Recordings that are not in the file get -1 and are skipped."""
    f = pd.read_csv(folds_csv)
    f.columns = [c.strip().lower() for c in f.columns]
    act_col = next(c for c in f.columns if c in ("activity", "label", "class", "folder"))
    file_col = next(c for c in f.columns if c in ("file", "filename", "file_name", "path"))
    f["_file"] = f[file_col].map(lambda s: Path(str(s)).name)
    lookup = {(a, fn): int(k) for a, fn, k in zip(f[act_col], f["_file"], f["fold"])}
    folds = pd.Series([lookup.get((r.label, r.file), -999) for r in recs.itertuples()], index=recs.index)
    folds = folds.where(folds != -999, -1)   # fold numbers stay as in the file
    missing = (folds < 0).sum()
    if missing:
        print(f"!! {missing} recordings are not in the folds file and will be skipped")
    return folds.astype(int)


# --------------------------------------------------------------------------------------
# Input layer and helpers (standard ops only -> converts to builtin TFLite operators)
# --------------------------------------------------------------------------------------
reg = keras.saving.register_keras_serializable(package="cw3")


@reg
class DynamicChannels(layers.Layer):
    """(B, W, 3) -> (B, W, 4): x, y, z and |a| with their window mean removed.
    Removing the mean removes gravity, so the signal no longer depends on posture –
    the social-signal data was recorded sitting, standing and lying."""
    def call(self, x):
        mag = ops.sqrt(ops.sum(ops.square(x), axis=-1, keepdims=True) + 1e-8)
        s = ops.concatenate([x, mag], axis=-1)
        return s - ops.mean(s, axis=1, keepdims=True)


def _adapted_norm(name: str, data: np.ndarray) -> layers.Normalization:
    norm = layers.Normalization(axis=-1, name=name)
    norm.adapt(data)
    return norm


def _eager(layer, X: np.ndarray, batch: int = 2048) -> np.ndarray:
    return np.concatenate([keras.ops.convert_to_numpy(layer(X[i:i + batch]))
                           for i in range(0, len(X), batch)])


# --------------------------------------------------------------------------------------
# Augmentation + training
# --------------------------------------------------------------------------------------
def random_rotations(n: int, max_deg: float, rng) -> np.ndarray:
    """n rotation matrices about random axes by angles in [-max_deg, max_deg] (Rodrigues)."""
    axis = rng.normal(size=(n, 3)); axis /= np.linalg.norm(axis, axis=1, keepdims=True)
    theta = np.deg2rad(rng.uniform(-max_deg, max_deg, size=n))
    K = np.zeros((n, 3, 3))
    K[:, 0, 1], K[:, 0, 2], K[:, 1, 2] = -axis[:, 2], axis[:, 1], -axis[:, 0]
    K[:, 1, 0], K[:, 2, 0], K[:, 2, 1] = axis[:, 2], -axis[:, 1], axis[:, 0]
    s, c = np.sin(theta)[:, None, None], np.cos(theta)[:, None, None]
    return (np.eye(3)[None] + s * K + (1 - c) * K @ K).astype(np.float32)


def augment(X: np.ndarray, rot_deg: float, rng) -> np.ndarray:
    """Small sensor-placement changes: rotation, amplitude scaling, Gaussian jitter."""
    n = len(X)
    Xa = np.einsum("nij,ntj->nti", random_rotations(n, rot_deg, rng), X)
    Xa *= rng.uniform(0.9, 1.1, size=(n, 1, 1)).astype(np.float32)
    Xa += rng.normal(0, 0.01, size=Xa.shape).astype(np.float32)
    return np.clip(Xa, -2.0, 2.0)          # the RESpeck saturates at ±2 g


class AugmentedWindows(keras.utils.PyDataset):
    def __init__(self, X, y, sample_w, batch_size, rot_deg, seed=0, **kw):
        super().__init__(**kw)
        self.X, self.y, self.w, self.bs, self.rot = X, y, sample_w, batch_size, rot_deg
        self.rng = np.random.default_rng(seed)
        self.order = self.rng.permutation(len(X))

    def __len__(self):
        return int(np.ceil(len(self.X) / self.bs))

    def __getitem__(self, i):
        idx = self.order[i * self.bs:(i + 1) * self.bs]
        return augment(self.X[idx], self.rot, self.rng), self.y[idx], self.w[idx]

    def on_epoch_end(self):
        self.order = self.rng.permutation(len(self.X))


def balanced_weights(y: np.ndarray, n_classes: int, power: float = 1.0) -> np.ndarray:
    """power 1 = fully balanced, 0.5 = square-root balancing (softer), 0 = no weighting."""
    counts = np.bincount(y, minlength=n_classes).astype(np.float64)
    w = (len(y) / (n_classes * np.maximum(counts, 1))) ** power
    return (w / w[np.bincount(y, minlength=n_classes).argmax()] if power == 0 else w).astype(np.float32)


def train_model(cfg: TaskConfig, X_tr, y_tr, X_val=None, y_val=None, epochs=40,
                batch_size=128, lr=1e-3, seed=0, verbose=0, weight_power=None, builder=None):
    """Build with builder(X_train, cfg) (e.g. cw3models.build_cnn_bilstm) and train on augmented
    batches. With validation data, early stopping restores the best epoch. Returns (model, best epoch)."""
    if builder is None:
        raise ValueError("pass builder=, e.g. cw3models.build_cnn_bilstm")
    set_seed(seed)
    model = builder(X_tr, cfg)
    model.compile(optimizer=keras.optimizers.Adam(lr),
                  loss=keras.losses.SparseCategoricalCrossentropy(), metrics=["accuracy"])
    power = cfg.weight_power if weight_power is None else weight_power
    cw = balanced_weights(y_tr, len(cfg.classes), power)
    data = AugmentedWindows(X_tr, y_tr, cw[y_tr], batch_size, cfg.rot_deg, seed)
    cbs, val = [], None
    if X_val is not None and len(X_val):
        val = (X_val, y_val, cw[y_val])
        cbs = [keras.callbacks.EarlyStopping(monitor="val_loss", patience=7, restore_best_weights=True),
               keras.callbacks.ReduceLROnPlateau(monitor="val_loss", factor=0.5, patience=3)]
    hist = model.fit(data, validation_data=val, epochs=epochs, callbacks=cbs, verbose=verbose)
    best = int(np.argmin(hist.history["val_loss"])) + 1 if val else epochs
    return model, best


# --------------------------------------------------------------------------------------
# Logit offsets ("threshold moving", He & Garcia 2009). CW3 grades the MEAN of per-class
# accuracies, so after training we shift each class's log-probability by an offset fitted on
# validation subjects. The offsets are baked into the exported model as its last layer.
# --------------------------------------------------------------------------------------
@reg
class LogitBias(layers.Layer):
    """p -> softmax(log p + b): re-weights classes without retraining (TFLite builtins only)."""
    def __init__(self, bias, **kw):
        super().__init__(**kw)
        self.bias_values = [float(b) for b in bias]

    def build(self, input_shape):
        self.b = self.add_weight(name="offsets", shape=(len(self.bias_values),), trainable=False,
                                 initializer=keras.initializers.Constant(self.bias_values))

    def call(self, p):
        return ops.softmax(ops.log(p + 1e-7) + self.b, axis=-1)

    def get_config(self):
        return {**super().get_config(), "bias": self.bias_values}


def _objective(p_log, y, b, n, min_weight=0.5):
    acc = per_class_accuracy(y, (p_log + b).argmax(1), n)
    return np.nanmean(acc) + min_weight * np.nanmin(acc)   # high average, no class left behind


def fit_logit_offsets(p_val: np.ndarray, y_val: np.ndarray, n_classes: int,
                      grid=np.linspace(-3, 3, 31), rounds: int = 3, min_weight: float = 0.5) -> np.ndarray:
    """Coordinate ascent over per-class offsets (class 0 fixed at 0)."""
    p_log, b = np.log(p_val + 1e-7), np.zeros(n_classes)
    for _ in range(rounds):
        for c in range(1, n_classes):
            scores = []
            for g in grid:
                bb = b.copy(); bb[c] = g
                scores.append(_objective(p_log, y_val, bb, n_classes, min_weight))
            b[c] = grid[int(np.argmax(scores))]
    return b


def apply_offsets(p: np.ndarray, b) -> np.ndarray:
    return np.log(p + 1e-7) + np.asarray(b)


def with_offsets(model: keras.Model, b) -> keras.Model:
    out = LogitBias(b, name="class_offsets")(model.output)
    return keras.Model(model.input, out, name=model.name)


# --------------------------------------------------------------------------------------
# CW3 metric: per-class accuracy, averaged within class groups, then across folds
# --------------------------------------------------------------------------------------
def per_class_accuracy(y_true, y_pred, n_classes) -> np.ndarray:
    acc = np.full(n_classes, np.nan)
    for c in range(n_classes):
        m = y_true == c
        if m.any():
            acc[c] = (y_pred[m] == c).mean()
    return acc


def confusion(y_true, y_pred, n_classes) -> np.ndarray:
    cm = np.zeros((n_classes, n_classes), np.int64)
    np.add.at(cm, (y_true, y_pred), 1)
    return cm


def summarise(fold_accs: list, cfg: TaskConfig) -> dict:
    A = np.array(fold_accs)                                   # (folds, classes)
    per_class = {c: {"mean": float(np.nanmean(A[:, i])), "std": float(np.nanstd(A[:, i]))}
                 for i, c in enumerate(cfg.classes)}
    groups = {}
    for g, members in cfg.groups.items():
        idx = [cfg.classes.index(c) for c in members]
        per_fold = np.nanmean(A[:, idx], axis=1)              # average classes, then folds
        groups[g] = {"mean": float(per_fold.mean()), "std": float(per_fold.std())}
    return {"per_class": per_class, "groups": groups}


# --------------------------------------------------------------------------------------
# Export for the app (Lab 3 / Lab 4 contract)
# --------------------------------------------------------------------------------------
def base_meta(cfg: TaskConfig, model_file: str, model_type: str) -> dict:
    return {
        "model_file": model_file,
        "task": cfg.folder,
        "sampling_frequency_hz": SAMPLING_FREQ,
        "window_samples": cfg.window,
        "step_samples": cfg.step,
        "input": {"shape": [1, cfg.window, 3], "channels": AXES,
                  "units": "g (raw accelerometer values)", "dtype": "float32"},
        "output": {"shape": [1, len(cfg.classes)], "classes": list(cfg.classes), "dtype": "float32"},
        "model_type": model_type,
        "run_when": {"activity_model_predicts_one_of": STATIC_CLASSES},
    }


def convert_to_tflite(model: keras.Model, name: str, cfg: TaskConfig, out_dir: Path,
                      quantize: bool = False, extra_meta: dict | None = None) -> Path:
    import tensorflow as tf
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    conv = tf.lite.TFLiteConverter.from_keras_model(model)
    conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]   # fail loudly if not phone-safe
    if quantize:
        conv.optimizations = [tf.lite.Optimize.DEFAULT]                   # int8 weights, float32 I/O
    with contextlib.redirect_stdout(io.StringIO()):
        blob = conv.convert()
    path = out_dir / f"{name}.tflite"
    path.write_bytes(blob)
    meta = base_meta(cfg, path.name, model.name)
    meta.update({"backend": "tflite", "normalization": "inside the model – feed raw values",
                 "quantized": quantize, **(extra_meta or {})})
    (out_dir / f"{name}_meta.json").write_text(json.dumps(meta, indent=2))
    print(f"   wrote {path.name} ({len(blob) / 1024:.1f} kB) and {name}_meta.json")
    return path


class TFLiteModel:
    """One window at a time, exactly as the app calls it."""
    def __init__(self, path):
        import tensorflow as tf
        self.it = tf.lite.Interpreter(model_path=str(path))
        self.inp, self.out = self.it.get_input_details()[0], self.it.get_output_details()[0]
        self.it.resize_tensor_input(self.inp["index"], [1, *self.inp["shape"][1:]])
        self.it.allocate_tensors()

    def predict_one(self, w):
        self.it.set_tensor(self.inp["index"], w[None].astype(np.float32))
        self.it.invoke()
        return self.it.get_tensor(self.out["index"])[0]

    def predict(self, X):
        return np.stack([self.predict_one(w) for w in X])


def verify_tflite(path: Path, model: keras.Model, X, y, cfg: TaskConfig, name: str, n: int = 300):
    """Check the TFLite model matches Keras and write <name>_example.json for the app."""
    lite = TFLiteModel(path)
    idx = np.random.default_rng(0).choice(len(X), size=min(n, len(X)), replace=False)
    t0 = time.time(); p_lite = lite.predict(X[idx]); ms = (time.time() - t0) / len(idx) * 1000
    p_keras = model.predict(X[idx], batch_size=512, verbose=0)
    agree = (p_lite.argmax(1) == p_keras.argmax(1)).mean()
    print(f"   TFLite vs Keras: argmax agrees on {agree:.1%}, max |Δp| = {np.abs(p_lite - p_keras).max():.1e}, "
          f"{ms:.2f} ms/window on this CPU")
    i0 = idx[0]
    example = {"input_window": X[i0].round(6).tolist(),
               "expected_probabilities": p_lite[0].round(6).tolist(),
               "expected_class": cfg.classes[int(p_lite[0].argmax())],
               "true_class": cfg.classes[int(y[i0])]}
    (Path(path).parent / f"{name}_example.json").write_text(json.dumps(example))
    return agree
