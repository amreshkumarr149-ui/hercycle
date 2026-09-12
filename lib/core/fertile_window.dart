/// Shared fertile-window math: one implementation for every screen that
/// shows ovulation/fertile estimates (Home's Ovulation Window card,
/// Calendar's info cards). Pure date arithmetic — no I/O, never throws.
class FertileRange {
  final DateTime start;
  final DateTime end;

  /// True when derived from a mid-cycle estimate rather than a known
  /// (tracked or LH-confirmed) ovulation date.
  final bool isEstimate;

  const FertileRange(
      {required this.start, required this.end, required this.isEstimate});
}

/// Returns the fertile window (ovulation−5 … ovulation+1) when an ovulation
/// date is known, else derives ovulation as nextPeriod−14 (mid-cycle
/// estimate), else null when there is nothing to base it on.
FertileRange? fertileRange({DateTime? ovulationDate, DateTime? nextPeriod}) {
  DateTime? ovu = ovulationDate;
  var estimate = false;
  if (ovu == null && nextPeriod != null) {
    ovu = nextPeriod.subtract(const Duration(days: 14));
    estimate = true;
  }
  if (ovu == null) return null;
  return FertileRange(
    start: ovu.subtract(const Duration(days: 5)),
    end: ovu.add(const Duration(days: 1)),
    isEstimate: estimate,
  );
}
