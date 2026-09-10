import 'package:hercycle/models/daily_log.dart';

/// Phases used to organise per-cycle logs. Ovulation is only ever
/// [CyclePhase.ovulation] with [CycleRecord.ovulationConfirmed] true when an
/// LH peak was actually logged; otherwise it is an estimate.
enum CyclePhase { menstrual, follicular, ovulation, luteal, unknown }

/// One reconstructed cycle with all of its tracked day-logs attached.
class CycleRecord {
  final int number; // 1 = oldest in the analysed set
  final DateTime start;
  final DateTime? end; // next start; null = ongoing / last observed
  final int? length; // days start -> end, null when ongoing
  final int bleedingDays;
  final List<DailyLog> days; // logs with date in [start, end)
  final DateTime? confirmedOvulation; // positive LH date + 1
  final DateTime? estimatedOvulation; // start + (length ?? typical) - 14
  final bool ovulationConfirmed;

  CycleRecord({
    required this.number,
    required this.start,
    required this.end,
    required this.length,
    required this.bleedingDays,
    required this.days,
    required this.confirmedOvulation,
    required this.estimatedOvulation,
    required this.ovulationConfirmed,
  });

  DateTime? get ovulationAnchor => confirmedOvulation ?? estimatedOvulation;
}

/// One baseline metric row: tracked value + optional reference + neutral tag.
class BaselineMetric {
  final String name;
  final String value;
  final String reference;
  final String tag; // Normal / Elevated / Lower than typical / Variable / Insufficient Data
  BaselineMetric(this.name, this.value, this.reference, this.tag);
}

/// A detected pattern with supporting evidence (never a diagnosis).
class TrackedPattern {
  final String name;
  final String trigger;
  final String observations;
  final int cycleCount;
  final List<String> dates;
  final String context;
  final String nextStep;
  TrackedPattern({
    required this.name,
    required this.trigger,
    required this.observations,
    required this.cycleCount,
    required this.dates,
    required this.context,
    required this.nextStep,
  });
}

/// One trend row with a visual indicator.
class TrendRow {
  final String name;
  final String indicator; // ↑ ↓ → ⚠ ✓
  final String detail;
  TrendRow(this.name, this.indicator, this.detail);
}

/// Symptom roll-up.
class SymptomSummary {
  final String name;
  final int occurrences;
  final String avgSeverity; // e.g. "6/10" or "—"
  final int cyclesAffected;
  final String typicalPhase;
  final String recent;
  SymptomSummary({
    required this.name,
    required this.occurrences,
    required this.avgSeverity,
    required this.cyclesAffected,
    required this.typicalPhase,
    required this.recent,
  });
}

/// The complete report model. Every field derives from tracked records;
/// missing data is reported as "Insufficient Data", never fabricated.
class ClinicalReport {
  final String userName;
  final String email;
  final String age;
  final String generatedDate;
  final String windowLabel;
  final String trackingDuration;
  final String trackingMode; // Online / Offline (cached)
  final int cyclesAnalyzed;
  final int daysLogged;
  final int spanDays;

  final List<BaselineMetric> baselines;
  final List<TrackedPattern> patterns;
  final List<CycleRecord> cycles;
  final List<TrendRow> trends;
  final List<SymptomSummary> symptoms;
  final List<String> insights;
  final List<String> attentionFlags;
  final String? urgentMessage;
  final String dataQualityNote;
  final String reliability; // High / Moderate / Low / Insufficient
  final List<String> summaryBullets;

  ClinicalReport({
    required this.userName,
    required this.email,
    required this.age,
    required this.generatedDate,
    required this.windowLabel,
    required this.trackingDuration,
    required this.trackingMode,
    required this.cyclesAnalyzed,
    required this.daysLogged,
    required this.spanDays,
    required this.baselines,
    required this.patterns,
    required this.cycles,
    required this.trends,
    required this.symptoms,
    required this.insights,
    required this.attentionFlags,
    required this.urgentMessage,
    required this.dataQualityNote,
    required this.reliability,
    required this.summaryBullets,
  });
}

String _d(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class ClinicalReportEngine {
  /// Builds the full report. [windowDays] null = all history.
  static ClinicalReport build({
    required Map<String, dynamic>? profile,
    required List<DailyLog> allLogs,
    required int? windowDays,
    required bool fromCache,
    DateTime? now,
  }) {
    final today = now ?? DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);

    final name = profile?['name']?.toString() ?? 'User';
    final email = profile?['email']?.toString() ?? '';
    final age = _age(profile?['dateOfBirth'], todayDay);
    final typicalCycle = _asInt(profile?['typicalCycleLength'], 28).clamp(15, 60);

    // ---- Sanitize entries ----
    final entries = <({DateTime date, DailyLog log})>[];
    for (final log in allLogs) {
      final d = DateTime.tryParse(log.date);
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      if (day.isAfter(todayDay)) continue;
      entries.add((date: day, log: log));
    }
    entries.sort((a, b) => a.date.compareTo(b.date));

    // ---- Window ----
    final windowLabel = windowDays == null ? 'All history' : 'Past $windowDays days';
    final cutoff = windowDays == null
        ? null
        : todayDay.subtract(Duration(days: windowDays - 1));
    final inWindow = cutoff == null
        ? entries
        : entries.where((e) => !e.date.isBefore(cutoff)).toList();

    bool isBleeding(DailyLog l) => l.period || l.flowIntensity != 'None';

    // ---- Period starts (from full history so intervals stay correct) ----
    final bleedingDaysAll = <DateTime>{};
    for (final e in entries) {
      if (isBleeding(e.log)) bleedingDaysAll.add(e.date);
    }
    final startsAll = <DateTime>[];
    for (final d in bleedingDaysAll) {
      if (!bleedingDaysAll.contains(d.subtract(const Duration(days: 1)))) {
        startsAll.add(d);
      }
    }
    startsAll.sort();

    // ---- Reconstruct cycles overlapping the window ----
    final cycles = <CycleRecord>[];
    for (var i = 0; i < startsAll.length; i++) {
      final start = startsAll[i];
      final end = i + 1 < startsAll.length ? startsAll[i + 1] : null;
      if (cutoff != null && end != null && end.isBefore(cutoff)) continue;
      if (cutoff != null && end == null && start.isBefore(cutoff)) {
        // Ongoing cycle that started before the window still counts if it
        // overlaps, but keep the window honest: only if it reaches into it.
        if (start.isBefore(cutoff)) continue;
      }
      final days = entries
          .where((e) =>
              !e.date.isBefore(start) && (end == null || e.date.isBefore(end)))
          .map((e) => e.log)
          .toList();
      final length = end?.difference(start).inDays;
      var bleed = 0;
      var d = start;
      final stop = end ?? todayDay.add(const Duration(days: 1));
      while (d.isBefore(stop)) {
        if (bleedingDaysAll.contains(d)) bleed++;
        d = d.add(const Duration(days: 1));
      }
      DateTime? confirmed;
      for (final log in days) {
        if (log.lhTest.toLowerCase() == 'positive') {
          final ld = DateTime.tryParse(log.date);
          if (ld != null) {
            confirmed = DateTime(ld.year, ld.month, ld.day)
                .add(const Duration(days: 1));
            break;
          }
        }
      }
      // Same convention as the live predictor: ovulation on cycle day
      // (length - 14), i.e. date offset (length - 15).
      final anchorLen = length ?? typicalCycle;
      final estimated =
          start.add(Duration(days: (anchorLen - 15).clamp(0, 89)));
      cycles.add(CycleRecord(
        number: cycles.length + 1,
        start: start,
        end: end,
        length: length,
        bleedingDays: bleed,
        days: days,
        confirmedOvulation: confirmed,
        estimatedOvulation: estimated,
        ovulationConfirmed: confirmed != null,
      ));
    }

    final complete = cycles.where((c) => c.length != null).toList();
    final loggedDays =
        inWindow.map((e) => e.date).toSet().length;
    final spanDays = windowDays ??
        (entries.isEmpty
            ? 0
            : todayDay.difference(entries.first.date).inDays + 1);

    CyclePhase phaseOf(CycleRecord c, DateTime day) {
      final bleedEnd = c.start.add(Duration(days: c.bleedingDays));
      if (!day.isBefore(c.start) && day.isBefore(bleedEnd)) {
        return CyclePhase.menstrual;
      }
      final ovu = c.ovulationAnchor;
      if (ovu == null) return CyclePhase.unknown;
      final fertileStart = ovu.subtract(const Duration(days: 5));
      final fertileEnd = ovu.add(const Duration(days: 2));
      if (!day.isBefore(fertileStart) && day.isBefore(fertileEnd)) {
        return CyclePhase.ovulation;
      }
      if (day.isBefore(fertileStart)) return CyclePhase.follicular;
      return CyclePhase.luteal;
    }

    // ---- 1. Baselines ----
    final baselines = <BaselineMetric>[];
    if (complete.length >= 2) {
      final lens = complete.map((c) => c.length!).toList();
      final avgLen = lens.reduce((a, b) => a + b) / lens.length;
      final variation = lens.reduce((a, b) => a > b ? a : b) -
          lens.reduce((a, b) => a < b ? a : b);
      baselines.add(BaselineMetric(
        'Average Cycle Length',
        '${avgLen.toStringAsFixed(1)} days',
        'Typical reference: 21–35 days',
        avgLen > 35
            ? 'Elevated'
            : avgLen < 21
                ? 'Lower than typical'
                : 'Normal',
      ));
      baselines.add(BaselineMetric(
        'Cycle-to-cycle variation',
        '$variation days',
        'Up to ~7 days is commonly seen',
        variation > 10
            ? 'Variable'
            : variation > 7
                ? 'Somewhat variable'
                : 'Normal',
      ));
      final bleeds = complete.map((c) => c.bleedingDays).toList();
      final avgBleed = bleeds.reduce((a, b) => a + b) / bleeds.length;
      baselines.add(BaselineMetric(
        'Average Bleeding Duration',
        '${avgBleed.toStringAsFixed(1)} days',
        'Typical reference: 2–7 days',
        avgBleed > 8
            ? 'Elevated'
            : avgBleed < 2
                ? 'Lower than typical'
                : 'Normal',
      ));
      // Luteal average from confirmed ovulations only.
      final luteals = <int>[];
      for (final c in complete) {
        if (c.confirmedOvulation != null && c.end != null) {
          luteals.add(c.end!.difference(c.confirmedOvulation!).inDays);
        }
      }
      if (luteals.length >= 2) {
        final avg = luteals.reduce((a, b) => a + b) / luteals.length;
        baselines.add(BaselineMetric(
          'Average Luteal Phase',
          '${avg.toStringAsFixed(1)} days (confirmed)',
          'Typical reference: 12–14 days',
          'Normal',
        ));
      } else {
        baselines.add(BaselineMetric(
          'Average Luteal Phase',
          'Insufficient Data',
          'Needs 2+ LH-confirmed ovulations',
          'Insufficient Data',
        ));
      }
      // Estimated/confirmed ovulation window from most recent complete cycle.
      final ref = complete.last;
      final ovu = ref.ovulationAnchor;
      baselines.add(BaselineMetric(
        'Ovulation Window',
        ovu == null
            ? 'Insufficient Data'
            : '${_d(ovu.subtract(const Duration(days: 5)))} → ${_d(ovu)} (${ref.ovulationConfirmed ? 'confirmed' : 'estimated'})',
        'Confirmed only with a logged LH peak',
        ovu == null ? 'Insufficient Data' : 'Normal',
      ));
      // Average flow (ordinal scale).
      const flowRank = {'None': 0, 'Light': 1, 'Medium': 2, 'Heavy': 3};
      final flows = <int>[];
      for (final c in complete) {
        for (final l in c.days) {
          flows.add(flowRank[l.flowIntensity] ?? 0);
        }
      }
      final flowDays = flows.where((f) => f > 0).toList();
      baselines.add(BaselineMetric(
        'Average Flow Intensity',
        flowDays.isEmpty
            ? 'Insufficient Data'
            : _flowLabel(
                (flowDays.reduce((a, b) => a + b) / flowDays.length)
                    .round()
                    .clamp(1, 3)),
        'Light / Medium / Heavy as logged',
        flowDays.isEmpty ? 'Insufficient Data' : 'Normal',
      ));
      // Average pain across days with pain > 0.
      final pains = <int>[];
      for (final c in complete) {
        for (final l in c.days) {
          if (l.painScore > 0) pains.add(l.painScore);
        }
      }
      baselines.add(BaselineMetric(
        'Average Pain Score',
        pains.isEmpty
            ? 'No pain logged'
            : '${(pains.reduce((a, b) => a + b) / pains.length).toStringAsFixed(1)}/10 across ${pains.length} days',
        'Severe pain is not typical — worth discussing',
        pains.isEmpty
            ? 'Normal'
            : (pains.reduce((a, b) => a + b) / pains.length) >= 7
                ? 'Elevated'
                : (pains.reduce((a, b) => a + b) / pains.length) >= 4
                    ? 'Moderate'
                    : 'Mild',
      ));
    } else {
      for (final n in [
        'Average Cycle Length',
        'Cycle-to-cycle variation',
        'Average Bleeding Duration',
        'Average Luteal Phase',
        'Ovulation Window',
        'Average Flow Intensity',
        'Average Pain Score'
      ]) {
        baselines.add(BaselineMetric(
            n, 'Insufficient Data', 'Needs 2+ complete cycles', 'Insufficient Data'));
      }
    }

    // ---- 2. Pattern screening (generic, evidence-attached) ----
    final patterns = <TrackedPattern>[];
    void addPattern({
      required String name,
      required String trigger,
      required String observations,
      required int cycleCount,
      required List<String> dates,
      required String context,
      required String nextStep,
    }) {
      patterns.add(TrackedPattern(
        name: name,
        trigger: trigger,
        observations: observations,
        cycleCount: cycleCount,
        dates: dates,
        context: context,
        nextStep: nextStep,
      ));
    }

    if (complete.length >= 2) {
      final long = complete.where((c) => c.length! > 35).toList();
      if (long.isNotEmpty) {
        addPattern(
          name: 'Unusually long cycles',
          trigger: 'Cycle length above 35 days',
          observations:
              'Observed lengths: ${long.map((c) => '${c.length}d').join(', ')}.',
          cycleCount: long.length,
          dates: long.map((c) => _d(c.start)).toList(),
          context:
              'Longer cycles can sometimes occur with hormonal variation and may be associated with conditions worth discussing with a healthcare professional.',
          nextStep: 'Continue logging; consider discussing persistent long cycles at your next check-up.',
        );
      }
      final short = complete.where((c) => c.length! < 21).toList();
      if (short.isNotEmpty) {
        addPattern(
          name: 'Unusually short cycles',
          trigger: 'Cycle length below 21 days',
          observations:
              'Observed lengths: ${short.map((c) => '${c.length}d').join(', ')}.',
          cycleCount: short.length,
          dates: short.map((c) => _d(c.start)).toList(),
          context:
              'Short cycles can sometimes occur with natural variation; frequent short cycles are worth discussing with a healthcare professional.',
          nextStep: 'Keep tracking for another 1–2 cycles and share this report with your doctor if it continues.',
        );
      }
      // Missed / late: interval beyond typical + 7.
      final late = <CycleRecord>[];
      for (final c in complete) {
        if (c.length! > typicalCycle + 7) late.add(c);
      }
      if (late.isNotEmpty) {
        addPattern(
          name: 'Possible missed or late period',
          trigger: 'Cycle longer than your typical length + 7 days',
          observations:
              'Affected starts: ${late.map((c) => _d(c.start)).join(', ')}.',
          cycleCount: late.length,
          dates: late.map((c) => _d(c.start)).toList(),
          context:
              'A late period can occur with stress, routine changes, or natural variation, and can sometimes occur with other factors worth discussing.',
          nextStep: 'If sexually active, consider a pregnancy test; otherwise keep logging and discuss repeats with a professional.',
        );
      }
      // Irregular: variation > 10.
      final lens = complete.map((c) => c.length!).toList();
      final variation = lens.reduce((a, b) => a > b ? a : b) -
          lens.reduce((a, b) => a < b ? a : b);
      if (lens.length >= 3 && variation > 10) {
        addPattern(
          name: 'Irregular cycle timing',
          trigger: 'Cycle-to-cycle variation above 10 days',
          observations:
              'Range observed: ${lens.reduce((a, b) => a < b ? a : b)}–${lens.reduce((a, b) => a > b ? a : b)} days across ${lens.length} cycles.',
          cycleCount: lens.length,
          dates: complete.map((c) => _d(c.start)).toList(),
          context:
              'Irregular timing may be associated with hormonal patterns that are worth discussing with a healthcare professional.',
          nextStep: 'Continue consistent logging for at least 3 cycles and bring this report to your appointment.',
        );
      }
    }
    // Prolonged bleeding (>8 consecutive calendar days), gap-aware.
    {
      DateTime? runStart;
      var run = 0;
      DateTime? prev;
      final episodes = <String>[];
      var affected = <int>{};
      for (final d in bleedingDaysAll.toList()..sort()) {
        if (cutoff != null && d.isBefore(cutoff)) {
          prev = d;
          continue;
        }
        if (prev == null || d.difference(prev).inDays > 1) {
          runStart = d;
          run = 1;
        } else {
          run++;
        }
        if (run > 8) {
          episodes.add('${_d(runStart!)} (+$run days)');
          for (final c in cycles) {
            final cycleEnd = c.end;
            if (!d.isBefore(c.start) &&
                (cycleEnd == null || d.isBefore(cycleEnd))) {
              affected.add(c.number);
            }
          }
        }
        prev = d;
      }
      if (episodes.isNotEmpty) {
        addPattern(
          name: 'Prolonged bleeding',
          trigger: 'Bleeding logged for more than 8 consecutive days',
          observations: 'Episodes: ${episodes.join('; ')}.',
          cycleCount: affected.length,
          dates: episodes,
          context:
              'Prolonged bleeding can sometimes occur with uterine factors and is worth discussing with a healthcare professional.',
          nextStep: 'Track flow intensity daily during bleeding and share this report with your doctor.',
        );
      }
    }
    // Consistently heavy flow: Heavy on 3+ days within a cycle, 2+ cycles.
    {
      final heavyCycles = <CycleRecord>[];
      for (final c in cycles) {
        final heavyDays =
            c.days.where((l) => l.flowIntensity == 'Heavy').length;
        if (heavyDays >= 3) heavyCycles.add(c);
      }
      if (heavyCycles.length >= 2) {
        addPattern(
          name: 'Consistently heavy flow',
          trigger: 'Heavy flow logged on 3+ days per cycle',
          observations:
              'Seen in cycles: ${heavyCycles.map((c) => '#${c.number}').join(', ')}.',
          cycleCount: heavyCycles.length,
          dates: heavyCycles.map((c) => _d(c.start)).toList(),
          context:
              'Repeated heavy flow may be associated with conditions such as fibroids and is worth discussing with a healthcare professional.',
          nextStep: 'Log flow intensity every bleeding day to strengthen this picture.',
        );
      }
    }
    // Severe/recurring pelvic pain.
    {
      final painCycles = <CycleRecord>{};
      final painDates = <String>[];
      for (final c in cycles) {
        for (final l in c.days) {
          if (l.painScore >= 7 || l.pelvicPressure) {
            painCycles.add(c);
            painDates.add(l.date);
          }
        }
      }
      if (painDates.length >= 3) {
        addPattern(
          name: 'Severe or recurring pelvic pain',
          trigger: 'Pain score 7+/10 or pelvic pressure logged repeatedly',
          observations:
              'Logged on ${painDates.length} days, most recently ${painDates.last}.',
          cycleCount: painCycles.length,
          dates: painDates.length > 8
              ? [...painDates.take(8), '…']
              : painDates,
          context:
              'Recurring severe pain can sometimes occur with conditions such as endometriosis and is worth discussing with a healthcare professional.',
          nextStep: 'Note pain timing (which cycle days) and bring this report to your appointment.',
        );
      }
    }
    // Recurring PMS: mood/somatic symptoms in luteal phase, 2+ cycles.
    {
      const pmsMoods = {'Irritable', 'Sad'};
      const pmsSyms = {'Headache', 'Bloating', 'Fatigue'};
      var hit = 0;
      final hitDates = <String>[];
      for (final c in cycles) {
        var found = false;
        for (final l in c.days) {
          final d = DateTime.tryParse(l.date);
          if (d == null) continue;
          if (phaseOf(c, DateTime(d.year, d.month, d.day)) !=
              CyclePhase.luteal) {
            continue;
          }
          if (l.mood.split('/').map((s) => s.trim()).any(pmsMoods.contains) ||
              l.symptoms.any(pmsSyms.contains)) {
            found = true;
            hitDates.add(l.date);
          }
        }
        if (found) hit++;
      }
      if (hit >= 2) {
        addPattern(
          name: 'Recurring PMS-type symptoms',
          trigger: 'Mood or somatic symptoms logged in the luteal phase',
          observations:
              'Seen in $hit cycles, most recently ${hitDates.isNotEmpty ? hitDates.last : '—'}.',
          cycleCount: hit,
          dates: hitDates.length > 8 ? [...hitDates.take(8), '…'] : hitDates,
          context:
              'Premenstrual symptom patterns are commonly tracked and can help you plan self-care around the late cycle.',
          nextStep: 'Continue mood logging to confirm which symptoms repeat each cycle.',
        );
      }
    }
    // Ovulation-pattern changes.
    {
      final confirmedDays = <int>[];
      for (final c in complete) {
        if (c.confirmedOvulation != null) {
          confirmedDays.add(
              c.confirmedOvulation!.difference(c.start).inDays + 1);
        }
      }
      if (confirmedDays.length >= 2) {
        final spread = confirmedDays.reduce((a, b) => a > b ? a : b) -
            confirmedDays.reduce((a, b) => a < b ? a : b);
        if (spread > 3) {
          addPattern(
            name: 'Shifting ovulation timing',
            trigger: 'LH-confirmed ovulation day varies by 4+ days',
            observations:
                'Confirmed ovulation on cycle days: ${confirmedDays.join(', ')}.',
            cycleCount: confirmedDays.length,
            dates: complete
                .where((c) => c.confirmedOvulation != null)
                .map((c) => _d(c.start))
                .toList(),
            context:
              'Ovulation timing can shift with natural variation; repeated large shifts are worth discussing with a healthcare professional.',
            nextStep: 'Keep logging LH tests through the fertile window each cycle.',
          );
        }
      }
    }

    // ---- 4. Trends (first half vs second half of complete cycles) ----
    final trends = <TrendRow>[];
    if (complete.length >= 2) {
      final half = (complete.length / 2).ceil();
      final first = complete.sublist(0, half);
      final second = complete.sublist(half);
      double avg(Iterable<num> xs) =>
          xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;
      String arrow(num delta, num threshold) {
        if (delta >= threshold) return '↑';
        if (delta <= -threshold) return '↓';
        return '→';
      }

      final dLen = avg(second.map((c) => c.length!)) -
          avg(first.map((c) => c.length!));
      trends.add(TrendRow(
        'Cycle length',
        arrow(dLen, 2),
        '${dLen >= 0 ? '+' : ''}${dLen.toStringAsFixed(1)} days vs earlier cycles',
      ));
      final dBleed = avg(second.map((c) => c.bleedingDays)) -
          avg(first.map((c) => c.bleedingDays));
      trends.add(TrendRow(
        'Bleeding duration',
        arrow(dBleed, 1),
        '${dBleed >= 0 ? '+' : ''}${dBleed.toStringAsFixed(1)} days vs earlier cycles',
      ));
      double painOf(List<CycleRecord> cs) {
        final ps = <int>[];
        for (final c in cs) {
          for (final l in c.days) {
            if (l.painScore > 0) ps.add(l.painScore);
          }
        }
        return ps.isEmpty ? 0 : ps.reduce((a, b) => a + b) / ps.length;
      }

      final dPain = painOf(second) - painOf(first);
      trends.add(TrendRow(
        'Pain',
        dPain >= 2
            ? '⚠'
            : arrow(dPain, 1),
        dPain == 0 && painOf(second) == 0
            ? 'No pain logged in either half'
            : '${dPain >= 0 ? '+' : ''}${dPain.toStringAsFixed(1)} points vs earlier cycles',
      ));
      const rank = {'None': 0, 'Light': 1, 'Medium': 2, 'Heavy': 3};
      double flowOf(List<CycleRecord> cs) {
        final fs = <int>[];
        for (final c in cs) {
          for (final l in c.days) {
            fs.add(rank[l.flowIntensity] ?? 0);
          }
        }
        final nz = fs.where((f) => f > 0).toList();
        return nz.isEmpty ? 0 : nz.reduce((a, b) => a + b) / nz.length;
      }

      final dFlow = flowOf(second) - flowOf(first);
      trends.add(TrendRow(
        'Flow intensity',
        arrow(dFlow, 0.5),
        dFlow == 0 ? 'Stable flow pattern' : 'Shifted vs earlier cycles',
      ));
      final confCount =
          complete.where((c) => c.confirmedOvulation != null).length;
      trends.add(TrendRow(
        'Ovulation consistency',
        confCount == 0
            ? '→'
            : confCount == complete.length
                ? '✓'
                : '→',
        confCount == 0
            ? 'No LH-confirmed ovulations yet — log LH tests to confirm'
            : '$confCount of ${complete.length} cycles LH-confirmed',
      ));
      // Symptom frequency shift for the top symptom.
      final freq = <String, int>{};
      for (final c in complete) {
        for (final l in c.days) {
          for (final s in l.symptoms) {
            freq[s] = (freq[s] ?? 0) + 1;
          }
        }
      }
      if (freq.isNotEmpty) {
        final top = freq.entries
            .reduce((a, b) => a.value >= b.value ? a : b);
        int countIn(List<CycleRecord> cs) {
          var n = 0;
          for (final c in cs) {
            for (final l in c.days) {
              if (l.symptoms.contains(top.key)) n++;
            }
          }
          return n;
        }

        final d = countIn(second) - countIn(first);
        trends.add(TrendRow(
          'Most frequent: ${top.key}',
          arrow(d.toDouble(), 2),
          '${top.value} days total${d == 0 ? ' — stable' : d > 0 ? ' — more often lately' : ' — less often lately'}',
        ));
      }
    }

    // ---- 5. Symptom summary ----
    final symptoms = <SymptomSummary>[];
    {
      final occ = <String, int>{};
      final sev = <String, List<int>>{};
      final cyc = <String, Set<int>>{};
      final phaseCount = <String, Map<CyclePhase, int>>{};
      final recent = <String, String>{};
      for (final c in cycles) {
        for (final l in c.days) {
          final d = DateTime.tryParse(l.date);
          final ph = d == null
              ? CyclePhase.unknown
              : phaseOf(c, DateTime(d.year, d.month, d.day));
          for (final s in l.symptoms) {
            occ[s] = (occ[s] ?? 0) + 1;
            final rating = l.symptomIntensity[s];
            if (rating != null) {
              sev.putIfAbsent(s, () => []).add(rating);
            }
            cyc.putIfAbsent(s, () => <int>{}).add(c.number);
            phaseCount.putIfAbsent(s, () => {})[ph] =
                (phaseCount[s]![ph] ?? 0) + 1;
            recent[s] = l.date;
          }
        }
      }
      final names = occ.keys.toList()
        ..sort((a, b) => occ[b]!.compareTo(occ[a]!));
      for (final s in names) {
        final ratings = sev[s] ?? [];
        final phases = phaseCount[s]!;
        final topPhase = phases.entries
            .reduce((a, b) => a.value >= b.value ? a : b)
            .key;
        symptoms.add(SymptomSummary(
          name: s,
          occurrences: occ[s]!,
          avgSeverity: ratings.isEmpty
              ? '—'
              : '${(ratings.reduce((a, b) => a + b) / ratings.length).toStringAsFixed(1)}/10',
          cyclesAffected: cyc[s]!.length,
          typicalPhase: _phaseLabel(topPhase),
          recent: recent[s]!,
        ));
      }
    }

    // ---- 6. Insights (guarded, data-only) ----
    final insights = <String>[];
    if (complete.length >= 2) {
      final lens = complete.map((c) => c.length!).toList();
      final variation = lens.reduce((a, b) => a > b ? a : b) -
          lens.reduce((a, b) => a < b ? a : b);
      if (variation <= 7) {
        insights.add(
            'Your cycle length has remained relatively consistent over the tracked period (variation of $variation days).');
      } else {
        insights.add(
            'Your cycle length has varied by $variation days across the tracked period.');
      }
      final bleeds = complete.map((c) => c.bleedingDays).toList();
      if (bleeds.length >= 2 &&
          bleeds.last > bleeds.sublist(0, bleeds.length - 1).reduce((a, b) => a > b ? a : b)) {
        insights.add(
            'Bleeding duration in your most recent cycle (${bleeds.last} days) was longer than in previous tracked cycles.');
      }
      var pelvicMenstrual = 0;
      var pelvicTotal = 0;
      for (final c in cycles) {
        for (final l in c.days) {
          if (l.pelvicPressure || l.painScore >= 4) {
            pelvicTotal++;
            final d = DateTime.tryParse(l.date);
            if (d != null &&
                phaseOf(c, DateTime(d.year, d.month, d.day)) ==
                    CyclePhase.menstrual) {
              pelvicMenstrual++;
            }
          }
        }
      }
      if (pelvicTotal >= 3 && pelvicMenstrual * 2 >= pelvicTotal) {
        insights.add(
            'Pelvic discomfort has been reported primarily during the menstrual phase.');
      }
      final lhDays = <int>[];
      for (final c in complete) {
        if (c.confirmedOvulation != null) {
          lhDays.add(c.confirmedOvulation!.difference(c.start).inDays + 1);
        }
      }
      if (lhDays.length >= 2) {
        final spread = lhDays.reduce((a, b) => a > b ? a : b) -
            lhDays.reduce((a, b) => a < b ? a : b);
        if (spread <= 3) {
          insights.add(
              'LH-positive results appear consistently around the same cycle days (days ${lhDays.join(', ')}).');
        }
      }
      if (symptoms.isNotEmpty) {
        insights.add(
            '${symptoms.first.name} is your most frequently logged symptom (${symptoms.first.occurrences} days across ${symptoms.first.cyclesAffected} cycles).');
      }
    }

    // ---- 7. Attention flags (incl. urgent safety message) ----
    final attentionFlags = <String>[];
    String? urgent;
    {
      final pain10 = <String>[];
      for (final e in entries) {
        if (cutoff != null && e.date.isBefore(cutoff)) continue;
        if (e.log.painScore >= 10) pain10.add(_d(e.date));
      }
      // Heavy 3+ consecutive days WITH pain >= 7 in the same run.
      var heavyPainRun = false;
      {
        DateTime? prev;
        var heavyRun = 0;
        var painInRun = false;
        for (final e in entries) {
          if (cutoff != null && e.date.isBefore(cutoff)) {
            prev = e.date;
            continue;
          }
          if (prev != null && e.date.difference(prev).inDays > 1) {
            heavyRun = 0;
            painInRun = false;
          }
          if (e.log.flowIntensity == 'Heavy') {
            heavyRun++;
            if (e.log.painScore >= 7) painInRun = true;
          } else {
            heavyRun = 0;
            painInRun = false;
          }
          if (heavyRun >= 3 && painInRun) {
            heavyPainRun = true;
            break;
          }
          prev = e.date;
        }
      }
      // Bleeding 15+ straight days.
      var longestBleed = 0;
      {
        DateTime? prev;
        var run = 0;
        for (final d in bleedingDaysAll.toList()..sort()) {
          if (cutoff != null && d.isBefore(cutoff)) {
            prev = d;
            continue;
          }
          run = (prev != null && d.difference(prev).inDays == 1) ? run + 1 : 1;
          if (run > longestBleed) longestBleed = run;
          prev = d;
        }
      }
      final urgentReasons = <String>[];
      if (pain10.isNotEmpty) {
        urgentReasons.add(
            'maximum pain score (10/10) logged on ${pain10.take(3).join(', ')}');
      }
      if (heavyPainRun) {
        urgentReasons.add(
            'heavy flow for 3+ consecutive days together with severe pain');
      }
      if (longestBleed >= 15) {
        urgentReasons.add(
            'bleeding logged for $longestBleed consecutive days');
      }
      if (urgentReasons.isNotEmpty) {
        urgent =
            'Please seek prompt medical care: our safety check noticed ${urgentReasons.join('; ')} in your tracked data. This is not a diagnosis — a clinician should review this promptly.';
      }
      for (final p in patterns) {
        attentionFlags.add(
            'Consider discussing "${p.name}" with a healthcare professional — ${p.observations}');
      }
    }

    // ---- 8. Data quality ----
    String reliability;
    String qualityNote;
    if (complete.length >= 3 && spanDays > 0 && loggedDays * 2 >= spanDays) {
      reliability = 'High';
      qualityNote =
          '${complete.length} complete cycles analysed across $loggedDays logged days.';
    } else if (complete.length >= 2) {
      reliability = 'Moderate';
      qualityNote =
          '${complete.length} complete cycles analysed; more consistent daily logging would strengthen reliability.';
    } else if (entries.isNotEmpty) {
      reliability = 'Low';
      qualityNote =
          'Insufficient tracking data to generate a reliable interpretation — only ${complete.length} complete cycle(s) so far. Keep logging daily.';
    } else {
      reliability = 'Insufficient';
      qualityNote =
          'Insufficient tracking data to generate a reliable interpretation. No tracked days in this period — nothing has been assumed or filled in.';
    }

    // ---- 9. Summary ----
    final summary = <String>[];
    if (complete.length >= 2) {
      final lens = complete.map((c) => c.length!).toList();
      final variation = lens.reduce((a, b) => a > b ? a : b) -
          lens.reduce((a, b) => a < b ? a : b);
      summary.add(
          'Cycle regularity: ${variation <= 7 ? 'fairly regular' : 'variable'} across ${complete.length} complete cycles.');
      final avgBleed = complete.map((c) => c.bleedingDays).reduce((a, b) => a + b) /
          complete.length;
      summary.add(
          'Bleeding pattern: averaging ${avgBleed.toStringAsFixed(1)} days per cycle.');
      final conf =
          complete.where((c) => c.confirmedOvulation != null).length;
      summary.add(conf == 0
          ? 'Ovulation tracking: estimated only so far — log LH tests to confirm ovulation.'
          : 'Ovulation tracking: confirmed by LH peak in $conf of ${complete.length} cycles.');
      summary.add(patterns.isEmpty
          ? 'Pain/symptom pattern: no concerning tracked patterns detected in this period.'
          : 'Pain/symptom pattern: ${patterns.length} tracked pattern(s) noted above.');
      summary.add(patterns.isEmpty && urgent == null
          ? 'Suggested next step: keep logging daily to keep these insights accurate.'
          : 'Suggested next step: share this report with your gynecologist or doctor at your next visit.');
    } else {
      summary.add(
          'Overall Tracking Summary: not enough complete cycles yet — log daily (period, symptoms, LH tests) and return for a fuller picture.');
    }

    final trackedDays = entries.isEmpty
        ? 'No history yet'
        : '${_d(entries.first.date)} → ${_d(entries.last.date)}';

    return ClinicalReport(
      userName: name,
      email: email,
      age: age,
      generatedDate: _d(todayDay),
      windowLabel: windowLabel,
      trackingDuration: trackedDays,
      trackingMode: fromCache ? 'Offline (cached data)' : 'Online',
      cyclesAnalyzed: complete.length,
      daysLogged: loggedDays,
      spanDays: spanDays,
      baselines: baselines,
      patterns: patterns,
      cycles: cycles,
      trends: trends,
      symptoms: symptoms,
      insights: insights,
      attentionFlags: attentionFlags,
      urgentMessage: urgent,
      dataQualityNote: qualityNote,
      reliability: reliability,
      summaryBullets: summary,
    );
  }

  static String _age(dynamic dob, DateTime today) {
    DateTime? d;
    if (dob is DateTime) {
      d = dob;
    } else if (dob is String) {
      d = DateTime.tryParse(dob);
    }
    if (d == null) return 'Not specified';
    var age = today.year - d.year;
    if (today.month < d.month ||
        (today.month == d.month && today.day < d.day)) {
      age--;
    }
    return age < 0 ? 'Not specified' : '$age years';
  }

  static int _asInt(dynamic v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return fallback;
  }

  static String _flowLabel(int rank) {
    switch (rank) {
      case 1:
        return 'Light (average)';
      case 3:
        return 'Heavy (average)';
      default:
        return 'Medium (average)';
    }
  }

  /// Phase of [day] within [cycle], shared by the app UI and PDF builder.
  static CyclePhase phaseOf(CycleRecord c, DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final bleedEnd = c.start.add(Duration(days: c.bleedingDays));
    if (!d.isBefore(c.start) && d.isBefore(bleedEnd)) {
      return CyclePhase.menstrual;
    }
    final ovu = c.ovulationAnchor;
    if (ovu == null) return CyclePhase.unknown;
    final fertileStart = ovu.subtract(const Duration(days: 5));
    final fertileEnd = ovu.add(const Duration(days: 2));
    if (!d.isBefore(fertileStart) && d.isBefore(fertileEnd)) {
      return CyclePhase.ovulation;
    }
    if (d.isBefore(fertileStart)) return CyclePhase.follicular;
    return CyclePhase.luteal;
  }

  static String phaseLabel(CyclePhase p) => _phaseLabel(p);

  static String _phaseLabel(CyclePhase p) {
    switch (p) {
      case CyclePhase.menstrual:
        return 'Menstrual';
      case CyclePhase.follicular:
        return 'Follicular';
      case CyclePhase.ovulation:
        return 'Ovulation';
      case CyclePhase.luteal:
        return 'Luteal';
      case CyclePhase.unknown:
        return '—';
    }
  }
}
