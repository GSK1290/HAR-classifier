import 'dart:math' as math;
import 'package:flutter/material.dart';

// Lightweight charts drawn with CustomPaint. They cover exactly what the app
// needs (donut, timeline band, stacked bars, live signal plot) without an
// extra charting package.

// ---------------------------------------------------------------------------
// Donut chart: share of the day per activity
// ---------------------------------------------------------------------------

class DonutSlice {
  final Color color;
  final double value;
  const DonutSlice(this.color, this.value);
}

class DonutChart extends StatelessWidget {
  final List<DonutSlice> slices;
  final double size;
  final double thickness;
  final Widget? center;

  const DonutChart(
      {super.key,
      required this.slices,
      this.size = 160,
      this.thickness = 22,
      this.center});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DonutPainter(slices, thickness,
            Theme.of(context).colorScheme.surfaceContainerHighest),
        child: Center(child: center),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<DonutSlice> slices;
  final double thickness;
  final Color track;
  _DonutPainter(this.slices, this.thickness, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(thickness / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness;
    final total = slices.fold<double>(0, (a, s) => a + s.value);
    if (total <= 0) {
      canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = track);
      return;
    }
    // A small gap between slices keeps neighbouring colours distinct
    final gap = slices.length > 1 ? 0.03 : 0.0;
    double start = -math.pi / 2;
    for (final s in slices) {
      final sweep = 2 * math.pi * s.value / total;
      if (sweep > gap) {
        canvas.drawArc(
            rect, start + gap / 2, sweep - gap, false, paint..color = s.color);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) => true;
}

// ---------------------------------------------------------------------------
// Timeline band: coloured blocks showing what happened when
// ---------------------------------------------------------------------------

class TimelineBlock {
  final DateTime start;
  final DateTime end;
  final Color color;
  const TimelineBlock(this.start, this.end, this.color);
}

class TimelineBand extends StatelessWidget {
  final List<TimelineBlock> blocks;
  final DateTime from;
  final DateTime to;
  final double height;

  const TimelineBand(
      {super.key,
      required this.blocks,
      required this.from,
      required this.to,
      this.height = 28});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _TimelinePainter(blocks, from, to,
              Theme.of(context).colorScheme.surfaceContainerHighest),
        ),
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  final List<TimelineBlock> blocks;
  final DateTime from;
  final DateTime to;
  final Color track;
  _TimelinePainter(this.blocks, this.from, this.to, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    final span = to.difference(from).inMilliseconds.toDouble();
    if (span <= 0) return;
    double xOf(DateTime t) =>
        (t.difference(from).inMilliseconds / span).clamp(0.0, 1.0) *
        size.width;
    final paint = Paint();
    for (final b in blocks) {
      final x0 = xOf(b.start);
      // At least one pixel wide, so short events stay visible on a 24 h band
      final x1 = math.max(xOf(b.end), x0 + 1);
      canvas.drawRect(
          Rect.fromLTRB(x0, 0, x1, size.height), paint..color = b.color);
    }
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) => true;
}

// ---------------------------------------------------------------------------
// Bar chart with up to two stacked series, e.g. active / still per day
// ---------------------------------------------------------------------------

class BarDatum {
  final String label;
  final double a;
  final double b;
  const BarDatum(this.label, this.a, [this.b = 0]);
}

class StackedBars extends StatelessWidget {
  final List<BarDatum> data;
  final Color colorA;
  final Color colorB;
  final double height;
  // Text drawn above each bar, e.g. "2.5 h"
  final String Function(BarDatum d)? valueLabel;
  final void Function(int index)? onTap;
  final int? highlighted;

  const StackedBars(
      {super.key,
      required this.data,
      required this.colorA,
      this.colorB = Colors.transparent,
      this.height = 140,
      this.valueLabel,
      this.onTap,
      this.highlighted});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxV = data.fold<double>(0, (m, d) => math.max(m, d.a + d.b));
    return SizedBox(
      height: height + 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < data.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap == null ? null : () => onTap!(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (valueLabel != null)
                        Text(valueLabel!(data[i]),
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: theme.textTheme.labelSmall),
                      const SizedBox(height: 2),
                      // Bars are drawn from the bottom: series B on top of A
                      if (maxV > 0 && data[i].b > 0)
                        Container(
                          height: height * data[i].b / maxV,
                          decoration: BoxDecoration(
                            color: colorB,
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4)),
                          ),
                        ),
                      if (maxV > 0 && data[i].a > 0)
                        Container(
                          height: height * data[i].a / maxV,
                          decoration: BoxDecoration(
                            color: colorA,
                            borderRadius: data[i].b > 0
                                ? null
                                : const BorderRadius.vertical(
                                    top: Radius.circular(4)),
                          ),
                        ),
                      Container(height: 1, color: theme.dividerColor),
                      const SizedBox(height: 4),
                      Text(data[i].label,
                          style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: highlighted == i
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: highlighted == i
                                  ? theme.colorScheme.primary
                                  : null)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Live acceleration plot: x, y, z over the last few seconds
// ---------------------------------------------------------------------------

const List<Color> axisColors = [
  Color(0xFFE15759), // x
  Color(0xFF59A14F), // y
  Color(0xFF4E79A7), // z
];

class AccelPlot extends StatelessWidget {
  final List<List<double>> trace;
  final double height;
  const AccelPlot({super.key, required this.trace, this.height = 90});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _AccelPainter(trace, Theme.of(context).dividerColor),
      ),
    );
  }
}

class _AccelPainter extends CustomPainter {
  final List<List<double>> trace;
  final Color grid;
  _AccelPainter(this.trace, this.grid);

  // Fixed scale of -2 g to +2 g, so the plot does not jump around
  static const double range = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid),
        Paint()..color = grid);
    if (trace.length < 2) return;
    final dx = size.width / 99; // room for 100 samples
    final x0 = size.width - dx * (trace.length - 1);
    for (int axis = 0; axis < 3; axis++) {
      final path = Path();
      for (int i = 0; i < trace.length; i++) {
        final v = (trace[i][axis] / range).clamp(-1.0, 1.0);
        final p = Offset(x0 + i * dx, mid - v * mid);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = axisColors[axis]);
    }
  }

  @override
  bool shouldRepaint(covariant _AccelPainter old) => true;
}
