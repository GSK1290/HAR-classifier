import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../history.dart';
import '../labels.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';

// The History tab: what the user did on a given day, or over a week.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

enum _Range { day, week }

class _HistoryPageState extends State<HistoryPage> {
  _Range range = _Range.day;
  DateTime day = dayOf(DateTime.now());
  // Past days are read from file once and cached here; today is computed
  // from the in-memory records so it updates live
  Future<DaySummary>? _dayFuture;
  Future<List<DaySummary>>? _weekFuture;

  bool get isToday => day == dayOf(DateTime.now());

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _dayFuture = history.summaryFor(day);
    _weekFuture = history.weekEnding(day);
  }

  void _setDay(DateTime d) {
    final today = dayOf(DateTime.now());
    setState(() {
      day = d.isAfter(today) ? today : dayOf(d);
      _reload();
    });
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: day,
      firstDate: DateTime(2025),
      lastDate: dayOf(DateTime.now()),
    );
    if (picked != null) _setDay(picked);
  }

  Future<void> _export() async {
    final file = await history.exportAll();
    if (!mounted) return;
    await showExportDialog(
        context, 'History exported', [if (file != null) file]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
              tooltip: 'Export as CSV',
              onPressed: _export,
              icon: const Icon(Icons.file_download_outlined)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          setState(_reload);
          await _weekFuture;
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Center(
              child: SegmentedButton<_Range>(
                segments: const [
                  ButtonSegment(
                      value: _Range.day,
                      label: Text('Day'),
                      icon: Icon(Icons.today)),
                  ButtonSegment(
                      value: _Range.week,
                      label: Text('Week'),
                      icon: Icon(Icons.date_range)),
                ],
                selected: {range},
                onSelectionChanged: (s) => setState(() {
                  range = s.first;
                  _reload();
                }),
              ),
            ),
            const SizedBox(height: 8),
            _dateSelector(context),
            const SizedBox(height: 8),
            if (range == _Range.day) _dayView() else _weekView(),
          ],
        ),
      ),
    );
  }

  Widget _dateSelector(BuildContext context) {
    final String label;
    if (range == _Range.day) {
      label = isToday ? 'Today' : DateFormat('EEE d MMM yyyy').format(day);
    } else {
      final first = DateTime(day.year, day.month, day.day - 6);
      label = '${DateFormat('d MMM').format(first)} – '
          '${DateFormat('d MMM').format(day)}';
    }
    final step = range == _Range.day ? 1 : 7;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
            tooltip: 'Earlier',
            onPressed: () =>
                _setDay(DateTime(day.year, day.month, day.day - step)),
            icon: const Icon(Icons.chevron_left)),
        TextButton.icon(
            onPressed: _pickDay,
            icon: const Icon(Icons.calendar_month, size: 18),
            label: Text(label)),
        IconButton(
            tooltip: 'Later',
            onPressed: isToday
                ? null
                : () => _setDay(DateTime(day.year, day.month, day.day + step)),
            icon: const Icon(Icons.chevron_right)),
      ],
    );
  }

  // ---- Day ----

  Widget _dayView() {
    if (isToday) {
      return ListenableBuilder(
        listenable: history,
        builder: (context, _) =>
            _DayContent(summarise(day, history.todayRecords)),
      );
    }
    return FutureBuilder<DaySummary>(
      future: _dayFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()));
        }
        return _DayContent(snap.data!);
      },
    );
  }

  // ---- Week ----

  Widget _weekView() {
    return FutureBuilder<List<DaySummary>>(
      future: _weekFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()));
        }
        return _WeekContent(snap.data!, onOpenDay: (d) {
          setState(() {
            range = _Range.day;
            day = d;
            _reload();
          });
        });
      },
    );
  }
}

String _dur(double seconds) =>
    formatDuration(Duration(seconds: seconds.round()));

class _DayContent extends StatelessWidget {
  final DaySummary s;
  const _DayContent(this.s);

  @override
  Widget build(BuildContext context) {
    if (s.isEmpty) {
      return const Card(
        child: EmptyState(
          icon: Icons.insights,
          title: 'No data for this day',
          message: 'Results are saved automatically while the RESpeck is '
              'connected. Connect it on the Live tab to start tracking.',
        ),
      );
    }
    final theme = Theme.of(context);
    final entries = s.activitySeconds.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = s.trackedSeconds;

    return Column(
      children: [
        SectionCard(
          title: 'Activities',
          icon: Icons.directions_walk,
          child: Column(
            children: [
              DonutChart(
                slices: [
                  for (final e in entries)
                    DonutSlice(classInfo(e.key).color, e.value)
                ],
                center: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_dur(total),
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    Text('tracked', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                      child: StatTile(
                          value: _dur(s.activeSeconds),
                          caption: 'active',
                          color: classInfo('normalWalking').color)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: StatTile(
                          value: _dur(s.stationarySeconds),
                          caption: 'still',
                          color: classInfo('sittingStanding').color)),
                ],
              ),
              const SizedBox(height: 12),
              for (final e in entries)
                _ActivityRow(classInfo(e.key), e.value, total),
            ],
          ),
        ),
        SectionCard(
          title: 'Timeline',
          icon: Icons.timeline,
          child: Column(
            children: [
              TimelineBand(
                height: 36,
                from: s.day,
                to: DateTime(s.day.year, s.day.month, s.day.day + 1),
                blocks: [
                  for (final seg in s.segments)
                    TimelineBlock(
                        seg.start, seg.end, classInfo(seg.label).color)
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final h in ['00', '06', '12', '18', '24'])
                    Text(h, style: theme.textTheme.labelSmall),
                ],
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Breathing & social signals',
          icon: Icons.air,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child: StatTile(
                          value: '${s.coughEpisodes}',
                          caption: 'coughing episodes',
                          icon: Icons.sick,
                          color: classInfo('coughing').color)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: StatTile(
                          value: '${s.hyperventilationEpisodes}',
                          caption: 'hyperventilation episodes',
                          icon: Icons.monitor_heart,
                          color: classInfo('hyperventilation').color)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                      child: StatTile(
                          value: _dur(s.socialSeconds['breathingNormally'] ?? 0),
                          caption: 'breathing normally',
                          icon: Icons.air,
                          color: classInfo('breathingNormally').color)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: StatTile(
                          value: _dur(s.socialSeconds['other'] ?? 0),
                          caption: 'talking, eating, laughing',
                          icon: Icons.record_voice_over,
                          color: classInfo('other').color)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Social signals are only recorded while you are still. An '
                'episode is one continuous stretch of coughing or '
                'hyperventilating.',
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

class _ActivityRow extends StatelessWidget {
  final ClassInfo info;
  final double seconds;
  final double total;
  const _ActivityRow(this.info, this.seconds, this.total);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final share = total == 0 ? 0.0 : seconds / total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(info.icon, color: info.color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                        child: Text(info.name,
                            style: theme.textTheme.bodyMedium)),
                    Text(_dur(seconds),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: share,
                    minHeight: 5,
                    color: info.color,
                    backgroundColor: info.color.withValues(alpha: 0.15),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 40,
            child: Text('${(share * 100).round()}%',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _WeekContent extends StatelessWidget {
  final List<DaySummary> days;
  final void Function(DateTime day) onOpenDay;
  const _WeekContent(this.days, {required this.onOpenDay});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (days.every((d) => d.isEmpty)) {
      return const Card(
        child: EmptyState(
          icon: Icons.date_range,
          title: 'No data this week',
          message: 'Results are saved automatically while the RESpeck is '
              'connected.',
        ),
      );
    }
    final activeColor = classInfo('normalWalking').color;
    final stillColor = classInfo('sittingStanding').color;
    final coughColor = classInfo('coughing').color;
    String weekday(DaySummary d) => DateFormat('E').format(d.day);

    final totalTracked = days.fold<double>(0, (a, d) => a + d.trackedSeconds);
    final totalActive = days.fold<double>(0, (a, d) => a + d.activeSeconds);
    final totalCoughs = days.fold<int>(0, (a, d) => a + d.coughEpisodes);
    final daysWithData = days.where((d) => !d.isEmpty).length;

    Widget legend(Color c, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: c, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 4),
            Text(text, style: theme.textTheme.labelSmall),
          ],
        );

    return Column(
      children: [
        SectionCard(
          title: 'Active and still time',
          icon: Icons.bar_chart,
          child: Column(
            children: [
              StackedBars(
                data: [
                  for (final d in days)
                    BarDatum(weekday(d), d.activeSeconds / 3600,
                        d.stationarySeconds / 3600)
                ],
                colorA: activeColor,
                colorB: stillColor,
                valueLabel: (b) =>
                    b.a + b.b == 0 ? '' : '${(b.a + b.b).toStringAsFixed(1)}h',
                onTap: (i) => onOpenDay(days[i].day),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 16, children: [
                legend(activeColor, 'Active'),
                legend(stillColor, 'Still'),
              ]),
              const SizedBox(height: 4),
              Text('Tap a day to see it in detail',
                  style: theme.textTheme.labelSmall),
            ],
          ),
        ),
        SectionCard(
          title: 'Coughing episodes',
          icon: Icons.sick,
          child: StackedBars(
            height: 100,
            data: [
              for (final d in days)
                BarDatum(weekday(d), d.coughEpisodes.toDouble())
            ],
            colorA: coughColor,
            valueLabel: (b) => b.a == 0 ? '' : '${b.a.round()}',
            onTap: (i) => onOpenDay(days[i].day),
          ),
        ),
        SectionCard(
          title: 'This week',
          icon: Icons.summarize,
          child: Column(
            children: [
              InfoRow('Time tracked', _dur(totalTracked)),
              InfoRow('Active time per tracked day',
                  daysWithData == 0 ? '-' : _dur(totalActive / daysWithData)),
              InfoRow('Coughing episodes', '$totalCoughs'),
              InfoRow('Days with data', '$daysWithData of 7'),
            ],
          ),
        ),
      ],
    );
  }
}
