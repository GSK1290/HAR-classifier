import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../app_settings.dart';
import '../har.dart';
import '../labels.dart';
import '../live.dart';
import '../replay.dart';
import '../trials.dart';
import '../widgets/common.dart';

// The Test tab: tools for evaluating the system for the report and the demo.
//  - Real-time accuracy trials (every member, every class)
//  - Replay of recorded sessions (stairs etc. for the demo)
//  - Performance measurements (inference time, latency, packet loss, memory)
class TestPage extends StatefulWidget {
  const TestPage({super.key});

  @override
  State<TestPage> createState() => _TestPageState();
}

class _TestPageState extends State<TestPage> {
  late final TextEditingController _participant =
      TextEditingController(text: testSession.participant);

  @override
  void dispose() {
    _participant.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Test & demo')),
      body: ListenableBuilder(
        listenable: Listenable.merge([testSession, live, replay, appSettings]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _trialCard(context),
            _resultsCard(context),
            _replayCard(context),
            _performanceCard(context),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Accuracy trial
  // ---------------------------------------------------------------------

  Widget _trialCard(BuildContext context) {
    final theme = Theme.of(context);
    final t = testSession;
    final info = classInfo(t.trueLabel);
    final ready = live.link == LinkState.connected || live.replaying;

    final Widget body;
    if (t.phase == TrialPhase.idle) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The participant performs the chosen activity for the whole '
            'trial. Results from the first window '
            '(${t.windowSeconds.toStringAsFixed(0)} s) are not counted, '
            'because that window still holds what they did before.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _participant,
            decoration: const InputDecoration(
              labelText: 'Participant',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: t.setParticipant,
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Performing',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: t.trueLabel,
                isExpanded: true,
                isDense: true,
                items: [
                  _header('Activities'),
                  for (final c in activityClasses) _classItem(c),
                  _header('Breathing & social signals'),
                  for (final c in socialClasses) _classItem(c),
                ],
                onChanged: (v) {
                  if (v != null) t.setTrueLabel(v);
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('Length', style: theme.textTheme.bodyMedium),
              const SizedBox(width: 12),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 30, label: Text('30 s')),
                  ButtonSegment(value: 60, label: Text('60 s')),
                ],
                selected: {t.trialSeconds},
                onSelectionChanged: (s) => t.setTrialSeconds(s.first),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: ready ? t.start : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start trial'),
            ),
          ),
          if (!ready)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Connect the RESpeck on the Live tab first.',
                  style: theme.textTheme.bodySmall),
            ),
          if (live.replaying)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  'A recording is replaying: this trial will be marked as '
                  'replayed and left out of the totals.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.tertiary)),
            ),
        ],
      );
    } else if (t.phase == TrialPhase.countdown) {
      body = Column(
        children: [
          Text('Get ready: ${info.name}', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('${t.countdown}',
              style: theme.textTheme.displayLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          TextButton(onPressed: t.cancel, child: const Text('Cancel')),
        ],
      );
    } else {
      final counted = t.current.where((p) => p.counted).toList();
      final correct = counted.where((p) => p.shown == t.trueLabel).length;
      final latest = t.current.isEmpty ? null : t.current.last;
      final elapsed = t.elapsedS.clamp(0, t.trialSeconds).toDouble();
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(info.icon, color: info.color, size: 28),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${t.participant}: ${info.name}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              Text('${elapsed.toStringAsFixed(0)} / ${t.trialSeconds} s',
                  style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
              value: elapsed / t.trialSeconds,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4)),
          const SizedBox(height: 12),
          InfoRow(
              'App shows',
              latest == null
                  ? 'waiting…'
                  : latest.shown == 'paused'
                      ? 'paused (moving)'
                      : classInfo(latest.shown).name),
          InfoRow('Counted so far', '$correct of ${counted.length} correct'),
          if (elapsed < t.windowSeconds)
            Text('Window still filling - not counted yet',
                style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              onPressed: t.cancel,
              icon: const Icon(Icons.stop),
              label: const Text('Cancel trial')),
        ],
      );
    }

    return SectionCard(
        title: 'Real-time accuracy test', icon: Icons.fact_check, child: body);
  }

  DropdownMenuItem<String> _header(String text) => DropdownMenuItem<String>(
        value: '#$text',
        enabled: false,
        child: Text(text,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary)),
      );

  DropdownMenuItem<String> _classItem(ClassInfo c) => DropdownMenuItem<String>(
        value: c.id,
        child: Row(
          children: [
            Icon(c.icon, color: c.color, size: 20),
            const SizedBox(width: 8),
            Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
          ],
        ),
      );

  // ---------------------------------------------------------------------
  // Results
  // ---------------------------------------------------------------------

  Widget _resultsCard(BuildContext context) {
    final theme = Theme.of(context);
    final t = testSession;
    if (t.trials.isEmpty) {
      return const SectionCard(
        title: 'Results',
        icon: Icons.table_chart,
        child: Text('No trials yet. Completed trials are saved on the phone '
            'and can be exported as CSV for the report.'),
      );
    }

    String pct(double? v) => v == null ? '-' : '${(v * 100).toStringAsFixed(1)}%';
    final rows = t.byClass();
    final hasReplay = t.trials.any((x) => x.fromReplay);

    return SectionCard(
      title: 'Results',
      icon: Icons.table_chart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: StatTile(
                      value: pct(t.predictionAccuracy(ClassKind.activity)),
                      caption: 'activities\n(per prediction)')),
              const SizedBox(width: 8),
              Expanded(
                  child: StatTile(
                      value: pct(t.predictionAccuracy(ClassKind.social)),
                      caption: 'social signals\n(per prediction)')),
            ],
          ),
          const SizedBox(height: 8),
          InfoRow('Trials correct by majority (activities)',
              pct(t.trialAccuracy(ClassKind.activity))),
          InfoRow('Trials correct by majority (social)',
              pct(t.trialAccuracy(ClassKind.social))),
          if (hasReplay)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include replayed trials'),
              value: t.includeReplay,
              onChanged: t.setIncludeReplay,
            ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              horizontalMargin: 0,
              headingRowHeight: 36,
              dataRowMinHeight: 32,
              dataRowMaxHeight: 40,
              columns: const [
                DataColumn(label: Text('Class')),
                DataColumn(label: Text('Trials'), numeric: true),
                DataColumn(label: Text('Accuracy'), numeric: true),
                DataColumn(label: Text('Majority'), numeric: true),
                DataColumn(label: Text('Time to\ncorrect'), numeric: true),
              ],
              rows: [
                for (final r in rows)
                  DataRow(cells: [
                    DataCell(Row(children: [
                      Icon(classInfo(r.label).icon,
                          size: 16, color: classInfo(r.label).color),
                      const SizedBox(width: 6),
                      Text(classInfo(r.label).name),
                    ])),
                    DataCell(Text('${r.trials}')),
                    DataCell(Text(pct(r.accuracy))),
                    DataCell(Text('${r.majorityCorrect}/${r.trials}')),
                    DataCell(Text(r.meanTimeToCorrect == null
                        ? '-'
                        : '${r.meanTimeToCorrect!.toStringAsFixed(1)} s')),
                  ]),
              ],
            ),
          ),
          const SizedBox(height: 4),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('All trials (${t.trials.length})',
                style: theme.textTheme.bodyMedium),
            children: [
              for (final trial in t.trials.reversed) _trialTile(trial),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () async {
                  final files = await t.export();
                  if (!context.mounted) return;
                  await showExportDialog(context, 'Trials exported', files);
                },
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('Export CSV'),
              ),
              TextButton.icon(
                onPressed: () async {
                  if (await confirm(context, 'Delete all trials?',
                      'Export them first if you need them for the report.')) {
                    t.clear();
                  }
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _trialTile(Trial trial) {
    final info = classInfo(trial.trueLabel);
    final ttc = trial.timeToCorrectS;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
          trial.majorityCorrect ? Icons.check_circle : Icons.cancel,
          color: trial.majorityCorrect ? Colors.green : Colors.red),
      title: Text('${trial.participant} · ${info.name}'
          '${trial.fromReplay ? ' (replay)' : ''}'),
      subtitle: Text('${trial.correct}/${trial.counted.length} correct · '
          '${ttc == null ? 'never correct' : 'correct after ${ttc.toStringAsFixed(1)} s'}'
          ' · ${DateFormat('d MMM HH:mm').format(trial.start)}'),
      trailing: IconButton(
        tooltip: 'Delete trial',
        icon: const Icon(Icons.delete_outline),
        onPressed: () async {
          if (await confirm(context, 'Delete this trial?',
              '${trial.participant} · ${info.name}')) {
            testSession.deleteTrial(trial);
          }
        },
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Replay
  // ---------------------------------------------------------------------

  Widget _replayCard(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Replay recorded data',
      icon: Icons.play_circle_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Plays a recorded session through the same pipeline as live data, '
            'in real time. Use it to demonstrate activities that are hard to '
            'do live. The recordings come from the training dataset, so they '
            'show how the app behaves, not how accurate it is.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Loop'),
            value: replay.loop,
            onChanged: replay.setLoop,
          ),
          for (final r in demoRecordings) _replayTile(r),
        ],
      ),
    );
  }

  Widget _replayTile(DemoRecording r) {
    final info = classInfo(r.classId);
    final playing = replay.current == r;
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(info.icon, color: info.color),
          title: Text(r.name),
          subtitle: Text(info.kind == ClassKind.activity
              ? 'Activity recording'
              : 'Social signal recording'),
          trailing: IconButton.filledTonal(
            tooltip: playing ? 'Stop' : 'Play',
            icon: Icon(playing ? Icons.stop : Icons.play_arrow),
            onPressed: () {
              if (playing) {
                replay.stop();
              } else {
                replay.play(r);
              }
            },
          ),
        ),
        if (playing)
          LinearProgressIndicator(
              value: replay.progress, color: info.color, minHeight: 4),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Performance
  // ---------------------------------------------------------------------

  Widget _performanceCard(BuildContext context) {
    final theme = Theme.of(context);
    String ms(Stat s) {
      final mean = s.mean;
      if (mean == null) return '-';
      return '${mean.toStringAsFixed(1)} ms avg · '
          '${s.percentile(0.95)!.toStringAsFixed(1)} p95';
    }

    final step = harClassifier?.stepSeconds;
    final lost = live.packets == 0
        ? 0.0
        : 100 * live.droppedPackets / (live.packets + live.droppedPackets);
    int? rssMb;
    try {
      rssMb = (ProcessInfo.currentRss / (1024 * 1024)).round();
    } catch (_) {
      rssMb = null;
    }

    return SectionCard(
      title: 'Performance',
      icon: Icons.speed,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoRow('Activity model inference', ms(live.harInferenceMs)),
          InfoRow('Social model inference', ms(live.socialInferenceMs)),
          InfoRow('Packet → result on screen', ms(live.packetToScreenMs)),
          InfoRow('Update interval',
              step == null ? '-' : 'every ${step.toStringAsFixed(1)} s'),
          InfoRow('Packets received / lost',
              '${live.packets} / ${live.droppedPackets} (${lost.toStringAsFixed(1)}%)'),
          InfoRow('App memory in use', rssMb == null ? '-' : '$rssMb MB'),
          const SizedBox(height: 6),
          Text(
            'Inference runs on the phone. Measure CPU and energy with the '
            'Xcode Debug navigator gauges or Instruments while this runs.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () async {
                  final f = await live.exportPerformance();
                  if (!context.mounted) return;
                  await showExportDialog(
                      context, 'Performance log exported', [if (f != null) f]);
                },
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('Export log'),
              ),
              TextButton.icon(
                onPressed: live.resetPerformance,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
