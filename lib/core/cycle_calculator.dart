class CycleCalculator {
  static Map<String, dynamic> calculate({
    required DateTime? lastPeriodStartDate,
    required int typicalCycleLength,
    required int typicalPeriodLength,
  }) {
    if (lastPeriodStartDate == null) {
      return {
        'currentDay': 1,
        'phaseName': 'Follicular Phase',
        'nextPeriod': DateTime.now().add(const Duration(days: 28)),
        'daysUntilNextPeriod': 28,
        'message': 'Complete your profile with your last period date to see accurate predictions.',
      };
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastStart = DateTime(lastPeriodStartDate.year, lastPeriodStartDate.month, lastPeriodStartDate.day);

    final differenceInDays = today.difference(lastStart).inDays;
    
    int currentDay = (differenceInDays % typicalCycleLength) + 1;
    if (currentDay < 1) currentDay = 1;

    int cyclesPassed = differenceInDays ~/ typicalCycleLength;
    DateTime nextPeriod = lastStart.add(Duration(days: (cyclesPassed + 1) * typicalCycleLength));
    if (nextPeriod.isBefore(today)) {
      nextPeriod = today.add(const Duration(days: 5));
    }

    String phaseName = 'Follicular Phase';
    if (currentDay <= typicalPeriodLength) {
      phaseName = 'Menstrual Phase (Menses)';
    } else {
      int ovulationDay = typicalCycleLength - 14;
      if (ovulationDay < 1) ovulationDay = 14;

      if (currentDay >= ovulationDay - 3 && currentDay <= ovulationDay + 2) {
        phaseName = 'Ovulation Phase';
      } else if (currentDay > ovulationDay + 2) {
        phaseName = 'Luteal Phase';
      } else {
        phaseName = 'Follicular Phase';
      }
    }

    int daysUntilNextPeriod = nextPeriod.difference(today).inDays;
    if (daysUntilNextPeriod < 0) daysUntilNextPeriod = 0;

    return {
      'currentDay': currentDay,
      'phaseName': phaseName,
      'nextPeriod': nextPeriod,
      'daysUntilNextPeriod': daysUntilNextPeriod,
      'message': null,
    };
  }
}
