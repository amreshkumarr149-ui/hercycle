import 'package:hercycle/core/lh_calibration.dart';
import 'package:hercycle/models/lh_test_entry.dart';

/// PRD §17 — NEW LH INTERPRETATION MODEL (single source of truth).
///
/// All LH status / velocity / prediction decisions MUST flow through this
/// model. Flutter-side duplicates and previous threshold logic are removed;
/// [LhStripCvPipeline] and [LhPredictionEngine] delegate here.
///
/// Versioning (PRD §44):
/// - Detection: YOLO-LH-v1 (confidence threshold 0.15, dup-filter 40px — kept
///   as config parameters here so they are not scattered through UI code).
/// - Image processing: CV-v1
/// - Calibration: LH-CAL-v1
/// - Interpretation: LH-INTERPRET-v2
/// - Personalization: ADAPTIVE-v1
class LhInterpretationModel {
  static const String detectionVersion = 'YOLO-LH-v1';
  static const String imageProcessingVersion = 'CV-v1';
  static const String calibrationVersion = 'LH-CAL-v1';
  static const String interpretationVersion = 'LH-INTERPRET-v2';
  static const String personalizationVersion = 'ADAPTIVE-v1';

  /// YOLO prototype config (PRD §12) — single location, not UI code.
  static const double yoloConfidenceThreshold = 0.15;
  static const double yoloDuplicateFilterPx = 40.0;

  /// PRD §26 — surge-status trigger (NOT the whole prediction algorithm).
  static const double surgeThreshold = 0.8;

  /// Calibrated ratio at/above which a PEAK status is reported.
  static const double peakThreshold = 1.15;

  /// Below this calibrated ratio LH is LOW regardless of velocity.
  static const double lowCeiling = 0.3;

  /// Initial baseline expected progression for new users (PRD §18),
  /// ratio/day. Personalized once reliable history exists (PRD §19).
  static const double baselineExpectedVelocityPerDay = 0.15;

  /// Minimum reliable quantitative points before personalization blends in.
  static const int minHistoryForAdaptation = 3;

  /// Ovulation timing post-surge: midpoint of the 24–36h window.
  static const int ovulationShiftHours = 30;

  /// Interprets a calibrated T/C ratio into a surge status.
  /// RISING = mid-range ratio with positive velocity (PRD §7/§28 examples).
  static LhSurgeStatus interpretStatus(double calibratedRatio, double? velocityPerDay) {
    if (calibratedRatio >= peakThreshold) return LhSurgeStatus.peak;
    if (calibratedRatio >= surgeThreshold) return LhSurgeStatus.high;
    if (calibratedRatio >= lowCeiling &&
        velocityPerDay != null &&
        velocityPerDay > 0.05) {
      return LhSurgeStatus.rising;
    }
    return LhSurgeStatus.low;
  }

  /// PRD §21 — LH Speed with actual elapsed time (never assumes 24h).
  /// Returns ratio/day, or null when velocity cannot be computed
  /// (single measurement, manual entry, non-positive interval).
  static double? velocityPerDay({
    required double currentRatio,
    required DateTime currentTime,
    required double previousRatio,
    required DateTime previousTime,
  }) {
    final hours = currentTime.difference(previousTime).inMinutes / 60.0;
    if (hours <= 0) return null;
    final v = (currentRatio - previousRatio) / hours * 24.0;
    return double.parse(v.toStringAsFixed(3));
  }

  /// PRD §19 — progressive adaptive expectation with reliability weighting.
  /// A single measurement can never radically alter the baseline: the blend
  /// weight grows with reliable history count and caps at 0.5.
  static double expectedVelocityPerDay(List<double> reliableHistoricalVelocities) {
    final valid = reliableHistoricalVelocities.where((v) => v.isFinite).toList();
    if (valid.length < minHistoryForAdaptation) {
      return baselineExpectedVelocityPerDay;
    }
    valid.sort();
    final median = valid[valid.length ~/ 2];
    final weight = (valid.length / 10.0).clamp(0.1, 0.5);
    final blended = baselineExpectedVelocityPerDay * (1 - weight) + median * weight;
    return double.parse(blended.clamp(0.05, 0.6).toStringAsFixed(3));
  }

  /// Confidence grows with reliable data quantity; poor-quality points are
  /// excluded by the caller so they never inflate confidence (PRD §42).
  static double confidence({required int reliableCount, required bool isSurge}) {
    var c = isSurge ? 0.85 : 0.55;
    if (reliableCount >= 3) c += 0.1;
    if (reliableCount >= 5) c += 0.05;
    return double.parse(c.clamp(0.3, 1.0).toStringAsFixed(2));
  }

  /// Calibrated T/C from a raw CV ratio (PRD §15–16).
  static double calibrateRaw(double raw) => LhCalibration.calibrate(raw);
}
