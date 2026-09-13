import 'dart:math';
import 'package:hercycle/core/lh_calibration.dart';
import 'package:hercycle/core/lh_interpretation_model.dart';
import 'package:hercycle/models/lh_test_entry.dart';

/// PRD §37 — Flutter-side thin adapter over the analysis pipeline.
///
/// Correct flow: Flutter → LH Analysis API → YOLO + OpenCV + new model →
/// result → Flutter. This class is the seam where the real backend plugs in:
/// when the YOLO/OpenCV service exists, only [_runBackendAnalysis] changes —
/// UI and prediction code stay untouched (PRD §38).
///
/// Until then it runs the on-device stand-in: simulated raw CV ratio →
/// [LhCalibration] (LH-CAL-v1) → [LhInterpretationModel] (LH-INTERPRET-v2,
/// the single source of truth — no duplicated thresholds here).
class LhStripCvPipeline {
  /// PRD §12 — kept here as config, never scattered through UI code.
  static const double yoloConfidenceThreshold =
      LhInterpretationModel.yoloConfidenceThreshold;
  static const double yoloDuplicateFilterPx =
      LhInterpretationModel.yoloDuplicateFilterPx;

  /// Analyzes a test strip image to compute raw + calibrated T/C.
  /// Returns failure (never throws) for: no image, control-line-missing
  /// simulation, poor-quality simulation — caller shows retake + manual
  /// fallback (PRD §10/§35).
  static LhCvResult analyzeStrip({List<int>? imageBytes, String? imagePath}) {
    if ((imageBytes == null || imageBytes.isEmpty) &&
        (imagePath == null || imagePath.isEmpty)) {
      return const LhCvResult(
        success: false,
        errorCode: LhErrorCode.noImage,
        errorMessage:
            'No image provided. Please capture or select a valid photo.',
        rawRatio: 0.0,
        tcRatio: 0.0,
        surgeStatus: LhSurgeStatus.low,
      );
    }

    final path = (imagePath ?? '').toLowerCase();
    // Simulated backend failure modes (deterministic hooks for tests/demos).
    if (path.contains('nocontrol') || path.contains('no_control')) {
      return const LhCvResult(
        success: false,
        errorCode: LhErrorCode.controlLineMissing,
        errorMessage:
            "We couldn't identify a valid control line. Please retake the test image.",
        rawRatio: 0.0,
        tcRatio: 0.0,
        surgeStatus: LhSurgeStatus.low,
      );
    }
    if (path.contains('blur') || path.contains('glare') || path.contains('dark')) {
      return const LhCvResult(
        success: false,
        errorCode: LhErrorCode.poorQuality,
        errorMessage:
            "We couldn't analyze this image. Try another photo with better lighting and less glare.",
        rawRatio: 0.0,
        tcRatio: 0.0,
        surgeStatus: LhSurgeStatus.low,
      );
    }

    final raw = _runBackendAnalysis(imageBytes: imageBytes, imagePath: imagePath);
    final calibrated = LhInterpretationModel.calibrateRaw(raw);
    final status = LhInterpretationModel.interpretStatus(calibrated, null);

    return LhCvResult(
      success: true,
      rawRatio: raw,
      tcRatio: calibrated,
      surgeStatus: status,
      reliability: 0.8,
      detectionVersion: LhInterpretationModel.detectionVersion,
      calibrationVersion: LhInterpretationModel.calibrationVersion,
      interpretationVersion: LhInterpretationModel.interpretationVersion,
    );
  }

  /// Stand-in for the YOLO + OpenCV backend (PRD §11–14).
  /// Produces a RAW (uncalibrated) ratio; calibration always applies after.
  static double _runBackendAnalysis({List<int>? imageBytes, String? imagePath}) {
    final path = (imagePath ?? '').toLowerCase();
    // Deterministic hooks so tests/demos can drive specific outcomes.
    if (path.contains('peak')) return 1.03;
    if (path.contains('high')) return 0.59;
    final rand = Random();
    final raw = 0.1 + rand.nextDouble() * 0.7;
    return double.parse(raw.toStringAsFixed(2));
  }

  /// PRD §21 — delegates to the single-source model (actual elapsed time).
  static double? calculateVelocity(LhTestEntry? previous, LhTestEntry current) {
    if (previous == null || previous.tcRatio == null || current.tcRatio == null) {
      return null;
    }
    final v = LhInterpretationModel.velocityPerDay(
      currentRatio: current.tcRatio!,
      currentTime: current.timestamp,
      previousRatio: previous.tcRatio!,
      previousTime: previous.timestamp,
    );
    if (v == null) return null;
    // Legacy shape: ratio/hour (existing callers/tests expect hourly).
    return double.parse((v / 24.0).toStringAsFixed(3));
  }
}

enum LhErrorCode { noImage, controlLineMissing, poorQuality }

class LhCvResult {
  final bool success;
  final LhErrorCode? errorCode;
  final String? errorMessage;

  /// Raw backend ratio (pre-calibration, PRD §15).
  final double rawRatio;

  /// Calibrated T/C (PRD §16). Legacy name kept for callers.
  final double tcRatio;
  final LhSurgeStatus surgeStatus;

  /// 0–1 reliability weight for personalization (PRD §42).
  final double? reliability;

  final String? detectionVersion;
  final String? calibrationVersion;
  final String? interpretationVersion;

  const LhCvResult({
    required this.success,
    this.errorCode,
    this.errorMessage,
    required this.rawRatio,
    required this.tcRatio,
    required this.surgeStatus,
    this.reliability,
    this.detectionVersion,
    this.calibrationVersion,
    this.interpretationVersion,
  });
}
