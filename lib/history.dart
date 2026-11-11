import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'globals.dart';
import 'har.dart';
import 'labels.dart';

// Stores every classification result so the user can look back at their day
// or week, as the coursework asks ("on October 17 they spent 1 hour walking,
// 10 hours sitting/standing, coughed 30 times").
//
// Storage is one CSV file per day in the app's documents folder:
//   history/2026-11-11.csv
//   timestamp_ms,kind,label,confidence,duration_s,source
// Plain files were chosen over a database because they need no extra
// packages, survive a crash (each line is written straight away), and are
// visible in the iPhone Files app (UIFileSharingEnabled), which makes them
// easy to export and analyse for the report.
//
// Each record covers `duration_s` seconds - the time between two predictions -
// so the time spent in an activity is simply the sum of its durations.

class HistoryRecord {
  final DateTime time;
  final ClassKind kind;
  final String label;
  final double confidence;
  final double durationS;
  // "live" for normal use, "test" while a real-time accuracy trial runs
  final String source;

  const HistoryRecord(this.time, this.kind, this.label, this.confidence,
      this.durationS, this.source);

  String toCsv() =>
      '${time.millisecondsSinceEpoch},${kind.name},$label,${confidence.toStringAsFixed(3)},${durationS.toStringAsFixed(2)},$source';

  static HistoryRecord? fromCsv(String line) {
    final p = line.split(',');
    if (p.length < 6) return null;
    final ms = int.tryParse(p[0]);
    if (ms == null) return null; // header or a corrupt line
    return HistoryRecord(
      DateTime.fromMillisecondsSinceEpoch(ms),
      p[1] == 'social' ? ClassKind.social : ClassKind.activity,
      p[2],
      double.tryParse(p[3]) ?? 0,
      double.tryParse(p[4]) ?? 0,
      p[5],
    );
  }
}

// A stretch of time spent in one activity, for the timeline charts
class Segment {
  final DateTime start;
  final DateTime end;
  final String label;
  const Segment(this.start, this.end, this.label);
}

// Everything the History tab shows for one day
class DaySummary {
  final DateTime day;
  // Seconds per activity / social signal label
  final Map<String, double> activitySeconds;
  final Map<String, double> socialSeconds;
  final int coughEpisodes;
  final int hyperventilationEpisodes;
  final List<Segment> segments;

  const DaySummary(this.day, this.activitySeconds, this.socialSeconds,
      this.coughEpisodes, this.hyperventilationEpisodes, this.segments);

  double get trackedSeconds =>
      activitySeconds.values.fold(0.0, (a, b) => a + b);

  double get stationarySeconds => activitySeconds.entries
      .where((e) => stationaryActivities.contains(e.key))
      .fold(0.0, (a, e) => a + e.value);

  double get activeSeconds => trackedSeconds - stationarySeconds;

  bool get isEmpty => activitySeconds.isEmpty && socialSeconds.isEmpty;
}

// Count episodes of `label`: runs of consecutive predictions with that label.
// A cough lasting 10 s produces about five predictions 2 s apart, but it is
// one episode. Two runs separated by a gap longer than `maxGap` (e.g. the
// person moved, or the sensor disconnected) count separately.
int countEpisodes(List<HistoryRecord> social, String label,
    {Duration maxGap = const Duration(seconds: 6)}) {
  int episodes = 0;
  bool inEpisode = false;
  DateTime? last;
  for (final r in social) {
    final gap = last == null ? Duration.zero : r.time.difference(last);
    if (gap > maxGap) inEpisode = false;
    if (r.label == label) {
      if (!inEpisode) episodes++;
      inEpisode = true;
    } else {
      inEpisode = false;
    }
    last = r.time;
  }
  return episodes;
}

// Merge consecutive activity predictions with the same label into segments.
// Each prediction describes the `durationS` seconds before it.
List<Segment> buildSegments(List<HistoryRecord> activity) {
  final segments = <Segment>[];
  DateTime? start, end;
  String? label;
  for (final r in activity) {
    final rStart =
        r.time.subtract(Duration(milliseconds: (r.durationS * 1000).round()));
    final joins = label == r.label &&
        end != null &&
        rStart.difference(end) <=
            Duration(milliseconds: (r.durationS * 1500).round());
    if (joins) {
      end = r.time;
    } else {
      if (label != null) segments.add(Segment(start!, end!, label));
      start = rStart;
      end = r.time;
      label = r.label;
    }
  }
  if (label != null) segments.add(Segment(start!, end!, label));
  return segments;
}

DaySummary summarise(DateTime day, List<HistoryRecord> records) {
  final activity = <String, double>{};
  final social = <String, double>{};
  final activityRecords = <HistoryRecord>[];
  final socialRecords = <HistoryRecord>[];
  for (final r in records) {
    if (r.kind == ClassKind.activity) {
      activity[r.label] = (activity[r.label] ?? 0) + r.durationS;
      activityRecords.add(r);
    } else {
      social[r.label] = (social[r.label] ?? 0) + r.durationS;
      socialRecords.add(r);
    }
  }
  return DaySummary(
    day,
    activity,
    social,
    countEpisodes(socialRecords, 'coughing'),
    countEpisodes(socialRecords, 'hyperventilation'),
    buildSegments(activityRecords),
  );
}

DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

class HistoryStore extends ChangeNotifier {
  Directory? _dir;
  // Today's records are kept in memory, so the Live and History tabs can show
  // today's totals without re-reading the file every update
  DateTime _today = dayOf(DateTime.now());
  final List<HistoryRecord> today = [];

  bool get available => _dir != null;

  // Today's records. Empty if the app has been open since before midnight
  // and nothing has been recorded since (the list then still holds
  // yesterday until the next record arrives).
  List<HistoryRecord> get todayRecords =>
      dayOf(DateTime.now()) == _today ? today : const <HistoryRecord>[];

  Future<void> init() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/history');
      await dir.create(recursive: true);
      _dir = dir;
      today.addAll(await loadDay(_today));
    } catch (e) {
      print("History storage not available: $e");
    }
  }

  File _fileFor(DateTime day) =>
      File('${_dir!.path}/${DateFormat('yyyy-MM-dd').format(day)}.csv');

  void add(HistoryRecord r) {
    if (_dir == null) return;
    final day = dayOf(r.time);
    if (day != _today) {
      // Midnight passed: start a new day
      _today = day;
      today.clear();
    }
    today.add(r);
    try {
      final f = _fileFor(day);
      if (!f.existsSync()) {
        f.writeAsStringSync(
            'timestamp_ms,kind,label,confidence,duration_s,source\n');
      }
      // A synchronous append keeps the lines in order and means nothing is
      // lost if the app is closed. At one short line every 2 s the cost is
      // negligible.
      f.writeAsStringSync('${r.toCsv()}\n', mode: FileMode.append);
    } catch (e) {
      print("Could not write history: $e");
    }
    notifyListeners();
  }

  Future<List<HistoryRecord>> loadDay(DateTime day) async {
    if (_dir == null) return [];
    if (dayOf(day) == _today && today.isNotEmpty) return List.of(today);
    final f = _fileFor(day);
    if (!await f.exists()) return [];
    final lines = await f.readAsLines();
    return lines.map(HistoryRecord.fromCsv).whereType<HistoryRecord>().toList();
  }

  Future<DaySummary> summaryFor(DateTime day) async =>
      summarise(dayOf(day), await loadDay(day));

  // Summaries for the 7 days ending on `lastDay`, oldest first
  Future<List<DaySummary>> weekEnding(DateTime lastDay) async {
    final end = dayOf(lastDay);
    return [
      for (int i = 6; i >= 0; i--)
        await summaryFor(DateTime(end.year, end.month, end.day - i)),
    ];
  }

  // Write all history into one CSV in the exports folder (visible in the
  // Files app on iPhone, Downloads on Android). Returns the file, or null if
  // there is nothing to export.
  Future<File?> exportAll() async {
    if (_dir == null || storageFolder == null) return null;
    final files = (await _dir!.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.csv'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) return null;
    final out = StringBuffer(
        'timestamp_ms,datetime,kind,label,confidence,duration_s,source\n');
    for (final f in files) {
      for (final line in await f.readAsLines()) {
        final r = HistoryRecord.fromCsv(line);
        if (r == null) continue;
        out.writeln('${r.time.millisecondsSinceEpoch},'
            '${r.time.toIso8601String()},${r.kind.name},${r.label},'
            '${r.confidence.toStringAsFixed(3)},${r.durationS},${r.source}');
      }
    }
    final stamp = DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now());
    final file = File('${storageFolder!.path}/PDIoT_history_$stamp.csv');
    await file.writeAsString(out.toString());
    return file;
  }

  Future<void> clear() async {
    today.clear();
    try {
      if (_dir != null && await _dir!.exists()) {
        await _dir!.delete(recursive: true);
        await _dir!.create(recursive: true);
      }
    } catch (e) {
      print("Could not clear history: $e");
    }
    notifyListeners();
  }
}

final HistoryStore history = HistoryStore();
