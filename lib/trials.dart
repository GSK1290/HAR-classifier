import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'app_settings.dart';
import 'globals.dart';
import 'har.dart';
import 'labels.dart';
import 'live.dart';
import 'utils.dart';

// Real-time accuracy testing (the "Real-time classification accuracy" section
// of the report).
//
// Protocol built into the app:
//  1. Choose the participant and the activity / social signal they will do.
//  2. A 3 s countdown, then the trial runs for a fixed time (30 s default).
//  3. Every prediction shown during the trial is logged with its time.
//  4. Predictions made before one full window of trial data exists (4 s for
//     activities, 10 s for social signals) are logged but not counted: their
//     window still contains what the person was doing before the trial, so
//     they measure lag rather than accuracy.
//  5. Prediction accuracy = counted predictions shown correctly / counted.
//     A trial is "correct" if the majority of its counted predictions were.
//  6. Time to correct = seconds from the start until the first correct result
//     appeared on screen, i.e. the user-visible latency.
// Judging is done on what the screen showed. A social result hidden because
// the person was not judged stationary counts as wrong ("paused").

class TrialPrediction {
  final double t; // seconds since the trial started
  final String raw;
  final double rawConfidence;
  final String shown;
  final double shownConfidence;
  final bool counted;

  const TrialPrediction(this.t, this.raw, this.rawConfidence, this.shown,
      this.shownConfidence, this.counted);

  Map<String, dynamic> toJson() => {
        't': t,
        'raw': raw,
        'rawConf': rawConfidence,
        'shown': shown,
        'shownConf': shownConfidence,
        'counted': counted,
      };

  factory TrialPrediction.fromJson(Map<String, dynamic> j) => TrialPrediction(
        (j['t'] as num).toDouble(),
        j['raw'] as String,
        (j['rawConf'] as num).toDouble(),
        j['shown'] as String,
        (j['shownConf'] as num).toDouble(),
        j['counted'] as bool,
      );
}

class Trial {
  final String participant;
  final String trueLabel;
  final DateTime start;
  final int durationS;
  final bool fromReplay;
  final bool smoothing;
  final List<TrialPrediction> predictions;

  const Trial(this.participant, this.trueLabel, this.start, this.durationS,
      this.fromReplay, this.smoothing, this.predictions);

  ClassKind get kind => classInfo(trueLabel).kind;

  List<TrialPrediction> get counted =>
      predictions.where((p) => p.counted).toList();

  int get correct => counted.where((p) => p.shown == trueLabel).length;

  double get accuracy => counted.isEmpty ? 0 : correct / counted.length;

  // Most common label shown among the counted predictions
  String? get majorityLabel {
    final c = counted;
    if (c.isEmpty) return null;
    final counts = <String, int>{};
    for (final p in c) {
      counts[p.shown] = (counts[p.shown] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  bool get majorityCorrect => majorityLabel == trueLabel;

  double? get timeToCorrectS {
    for (final p in predictions) {
      if (p.shown == trueLabel) return p.t;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'participant': participant,
        'trueLabel': trueLabel,
        'start': start.millisecondsSinceEpoch,
        'durationS': durationS,
        'fromReplay': fromReplay,
        'smoothing': smoothing,
        'predictions': [for (final p in predictions) p.toJson()],
      };

  factory Trial.fromJson(Map<String, dynamic> j) => Trial(
        j['participant'] as String,
        j['trueLabel'] as String,
        DateTime.fromMillisecondsSinceEpoch(j['start'] as int),
        j['durationS'] as int,
        j['fromReplay'] as bool? ?? false,
        j['smoothing'] as bool? ?? false,
        [
          for (final p in j['predictions'] as List)
            TrialPrediction.fromJson(p as Map<String, dynamic>)
        ],
      );
}

// Aggregate results for one class across all its trials
class ClassResult {
  final String label;
  int trials = 0;
  int majorityCorrect = 0;
  int counted = 0;
  int correct = 0;
  final List<double> timesToCorrect = [];
  ClassResult(this.label);

  double get accuracy => counted == 0 ? 0 : correct / counted;
  double? get meanTimeToCorrect => timesToCorrect.isEmpty
      ? null
      : timesToCorrect.reduce((a, b) => a + b) / timesToCorrect.length;
}

enum TrialPhase { idle, countdown, running }

class TestSession extends ChangeNotifier {
  TrialPhase phase = TrialPhase.idle;
  String participant = '';
  String trueLabel = 'sittingStanding';
  int trialSeconds = 30;
  int countdown = 0;
  // Leave out trials made with replayed data from the totals
  bool includeReplay = false;

  final List<Trial> trials = [];
  final List<TrialPrediction> current = [];
  DateTime? _start;
  Timer? _timer;
  StreamSubscription<PredictionEvent>? _sub;
  File? _file;

  ClassKind get kind => classInfo(trueLabel).kind;

  double get elapsedS => _start == null
      ? 0
      : DateTime.now().difference(_start!).inMilliseconds / 1000.0;

  double get windowSeconds => kind == ClassKind.activity
      ? (harClassifier?.windowSeconds ?? 4)
      : (socialClassifier?.windowSeconds ?? 10);

  Future<void> init() async {
    participant = subjectID ?? '';
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/tests');
      await dir.create(recursive: true);
      _file = File('${dir.path}/trials.jsonl');
      if (await _file!.exists()) {
        for (final line in await _file!.readAsLines()) {
          if (line.trim().isEmpty) continue;
          try {
            trials.add(Trial.fromJson(jsonDecode(line)));
          } catch (e) {
            print("Skipping unreadable trial: $e");
          }
        }
      }
    } catch (e) {
      print("Trial storage not available: $e");
    }
  }

  void setParticipant(String p) {
    participant = p;
    notifyListeners();
  }

  void setTrueLabel(String l) {
    trueLabel = l;
    notifyListeners();
  }

  void setTrialSeconds(int s) {
    trialSeconds = s;
    notifyListeners();
  }

  void setIncludeReplay(bool on) {
    includeReplay = on;
    notifyListeners();
  }

  void start() {
    if (phase != TrialPhase.idle) return;
    if (live.link != LinkState.connected && !live.replaying) {
      showToast("Connect the RESpeck first");
      return;
    }
    if (participant.trim().isEmpty) {
      showToast("Enter the participant's name or ID");
      return;
    }
    phase = TrialPhase.countdown;
    countdown = 3;
    HapticFeedback.selectionClick();
    notifyListeners();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      countdown--;
      if (countdown <= 0) {
        t.cancel();
        _begin();
      } else {
        HapticFeedback.selectionClick();
      }
      notifyListeners();
    });
  }

  void _begin() {
    phase = TrialPhase.running;
    _start = DateTime.now();
    current.clear();
    live.historySource = 'test';
    HapticFeedback.heavyImpact();
    final window = windowSeconds;
    final wantedKind = kind;
    _sub = live.events.where((e) => e.kind == wantedKind).listen((e) {
      final start = _start;
      if (start == null) return;
      final t = e.at.difference(start).inMilliseconds / 1000.0;
      if (t < 0) return;
      current.add(TrialPrediction(t, e.rawLabel, e.rawConfidence,
          e.shownLabel, e.shownConfidence, t >= window));
      notifyListeners();
    });
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (elapsedS >= trialSeconds) {
        _finish();
      } else {
        notifyListeners();
      }
    });
  }

  void _finish() {
    final start = _start;
    _stopRunning();
    if (start == null) return;
    final trial = Trial(participant.trim(), trueLabel, start, trialSeconds,
        live.replaying, appSettings.smoothing, List.of(current));
    trials.add(trial);
    _append(trial);
    HapticFeedback.heavyImpact();
    showToast(
        "Trial saved: ${trial.correct}/${trial.counted.length} correct");
    notifyListeners();
  }

  void cancel() {
    _stopRunning();
    notifyListeners();
  }

  void _stopRunning() {
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
    _start = null;
    phase = TrialPhase.idle;
    live.historySource = 'live';
  }

  void _append(Trial t) {
    try {
      _file?.writeAsStringSync('${jsonEncode(t.toJson())}\n',
          mode: FileMode.append);
    } catch (e) {
      print("Could not save trial: $e");
    }
  }

  void _rewrite() {
    try {
      _file?.writeAsStringSync(
          trials.map((t) => '${jsonEncode(t.toJson())}\n').join());
    } catch (e) {
      print("Could not save trials: $e");
    }
  }

  void deleteTrial(Trial t) {
    trials.remove(t);
    _rewrite();
    notifyListeners();
  }

  void clear() {
    trials.clear();
    _rewrite();
    notifyListeners();
  }

  List<Trial> get scoredTrials =>
      trials.where((t) => includeReplay || !t.fromReplay).toList();

  // Per-class results, in the order the classes are listed in the app
  List<ClassResult> byClass() {
    final results = <String, ClassResult>{};
    for (final t in scoredTrials) {
      final r = results.putIfAbsent(t.trueLabel, () => ClassResult(t.trueLabel));
      r.trials++;
      if (t.majorityCorrect) r.majorityCorrect++;
      r.counted += t.counted.length;
      r.correct += t.correct;
      final ttc = t.timeToCorrectS;
      if (ttc != null) r.timesToCorrect.add(ttc);
    }
    return [
      for (final c in [...activityClasses, ...socialClasses])
        if (results.containsKey(c.id)) results[c.id]!
    ];
  }

  // Accuracy over all counted predictions of one kind
  double? predictionAccuracy(ClassKind k) {
    int counted = 0, correct = 0;
    for (final t in scoredTrials.where((t) => t.kind == k)) {
      counted += t.counted.length;
      correct += t.correct;
    }
    return counted == 0 ? null : correct / counted;
  }

  // Share of trials of one kind whose majority label was right
  double? trialAccuracy(ClassKind k) {
    final ts = scoredTrials.where((t) => t.kind == k).toList();
    if (ts.isEmpty) return null;
    return ts.where((t) => t.majorityCorrect).length / ts.length;
  }

  // Write two CSVs for the report: one row per trial, and one row per
  // prediction (for confusion matrices and latency plots)
  Future<List<File>> export() async {
    if (storageFolder == null || trials.isEmpty) return [];
    final stamp = DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now());
    final summary = StringBuffer(
        'trial,participant,true_label,kind,start,duration_s,from_replay,smoothing,'
        'counted,correct,accuracy,majority_label,majority_correct,time_to_correct_s\n');
    final preds = StringBuffer(
        'trial,participant,true_label,t_s,raw_label,raw_confidence,shown_label,shown_confidence,counted\n');
    for (int i = 0; i < trials.length; i++) {
      final t = trials[i];
      summary.writeln('${i + 1},${t.participant},${t.trueLabel},${t.kind.name},'
          '${t.start.toIso8601String()},${t.durationS},${t.fromReplay},${t.smoothing},'
          '${t.counted.length},${t.correct},${t.accuracy.toStringAsFixed(3)},'
          '${t.majorityLabel ?? ''},${t.majorityCorrect},'
          '${t.timeToCorrectS?.toStringAsFixed(2) ?? ''}');
      for (final p in t.predictions) {
        preds.writeln('${i + 1},${t.participant},${t.trueLabel},'
            '${p.t.toStringAsFixed(2)},${p.raw},${p.rawConfidence.toStringAsFixed(3)},'
            '${p.shown},${p.shownConfidence.toStringAsFixed(3)},${p.counted}');
      }
    }
    final a = File('${storageFolder!.path}/PDIoT_trials_$stamp.csv');
    final b = File('${storageFolder!.path}/PDIoT_trial_predictions_$stamp.csv');
    await a.writeAsString(summary.toString());
    await b.writeAsString(preds.toString());
    return [a, b];
  }
}

final TestSession testSession = TestSession();
