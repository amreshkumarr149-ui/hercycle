import 'package:flutter/material.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/core/week_planner.dart';
import 'package:intl/intl.dart';

/// "Plan with your cycle": 7-day outlook chips tagged from tracked data.
/// Pure presentation — all rules live in [planWeek]. Tapping a day explains
/// the "why" with the user's own signals, never population averages.
class WeekPlannerCard extends StatelessWidget {
  final List<PlannedDay> days;
  final bool personalized;

  const WeekPlannerCard(
      {super.key, required this.days, required this.personalized});

  (IconData, Color) _badge(DayEnergy energy) {
    return switch (energy) {
      DayEnergy.period => (Icons.water_drop, const Color(0xFFE53935)),
      DayEnergy.high => (Icons.bolt_outlined, const Color(0xFFFB8C00)),
      DayEnergy.pmsLikely => (Icons.nights_stay_outlined, const Color(0xFF7E57C2)),
      DayEnergy.rest => (Icons.bedtime_outlined, const Color(0xFF00ACC1)),
      DayEnergy.calm => (Icons.spa_outlined, const Color(0xFF83C5BE)),
    };
  }

  String _label(DayEnergy energy) {
    return switch (energy) {
      DayEnergy.period => 'Period',
      DayEnergy.high => 'High energy',
      DayEnergy.pmsLikely => 'PMS likely',
      DayEnergy.rest => 'Rest',
      DayEnergy.calm => 'Steady',
    };
  }

  void _showDay(BuildContext context, PlannedDay day) {
    final (icon, color) = _badge(day.energy);
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  '${DateFormat('EEE, MMM dd').format(day.date)} — ${_label(day.energy)}'),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in day.reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('• $r',
                    style: const TextStyle(fontSize: 14, height: 1.5)),
              ),
            const SizedBox(height: 6),
            Text(
              personalized
                  ? 'Based on your tracked cycle and symptom patterns.'
                  : 'Based on typical cycle lengths — log daily to personalize.',
              style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: d.her.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Defensive: the mapper contract is 7 days, but never render a
    // broken strip if a caller passes anything else.
    if (days.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.her.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF9C8D2), width: 1.5),
        boxShadow: [
          BoxShadow(
              color: Colors.pink.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event_note_outlined,
                  color: Color(0xFFC26D81), size: 20),
              const SizedBox(width: 8),
              Text('Plan With Your Cycle',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: context.her.ink)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            personalized
                ? 'Your next 7 days, from your own patterns'
                : 'Your next 7 days, from typical lengths',
            style: TextStyle(fontSize: 12, color: context.her.muted),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (var i = 0; i < days.length; i++)
                Expanded(
                  child: GestureDetector(
                    onTap: () => _showDay(context, days[i]),
                    child: Container(
                      margin: EdgeInsets.only(
                          right: i == days.length - 1 ? 0 : 6),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: _badge(days[i].energy)
                            .$2
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: i == 0
                            ? Border.all(
                                color: const Color(0xFFC26D81), width: 1.5)
                            : null,
                      ),
                      child: Column(
                        children: [
                          Text(
                            DateFormat('E').format(days[i].date),
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: context.her.muted),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${days[i].date.day}',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: context.her.ink),
                          ),
                          const SizedBox(height: 4),
                          Icon(_badge(days[i].energy).$1,
                              color: _badge(days[i].energy).$2, size: 18),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
