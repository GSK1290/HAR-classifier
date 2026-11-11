import 'dart:async';
import 'package:flutter/material.dart';
import '../globals.dart';
import '../har.dart';
import '../history.dart';
import '../labels.dart';
import '../live.dart';
import '../replay.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';

// The Live tab: connection status, the current activity and social signal,
// the last five minutes, today's totals and the raw sensor signal.
class LivePage extends StatefulWidget {
  final VoidCallback onOpenHistory;
  final VoidCallback onOpenTest;
  const LivePage(
      {super.key, required this.onOpenHistory, required this.onOpenTest});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  // Rebuilds once a second so "updated 3 s ago" and durations keep ticking
  // even between predictions
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live')),
      body: ListenableBuilder(
        listenable: Listenable.merge([live, history, replay]),
        builder: (context, _) {
          final idle = live.link == LinkState.disconnected &&
              !live.replaying &&
              live.activity == null;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _ConnectionCard(),
              if (live.replaying) _ReplayBanner(),
              if (live.reminder != null) _ReminderCard(live.reminder!),
              if (idle)
                _IdleCard(onOpenTest: widget.onOpenTest)
              else ...[
                _ActivityCard(),
                _SocialCard(),
                _RecentCard(),
              ],
              _TodayCard(onTap: widget.onOpenHistory),
              _SensorCard(),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ConnectionCard extends StatelessWidget {
  _ConnectionCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final last = live.lastPacketAt;
    final staleS =
        last == null ? 0 : DateTime.now().difference(last).inSeconds;
    final stale = live.link == LinkState.connected && staleS >= 5;

    final (IconData icon, String status, Color color) = switch (live.link) {
      LinkState.connected => stale
          ? (Icons.bluetooth_disabled, 'No data for $staleS s', Colors.orange)
          : (Icons.bluetooth_connected, 'Connected', Colors.green),
      LinkState.scanning => (
          Icons.bluetooth_searching,
          'Searching…',
          scheme.primary
        ),
      LinkState.connecting => (
          Icons.bluetooth_searching,
          'Connecting…',
          scheme.primary
        ),
      LinkState.disconnected => (
          Icons.bluetooth_disabled,
          'Not connected',
          scheme.onSurfaceVariant
        ),
    };

    final Widget button = switch (live.link) {
      LinkState.disconnected => FilledButton(
          onPressed: live.connect, child: const Text('Connect')),
      LinkState.connected => OutlinedButton(
          onPressed: live.disconnectSensor, child: const Text('Disconnect')),
      _ => const SizedBox(
          width: 24, height: 24, child: CircularProgressIndicator()),
    };

    final battery = live.battery;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(status,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  Text(
                    (respeckUUID == null || respeckUUID!.isEmpty)
                        ? 'No RESpeck paired - see Settings'
                        : 'RESpeck $respeckUUID',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (battery != null) ...[
              Icon(
                  live.charging
                      ? Icons.battery_charging_full
                      : battery > 20
                          ? Icons.battery_full
                          : Icons.battery_alert,
                  size: 18,
                  color: battery > 20 ? scheme.onSurfaceVariant : Colors.red),
              Text('$battery%', style: theme.textTheme.bodySmall),
              const SizedBox(width: 12),
            ],
            button,
          ],
        ),
      ),
    );
  }
}

class _ReplayBanner extends StatelessWidget {
  _ReplayBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(Icons.play_circle, color: scheme.onTertiaryContainer),
        title: Text('Replaying recorded data',
            style: TextStyle(color: scheme.onTertiaryContainer)),
        subtitle: Text('${live.replayName} · live data paused',
            style: TextStyle(color: scheme.onTertiaryContainer)),
        trailing: TextButton(onPressed: replay.stop, child: const Text('Stop')),
      ),
    );
  }
}

class _ReminderCard extends StatelessWidget {
  final String message;
  const _ReminderCard(this.message);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(Icons.notifications_active,
            color: scheme.onSecondaryContainer),
        title: Text(message,
            style: TextStyle(color: scheme.onSecondaryContainer)),
        trailing: IconButton(
            tooltip: 'Dismiss',
            onPressed: live.dismissReminder,
            icon: const Icon(Icons.close)),
      ),
    );
  }
}

class _IdleCard extends StatelessWidget {
  final VoidCallback onOpenTest;
  const _IdleCard({required this.onOpenTest});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: EmptyState(
        icon: Icons.sensors,
        title: 'Connect your RESpeck to start',
        message: 'Wear the sensor as shown in the placement guide, then press '
            'Connect. Your activity and breathing will appear here within a '
            'few seconds.',
        action: Column(
          children: [
            FilledButton.icon(
                onPressed: live.connect,
                icon: const Icon(Icons.bluetooth),
                label: const Text('Connect')),
            const SizedBox(height: 8),
            TextButton(
                onPressed: onOpenTest,
                child: const Text('No sensor? Replay a recording')),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Result cards
// ---------------------------------------------------------------------------

class _ResultView extends StatelessWidget {
  final ShownPrediction prediction;
  final DateTime? since;
  const _ResultView(this.prediction, this.since);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = classInfo(prediction.label);
    final now = DateTime.now();
    final pct = (prediction.confidence * 100).round();
    final ago = now.difference(prediction.at).inSeconds;
    final s = since;
    return Row(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: info.color.withValues(alpha: 0.18),
            shape: BoxShape.circle,
          ),
          child: Icon(info.icon, color: info.color, size: 34),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(info.name,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: prediction.confidence,
                  minHeight: 8,
                  color: info.color,
                  backgroundColor: info.color.withValues(alpha: 0.15),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                [
                  '$pct% confident${pct < 50 ? ' (unsure)' : ''}',
                  if (s != null) 'for ${formatDuration(now.difference(s))}',
                  ago <= 1 ? 'just updated' : 'updated $ago s ago',
                ].join(' · '),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WarmUp extends StatelessWidget {
  final double progress;
  final double seconds;
  final String title;
  final String? note;
  const _WarmUp(
      {required this.progress,
      required this.seconds,
      required this.title,
      this.note});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 52,
          height: 52,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                    value: progress.clamp(0.0, 1.0), strokeWidth: 5),
              ),
              Text('${(progress * 100).clamp(0, 100).round()}%',
                  style: theme.textTheme.labelSmall),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                note ??
                    '${(progress * seconds).clamp(0, seconds).toStringAsFixed(0)} '
                        'of ${seconds.toStringAsFixed(0)} s of data collected',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActivityCard extends StatelessWidget {
  _ActivityCard();

  @override
  Widget build(BuildContext context) {
    final classifier = harClassifier;
    final prediction = live.activity;
    final Widget body;
    if (classifier == null) {
      body = const MessageRow(
          icon: Icons.error_outline,
          title: 'Activity model not available',
          subtitle: 'The model could not be loaded. Check the files in '
              'assets/models and pubspec.yaml.');
    } else if (prediction == null) {
      body = _WarmUp(
          progress: classifier.warmup,
          seconds: classifier.windowSeconds,
          title: 'Collecting data…');
    } else {
      body = _ResultView(prediction, live.activitySince);
    }
    return SectionCard(
        title: 'Activity', icon: Icons.directions_walk, child: body);
  }
}

class _SocialCard extends StatelessWidget {
  _SocialCard();

  @override
  Widget build(BuildContext context) {
    final classifier = socialClassifier;
    final prediction = live.social;
    final window = live.socialWindowSeconds.toStringAsFixed(0);
    final Widget body;
    bool dimmed = false;
    if (classifier == null) {
      body = const MessageRow(
          icon: Icons.error_outline,
          title: 'Social signal model not available',
          subtitle: 'The model could not be loaded. Check the files in '
              'assets/models and pubspec.yaml.');
    } else if (live.activity == null || prediction == null) {
      body = _WarmUp(
          progress: classifier.warmup,
          seconds: classifier.windowSeconds,
          title: 'Listening to your breathing…');
    } else if (!live.isStationary) {
      // Gating: the social model only knows stationary data, so while the
      // person moves its output would be a guess and is not shown
      dimmed = true;
      body = const MessageRow(
          icon: Icons.pause_circle_outline,
          title: "Paused while you're moving",
          subtitle: 'Breathing and coughing can only be detected while you '
              'are still. It resumes when you sit, stand or lie down.');
    } else if (!live.socialClean) {
      body = _WarmUp(
          progress: live.socialResumeProgress,
          seconds: live.socialWindowSeconds,
          title: 'Resuming…',
          note: 'Waiting for $window s of stillness, so movement does not '
              'affect the result');
    } else {
      body = _ResultView(prediction, live.socialSince);
    }
    return Opacity(
      opacity: dimmed ? 0.75 : 1,
      child: SectionCard(
          title: 'Breathing & social signal', icon: Icons.air, child: body),
    );
  }
}

class _RecentCard extends StatelessWidget {
  _RecentCard();

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final from = now.subtract(const Duration(minutes: 5));
    final blocks = [
      for (final e in live.recent)
        TimelineBlock(
            e.at.subtract(Duration(milliseconds: (e.durationS * 1000).round())),
            e.at,
            classInfo(e.label).color),
    ];
    final labels = <String>{for (final e in live.recent) e.label};
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Last 5 minutes',
      icon: Icons.timeline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TimelineBand(blocks: blocks, from: from, to: now),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('5 min ago', style: theme.textTheme.labelSmall),
              Text('now', style: theme.textTheme.labelSmall),
            ],
          ),
          if (labels.isNotEmpty) const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [for (final l in labels) _LegendDot(classInfo(l))],
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final ClassInfo info;
  const _LegendDot(this.info);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 10,
            height: 10,
            decoration:
                BoxDecoration(color: info.color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(info.name, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _TodayCard extends StatelessWidget {
  final VoidCallback onTap;
  const _TodayCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final summary = summarise(dayOf(DateTime.now()), history.todayRecords);
    String dur(double s) => formatDuration(Duration(seconds: s.round()));
    return SectionCard(
      title: 'Today',
      icon: Icons.today,
      trailing: TextButton(onPressed: onTap, child: const Text('History')),
      child: Row(
        children: [
          Expanded(
              child: StatTile(
                  value: dur(summary.activeSeconds),
                  caption: 'active',
                  icon: Icons.directions_walk,
                  color: classInfo('normalWalking').color)),
          const SizedBox(width: 8),
          Expanded(
              child: StatTile(
                  value: dur(summary.stationarySeconds),
                  caption: 'still',
                  icon: Icons.chair_alt,
                  color: classInfo('sittingStanding').color)),
          const SizedBox(width: 8),
          Expanded(
              child: StatTile(
                  value: '${summary.coughEpisodes}',
                  caption: 'coughs',
                  icon: Icons.sick,
                  color: classInfo('coughing').color)),
        ],
      ),
    );
  }
}

class _SensorCard extends StatelessWidget {
  _SensorCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lost = live.packets == 0
        ? 0.0
        : 100 * live.droppedPackets / (live.packets + live.droppedPackets);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(Icons.show_chart, color: theme.colorScheme.primary),
        title: const Text('Sensor details'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AccelPlot(trace: live.trace),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            children: [
              for (final (i, name, v) in [
                (0, 'x', live.x),
                (1, 'y', live.y),
                (2, 'z', live.z)
              ])
                Text('$name = ${v.toStringAsFixed(3)} g',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: axisColors[i], fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          InfoRow('Packets received', '${live.packets}'),
          InfoRow('Packets lost',
              '${live.droppedPackets} (${lost.toStringAsFixed(1)}%)'),
          InfoRow('Firmware', fwString ?? '-'),
        ],
      ),
    );
  }
}
