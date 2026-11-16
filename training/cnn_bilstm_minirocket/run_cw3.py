"""
PDIoT CW3 – cross-validate and export the CNN + BiLSTM and MiniRocket social-signal models.

Modes (--mode):
  cv     10-fold subject-wise cross-validation on the official folds
         (each round: 1 test fold, the next fold for validation, 8 folds for training)
  final  train on ALL folds and export for the app. The number of epochs is the median best
         epoch from the CV, and the class offsets are the mean of the CV offsets.
  both   cv, then final

Examples
  python run_cw3.py --task social --mode both --model bilstm     --folds folds/folds_social_signal.csv
  python run_cw3.py --task social --mode both --model minirocket --folds folds/folds_social_signal.csv
  python compare_cv.py --task social --models minirocket bilstm
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

import cw3lib as L
import cw3models as M

PREFIX = {"social": "social"}


def report(name, cfg, accs, cms, extra, out_dir, raw=None):
    summary = L.summarise(accs, cfg)
    summary.update(extra)
    summary["confusion_matrix_summed"] = np.sum(cms, 0).tolist()
    if raw:
        summary["uncalibrated"] = L.summarise(raw, cfg)["groups"]
    (out_dir / f"{name}.json").write_text(json.dumps(summary, indent=2))
    n = len(accs)
    print(f"\n=== {name}: " + (f"mean over {n} folds" if n > 1 else "result") + " ===")
    for c, v in summary["per_class"].items():
        print(f"  {c:18s} {v['mean']:.3f}" + (f" ± {v['std']:.3f}" if n > 1 else ""))
    for g, v in summary["groups"].items():
        r = summary.get("uncalibrated", {}).get(g)
        print(f"  GROUP {g:12s} {v['mean']:.3f}" + (f" ± {v['std']:.3f}" if n > 1 else "")
              + (f"   (uncalibrated {r['mean']:.3f})" if r else ""))
    print("  summed confusion matrix (rows = true, cols = predicted):")
    for c, row in zip(cfg.classes, summary["confusion_matrix_summed"]):
        print(f"  {c[:12]:12s} {row}")
    print(f"saved {out_dir / (name + '.json')}")
    return summary


def calibrate(eng, cfg, X_va, y_va):
    if not cfg.calibrate or X_va is None or not len(X_va):
        return None
    return L.fit_logit_offsets(eng.predict_proba(X_va), y_va, len(cfg.classes), min_weight=cfg.calib_min_weight)


# ----------------------------------------------------------------------------- cv
def run_cv(cfg, recs, folds, args, out_dir):
    fold_ids = sorted(int(f) for f in folds.unique() if f >= 0)
    if args.quick:
        fold_ids = fold_ids[:2]
    accs, raw, cms, best_epochs, offsets = [], [], [], [], []
    print(f"CV model={args.model}, {len(fold_ids)} folds (val = next fold), test step {cfg.step}")

    def group_means(a):
        return "  ".join(f"{g} {np.nanmean([a[cfg.classes.index(c)] for c in m]):.3f}" for g, m in cfg.groups.items())

    for i, k in enumerate(fold_ids):
        t0 = time.time()
        test = recs[folds == k]
        rest = recs[(folds != k) & (folds >= 0)]
        val_k = fold_ids[(fold_ids.index(k) + 1) % len(fold_ids)]
        val = rest[folds.loc[rest.index] == val_k]
        train = rest.drop(val.index)
        X_tr, y_tr, _ = L.windows_from_recordings(train, cfg)
        X_te, y_te, _ = L.windows_from_recordings(test, cfg, step=cfg.step)
        X_va, y_va = L.windows_from_recordings(val, cfg, step=cfg.step)[:2]
        eng = M.ENGINES[args.model](cfg, args)
        best_epochs.append(eng.fit(X_tr, y_tr, X_va, y_va))       # early stopping on the validation fold
        p_te = eng.predict_proba(X_te)
        raw.append(L.per_class_accuracy(y_te, p_te.argmax(1), len(cfg.classes)))
        b = calibrate(eng, cfg, X_va, y_va)                       # class offsets fitted on the validation fold
        if b is not None:
            offsets.append(b.tolist())
            p_te = L.apply_offsets(p_te, b)
        y_hat = p_te.argmax(1)
        acc = L.per_class_accuracy(y_te, y_hat, len(cfg.classes))
        accs.append(acc); cms.append(L.confusion(y_te, y_hat, len(cfg.classes)))
        print(f"fold {k} ({i + 1:2d}/{len(fold_ids)})  "
              + "  ".join(f"{c[:10]} {a:.2f}" for c, a in zip(cfg.classes, acc))
              + f" | {group_means(acc)}" + (f" (uncalibrated: {group_means(raw[-1])})" if b is not None else "")
              + f" | best {best_epochs[-1]} | {time.time() - t0:.0f} s")
    extra = {"model": args.model, "folds": fold_ids, "best_epochs": best_epochs, "logit_offsets": offsets,
             "per_fold_class_accuracy": np.round(np.array(accs), 4).tolist(),
             "per_fold_class_accuracy_uncalibrated": np.round(np.array(raw), 4).tolist(),
             "window": cfg.window, "step": cfg.step}
    return report(f"{cfg.name}_{args.model}_cv", cfg, accs, cms, extra, out_dir,
                  raw if offsets else None)


# ----------------------------------------------------------------------------- final
def run_final(cfg, recs, folds, args, out_dir, cv_summary=None):
    """Train on all folds for a fixed number of epochs (median best epoch of the CV) and export."""
    train_ids = sorted(int(f) for f in folds.unique() if f >= 0)
    train = recs[folds.isin(train_ids)]
    name = args.name or f"{PREFIX[cfg.name]}_{args.model}" + ("_int8" if args.quantize else "")

    cv_file = out_dir / f"{cfg.name}_{args.model}_cv.json"
    if cv_summary is None and cv_file.exists():
        cv_summary = json.loads(cv_file.read_text())
    X, y, _ = L.windows_from_recordings(train, cfg)
    eng = M.ENGINES[args.model](cfg, args)
    epochs = None
    if cv_summary and cv_summary.get("best_epochs"):
        epochs = max(1, int(np.median(cv_summary["best_epochs"])))
        src = f"median of CV in {cv_file.name}"
    else:
        src = "default – run --mode cv first"
    if args.quick:
        epochs = 2
    print(f"{name}: train folds {train_ids} ({len(train)} recs, {len(X)} windows), "
          f"epochs: {epochs or 'default'} ({src})")
    best = eng.fit(X, y, epochs=epochs)
    offsets = None
    if cfg.calibrate and cv_summary and cv_summary.get("logit_offsets"):
        offsets = np.mean(cv_summary["logit_offsets"], axis=0)
        print(f"   class offsets (mean over CV folds): {np.round(offsets, 2)}")
    extra = {"trained_on_folds": train_ids, "validation_fold": None, "folds_file": args.folds,
             "model_family": args.model, "best_epochs_or_rounds": best}
    X_chk, y_chk, _ = L.windows_from_recordings(train, cfg, step=cfg.step)
    eng.export(out_dir, name, offsets, extra, X_chk, y_chk)


def main():
    try:                                     # show every line immediately, even when piped / logged
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:
        pass
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--data", default="datasetJan2026", help="folder with social_signal/")
    p.add_argument("--task", choices=list(L.TASKS), default="social")
    p.add_argument("--mode", choices=["cv", "final", "both"], default="cv")
    p.add_argument("--model", choices=list(M.ENGINES), required=True)
    p.add_argument("--folds", required=True, help="Learn fold CSV (activity, file, fold)")
    p.add_argument("--out", default="cw3_out")
    p.add_argument("--name", default=None, help="exported model name (default social_<model>)")
    p.add_argument("--epochs", type=int, default=40, help="max epochs")
    p.add_argument("--mr-features", type=int, default=4032, help="MiniRocket features (multiple of 84)")
    p.add_argument("--batch", type=int, default=128)
    p.add_argument("--quantize", action="store_true", help="int8 weights, float32 input/output (TFLite)")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--verbose", type=int, choices=[0, 1, 2], default=0,
                   help="Keras training output: 2 one line per epoch, 1 progress bar, 0 silent")
    p.add_argument("--quick", action="store_true", help="2 folds, 2 epochs – smoke test only")
    args = p.parse_args()
    if args.quick:
        args.epochs = 2

    cfg = L.TASKS[args.task]
    out_dir = Path(args.out); out_dir.mkdir(parents=True, exist_ok=True)
    L.set_seed(args.seed)

    recs = L.list_recordings(Path(args.data), cfg)
    folds = L.load_folds(recs, args.folds)
    print(f"{cfg.name}: {len(recs)} recordings, folds {sorted(int(f) for f in folds.unique() if f >= 0)}, "
          f"window {cfg.window} ({cfg.window / L.SAMPLING_FREQ:.1f} s), app step {cfg.step}")

    summary = None
    if args.mode in ("cv", "both"):
        summary = run_cv(cfg, recs, folds, args, out_dir)
    if args.mode in ("final", "both"):
        run_final(cfg, recs, folds, args, out_dir, summary)


if __name__ == "__main__":
    main()
