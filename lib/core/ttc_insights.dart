/// Trying-to-conceive insights. Pure functions — no I/O, never throw.
///
/// Copy contract (enforced by tests): nothing here predicts or implies
/// conception. Outputs are fertile-window coverage and a test-day pointer;
/// the UI must always pair them with "test to confirm" language.
class TtcStatus {
  /// Ovulation day (tracked or mid-cycle estimate), or null.
  final DateTime? peakDay;

  /// Suggested test day (peak + 14), or null when no peak is known.
  final DateTime? testDay;

  /// Days from today to peak (negative = passed), null when unknown.
  final int? daysToPeak;

  /// Days from today to test day (negative = passed), null when unknown.
  final int? daysToTest;

  /// Logged intimacy days inside the fertile window.
  final int coveredDays;

  /// Fertile window length in days (0 when unknown).
  final int fertileDays;

  /// Fraction of the fertile window covered (0..1).
  double get coverage =>
      fertileDays <= 0 ? 0 : (coveredDays / fertileDays).clamp(0.0, 1.0);

  /// yyyy-MM-dd keys of covered fertile-window days (for coverage dots).
  final Set<String> coveredKeys;

  /// True when the peak is a mid-cycle estimate rather than tracked/LH data.
  final bool estimated;

  const TtcStatus({
    required this.peakDay,
    required this.testDay,
    required this.daysToPeak,
    required this.daysToTest,
    required this.coveredDays,
    required this.fertileDays,
    required this.coveredKeys,
    required this.estimated,
  });
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

TtcStatus ttcStatus({
  required DateTime today,
  DateTime? ovulationDate,
  DateTime? nextPeriod,
  Set<String> intimacyDates = const {},
}) {
  final now = _day(today);
  DateTime? peak = ovulationDate == null ? null : _day(ovulationDate);
  var estimated = false;
  if (peak == null && nextPeriod != null) {
    peak = _day(nextPeriod).subtract(const Duration(days: 14));
    estimated = true;
  }
  if (peak == null) {
    return const TtcStatus(
      peakDay: null,
      testDay: null,
      daysToPeak: null,
      daysToTest: null,
      coveredDays: 0,
      fertileDays: 0,
      coveredKeys: {},
      estimated: true,
    );
  }
  final testDay = peak.add(const Duration(days: 14));
  final windowStart = peak.subtract(const Duration(days: 5));
  final windowEnd = peak.add(const Duration(days: 1));
  var covered = 0;
  final coveredKeys = <String>{};
  var cursor = windowStart;
  while (!cursor.isAfter(windowEnd)) {
    final key =
        '${cursor.year.toString().padLeft(4, '0')}-${cursor.month.toString().padLeft(2, '0')}-${cursor.day.toString().padLeft(2, '0')}';
    if (intimacyDates.contains(key)) {
      covered++;
      coveredKeys.add(key);
    }
    cursor = cursor.add(const Duration(days: 1));
  }
  return TtcStatus(
    peakDay: peak,
    testDay: testDay,
    daysToPeak: peak.difference(now).inDays,
    daysToTest: testDay.difference(now).inDays,
    coveredDays: covered,
    fertileDays: 7,
    coveredKeys: coveredKeys,
    estimated: estimated,
  );
}
