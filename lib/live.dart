import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'app_settings.dart';
import 'ble.dart';
import 'globals.dart';
import 'har.dart';
import 'history.dart';
import 'labels.dart';
import 'recorder.dart';
import 'utils.dart';

// The live state of the app, shared by every tab.
//
// Data flow:
//   ble.dart (RESpeck packets) ─┐
//                               ├─> LiveSession.ingest() ─> both classifiers
//   replay.dart (recorded CSV) ─┘        │
//                                        ├─> smoothing, stationary gating
//                                        ├─> history (stored results)
//                                        ├─> events (Test tab trials)
//                                        └─> notifyListeners() (UI)
//
// Live and replayed data go through exactly the same code, so a replay shows
// what the app would do with that movement live.

enum LinkState { disconnected, scanning, connecting, connected }

// A result as shown on screen (after optional smoothing)
class ShownPrediction {
  final String label;
  final double confidence;
  final DateTime at;
  const ShownPrediction(this.label, this.confidence, this.at);
}

// Published for every new prediction, for the Test tab's accuracy trials
class PredictionEvent {
  final ClassKind kind;
  final DateTime at;
  // The model's own output for this window
  final String rawLabel;
  final double rawConfidence;
  // What the screen showed. For social signals this is "paused" when the
  // result was hidden because the person was not stationary.
  final String shownLabel;
  final double shownConfidence;
  final bool fromReplay;
  const PredictionEvent(this.kind, this.at, this.rawLabel, this.rawConfidence,
      this.shownLabel, this.shownConfidence, this.fromReplay);
}

// Majority vote over recent predictions (oldest first, not empty). A tie goes
// to the most recent of the tied labels. The confidence is the mean
// confidence of the winning label's predictions.
HarPrediction majorityVote(List<HarPrediction> recent) {
  final counts = <String, int>{};
  for (final p in recent) {
    counts[p.label] = (counts[p.label] ?? 0) + 1;
  }
  final best = counts.values.reduce(math.max);
  final label =
      recent.reversed.firstWhere((p) => counts[p.label] == best).label;
  final confs =
      recent.where((p) => p.label == label).map((p) => p.confidence).toList();
  return HarPrediction(label, confs.reduce((a, b) => a + b) / confs.length);
}

// Rolling statistics over the most recent values of a measurement
class Stat {
  static const int keep = 500;
  final List<double> _values = [];

  void add(double v) {
    _values.add(v);
    if (_values.length > keep) _values.removeAt(0);
  }

  int get count => _values.length;
  double? get last => _values.isEmpty ? null : _values.last;
  double? get mean => _values.isEmpty
      ? null
      : _values.reduce((a, b) => a + b) / _values.length;

  double? percentile(double p) {
    if (_values.isEmpty) return null;
    final sorted = List.of(_values)..sort();
    return sorted[((sorted.length - 1) * p).round()];
  }

  void clear() => _values.clear();
}

// One activity prediction in the "last 5 minutes" strip
class TimelineEntry {
  final DateTime at;
  final String label;
  final double durationS;
  const TimelineEntry(this.at, this.label, this.durationS);
}

class LiveSession extends ChangeNotifier {
  // ---- Connection ----
  LinkState link = LinkState.disconnected;
  int? battery;
  bool charging = false;
  DateTime? lastPacketAt;
  int packets = 0;
  int droppedPackets = 0;
  int? _lastSeq;

  // ---- Latest sensor values ----
  double x = 0, y = 0, z = 0;
  // The last 100 samples (8 s), for the live acceleration plot
  final List<List<double>> trace = [];

  // ---- Predictions ----
  ShownPrediction? activity;
  DateTime? activitySince; // when the shown activity last changed
  ShownPrediction? social;
  DateTime? socialSince;
  // Estimated start of the current stationary period (null while moving)
  DateTime? stationarySince;
  final List<TimelineEntry> recent = [];
  final List<HarPrediction> _harRecent = [];
  final List<HarPrediction> _socialRecent = [];

  // Source tag written to history: "live", or "test" during a trial
  String historySource = 'live';

  // ---- Replay ----
  // Name of the recording being replayed, or null for live data
  String? replayName;
  bool get replaying => replayName != null;

  // ---- Reminders ----
  String? reminder;
  final List<DateTime> _coughStarts = [];
  DateTime? _inactivityRemindedFor;
  DateTime? _coughAlertAt;

  // ---- Performance ----
  final Stat harInferenceMs = Stat();
  final Stat socialInferenceMs = Stat();
  // From the packet arriving on the phone to the new result being drawn
  final Stat packetToScreenMs = Stat();
  final List<String> _perfLog = [];

  final StreamController<PredictionEvent> _events =
      StreamController<PredictionEvent>.broadcast();
  Stream<PredictionEvent> get events => _events.stream;

  // True when the latest activity is one of the static postures
  bool get isStationary =>
      activity != null && stationaryActivities.contains(activity!.label);

  // Seconds of stillness needed before a social result can be trusted: the
  // whole social window must have been recorded while stationary
  double get socialWindowSeconds => socialClassifier?.windowSeconds ?? 10;

  // True when the latest social result was computed entirely from data
  // recorded while stationary, i.e. it is safe to show and store
  bool get socialClean {
    final s = social;
    final since = stationarySince;
    if (s == null || since == null || !isStationary) return false;
    final needed =
        since.add(Duration(milliseconds: (socialWindowSeconds * 1000).round()));
    return !s.at.isBefore(needed);
  }

  // How far the "resuming" period after the person stops moving has got,
  // from 0 to 1
  double get socialResumeProgress {
    final since = stationarySince;
    if (since == null) return 0;
    final s = DateTime.now().difference(since).inMilliseconds / 1000.0;
    return (s / socialWindowSeconds).clamp(0.0, 1.0);
  }

  // ---- Called by ble.dart ----

  void onConnected() {
    link = LinkState.connected;
    _lastSeq = null;
    notifyListeners();
  }

  void onDisconnected() {
    // The connection listener reports "disconnected" once when it is first
    // attached, while a connection attempt is still under way. Only a drop
    // from the connected state is a real disconnect.
    if (link == LinkState.connected) link = LinkState.disconnected;
    lastPacketAt = null;
    battery = null;
    if (!replaying) _resetPipeline();
    notifyListeners();
  }

  // Bookkeeping for one BLE packet, before its samples are ingested
  void onPacket(
      {required DateTime receivedAt,
      required int seq,
      int? batteryLevel,
      bool isCharging = false}) {
    lastPacketAt = receivedAt;
    packets++;
    final last = _lastSeq;
    if (last != null) {
      // The 16 bit sequence number wraps round; a gap means lost packets
      final gap = (seq - last - 1) & 0xFFFF;
      if (gap > 0 && gap < 1000) droppedPackets += gap;
    }
    _lastSeq = seq;
    battery = batteryLevel;
    charging = isCharging;
  }

  // Feed samples ([x, y, z] in g) to both classifiers and update the state.
  // Called once per BLE packet, or once per replay tick with fromReplay set.
  void ingest(List<List<double>> samples,
      {required DateTime receivedAt, bool fromReplay = false}) {
    // While a recording is replayed, live packets are ignored (and the other
    // way round), so the two streams never mix in one window
    if (fromReplay != replaying || samples.isEmpty) return;

    HarPrediction? act;
    HarPrediction? soc;
    for (final s in samples) {
      act = harClassifier?.addSample(s[0], s[1], s[2]) ?? act;
      soc = socialClassifier?.addSample(s[0], s[1], s[2]) ?? soc;
      trace.add(s);
    }
    if (trace.length > 100) trace.removeRange(0, trace.length - 100);
    x = samples.last[0];
    y = samples.last[1];
    z = samples.last[2];

    if (act != null) _onActivity(act, receivedAt, fromReplay);
    if (soc != null) _onSocial(soc, receivedAt, fromReplay);
    _checkReminders(receivedAt);

    notifyListeners();
    if (act != null || soc != null) _measureScreenLatency(receivedAt);
  }

  void _onActivity(HarPrediction p, DateTime at, bool fromReplay) {
    final h = harClassifier!;
    harInferenceMs.add(h.lastInferenceMs);
    _log(at, 'activity_inference_ms', h.lastInferenceMs);

    _harRecent.add(p);
    if (_harRecent.length > 3) _harRecent.removeAt(0);
    final shown = appSettings.smoothing ? majorityVote(_harRecent) : p;

    final previous = activity?.label;
    final wasStationary = isStationary;
    activity = ShownPrediction(shown.label, shown.confidence, at);
    if (previous != shown.label) activitySince = at;

    if (isStationary && !wasStationary) {
      // The label flips once about half the window shows the new posture,
      // so stillness started roughly half a window ago (a whole window for
      // the very first prediction)
      final back = previous == null ? h.windowSeconds : h.windowSeconds / 2;
      stationarySince =
          at.subtract(Duration(milliseconds: (back * 1000).round()));
    } else if (!isStationary) {
      stationarySince = null;
    }

    recent.add(TimelineEntry(at, shown.label, h.stepSeconds));
    recent.removeWhere((e) => at.difference(e.at) > const Duration(minutes: 5));

    if (!fromReplay) {
      history.add(HistoryRecord(at, ClassKind.activity, shown.label,
          shown.confidence, h.stepSeconds, historySource));
    }
    _events.add(PredictionEvent(ClassKind.activity, at, p.label, p.confidence,
        shown.label, shown.confidence, fromReplay));
  }

  void _onSocial(HarPrediction p, DateTime at, bool fromReplay) {
    final s = socialClassifier!;
    socialInferenceMs.add(s.lastInferenceMs);
    _log(at, 'social_inference_ms', s.lastInferenceMs);

    _socialRecent.add(p);
    if (_socialRecent.length > 3) _socialRecent.removeAt(0);
    final shown = appSettings.smoothing ? majorityVote(_socialRecent) : p;

    final previous = social?.label;
    final wasClean = socialClean;
    social = ShownPrediction(shown.label, shown.confidence, at);
    if (previous != shown.label) socialSince = at;

    final clean = socialClean;
    if (clean && !fromReplay) {
      history.add(HistoryRecord(at, ClassKind.social, shown.label,
          shown.confidence, s.stepSeconds, historySource));
    }
    // A new cough episode, for the frequent-coughing alert
    if (clean &&
        shown.label == 'coughing' &&
        !(wasClean && previous == 'coughing')) {
      _coughStarts.add(at);
    }
    _events.add(PredictionEvent(ClassKind.social, at, p.label, p.confidence,
        clean ? shown.label : 'paused', clean ? shown.confidence : 0,
        fromReplay));
  }

  void _checkReminders(DateTime now) {
    if (replaying) return;
    final minutes = appSettings.inactivityMinutes;
    final since = stationarySince;
    if (minutes > 0 &&
        since != null &&
        _inactivityRemindedFor != since &&
        now.difference(since) >= Duration(minutes: minutes)) {
      _inactivityRemindedFor = since;
      _remind("You've been still for $minutes minutes. "
          "Time to get up and move!");
    }
    _coughStarts
        .removeWhere((t) => now.difference(t) > const Duration(minutes: 10));
    final alertAt = _coughAlertAt;
    if (_coughStarts.length >= 3 &&
        (alertAt == null ||
            now.difference(alertAt) > const Duration(minutes: 10))) {
      _coughAlertAt = now;
      _remind("Frequent coughing: ${_coughStarts.length} episodes "
          "in the last 10 minutes.");
    }
  }

  void _remind(String message) {
    reminder = message;
    HapticFeedback.mediumImpact();
  }

  void dismissReminder() {
    reminder = null;
    notifyListeners();
  }

  // Time from the packet arriving to the frame that shows its result
  void _measureScreenLatency(DateTime receivedAt) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final ms = DateTime.now().difference(receivedAt).inMicroseconds / 1000.0;
      packetToScreenMs.add(ms);
      _log(receivedAt, 'packet_to_screen_ms', ms);
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _log(DateTime at, String metric, double value) {
    if (_perfLog.length >= 50000) _perfLog.removeAt(0);
    _perfLog.add('${at.toIso8601String()},$metric,${value.toStringAsFixed(3)}');
  }

  void resetPerformance() {
    harInferenceMs.clear();
    socialInferenceMs.clear();
    packetToScreenMs.clear();
    _perfLog.clear();
    packets = 0;
    droppedPackets = 0;
    notifyListeners();
  }

  // Write every logged measurement to a CSV for the report's graphs
  Future<File?> exportPerformance() async {
    if (storageFolder == null || _perfLog.isEmpty) return null;
    final stamp = DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now());
    final file = File('${storageFolder!.path}/PDIoT_performance_$stamp.csv');
    await file.writeAsString(
        'timestamp,metric,value\n${_perfLog.join('\n')}\n');
    return file;
  }

  // ---- Replay ----

  void beginReplay(String name) {
    replayName = name;
    _resetPipeline();
    notifyListeners();
  }

  void endReplay() {
    replayName = null;
    _resetPipeline();
    notifyListeners();
  }

  // Forget all buffered data and results, so the next window starts clean
  void _resetPipeline() {
    harClassifier?.reset();
    socialClassifier?.reset();
    _harRecent.clear();
    _socialRecent.clear();
    activity = null;
    activitySince = null;
    social = null;
    socialSince = null;
    stationarySince = null;
    recent.clear();
    trace.clear();
  }

  // ---- Connecting ----

  Future<void> connect() async {
    if (respeckUUID == null || respeckUUID!.isEmpty) {
      showToast("Pair a RESpeck in Settings first");
      return;
    }
    if (link == LinkState.scanning || link == LinkState.connecting) return;
    if (respeckConnected) {
      showToast("Already connected");
      return;
    }

    bool ok = false;
    link = LinkState.scanning;
    notifyListeners();
    try {
      await scanForRespeck();
      if (respeck == null) {
        showLongToast("RESpeck $respeckUUID not found - is it awake?");
        return;
      }
      link = LinkState.connecting;
      notifyListeners();
      await connectToRespeck();
      ok = true;
    } catch (e) {
      print("Connect failed: $e");
      showLongToast("Could not connect to the RESpeck");
    } finally {
      // On success the connection listener sets the state to connected
      if (!ok && link != LinkState.connected) link = LinkState.disconnected;
      notifyListeners();
    }
  }

  Future<void> disconnectSensor() async {
    // Close a running recording properly first, so its state and file agree
    await recorder.stop(message: "Disconnected - recording stopped");
    try {
      await disconnect();
    } catch (e) {
      print("Disconnect failed: $e");
    }
    link = LinkState.disconnected;
    lastPacketAt = null;
    battery = null;
    if (!replaying) _resetPipeline();
    notifyListeners();
  }
}

final LiveSession live = LiveSession();
