# Model training code

The Python code that made the models in `assets/models/`.

| App model | Code |
|---|---|
| Hybrid: activity (`har_hybrid`) and social (`social_hybrid`) | `hybrid/` |
| CNN + BiLSTM (`social_bilstm`) and MiniRocket (`social_minirocket`) | `cnn_bilstm_minirocket/` |

## Setup

```
pip install tensorflow pandas scikit-learn scipy
```

Put the dataset folder `datasetJan2026/` (not included) inside the folder you run from.

## Hybrid

Trains on folds 1–9 and tests on fold 0.

```
cd hybrid
python train_cw3.py --task har        # train + export har_hybrid
python train_cw3.py --task social     # train + export social_hybrid
python eval_cw3.py  --task har        # accuracy on fold 0
python eval_cw3.py  --task social
```

The models are saved in `lab3_models/`.

## CNN + BiLSTM and MiniRocket

Runs a 10-fold cross-validation on the official folds, then trains the final model on all folds.

```
cd cnn_bilstm_minirocket
python run_cw3.py --mode both --model bilstm     --folds folds/folds_social_signal.csv
python run_cw3.py --mode both --model minirocket --folds folds/folds_social_signal.csv
python compare_cv.py --task social --models minirocket bilstm    # compare the two
```

The models and results are saved in `cw3_out/`.

## Using a new model in the app

Copy its `.tflite`, `_meta.json` and `_example.json` files into `assets/models/`.
