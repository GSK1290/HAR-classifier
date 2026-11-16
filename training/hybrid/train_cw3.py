"""
PDIoT CW3 - train the Hybrid models and export them for the app.

    python train_cw3.py --task har      # -> har_hybrid.tflite    (11 activities, 4 s windows)
    python train_cw3.py --task social   # -> social_hybrid.tflite (4 social signals, 10 s windows)

Each command trains a Hybrid network (hybrid_model.py), converts it to TensorFlow Lite with
standard operations only, and writes the three files the app reads:
<name>.tflite, <name>_meta.json and <name>_example.json.

Recordings are split into 10 subject-wise folds (Lab 3 method). Folds 1-9 are used for training;
fold 0 is held out and used only to decide when to stop training. eval_cw3.py then measures the
exported model's accuracy on fold 0.
"""
import argparse, json, re, time
from pathlib import Path

import numpy as np
import pandas as pd

SAMPLING_FREQ = 12.5
AXES = ["accelX", "accelY", "accelZ"]
SEED = 0
N_FOLDS = 10

TASKS = {
    "har": dict(
        folder="daily_activity", name="har_hybrid", window=50, step=25, n_pool=1,      # 4 s windows
        classes=["sittingStanding", "lyingBack", "lyingLeft", "lyingRight", "lyingStomach",
                 "normalWalking", "shuffleWalking", "ascending", "descending", "running", "miscMovement"]),
    "social": dict(
        folder="social_signal", name="social_hybrid", window=125, step=25, n_pool=2,   # 10 s windows
        classes=["breathingNormally", "coughing", "hyperventilation", "other"]),
}


# ----------------------------------------------------------------------------- data (as in Lab 3)
def list_recordings(data_dir, folder, classes):
    rows = [{"path": p, "label": c, "y": i}
            for i, c in enumerate(classes) for p in sorted((data_dir / folder / c).glob("*.csv"))]
    assert rows, f"no CSV files under {data_dir / folder} - check --data"
    return pd.DataFrame(rows)


def load_recording(path):
    return pd.read_csv(path, usecols=AXES)[AXES].dropna().to_numpy(dtype=np.float32)


def make_windows(signal, window, step):
    if len(signal) < window:
        return np.empty((0, window, 3), np.float32)
    return np.stack([signal[s:s + window] for s in range(0, len(signal) - window + 1, step)])


def subject_id(path):
    m = re.fullmatch(r"N_(\d+)\.csv", path.name)
    return m.group(1) if m else path.stem


def make_folds(recs, n_folds=N_FOLDS, seed=SEED):
    """Subject-wise folds (Lab 3): within each class, subjects are shuffled and dealt into
    n_folds folds, so all of a subject's data for that class is in one fold."""
    rng = np.random.default_rng(seed)
    out = pd.Series(-1, index=recs.index)
    for _, idx in recs.groupby("label").groups.items():
        subjects = recs.loc[idx, "path"].map(subject_id)
        fold_of = {s: k % n_folds for k, s in enumerate(rng.permutation(subjects.unique()))}
        out.loc[idx] = subjects.map(fold_of)
    return out


def load_task(data_dir, cfg):
    """All windows of a task, each with its label and the fold of the recording it came from.
    Splitting by fold means windows of one subject never end up on both sides."""
    recs = list_recordings(data_dir, cfg["folder"], cfg["classes"])
    recs["fold"] = make_folds(recs)
    X, y, fold = [], [], []
    for r in recs.itertuples():
        w = make_windows(load_recording(r.path), cfg["window"], cfg["step"])
        X.append(w); y += [r.y] * len(w); fold += [r.fold] * len(w)
    X, y, fold = np.concatenate(X), np.array(y), np.array(fold)
    print(f"{cfg['folder']}: {len(recs)} recordings -> {len(X)} windows of {cfg['window']} samples; "
          f"per class {dict(zip(cfg['classes'], np.bincount(y, minlength=len(cfg['classes']))))}", flush=True)
    return X, y, fold


# ----------------------------------------------------------------------------- train + export
def train_and_export(args, cfg):
    """Train on folds 1-9 (fold 0 only decides when to stop), then export for the app.
    With --members > 1, several networks are trained and their outputs averaged into one model."""
    import keras, tensorflow as tf
    import hybrid_model as hm
    X, y, fold = load_task(args.data, cfg)
    classes, n, window, name = cfg["classes"], len(cfg["classes"]), cfg["window"], cfg["name"]
    tr = fold != 0
    members = []
    for m in range(args.members):
        keras.utils.set_random_seed(1000 + m)
        Xa, ya = hm.augment(X[tr], y[tr], seed=m)
        model = hm.build_hybrid(window, n, X[tr], n_pool=cfg["n_pool"])
        hm.train_model(model, Xa, ya, X[~tr], y[~tr], n, epochs=args.epochs)
        members.append(model)
        print(f"trained member {m + 1}/{args.members}", flush=True)
    model = hm.make_ensemble(members, window)

    conv = tf.lite.TFLiteConverter.from_keras_model(model)
    conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]    # only operations the app supports
    tflite_bytes = conv.convert()
    (args.out / f"{name}.tflite").write_bytes(tflite_bytes)

    interp = tf.lite.Interpreter(model_content=tflite_bytes)
    inp, out = interp.get_input_details()[0], interp.get_output_details()[0]
    interp.resize_tensor_input(inp["index"], [1, window, 3]); interp.allocate_tensors()
    meta = {
        "model_file": f"{name}.tflite", "task": cfg["folder"], "sampling_frequency_hz": SAMPLING_FREQ,
        "window_samples": window, "step_samples": cfg["step"],
        "input": {"shape": [1, window, 3], "channels": AXES, "units": "g (raw accelerometer values)",
                  "dtype": str(np.dtype(inp["dtype"]))},
        "output": {"shape": [1, n], "classes": classes, "dtype": str(np.dtype(out["dtype"]))},
        "normalization": "inside the model – feed raw values",
    }
    (args.out / f"{name}_meta.json").write_text(json.dumps(meta, indent=2))

    # Check: one window at a time, like the app. TFLite must agree with Keras.
    Xv, yv = X[~tr][:300], y[~tr][:300]
    t0, p_lite = time.time(), []
    for w in Xv:
        interp.set_tensor(inp["index"], w[np.newaxis]); interp.invoke()
        p_lite.append(interp.get_tensor(out["index"])[0].copy())
    ms = (time.time() - t0) / len(Xv) * 1000
    p_lite, p_keras = np.array(p_lite), model.predict(Xv, verbose=0)
    example = {"input_window": Xv[0].round(6).tolist(), "expected_probabilities": p_lite[0].round(6).tolist(),
               "expected_class": classes[int(p_lite[0].argmax())], "true_class": classes[int(yv[0])]}
    (args.out / f"{name}_example.json").write_text(json.dumps(example))
    print(f"\nwrote {name}.tflite ({len(tflite_bytes) / 1024:.0f} kB), {name}_meta.json, {name}_example.json in {args.out}")
    print(f"TFLite vs Keras: same class on {(p_lite.argmax(1) == p_keras.argmax(1)).mean():.1%} of windows, "
          f"max probability difference {np.abs(p_lite - p_keras).max():.1e}, {ms:.1f} ms per window on this CPU")
    print("accuracy on the held-out fold: run eval_cw3.py")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--task", choices=list(TASKS), required=True)
    p.add_argument("--members", type=int, default=1,
                   help="networks averaged into one model (the app's models use 1)")
    p.add_argument("--epochs", type=int, default=60, help="maximum; early stopping usually ends sooner")
    p.add_argument("--data", type=Path, default=Path("datasetJan2026"))
    p.add_argument("--out", type=Path, default=Path("lab3_models"))
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    train_and_export(args, TASKS[args.task])
