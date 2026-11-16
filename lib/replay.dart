import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'labels.dart';
import 'live.dart';

// Replays recorded RESpeck sessions through the live pipeline at the real
// sampling rate (12.5 Hz). The coursework asks for recorded data to be used
// in the demo for activities that are hard to perform live, such as stairs.
//
// The recordings in assets/demo/ come from the course dataset. The models
// were trained on that dataset, so a replay demonstrates how the app behaves,
// not how accurate it is on new people.

class DemoRecording {
  final String asset;
  // Model class id of what the recording contains
  final String classId;
  const DemoRecording(this.asset, this.classId);
  String get name => classInfo(classId).name;
}

const List<DemoRecording> demoRecordings = [
  DemoRecording('assets/demo/ascending.csv', 'ascending'),
  DemoRecording('assets/demo/descending.csv', 'descending'),
  DemoRecording('assets/demo/running.csv', 'running'),
  DemoRecording('assets/demo/shuffleWalking.csv', 'shuffleWalking'),
  DemoRecording('assets/demo/coughing.csv', 'coughing'),
  DemoRecording('assets/demo/hyperventilation.csv', 'hyperventilation'),
];

// Parse "accelX,accelY,accelZ" CSV text into samples, skipping the header and
// any line that is not three numbers
List<List<double>> parseAccelCsv(String text) {
  final samples = <List<double>>[];
  for (final line in text.split('\n')) {
    final p = line.trim().split(',');
    if (p.length < 3) continue;
    final x = double.tryParse(p[0]);
    final y = double.tryParse(p[1]);
    final z = double.tryParse(p[2]);
    if (x == null || y == null || z == null) continue;
    samples.add([x, y, z]);
  }
  return samples;
}

class ReplayController extends ChangeNotifier {
  // Two samples every 160 ms = 12.5 samples per second, like the RESpeck
  static const int samplesPerTick = 2;
  static const Duration tick = Duration(milliseconds: 160);

  DemoRecording? current;
  List<List<double>> _data = [];
  int position = 0;
  // Start again from the beginning at the end of the recording
  bool loop = true;
  Timer? _timer;

  bool get playing => current != null;
  double get progress => _data.isEmpty ? 0 : position / _data.length;
  double get lengthSeconds => _data.length / 12.5;

  Future<void> play(DemoRecording r) async {
    stop();
    try {
      _data = parseAccelCsv(await rootBundle.loadString(r.asset));
    } catch (e) {
      print("Could not load ${r.asset}: $e");
      return;
    }
    if (_data.isEmpty) return;
    current = r;
    position = 0;
    live.beginReplay(r.name);
    _timer = Timer.periodic(tick, (_) => _tick());
    notifyListeners();
  }

  void _tick() {
    if (position >= _data.length) {
      if (!loop) {
        stop();
        return;
      }
      position = 0;
    }
    final int end = position + samplesPerTick < _data.length
        ? position + samplesPerTick
        : _data.length;
    final chunk = _data.sublist(position, end);
    position = end;
    live.ingest(chunk, receivedAt: DateTime.now(), fromReplay: true);
    notifyListeners();
  }

  void setLoop(bool on) {
    loop = on;
    notifyListeners();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (current != null) {
      current = null;
      live.endReplay();
    }
    notifyListeners();
  }
}

final ReplayController replay = ReplayController();
