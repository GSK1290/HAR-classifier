"""
Accuracy check of the exported Hybrid .tflite models on the held-out fold (fold 0).

    python eval_cw3.py --task har
    python eval_cw3.py --task social --models /content/drive/MyDrive/cw3_models

No training: it only runs the exported model, so it takes a few minutes.
train_cw3.py trained on folds 1-9 and used fold 0 only to decide when to stop, so these
subjects were not trained on. The result is slightly optimistic (fold 0 chose the stopping
point) and comes from one fold only.
"""
import argparse, json
from pathlib import Path
import numpy as np, pandas as pd, tensorflow as tf
from train_cw3 import TASKS, load_task

p = argparse.ArgumentParser()
p.add_argument("--task", choices=list(TASKS), required=True)
p.add_argument("--data", type=Path, default=Path("datasetJan2026"))
p.add_argument("--models", type=Path, default=Path("lab3_models"))
args = p.parse_args()

cfg = TASKS[args.task]
meta = json.loads((args.models / f"{cfg['name']}_meta.json").read_text())
classes = meta["output"]["classes"]
assert classes == cfg["classes"] and meta["window_samples"] == cfg["window"], "model and script settings differ"

X, y, fold = load_task(args.data, cfg)
X, y = X[fold == 0], y[fold == 0]

interp = tf.lite.Interpreter(model_path=str(args.models / f"{cfg['name']}.tflite"))
inp, out = interp.get_input_details()[0], interp.get_output_details()[0]
interp.resize_tensor_input(inp["index"], [1, cfg["window"], 3]); interp.allocate_tensors()
pred = []
for w in X:                                   # one window at a time, exactly like the app
    interp.set_tensor(inp["index"], w[np.newaxis]); interp.invoke()
    pred.append(int(interp.get_tensor(out["index"])[0].argmax()))
pred = np.array(pred)

cm = pd.crosstab(pd.Categorical.from_codes(y, classes), pd.Categorical.from_codes(pred, classes),
                 dropna=False, rownames=["true"], colnames=["predicted"])
acc = pd.Series(np.diag(cm) / cm.sum(axis=1).to_numpy(), index=classes)
print(f"\n{cfg['name']}.tflite on {len(X)} windows from held-out fold 0")
print("\nAccuracy per class:"); print(acc.round(3).to_string())
print(f"\nMean of class accuracies: {acc.mean():.3f}   |   weakest: {acc.idxmin()} {acc.min():.3f}")
print("\nConfusion matrix (rows = true class, columns = predicted):"); print(cm.to_string())
cm.to_csv(args.models / f"confusion_{args.task}_fold0.csv")
