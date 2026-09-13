/// PRD §16 — Calibration (versioned).
///
/// Converts a raw computer-vision T/C measurement into a calibrated T/C
/// value using the LH-CAL-v1 anchor table with linear interpolation.
/// Future calibration changes MUST create a new version, never silently
/// change these anchors (PRD §44 model versioning).
class LhCalibration {
  static const String version = 'LH-CAL-v1';

  /// Anchor points: (rawRatio, calibratedValue), sorted ascending.
  /// From PRD §16 prototype calibration table.
  static const List<List<double>> anchors = [
    [0.00, 0.00],
    [0.17, 0.32],
    [0.40, 0.54],
    [0.59, 0.90],
    [1.01, 0.93],
    [1.03, 1.15],
    [2.00, 2.20],
  ];

  /// Interpolates [raw] through the anchor table.
  /// Values below/above the table clamp to the edge calibrated values
  /// (extrapolation would overclaim precision — PRD §5 out of scope).
  static double calibrate(double raw) {
    if (raw <= anchors.first[0]) return anchors.first[1];
    for (var i = 0; i < anchors.length - 1; i++) {
      final x0 = anchors[i][0];
      final y0 = anchors[i][1];
      final x1 = anchors[i + 1][0];
      final y1 = anchors[i + 1][1];
      if (raw >= x0 && raw <= x1) {
        final t = (raw - x0) / (x1 - x0);
        return double.parse((y0 + t * (y1 - y0)).toStringAsFixed(3));
      }
    }
    return anchors.last[1];
  }
}
