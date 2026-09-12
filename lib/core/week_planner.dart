import 'package:hercycle/core/clinical_report_engine.dart';
import 'package:hercycle/core/fertile_window.dart';
import 'package:hercycle/models/daily_log.dart';

/// The energy/awareness tag for one upcoming day.
enum DayEnergy { rest, high, pmsLikely, period, calm }

/// One day of the 7-day outlook.
class PlannedDay {
  final DateTime date;

  /// 1-based day of the cycle this date falls on (may exceed the typical
  /// length when the period is late/unknown — still monotonic, always ≥ 1).
  final int cycleDay;
  final DayEnergy energy;

  /// Human-readable reasons ("Day 26 Luteal", "headaches in 3 of last 4
  /// luteals"). Shown verbatim in the day dialog.
  final List<String> reasons;

  const PlannedDay({
    required this.date,
    required this.cycleDay,
    required this.energy,
    required this.reasons,
  });
}

/// A luteal-typical symptom from the user's own history, used only for the
/// PMS-likelihood signal. Nothing is inferred from population averages.
class LutealSignal {
  final String name;
  final int cyclesAffected;

  const LutealSignal({required this.name, required this.cyclesAffected});
}

/// Maps the next 7 days to energy tags from tracked data. Pure function —
/// no I/O, never throws.
///
/// Inputs come from existing providers: [currentDay] from predictions,
/// [typicalCycleLength]/[typicalPeriodLength] from the profile,
/// [nextPeriod]/[ovulationDate]/[ovulationLocked] from predictions, and
/// [lutealSignals] from the clinical report's luteal-typical symptoms.
///
/// Hardening rules (so callers can't produce nonsense later):
/// - Lengths are clamped to the predictor's valid ranges (15–60 / 1–15).
/// - [currentDay] below 1 is treated as 1 (labels never show "Day 0").
/// - [pmsThreshold] below 1 falls back to 2 (a zero threshold would flag
///   every luteal day on a single occurrence).
/// - Signals are trimmed, empties dropped, case-insensitive duplicates
///   merged (keeping the strongest), negative counts clamped to 0.
/// - A day is tagged PMS-likely only on a repeat luteal pattern.
/// - An ovulation date after the predicted next period is stale (a new
///   cycle started) and is ignored rather than painted over bleeding days.
/// - Days past the predicted bleeding window are tagged period-late
///   ("log it when it starts") instead of silently flipping to Luteal.
/// - With no history at all, tags fall back to phase-only estimates and
///   [personalized] is false.
({List<PlannedDay> days, bool personalized}) planWeek({
  required DateTime today,
  required int currentDay,
  required int typicalCycleLength,
  required int typicalPeriodLength,
  DateTime? nextPeriod,
  DateTime? ovulationDate,
  bool ovulationLocked = false,
  List<LutealSignal> lutealSignals = const [],
  int pmsThreshold = 2,
}) {
  final cycleLen = typicalCycleLength.clamp(15, 60);
  final periodLen = typicalPeriodLength.clamp(1, 15);
  final baseDay = currentDay < 1 ? 1 : currentDay;
  final threshold = pmsThreshold < 1 ? 2 : pmsThreshold;

  DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  final npDay = nextPeriod == null ? null : dayOnly(nextPeriod);
  // Stale ovulation anchor (new cycle started since): ignore it.
  final ovu = (ovulationDate != null &&
          npDay != null &&
          dayOnly(ovulationDate).isAfter(npDay))
      ? null
      : ovulationDate;
  final fertile = fertileRange(
    ovulationDate: ovu,
    nextPeriod: nextPeriod,
  );

  // Normalize signals: trim, drop empties/negatives, merge duplicates
  // (keeping the first-seen display name for user-facing strings).
  final merged = <String, ({String display, int count})>{};
  for (final s in lutealSignals) {
    final name = s.name.trim();
    if (name.isEmpty) continue;
    final key = name.toLowerCase();
    final count = s.cyclesAffected < 0 ? 0 : s.cyclesAffected;
    final prev = merged[key];
    if (prev == null) {
      merged[key] = (display: name, count: count);
    } else if (count > prev.count) {
      merged[key] = (display: prev.display, count: count);
    }
  }
  // Deterministic order: strongest first, then alphabetical.
  final strongNames = merged.entries
      .where((e) => e.value.count >= threshold)
      .toList()
    ..sort((a, b) {
      final byCount = b.value.count.compareTo(a.value.count);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  final personalized =
      nextPeriod != null || ovu != null || strongNames.isNotEmpty;

  final days = <PlannedDay>[];
  for (var offset = 0; offset < 7; offset++) {
    final date =
        dayOnly(today).add(Duration(days: offset));
    final day = baseDay + offset;

    // Where does this date fall relative to tracked anchors?
    final isBleedDay = npDay != null &&
        !date.isBefore(npDay) &&
        date.isBefore(npDay.add(Duration(days: periodLen)));
    final isLate = !isBleedDay &&
        npDay != null &&
        !date.isBefore(npDay.add(Duration(days: periodLen)));
    final inFertile = fertile != null &&
        !date.isBefore(dayOnly(fertile.start)) &&
        !date.isAfter(dayOnly(fertile.end));
    final isOvulationDay = ovu != null && sameDay(date, ovu);

    // Phase estimate from cycle arithmetic (mirrors the predictor's
    // layout: bleed → follicular → fertile → luteal).
    final String phase;
    if (day <= periodLen) {
      phase = 'Menstrual';
    } else if (inFertile || isOvulationDay) {
      phase = 'Ovulation';
    } else {
      final lutealStart = cycleLen - 13;
      phase = day >= lutealStart ? 'Luteal' : 'Follicular';
    }

    final reasons = <String>['Day $day • $phase phase'];
    DayEnergy energy;
    if (isBleedDay) {
      energy = DayEnergy.period;
      reasons.add(sameDay(date, npDay)
          ? 'Period expected today'
          : 'Inside your predicted bleeding window');
    } else if (isLate) {
      energy = DayEnergy.period;
      reasons.add(
          'Period was expected around ${_shortDay(npDay)} — log it when it starts');
    } else if (isOvulationDay && ovulationLocked) {
      energy = DayEnergy.high;
      reasons.add('Ovulation confirmed ✓ via LH test');
    } else if (inFertile || isOvulationDay) {
      energy = DayEnergy.high;
      reasons.add('Fertile window — energy often peaks here');
    } else if (phase == 'Menstrual') {
      energy = DayEnergy.rest;
      reasons.add('Bleeding days — rest is productive');
    } else if (phase == 'Luteal' && strongNames.isNotEmpty) {
      energy = DayEnergy.pmsLikely;
      final names = strongNames
          .take(2)
          .map((e) => '${e.value.display} (${e.value.count} cycles)')
          .join(', ');
      reasons.add('Your pattern: $names tend to show up in luteals');
    } else if (phase == 'Follicular') {
      energy = DayEnergy.high;
      reasons.add('Rebuilding phase — good days to start things');
    } else {
      energy = DayEnergy.calm;
      reasons.add('Steady days — nothing demanding expected');
    }

    days.add(PlannedDay(
        date: date, cycleDay: day, energy: energy, reasons: reasons));
  }
  return (days: days, personalized: personalized);
}

String _shortDay(DateTime d) => '${d.month}/${d.day}';

/// Shared input builder: luteal signals from raw provider payloads.
/// Never throws — any failure yields no signals and the planner degrades
/// to phase-only tags. Used by both the dashboard card and the evening
/// nudge sync so the two can never disagree on signals.
List<LutealSignal> lutealSignalsFrom({
  required List<DailyLog>? logs,
  required Map<String, dynamic>? profile,
  required bool fromCache,
}) {
  try {
    if (logs == null) return const [];
    final report = ClinicalReportEngine.build(
      profile: profile,
      allLogs: logs,
      windowDays: null,
      fromCache: fromCache,
    );
    return report.symptoms
        .where((s) => s.typicalPhase.toLowerCase().contains('luteal'))
        .map((s) =>
            LutealSignal(name: s.name, cyclesAffected: s.cyclesAffected))
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Evening-nudge copy for tomorrow. Returns null when tomorrow warrants
/// no ping (high/calm days never notify). Pure — unit-tested.
({String title, String body})? plannerNudgeFor(
  PlannedDay tomorrow, {
  required bool personalized,
}) {
  switch (tomorrow.energy) {
    case DayEnergy.rest:
      return (
        title: 'Tomorrow looks restful 🌙',
        body: personalized
            ? 'Bleeding days ahead, based on your tracked cycle — keep the evening free.'
            : 'Bleeding days may be ahead — keep the evening free.'
      );
    case DayEnergy.pmsLikely:
      final pattern = tomorrow.reasons.length > 1
          ? tomorrow.reasons[1]
          : 'Your luteal pattern';
      return (
        title: 'PMS likely tomorrow 💗',
        body: personalized
            ? '$pattern — plan something gentle.'
            : 'Low-energy day ahead — plan something gentle.'
      );
    case DayEnergy.period:
      return (
        title: 'Period expected tomorrow 🌸',
        body: 'Keep supplies handy — and log it when it starts.'
      );
    case DayEnergy.high:
    case DayEnergy.calm:
      return null;
  }
}
