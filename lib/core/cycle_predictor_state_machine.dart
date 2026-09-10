import 'package:hercycle/models/daily_log.dart';

class CyclePredictionResult {
  final int currentDay;
  final String phaseName;
  final DateTime nextPeriodDate;
  final int daysUntilNextPeriod;
  final DateTime? ovulationDate;
  final bool isOvulationLocked;
  final String? alertMessage;
  final String stateStatus;
  /// Observed bleeding duration from the tracked period start/end dates.
  /// Null when no valid end date was recorded.
  final int? observedBleedDays;

  CyclePredictionResult({
    required this.currentDay,
    required this.phaseName,
    required this.nextPeriodDate,
    required this.daysUntilNextPeriod,
    this.ovulationDate,
    required this.isOvulationLocked,
    this.alertMessage,
    required this.stateStatus,
    this.observedBleedDays,
  });
}

class CyclePredictorStateMachine {
  /// Evaluates state transitions, mucus shifts, O-3 fallbacks, and LH Peak lock-ins
  /// using only logs within the current active cycle.
  ///
  /// Hardened against: future-dated last-period, multi-cycle rollover
  /// (last period many cycles ago), malformed log dates, future-dated logs,
  /// and out-of-range cycle/period lengths.
  static CyclePredictionResult evaluate({
    required DateTime? lastPeriodStartDate,
    required int typicalCycleLength,
    required int typicalPeriodLength,
    required List<DailyLog> cycleLogs,
    required int lutealPhaseLength,
    DateTime? lastPeriodEndDate,
  }) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Clamp inputs to sane biological ranges so bad profile data can't
    // produce absurd predictions or divide-by-zero/modulo crashes.
    final cycleLen = typicalCycleLength.clamp(15, 60);
    final periodLen = typicalPeriodLength.clamp(1, 15);
    final lutealLen = lutealPhaseLength.clamp(8, 20);

    if (lastPeriodStartDate == null) {
      return CyclePredictionResult(
        currentDay: 1,
        phaseName: 'Follicular Phase',
        nextPeriodDate: today.add(const Duration(days: 28)),
        daysUntilNextPeriod: 28,
        isOvulationLocked: false,
        stateStatus: 'preOvulation',
        alertMessage: 'Log your last period to start real-time reactive tracking.',
      );
    }

    final lastStart = DateTime(
        lastPeriodStartDate.year, lastPeriodStartDate.month, lastPeriodStartDate.day);
    // Tracked period end date, validated: must not precede the start and
    // must not lie in the future (both indicate entry mistakes).
    DateTime? endDay;
    if (lastPeriodEndDate != null) {
      final rawEnd = DateTime(lastPeriodEndDate.year, lastPeriodEndDate.month,
          lastPeriodEndDate.day);
      if (!rawEnd.isBefore(lastStart) && !rawEnd.isAfter(today)) {
        endDay = rawEnd;
      }
    }
    final observedBleedDays =
        endDay == null ? null : endDay.difference(lastStart).inDays + 1;
    final differenceInDays = today.difference(lastStart).inDays;

    // Edge case: last period dated in the future (user typo). Don't let
    // negative modulo produce a bogus day; anchor to day 1 instead.
    // Rollover: if several cycles elapsed since lastStart, roll the cycle
    // window forward so "next period" is always in the future.
    late final DateTime cycleStart;
    late final int currentDay;
    if (differenceInDays < 0) {
      cycleStart = lastStart;
      currentDay = 1;
    } else {
      final cyclesElapsed = differenceInDays ~/ cycleLen;
      cycleStart = lastStart.add(Duration(days: cyclesElapsed * cycleLen));
      currentDay = differenceInDays - cyclesElapsed * cycleLen + 1;
    }

    // Default Estimated Ovulation (cycle length minus 14 days)
    int estOvulationDay = cycleLen - 14;
    if (estOvulationDay < 1) estOvulationDay = 14;

    DateTime estimatedOvulationDate =
        cycleStart.add(Duration(days: estOvulationDay - 1));
    DateTime nextPeriodDate = cycleStart.add(Duration(days: cycleLen));

    bool isOvulationLocked = false;
    String stateStatus = 'preOvulation';
    String? alertMessage;

    // Filter logs strictly belonging to the current active cycle window
    // [cycleStart, cycleStart + cycleLen], ignoring malformed and
    // future-dated entries that would corrupt state transitions.
    final currentCycleLogs = cycleLogs.where((log) {
      final logDate = DateTime.tryParse(log.date);
      if (logDate == null) return false;
      final d = DateTime(logDate.year, logDate.month, logDate.day);
      if (d.isAfter(today)) return false;
      final cycleEnd = cycleStart.add(Duration(days: cycleLen));
      return (d.isAfter(cycleStart) || d.isAtSameMomentAs(cycleStart)) &&
          d.isBefore(cycleEnd);
    }).toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    // Check for LH Peak Lock-In (first Positive LH Test in current cycle)
    DailyLog? positiveLhLog;
    for (var log in currentCycleLogs) {
      if (log.lhTest.toLowerCase() == 'positive') {
        positiveLhLog = log;
        break;
      }
    }

    if (positiveLhLog != null) {
      final lhDate = DateTime.tryParse(positiveLhLog.date);
      if (lhDate != null) {
        final lhDay = DateTime(lhDate.year, lhDate.month, lhDate.day);
        isOvulationLocked = true;
        stateStatus = 'lhPeakLocked';
        // Lock Ovulation Date = Positive LH Test Date + 1 Day
        estimatedOvulationDate = lhDay.add(const Duration(days: 1));
        // Lock Next Period = Ovulation Date + Luteal Phase Length
        nextPeriodDate =
            estimatedOvulationDate.add(Duration(days: lutealLen));
        alertMessage =
            "LH Peak detected! Ovulation and next period dates locked.";
      }
    }

    if (positiveLhLog == null || !isOvulationLocked) {
      // Check for Mucus Transition Trigger (Dry/Sticky -> Creamy/Watery/EggWhite) in current cycle
      bool hasWetMucus = false;
      bool loggedMucusEarlier = false;

      for (var log in currentCycleLogs) {
        final m = log.mucus.toLowerCase();
        if (m.contains('creamy') ||
            m.contains('watery') ||
            m.contains('eggwhite') ||
            m.contains('slippery')) {
          hasWetMucus = true;
          break;
        }
        if (m.contains('dry') ||
            m.contains('sticky') ||
            m.contains('tacky')) {
          loggedMucusEarlier = true;
        }
      }

      final oMinus3 =
          estimatedOvulationDate.subtract(const Duration(days: 3));

      if (hasWetMucus ||
          (loggedMucusEarlier && !hasWetMucus && today.isAfter(oMinus3))) {
        stateStatus = 'fertileWindowOpening';
        if (hasWetMucus) {
          alertMessage = "Mucus shift detected: Start LH testing tomorrow.";
        } else {
          alertMessage = "Fertile window opening. Start LH testing.";
        }
      } else if (today.isAtSameMomentAs(oMinus3) ||
          today.isAfter(oMinus3)) {
        stateStatus = 'fertileWindowOpening';
        alertMessage =
            "Fertile window opening (O-3 fallback). Start LH testing.";
      }
    }

    // Determine Phase. A tracked end date takes precedence over the
    // typical period length: while today is within [start, end] the user is
    // still bleeding, regardless of the average.
    String phaseName = 'Follicular Phase';
    if ((endDay != null && !today.isAfter(endDay)) ||
        currentDay <= periodLen) {
      phaseName = 'Menstrual Phase (Menses)';
    } else if (isOvulationLocked ||
        (currentDay >= estOvulationDay - 3 &&
            currentDay <= estOvulationDay + 2)) {
      phaseName = 'Ovulation Phase';
    } else if (currentDay > estOvulationDay + 2) {
      phaseName = 'Luteal Phase';
    } else {
      phaseName = 'Follicular Phase';
    }

    int daysUntilNextPeriod = nextPeriodDate.difference(today).inDays;
    if (daysUntilNextPeriod < 0) daysUntilNextPeriod = 0;

    return CyclePredictionResult(
      currentDay: currentDay,
      phaseName: phaseName,
      nextPeriodDate: nextPeriodDate,
      daysUntilNextPeriod: daysUntilNextPeriod,
      ovulationDate: estimatedOvulationDate,
      isOvulationLocked: isOvulationLocked,
      alertMessage: alertMessage,
      stateStatus: stateStatus,
      observedBleedDays: observedBleedDays,
    );
  }
}
