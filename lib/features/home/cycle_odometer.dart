import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hercycle/core/app_theme.dart';

/// Cycle phases for odometer ring segments.
enum OdometerPhase { menstrual, follicular, fertile, ovulation, luteal }

/// Brand colors per phase (data colors — readable on light and dark cards).
const odometerPhaseColors = {
  OdometerPhase.menstrual: Color(0xFFE53935),
  OdometerPhase.follicular: Color(0xFFFB8C00),
  OdometerPhase.fertile: Color(0xFF00ACC1),
  OdometerPhase.ovulation: Color(0xFF2E9E57),
  OdometerPhase.luteal: Color(0xFF7B4B94),
};

/// Pure mapper: one phase per cycle day (1-based, index 0 == day 1).
///
/// Strong-logic rules:
/// - Lengths clamp to the predictor's ranges (15–60 / 1–15); degenerate
///   input still yields a valid ring.
/// - [ovulationDay] outside 1..N (or null) falls back to the mid-cycle
///   estimate (N−14); the fertile window is always ovu−5..ovu+1, clamped
///   to start after the bleeding days so estimates can never paint over
///   menses.
/// - Priority per day: menstrual > ovulation > fertile > luteal >
///   follicular, so overlapping anchors resolve deterministically.
List<OdometerPhase> odometerSegments({
  required int cycleLen,
  required int periodLen,
  int? ovulationDay,
}) {
  final n = cycleLen.clamp(15, 60);
  final p = periodLen.clamp(1, 15);
  // Only an in-range tracked day earns the distinct ovulation marker;
  // anything else (null or stale/out-of-range) degrades to the estimate.
  final tracked =
      ovulationDay != null && ovulationDay >= 1 && ovulationDay <= n;
  var ovu = tracked ? ovulationDay : (n - 14);
  if (ovu < 1 || ovu > n) ovu = n - 14;
  // Degenerate input (bleed longer than the cycle) inverts the fertile
  // floor — pin it so clamp bounds can never cross.
  final fertileFloor = p + 1 > n ? n : p + 1;
  var fertileStart = (ovu - 5).clamp(fertileFloor, n);
  var fertileEnd = (ovu + 1).clamp(fertileFloor, n);
  if (fertileEnd < fertileStart) {
    final mid = ((fertileStart + fertileEnd) / 2).round().clamp(1, n);
    fertileStart = mid;
    fertileEnd = mid;
  }
  final lutealStart = n - 13;

  final segments = <OdometerPhase>[];
  for (var day = 1; day <= n; day++) {
    OdometerPhase phase;
    if (day <= p) {
      phase = OdometerPhase.menstrual;
    } else if (day == ovu && tracked) {
      phase = OdometerPhase.ovulation;
    } else if (day >= fertileStart && day <= fertileEnd) {
      phase = OdometerPhase.fertile;
    } else if (day >= lutealStart) {
      phase = OdometerPhase.luteal;
    } else {
      phase = OdometerPhase.follicular;
    }
    segments.add(phase);
  }
  return segments;
}

/// Angle (radians) for a 1-based day on a dial of [total] days.
/// Day 1 sits at the top; days advance clockwise.
double odometerAngle(int day, int total) {
  final n = total < 1 ? 1 : total;
  final d = day.clamp(1, n);
  return -math.pi / 2 + (d - 1) / n * math.pi * 2;
}

/// Odometer-style cycle dial: per-day phase segments, ticks, numerals,
/// and an animated needle pointing at [currentDay].
///
/// - [cycleLen]/[periodLen]: ring sizing (clamped by the mapper).
/// - [ovulationDay]: 1-based tracked/estimated ovulation day, or null.
/// - [ovulationLocked]: LH-confirmed marker on the ovulation segment.
/// - [currentDay]: may exceed [cycleLen] when late — the needle parks on
///   the final segment while [dayLabel] still shows the true number.
/// - [dayLabel]: center headline (e.g. "Today: Day 32").
/// - [phaseLabel]: center subline (e.g. "Luteal Phase").
/// - [statusLabel]: center footnote ("Ovulation Locked ✓" / default).
/// - [statusColor]: footnote color.
class CycleOdometer extends StatelessWidget {
  final int cycleLen;
  final int periodLen;
  final int? ovulationDay;
  final bool ovulationLocked;
  final int currentDay;
  final String dayLabel;
  final String phaseLabel;
  final String statusLabel;
  final Color statusColor;

  const CycleOdometer({
    super.key,
    required this.cycleLen,
    required this.periodLen,
    required this.ovulationDay,
    required this.ovulationLocked,
    required this.currentDay,
    required this.dayLabel,
    required this.phaseLabel,
    required this.statusLabel,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    final her = context.her;
    final segments = odometerSegments(
      cycleLen: cycleLen,
      periodLen: periodLen,
      ovulationDay: ovulationDay,
    );
    final n = segments.length;
    // Day-by-day needle motion: sweep forward from yesterday's angle to
    // today's on every change (and on first build, for the intro).
    final target = odometerAngle(currentDay, n);
    final start = odometerAngle(currentDay - 1 < 1 ? n : currentDay - 1, n);
    return SizedBox(
      width: 300,
      height: 300,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(300, 300),
            painter: _OdometerPainter(
              segments: segments,
              numeralColor: her.muted,
              tickColor: her.muted.withValues(alpha: 0.5),
              ovulationLocked: ovulationLocked,
            ),
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: start, end: target),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, angle, _) => CustomPaint(
              size: const Size(300, 300),
              painter: _NeedlePainter(
                angle: angle,
                needleColor: context.her.ink,
                hubColor: const Color(0xFFC26D81),
              ),
            ),
          ),
          Container(
            width: 208,
            height: 208,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: her.card,
              boxShadow: [
                BoxShadow(
                    color: Colors.pink.withValues(alpha: 0.10),
                    blurRadius: 16,
                    offset: const Offset(0, 4)),
              ],
            ),
            // Scale-down guard: at large system text scales the
            // headline still fits the fixed dial instead of overflowing.
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                        ovulationLocked ? Icons.lock : Icons.star,
                        color: ovulationLocked
                            ? Colors.green
                            : const Color(0xFFFFD166),
                        size: 26),
                    const SizedBox(height: 4),
                    Text(dayLabel,
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: her.ink)),
                    const SizedBox(height: 4),
                    Text("You're in your\n$phaseLabel!",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFC26D81))),
                    const SizedBox(height: 4),
                    Text(statusLabel,
                        style: TextStyle(
                            fontSize: 12,
                            color: statusColor,
                            fontStyle: FontStyle.italic)),
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

/// Phase legend dots for placement under the dial.
class OdometerLegend extends StatelessWidget {
  const OdometerLegend({super.key});

  @override
  Widget build(BuildContext context) {
    const items = [
      ('Period', OdometerPhase.menstrual),
      ('Follicular', OdometerPhase.follicular),
      ('Fertile', OdometerPhase.fertile),
      ('Luteal', OdometerPhase.luteal),
    ];
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final (label, phase) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: odometerPhaseColors[phase],
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: 12, color: context.her.muted)),
            ],
          ),
      ],
    );
  }
}

class _OdometerPainter extends CustomPainter {
  final List<OdometerPhase> segments;
  final Color numeralColor;
  final Color tickColor;
  final bool ovulationLocked;

  const _OdometerPainter({
    required this.segments,
    required this.numeralColor,
    required this.tickColor,
    required this.ovulationLocked,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final n = segments.length;
    final outer = size.width / 2 - 4;
    final stroke = 24.0;
    final radius = outer - stroke / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const gap = 0.012; // radians between day segments

    for (var i = 0; i < n; i++) {
      final start = -math.pi / 2 + i / n * math.pi * 2 + gap / 2;
      final sweep = math.pi * 2 / n - gap;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..color = odometerPhaseColors[segments[i]]!
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.butt,
      );
    }

    // Ticks + numerals (every 7th day plus the final day).
    final tickInner = outer - stroke - 6;
    for (var i = 0; i < n; i++) {
      final day = i + 1;
      final angle = -math.pi / 2 + i / n * math.pi * 2;
      final dir = Offset(math.cos(angle), math.sin(angle));
      final labeled = day == 1 || day == n || day % 7 == 1;
      final len = labeled ? 9.0 : 5.0;
      canvas.drawLine(
        center + dir * (tickInner - len),
        center + dir * tickInner,
        Paint()
          ..color = tickColor
          ..strokeWidth = labeled ? 2.0 : 1.2
          ..strokeCap = StrokeCap.round,
      );
      if (labeled) {
        final tp = TextPainter(
          text: TextSpan(
            text: '$day',
            style: TextStyle(
                color: numeralColor,
                fontSize: 11,
                fontWeight: FontWeight.w600),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final pos = center + dir * (tickInner - 20) -
            Offset(tp.width / 2, tp.height / 2);
        tp.paint(canvas, pos);
      }
    }

    // LH-confirmed ovulation marker: white ring on that segment.
    if (ovulationLocked) {
      for (var i = 0; i < n; i++) {
        if (segments[i] == OdometerPhase.ovulation) {
          final angle = -math.pi / 2 + (i + 0.5) / n * math.pi * 2;
          final pos = Offset(center.dx + radius * math.cos(angle),
              center.dy + radius * math.sin(angle));
          canvas.drawCircle(
            pos,
            7,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.5,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _OdometerPainter old) =>
      old.segments != segments ||
      old.numeralColor != numeralColor ||
      old.tickColor != tickColor ||
      old.ovulationLocked != ovulationLocked;
}

class _NeedlePainter extends CustomPainter {
  final double angle;
  final Color needleColor;
  final Color hubColor;

  const _NeedlePainter({
    required this.angle,
    required this.needleColor,
    required this.hubColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final dir = Offset(math.cos(angle), math.sin(angle));
    // Tail + shaft: classic odometer nail with a glowing tip on the ring.
    canvas.drawLine(
      center - dir * 26,
      center + dir * 118,
      Paint()
        ..color = needleColor
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      center + dir * 118,
      7,
      Paint()
        ..color = hubColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(center, 13, Paint()..color = hubColor);
    canvas.drawCircle(center, 13,
        Paint()..color = Colors.white.withValues(alpha: 0.35));
    canvas.drawCircle(center, 5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _NeedlePainter old) =>
      old.angle != angle ||
      old.needleColor != needleColor ||
      old.hubColor != hubColor;
}
