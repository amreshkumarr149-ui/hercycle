import 'package:flutter/material.dart';
import 'package:hercycle/core/ttc_insights.dart';
import 'package:intl/intl.dart';

/// Trying-to-conceive hero: peak countdown, fertile-window coverage dots
/// and test-day pointer. Awareness only — the dialog states plainly that
/// nothing here confirms conception.
class TtcHeroCard extends StatelessWidget {
  final TtcStatus status;

  const TtcHeroCard({super.key, required this.status});

  String _peakLine() {
    final peak = status.peakDay;
    if (peak == null) return 'Log periods to find your fertile window';
    final when = status.daysToPeak;
    final fmt = DateFormat('MMM dd').format(peak);
    if (when == null) return 'Peak day: $fmt';
    if (when > 1) return 'Peak day in $when days • $fmt';
    if (when == 1) return 'Peak day tomorrow • $fmt';
    if (when == 0) return 'Peak day is today 💗';
    return 'Peak day was $fmt';
  }

  String _testLine() {
    final test = status.testDay;
    if (test == null) return 'Test day unlocks with your fertile window';
    final fmt = DateFormat('MMM dd').format(test);
    final when = status.daysToTest;
    if (when == null) return 'Suggested test day: $fmt';
    if (when > 1) return 'Suggested test day: $fmt (in $when days)';
    if (when == 1) return 'Suggested test day: tomorrow ($fmt)';
    if (when == 0) return 'Suggested test day: today ($fmt)';
    return 'Suggested test day was $fmt';
  }

  void _showExplainer(BuildContext context) {
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Trying to conceive'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Log intimacy on fertile days to fill the coverage dots — '
              'consistency across the whole window matters more than any '
              'single day.',
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            SizedBox(height: 8),
            Text(
              'Nothing here can confirm conception — only a pregnancy test '
              'taken on or after the suggested day can. If cycles stay '
              'irregular or conception takes many months, talk to a doctor.',
              style: TextStyle(fontSize: 14, height: 1.5),
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
    final peak = status.peakDay;
    return InkWell(
      onTap: () => _showExplainer(context),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF8E3A5B), Color(0xFFE29578)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.pink.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 4)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.favorite, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Text('Trying to Conceive',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
              ],
            ),
            const SizedBox(height: 10),
            if (peak == null)
              const Text(
                'Log your periods (and LH tests) to find your fertile window.',
                style: TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
              )
            else ...[
              TweenAnimationBuilder<double>(
                tween: Tween(
                    begin: 0,
                    end: (status.daysToPeak ?? 0)
                        .clamp(0, 99)
                        .toDouble()),
                duration: const Duration(milliseconds: 1000),
                curve: Curves.easeOutCubic,
                builder: (context, v, child) => Text(
                  (status.daysToPeak ?? 0) <= 0
                      ? _peakLine()
                      : 'Peak in ${v.round()} day${v.round() == 1 ? '' : 's'} 💗',
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                ),
              ),
              const SizedBox(height: 4),
              Text(_peakLine(),
                  style: const TextStyle(
                      fontSize: 13, color: Colors.white70)),
              const SizedBox(height: 10),
              // Coverage dots across the 7-day fertile window.
              _CoverageDots(status: status),
              const SizedBox(height: 10),
              Text(_testLine(),
                  style: const TextStyle(
                      fontSize: 13, color: Colors.white)),
              Text(
                status.estimated
                    ? 'Mid-cycle estimate — LH tests confirm it.'
                    : 'From your tracked ovulation.',
                style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                    fontStyle: FontStyle.italic),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CoverageDots extends StatelessWidget {
  final TtcStatus status;

  const _CoverageDots({required this.status});

  @override
  Widget build(BuildContext context) {
    final peak = status.peakDay;
    if (peak == null) return const SizedBox.shrink();
    final start = peak.subtract(const Duration(days: 5));
    final today = DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);
    String keyOf(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return Row(
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Builder(
              builder: (context) {
                final day = start.add(Duration(days: i));
                final covered = status.coveredKeys.contains(keyOf(day));
                final isToday = day.isAtSameMomentAs(todayDay);
                return Container(
                  height: 8,
                  margin: EdgeInsets.only(right: i == 6 ? 0 : 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    color: covered
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.3),
                    border: isToday
                        ? Border.all(color: Colors.white, width: 1.5)
                        : null,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
