// Basic tests for the PDIoT recording app.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package.

import 'package:flutter_test/flutter_test.dart';

import 'package:pdiot/main.dart';
import 'package:pdiot/utils.dart';
import 'package:flutter/material.dart';
import 'package:pdiot/har.dart';
import 'package:pdiot/app_settings.dart';
import 'package:pdiot/history.dart';
import 'package:pdiot/labels.dart';
import 'package:pdiot/live.dart';
import 'package:pdiot/replay.dart';
import 'package:pdiot/trials.dart';

void main() {
  testWidgets('Shows the first-launch guide until it is completed',
      (WidgetTester tester) async {
    appSettings.onboardingDone = false;
    await tester.pumpWidget(const MyApp());
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('Live tab invites the user to connect',
      (WidgetTester tester) async {
    appSettings.onboardingDone = true;
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Connect your RESpeck to start'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    // Bottom navigation
    for (final tab in ['History', 'Test', 'Settings']) {
      expect(find.text(tab), findsWidgets);
    }

    // Remove the app so the Live tab's one-second timer is cancelled
    await tester.pumpWidget(const SizedBox());
  });

  group('sentenceToCamelCase', () {
    test('joins the words of an activity name', () {
      expect(sentenceToCamelCase('Lying down on left'), 'lyingDownOnLeft');
      expect(sentenceToCamelCase('Standing'), 'standing');
    });

    test('tolerates empty and oddly spaced input', () {
      expect(sentenceToCamelCase(''), '');
      expect(sentenceToCamelCase('   '), '');
      expect(sentenceToCamelCase('  Normal   walking '), 'normalWalking');
    });
  });

  group('combineAccelBytes', () {
    test('decodes positive values', () {
      expect(combineAccelBytes(0, 0), 0.0);
      // 0x4000 = 16384 = 1g
      expect(combineAccelBytes(0x40, 0x00), 1.0);
    });

    test('decodes negative values', () {
      // 0xC000 as a signed 16 bit value is -16384 = -1g. The upper byte is
      // read from the packet with getInt8, so it arrives here as -64.
      expect(combineAccelBytes(-64, 0x00), -1.0);
      // 0xFFFF = -1
      expect(combineAccelBytes(-1, 0xFF), -1 / 16384.0);
    });
  });

  // The sliding window decides when the activity classifier runs. These tests
  // use a small window (4 samples, step 2) so the expected pattern is easy to
  // follow; the real model uses 50 and 25.
  group('SampleWindow', () {
    test('is ready once full, then every step samples', () {
      final w = SampleWindow(4, 2);
      // Add samples 0..8 (only x is set, so each sample is easy to identify).
      // The window is first full after sample 3, then ready again after every
      // 2 further samples: after samples 5 and 7.
      final ready = [for (int i = 0; i < 9; i++) w.add(i.toDouble(), 0, 0)];
      expect(
          ready, [false, false, false, true, false, true, false, true, false]);
      // After 9 samples the window holds the newest 4, oldest first
      expect(w.batch[0].map((s) => s[0]), [5.0, 6.0, 7.0, 8.0]);
    });

    // After a disconnect the window is cleared, and must fill up again
    // completely before the next prediction
    test('starts again after clear', () {
      final w = SampleWindow(2, 1);
      w.add(0, 0, 0);
      w.add(0, 0, 0);
      w.clear();
      expect(w.add(0, 0, 0), false);
      expect(w.add(0, 0, 0), true);
    });
  });

  group('majorityVote', () {
    test('picks the most common label and averages its confidence', () {
      final p = majorityVote(const [
        HarPrediction('a', 0.6),
        HarPrediction('b', 0.9),
        HarPrediction('a', 0.8),
      ]);
      expect(p.label, 'a');
      expect(p.confidence, closeTo(0.7, 1e-9));
    });

    test('breaks ties in favour of the newest prediction', () {
      final p = majorityVote(const [
        HarPrediction('a', 0.5),
        HarPrediction('b', 0.5),
      ]);
      expect(p.label, 'b');
    });
  });

  // History: time per activity, cough episodes and timeline segments
  group('history summary', () {
    final t0 = DateTime(2026, 11, 11, 10);
    HistoryRecord rec(int s, ClassKind k, String label) =>
        HistoryRecord(t0.add(Duration(seconds: s)), k, label, 0.9, 2, 'live');

    test('counts a run of coughing predictions as one episode', () {
      final social = [
        rec(0, ClassKind.social, 'breathingNormally'),
        rec(2, ClassKind.social, 'coughing'),
        rec(4, ClassKind.social, 'coughing'),
        rec(6, ClassKind.social, 'coughing'),
        rec(8, ClassKind.social, 'breathingNormally'),
        rec(10, ClassKind.social, 'coughing'),
      ];
      expect(countEpisodes(social, 'coughing'), 2);
    });

    test('a long gap splits an episode', () {
      final social = [
        rec(0, ClassKind.social, 'coughing'),
        rec(60, ClassKind.social, 'coughing'),
      ];
      expect(countEpisodes(social, 'coughing'), 2);
    });

    test('adds up time per activity and splits active from still', () {
      final s = summarise(dayOf(t0), [
        rec(0, ClassKind.activity, 'sittingStanding'),
        rec(2, ClassKind.activity, 'sittingStanding'),
        rec(4, ClassKind.activity, 'normalWalking'),
        rec(6, ClassKind.social, 'coughing'),
      ]);
      expect(s.activitySeconds['sittingStanding'], 4);
      expect(s.activitySeconds['normalWalking'], 2);
      expect(s.stationarySeconds, 4);
      expect(s.activeSeconds, 2);
      expect(s.coughEpisodes, 1);
      expect(s.segments.map((x) => x.label),
          ['sittingStanding', 'normalWalking']);
    });

    test('a record survives a round trip through CSV', () {
      final r = rec(0, ClassKind.social, 'coughing');
      final back = HistoryRecord.fromCsv(r.toCsv())!;
      expect(back.time, r.time);
      expect(back.kind, ClassKind.social);
      expect(back.label, 'coughing');
      expect(HistoryRecord.fromCsv('timestamp_ms,kind,label'), isNull);
    });
  });

  group('accuracy trials', () {
    test('only counted predictions are scored', () {
      final trial =
          Trial('A', 'running', DateTime(2026), 30, false, false, const [
        // Inside the first window: logged, not counted
        TrialPrediction(2, 'normalWalking', 0.6, 'normalWalking', 0.6, false),
        TrialPrediction(4, 'running', 0.9, 'running', 0.9, true),
        TrialPrediction(6, 'running', 0.9, 'running', 0.9, true),
        TrialPrediction(8, 'normalWalking', 0.5, 'normalWalking', 0.5, true),
      ]);
      expect(trial.counted.length, 3);
      expect(trial.correct, 2);
      expect(trial.accuracy, closeTo(2 / 3, 1e-9));
      expect(trial.majorityCorrect, isTrue);
      expect(trial.timeToCorrectS, 4);
    });

    test('a trial survives a round trip through JSON', () {
      final trial = Trial(
          'B', 'coughing', DateTime(2026, 11, 11), 30, true, true, const [
        TrialPrediction(10, 'coughing', 0.8, 'paused', 0, true),
      ]);
      final back = Trial.fromJson(trial.toJson());
      expect(back.participant, 'B');
      expect(back.fromReplay, isTrue);
      expect(back.predictions.single.shown, 'paused');
      expect(back.correct, 0);
    });
  });

  group('replay', () {
    test('parses accelerometer CSV and skips the header', () {
      final s = parseAccelCsv('accelX,accelY,accelZ\n0.1,-0.9,0.2\n\n1,2,3\n');
      expect(s, [
        [0.1, -0.9, 0.2],
        [1.0, 2.0, 3.0]
      ]);
    });
  });

  group('labels', () {
    test('every model class has display information', () {
      for (final id in [
        'sittingStanding',
        'lyingBack',
        'lyingLeft',
        'lyingRight',
        'lyingStomach',
        'normalWalking',
        'shuffleWalking',
        'ascending',
        'descending',
        'running',
        'miscMovement',
        'breathingNormally',
        'coughing',
        'hyperventilation',
        'other'
      ]) {
        expect(classInfo(id).name, isNot(id), reason: id);
      }
    });

    test('stationary activities match the static postures', () {
      expect(stationaryActivities, {
        for (final c in activityClasses)
          if (c.stationary) c.id
      });
    });

    test('durations are formatted compactly', () {
      expect(formatDuration(const Duration(seconds: 45)), '45 s');
      expect(formatDuration(const Duration(minutes: 12)), '12 min');
      expect(
          formatDuration(const Duration(hours: 2, minutes: 5)), '2 h 05 min');
    });
  });

  group('faster updates', () {
    test('halve the step of a classifier window', () {
      final w = SampleWindow(50, 25);
      w.step = (25 / 2).round();
      expect(w.step, 13);
    });
  });
}
