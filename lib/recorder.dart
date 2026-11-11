import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'globals.dart';
import 'live.dart';
import 'utils.dart';

// Records raw RESpeck data to CSV, labelled with an activity and social
// signal (the data collection feature from the labs). The recording itself is
// written by ble.dart through `csvSink`; this class starts and stops it and
// keeps the counters shown on the Data collection page.
//
// It lives outside any page, so a recording keeps going while the user
// switches tabs.
class Recorder extends ChangeNotifier {
  static const List<String> activities = [
    'Standing',
    'Lying down on left',
    'Lying down right',
    'Lying down back',
    'Lying down on stomach',
    'Normal walking',
    'Ascending stairs',
    'Descending stairs',
    'Shuffle walking',
    'Running',
    'Miscellaneous movements'
  ];
  static const List<String> signals = [
    'Normal',
    'Coughing',
    'Hyperventilating',
    'Talking',
    'Eating',
    'Singing',
    'Laughing'
  ];

  String activity = 'Standing';
  String signal = 'Normal';
  bool recording = false;
  int samples = 0;
  DateTime? _start;
  String filename = '';
  String info = 'Not recording';

  void setActivity(String a) {
    activity = a;
    notifyListeners();
  }

  void setSignal(String s) {
    signal = s;
    notifyListeners();
  }

  // Called by ble.dart after writing a packet's samples
  void addSamples(int n, DateTime packetTime) {
    if (!recording) return;
    samples += n;
    final start = _start;
    if (start != null) {
      info = "Written $samples samples "
          "(${packetTime.difference(start).inSeconds} seconds)";
    }
    notifyListeners();
  }

  Future<void> start() async {
    if (live.lastPacketAt == null) {
      showToast("Please connect to a RESpeck first");
      return;
    }
    if (recording) {
      showToast("Already recording");
      return;
    }
    if (storageFolder == null) {
      showLongToast("No storage folder available - cannot record");
      return;
    }

    samples = 0;
    final DateTime now = DateTime.now().toUtc();
    _start = now;
    // HH is the 0-23 hour clock (kk would format midnight as hour 24)
    final String formattedDate =
        '${DateFormat('yyyy-MM-dd').format(now)}T${DateFormat('HHmmss').format(now)}Z';
    final String newFilename =
        'PDIoT_${subjectID}_${sentenceToCamelCase(activity)}_${sentenceToCamelCase(signal)}_${formattedDate}_${respeckUUID?.replaceAll(":", "")}.csv';
    print(newFilename);

    // Close any sink left open by a recording that did not shut down cleanly
    final IOSink? stale = csvSink;
    csvSink = null;
    if (stale != null) {
      try {
        await stale.flush();
        await stale.close();
      } catch (e) {
        print("Error closing previous CSV file: $e");
      }
    }

    try {
      csvFile = File('${storageFolder!.path}/$newFilename');
      final IOSink sink = csvFile!.openWrite(mode: FileMode.writeOnly);
      // openWrite is lazy, so a bad path or a full disk surfaces on done
      sink.done.catchError((e) {
        print("Error writing $newFilename: $e");
        showLongToast("Error writing the recording file");
      });
      csvSink = sink;
      sink.write(
          "receivedPhoneTimestamp,respeckTimestamp,packetSeqNum,sampleSeqNum,accelX,accelY,accelZ\n");
    } catch (e) {
      print("Could not open $newFilename for writing: $e");
      showLongToast("Could not create the recording file");
      csvSink = null;
      csvFile = null;
      return;
    }

    showToast("Recording started..");
    filename = newFilename;
    info = "Written 0 samples (0 seconds)";
    recording = true;
    notifyListeners();
  }

  Future<void> stop({String message = "Recording stopped"}) async {
    if (!recording) return;
    // Clear the sink before closing it, so a packet arriving during the close
    // cannot write to a half closed file
    final IOSink? sink = csvSink;
    csvSink = null;
    recording = false;
    info = "Not recording";
    notifyListeners();
    try {
      await sink?.flush();
      await sink?.close();
    } catch (e) {
      print("Error closing CSV file: $e");
    }
    showToast(message);
  }
}

final Recorder recorder = Recorder();
