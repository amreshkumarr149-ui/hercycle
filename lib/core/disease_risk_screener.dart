import 'package:hercycle/models/daily_log.dart';

class RiskAssessmentResult {
  final String condition;
  final String title;
  final String description;
  final bool isFlagged;

  RiskAssessmentResult({
    required this.condition,
    required this.title,
    required this.description,
    required this.isFlagged,
  });
}

class DiseaseRiskScreener {
  /// Evaluates cycle history and daily logs against clinical patterns for
  /// PCOS, Fibroids, and Endometriosis.
  ///
  /// Hardened: date-gap-aware consecutive-day counting (list adjacency is
  /// NOT consecutiveness), endometriosis pain checked outside the first two
  /// bleeding days per spec, PCOS variance derived from observed period
  /// starts, future-dated and malformed logs excluded. Output is strictly
  /// non-diagnostic ("risk pattern identified").
  static List<RiskAssessmentResult> evaluate({
    required List<DailyLog> allLogs,
    required int typicalCycleLength,
  }) {
    List<RiskAssessmentResult> results = [];

    final today = DateTime.now();
    final todayDay =
        DateTime(today.year, today.month, today.day);

    // Parse once, drop malformed + future-dated logs, sort chronologically.
    final entries = <({DateTime date, DailyLog log})>[];
    for (final log in allLogs) {
      final d = DateTime.tryParse(log.date);
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      if (day.isAfter(todayDay)) continue;
      entries.add((date: day, log: log));
    }
    entries.sort((a, b) => a.date.compareTo(b.date));

    bool isBleeding(DailyLog l) =>
        l.period || l.flowIntensity != 'None';

    // ---- Derive observed period starts + cycle intervals from logs ----
    // A period start = bleeding day whose previous calendar day is NOT bleeding.
    final bleedingDays = <DateTime>{};
    for (final e in entries) {
      if (isBleeding(e.log)) bleedingDays.add(e.date);
    }
    final periodStarts = <DateTime>[];
    for (final d in bleedingDays) {
      final prev = d.subtract(const Duration(days: 1));
      if (!bleedingDays.contains(prev)) periodStarts.add(d);
    }
    periodStarts.sort();
    final intervals = <int>[];
    for (var i = 1; i < periodStarts.length; i++) {
      intervals.add(periodStarts[i].difference(periodStarts[i - 1]).inDays);
    }
    final hasHighVariance = intervals.length >= 2 &&
        (intervals.reduce((a, b) => a > b ? a : b) -
                intervals.reduce((a, b) => a < b ? a : b) >
            10);

    // ---- 1. PCOS: (cycle > 35d OR observed variance > 10d) AND >= 2
    // positive LH tests >= 4 days apart in a single cycle window ----
    bool pcosFlagged = false;
    final longOrVariable =
        typicalCycleLength > 35 || hasHighVariance;
    if (longOrVariable) {
      final positiveLhDates = <DateTime>[];
      for (final e in entries) {
        if (e.log.lhTest.toLowerCase() == 'positive') {
          positiveLhDates.add(e.date);
        }
      }
      positiveLhDates.sort();
      // "Single cycle" approximated as a 60-day window so stale positives
      // from months ago can't combine into a false flag.
      for (var i = 0; i < positiveLhDates.length; i++) {
        for (var j = i + 1; j < positiveLhDates.length; j++) {
          final gap =
              positiveLhDates[j].difference(positiveLhDates[i]).inDays;
          if (gap >= 4 && gap <= 60) {
            pcosFlagged = true;
            break;
          }
        }
        if (pcosFlagged) break;
      }
    }

    results.add(RiskAssessmentResult(
      condition: 'PCOS',
      title: 'Polycystic Ovary Syndrome (PCOS)',
      description:
          'Clinical risk pattern identified based on extended cycle length and LH test frequency. (Educational tracking only, not a medical diagnosis.)',
      isFlagged: pcosFlagged,
    ));

    // ---- 2. Fibroids: bleeding > 8 CONSECUTIVE calendar days OR Heavy
    // flow >= 3 consecutive calendar days AND pelvic pressure logged ----
    bool fibroidsFlagged = false;
    bool hasPelvicPressure =
        entries.any((e) => e.log.pelvicPressure);
    int runBleed = 0;
    int runHeavy = 0;
    DateTime? prevDate;
    for (final e in entries) {
      // Gap in calendar days breaks consecutiveness.
      if (prevDate != null &&
          e.date.difference(prevDate).inDays > 1) {
        runBleed = 0;
        runHeavy = 0;
      }
      if (isBleeding(e.log)) {
        runBleed++;
        if (e.log.flowIntensity == 'Heavy') {
          runHeavy++;
        } else {
          runHeavy = 0;
        }
      } else {
        runBleed = 0;
        runHeavy = 0;
      }
      if (runBleed > 8 ||
          (runHeavy >= 3 && hasPelvicPressure)) {
        fibroidsFlagged = true;
        break;
      }
      prevDate = e.date;
    }

    results.add(RiskAssessmentResult(
      condition: 'Fibroids',
      title: 'Uterine Fibroids Pattern',
      description:
          'Clinical risk pattern identified based on prolonged bleeding duration or heavy flow combined with pelvic pressure logs. (Educational tracking only, not a medical diagnosis.)',
      isFlagged: fibroidsFlagged,
    ));

    // ---- 3. Endometriosis: pain >= 7 outside the first 2 bleeding days
    // of its episode, OR severe lower back/bowel pain ----
    bool endoFlagged = false;
    // Map each bleeding day -> its episode start for the 2-day window check.
    final episodeStartOf = <DateTime, DateTime>{};
    {
      DateTime? runStart;
      DateTime? prev;
      // Walk sorted unique bleeding days in order.
      final sortedBleed = bleedingDays.toList()..sort();
      for (final d in sortedBleed) {
        if (prev == null || d.difference(prev).inDays > 1) {
          runStart = d;
        }
        episodeStartOf[d] = runStart!;
        prev = d;
      }
    }
    for (final e in entries) {
      if (e.log.backBowelPain) {
        endoFlagged = true;
        break;
      }
      if (e.log.painScore >= 7) {
        final start = episodeStartOf[e.date];
        if (start == null) {
          // High pain on a non-bleeding day counts per spec.
          endoFlagged = true;
          break;
        }
        final dayIndex = e.date.difference(start).inDays;
        if (dayIndex > 1) {
          endoFlagged = true;
          break;
        }
      }
    }

    results.add(RiskAssessmentResult(
      condition: 'Endometriosis',
      title: 'Endometriosis Pattern',
      description:
          'Clinical risk pattern identified based on high pain scores outside early bleeding days or severe lower back/bowel pain logs. (Educational tracking only, not a medical diagnosis.)',
      isFlagged: endoFlagged,
    ));

    return results;
  }
}
