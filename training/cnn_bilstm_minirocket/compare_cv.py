"""
Compare cross-validation results of several models on the same folds.

  python compare_cv.py --task social --models minirocket bilstm

Reads cw3_out/<task>_<model>_cv.json (written by `run_cw3.py --mode cv`), checks that all models
used the same folds, and prints / saves:
  * per-class accuracy (mean ± std over folds)
  * group means (the CW3 metric), calibrated and uncalibrated
  * the group mean per fold
  * pairwise paired tests over folds (t-test and Wilcoxon signed-rank)
  * the summed confusion matrices
Output: cw3_out/<task>_cv_comparison.json and .md
"""
import argparse
import itertools
import json
from pathlib import Path

import numpy as np
from scipy import stats

import cw3lib as L


def fold_group_means(cv: dict, cfg, key="per_fold_class_accuracy") -> dict:
    A = np.array(cv[key], dtype=float)                      # (folds, classes)
    out = {}
    for g, members in cfg.groups.items():
        idx = [cfg.classes.index(c) for c in members]
        out[g] = np.nanmean(A[:, idx], axis=1)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--task", choices=list(L.TASKS), default="social")
    ap.add_argument("--models", nargs="+", default=["minirocket", "bilstm"])
    ap.add_argument("--out", default="cw3_out")
    args = ap.parse_args()
    cfg, out = L.TASKS[args.task], Path(args.out)

    cvs = {}
    for m in args.models:
        f = out / f"{cfg.name}_{m}_cv.json"
        if not f.exists():
            print(f"!! missing {f} – run: python run_cw3.py --task {args.task} --mode cv --model {m} --folds ...")
            continue
        cvs[m] = json.loads(f.read_text())
    if len(cvs) < 1:
        raise SystemExit("nothing to compare")
    folds = {m: tuple(cv["folds"]) for m, cv in cvs.items()}
    if len(set(folds.values())) > 1:
        raise SystemExit(f"models were cross-validated on different folds: {folds}")
    fold_ids = list(next(iter(folds.values())))
    models = list(cvs)
    md, res = [], {"task": cfg.name, "folds": fold_ids, "models": {}, "pairwise": {}}
    w = max(18, *(len(m) + 2 for m in models))

    def line(s=""):
        print(s); md.append(s)

    line(f"# {cfg.name}: {len(fold_ids)}-fold CV comparison (folds {fold_ids})\n")
    line("## Per-class accuracy (mean ± std over folds)\n")
    line("| class | " + " | ".join(models) + " |")
    line("|---|" + "---|" * len(models))
    for c in cfg.classes:
        line(f"| {c} | " + " | ".join(f"{cvs[m]['per_class'][c]['mean']:.3f} ± {cvs[m]['per_class'][c]['std']:.3f}"
                                     for m in models) + " |")
    for g in cfg.groups:
        line(f"| **{g} (CW3 metric)** | " + " | ".join(
            f"**{cvs[m]['groups'][g]['mean']:.3f} ± {cvs[m]['groups'][g]['std']:.3f}**" for m in models) + " |")
        line(f"| {g} uncalibrated | " + " | ".join(
            f"{cvs[m]['uncalibrated'][g]['mean']:.3f}" if cvs[m].get("uncalibrated") else "–" for m in models) + " |")

    per_fold = {m: fold_group_means(cvs[m], cfg) for m in models}
    for g in cfg.groups:
        line(f"\n## {g} group mean per fold\n")
        line("| fold | " + " | ".join(models) + " |")
        line("|---|" + "---|" * len(models))
        for i, k in enumerate(fold_ids):
            line(f"| {k} | " + " | ".join(f"{per_fold[m][g][i]:.3f}" for m in models) + " |")

        if len(models) > 1:
            line(f"\n## Pairwise paired tests on the {g} group mean (n = {len(fold_ids)} folds)\n")
            line("| A vs B | mean diff (A−B) | A wins | t-test p | Wilcoxon p |")
            line("|---|---|---|---|---|")
            for a, b in itertools.combinations(models, 2):
                d = per_fold[a][g] - per_fold[b][g]
                t_p = float(stats.ttest_rel(per_fold[a][g], per_fold[b][g]).pvalue)
                try:
                    w_p = float(stats.wilcoxon(d).pvalue)
                except ValueError:                            # all differences zero
                    w_p = float("nan")
                res["pairwise"][f"{a}_vs_{b}_{g}"] = {"mean_diff": float(d.mean()), "std_diff": float(d.std()),
                                                     "a_wins": int((d > 0).sum()), "t_test_p": t_p,
                                                     "wilcoxon_p": w_p}
                line(f"| {a} vs {b} | {d.mean():+.3f} ± {d.std():.3f} | {(d > 0).sum()}/{len(d)} "
                     f"| {t_p:.3g} | {w_p:.3g} |")

    line("\n## Summed confusion matrices (rows = true, cols = predicted)\n")
    for m in models:
        cm = np.array(cvs[m]["confusion_matrix_summed"])
        line(f"**{m}**\n")
        line("| true \\ pred | " + " | ".join(c[:12] for c in cfg.classes) + " |")
        line("|---|" + "---|" * len(cfg.classes))
        for c, row in zip(cfg.classes, cm):
            line(f"| {c} | " + " | ".join(str(v) for v in row) + " |")
        line()

    for m in models:
        res["models"][m] = {"per_class": cvs[m]["per_class"], "groups": cvs[m]["groups"],
                            "uncalibrated": cvs[m].get("uncalibrated"),
                            "per_fold_group_mean": {g: v.round(4).tolist() for g, v in per_fold[m].items()},
                            "best_epochs": cvs[m].get("best_epochs")}
    (out / f"{cfg.name}_cv_comparison.json").write_text(json.dumps(res, indent=2))
    (out / f"{cfg.name}_cv_comparison.md").write_text("\n".join(md), encoding="utf-8")
    print(f"\nsaved {out / (cfg.name + '_cv_comparison.json')} and .md")


if __name__ == "__main__":
    main()
