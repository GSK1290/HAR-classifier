"""
PDIoT CW3 - the Hybrid model (multi-scale CNN + GRU + attention + window statistics), used for
both the activity model (har_hybrid) and the social-signal model (social_hybrid).

  * input  : [batch, window, 3]  raw x, y, z in g, oldest sample first
  * output : [batch, n_classes]  softmax probabilities
All pre-processing (magnitude, statistics, normalisation) happens INSIDE the model, so the app
sends raw x, y, z.
"""
import numpy as np
import keras
from keras import layers, ops
from sklearn.utils.class_weight import compute_class_weight


# --------------------------------------------------------------------------------------
# 1. Calculations done inside the model
# --------------------------------------------------------------------------------------
def magnitude(x):
    """Length of the acceleration vector: does not depend on how the sensor is rotated."""
    return ops.sqrt(ops.sum(ops.square(x), axis=-1, keepdims=True))


def stat_features(x):
    """The statistical features from the Edinburgh RESpeck thesis, per channel.

    x: (batch, window, channels) -> (batch, 12 * channels)
    mean, std, min, max, range, skew, kurtosis, 10/25/50/75/90th percentiles.
    (Mode is left out: it is unstable on continuous data and close to the median.)
    """
    w = x.shape[1]
    mean = ops.mean(x, axis=1)
    centred = x - ops.expand_dims(mean, 1)
    var = ops.mean(ops.square(centred), axis=1)
    std = ops.sqrt(var + 1e-6)
    skew = ops.mean(centred ** 3, axis=1) / (std ** 3 + 1e-6)
    kurt = ops.mean(centred ** 4, axis=1) / (var ** 2 + 1e-6)

    s = ops.sort(ops.transpose(x, (0, 2, 1)), axis=-1)       # (batch, channels, window), sorted in time

    def pct(p):
        return s[:, :, int(round(p * (w - 1)))]

    mn, mx = s[:, :, 0], s[:, :, -1]
    feats = [mean, std, mn, mx, mx - mn, skew, kurt,
             pct(0.10), pct(0.25), pct(0.50), pct(0.75), pct(0.90)]
    return ops.concatenate(feats, axis=-1)


def _with_magnitude_np(X):
    return np.concatenate([X, np.linalg.norm(X, axis=2, keepdims=True)], axis=2)


# --------------------------------------------------------------------------------------
# 2. Building block
# --------------------------------------------------------------------------------------
def ms_block(x, filters):
    """Multi-scale residual block: short (3), medium (7) and long (15-sample) detectors in parallel."""
    branches = [layers.Conv1D(filters // 2, k, padding="same", use_bias=False)(x) for k in (3, 7, 15)]
    y = layers.Concatenate()(branches)
    y = layers.BatchNormalization()(y)
    y = layers.ReLU()(y)
    y = layers.Conv1D(filters, 1, use_bias=False)(y)
    y = layers.BatchNormalization()(y)
    shortcut = x if x.shape[-1] == filters else layers.Conv1D(filters, 1)(x)
    return layers.ReLU()(layers.Add()([y, shortcut]))


# --------------------------------------------------------------------------------------
# 3. The model
# --------------------------------------------------------------------------------------
def _adapt_on(inp, tensor, X_train, name):
    """Normalization layer fitted on the values `tensor` takes for the training windows."""
    probe = keras.Model(inp, tensor)
    probe.compile(jit_compile=False)
    values = probe.predict(X_train, batch_size=1024, verbose=0)
    norm = layers.Normalization(axis=-1, name=name)
    norm.adapt(values)
    return norm


def build_hybrid(window, n_classes, X_train, n_pool=1, gru_units=64, dropout=0.3):
    """CNN + GRU + attention, plus a statistical-feature branch.

    window   : samples per window (50 for activities, 125 for social signals)
    X_train  : training windows (n, window, 3) - used ONLY to set normalisation statistics
    n_pool   : 1 for 4 s windows, 2 for 10 s windows (keeps the GRU sequence 25-31 steps)
    """
    inp = keras.Input((window, 3), name="window")
    x4 = layers.Concatenate(name="xyz_mag")([inp, layers.Lambda(magnitude, name="magnitude")(inp)])

    # --- deep branch: CNN (patterns) -> GRU (order in time) -> attention (important moments)
    norm = layers.Normalization(axis=-1, name="normalize")
    norm.adapt(_with_magnitude_np(X_train))
    d = norm(x4)

    d = ms_block(d, 64)
    for _ in range(n_pool):
        d = layers.MaxPooling1D(2)(d)
        d = ms_block(d, 64)
    d = ms_block(d, 128)
    d = layers.SpatialDropout1D(0.1)(d)

    summary = layers.GlobalAveragePooling1D(name="summary")(d)
    seq = layers.GRU(gru_units, return_sequences=True, unroll=True, name="gru")(d)  # unroll=True for the phone
    weights = layers.Softmax(axis=1, name="attention_weights")(layers.Dense(1)(seq))
    attended = layers.Lambda(lambda t: ops.sum(t[0] * t[1], axis=1), name="attention")([seq, weights])

    # --- statistics branch, computed on RAW values so gravity (posture) is kept
    f = layers.Lambda(stat_features, name="stats")(x4)
    f = _adapt_on(inp, f, X_train, "normalize_stats")(f)
    f = layers.Dense(64, activation="relu")(f)
    f = layers.Dropout(0.2)(f)

    # --- combine -> class probabilities
    h = layers.Concatenate(name="combine")([summary, attended, f])
    h = layers.Dropout(dropout)(h)
    out = layers.Dense(n_classes, activation="softmax", name="probabilities")(h)
    return keras.Model(inp, out, name="hybrid")


# --------------------------------------------------------------------------------------
# 4. Data augmentation (training data only)
# --------------------------------------------------------------------------------------
def _random_rotations(rng, n, max_deg):
    axes = rng.normal(size=(n, 3))
    axes /= np.linalg.norm(axes, axis=1, keepdims=True)
    theta = np.deg2rad(rng.uniform(-max_deg, max_deg, size=n))
    K = np.zeros((n, 3, 3))
    K[:, 0, 1], K[:, 0, 2] = -axes[:, 2], axes[:, 1]
    K[:, 1, 0], K[:, 1, 2] = axes[:, 2], -axes[:, 0]
    K[:, 2, 0], K[:, 2, 1] = -axes[:, 1], axes[:, 0]
    I = np.eye(3)[None]
    s, c = np.sin(theta)[:, None, None], np.cos(theta)[:, None, None]
    return I + s * K + (1 - c) * (K @ K)                       # Rodrigues' rotation formula


def augment(X, y, copies=1, max_deg=10, scale=0.1, noise=0.01, seed=0):
    """Adds `copies` altered versions of every window: small sensor rotation (placement differs
    between people), amplitude scaling and a little noise. max_deg is kept small so lying
    postures keep their gravity direction."""
    rng = np.random.default_rng(seed)
    Xs, ys = [X], [y]
    for _ in range(copies):
        R = _random_rotations(rng, len(X), max_deg)
        Xa = np.einsum("nij,ntj->nti", R, X)
        Xa = Xa * rng.uniform(1 - scale, 1 + scale, size=(len(X), 1, 1))
        Xa = Xa + rng.normal(0, noise, size=Xa.shape)
        Xs.append(Xa.astype(np.float32))
        ys.append(y)
    return np.concatenate(Xs), np.concatenate(ys)


# --------------------------------------------------------------------------------------
# 5. Training and ensemble
# --------------------------------------------------------------------------------------
def train_model(model, X_tr, y_tr, X_val, y_val, n_classes, epochs=60, batch_size=64, lr=1e-3):
    """Class weights make every class count equally (vital for social signals' big 'other' class).
    Early stopping on the validation windows restores the best epoch."""
    present = np.unique(y_tr)
    w = compute_class_weight("balanced", classes=present, y=y_tr)
    class_weight = {int(c): float(v) for c, v in zip(present, w)}

    model.compile(optimizer=keras.optimizers.Adam(lr), jit_compile=False,
                  loss="sparse_categorical_crossentropy", metrics=["accuracy"])
    callbacks = [
        keras.callbacks.EarlyStopping(monitor="val_loss", patience=8, restore_best_weights=True),
        keras.callbacks.ReduceLROnPlateau(monitor="val_loss", factor=0.5, patience=4),
    ]
    return model.fit(X_tr, y_tr, validation_data=(X_val, y_val), epochs=epochs,
                     batch_size=batch_size, class_weight=class_weight,
                     callbacks=callbacks, verbose=0)


def make_ensemble(models, window):
    """Averages several trained models into ONE model -> one .tflite file for the app.
    With a single model (as for the app's models) it simply returns that model's output."""
    inp = keras.Input((window, 3), name="window")
    for k, m in enumerate(models):
        m.name = f"member_{k}"          # each member needs a unique name inside the ensemble
    outs = [m(inp) for m in models]
    out = layers.Average(name="probabilities")(outs) if len(outs) > 1 else outs[0]
    ensemble = keras.Model(inp, out, name="ensemble")
    ensemble.compile(jit_compile=False)
    return ensemble
