import 'package:hercycle/core/lh_advanced_prediction_engine.dart';
import 'package:hercycle/core/lh_interpretation_model.dart';
import 'package:hercycle/models/lh_test_entry.dart';

/// Dynamic prediction (PRD §22–24).
///
/// Predicted Ovulation = f(T/C, LH Velocity, CycleDay, HistoricalPattern).
/// All thresholds, baselines and personalization come from
/// [LhInterpretationModel] — this engine holds NO duplicate LH logic
/// (PRD §17 single source of truth). It orchestrates: velocity → expected
/// → date shift → explanation → window.
class LhPredictionEngine {
  /// Legacy alias kept for callers/tests.
  static double get calibratedExpectedVelocityPerDay =>
      LhInterpretationModel.baselineExpectedVelocityPerDay;

  static double get surgeThreshold => LhInterpretationModel.surgeThreshold;
  static int get ovulationShiftHours => LhInterpretationModel.ovulationShiftHours;
  static const double maxConfidence = 1.0;
  static const double minConfidence = 0.3;

  /// Entries must be sorted ascending by timestamp.
  static LhPredictionResult compute({
    required List<LhTestEntry> sortedEntries,
    required DateTime baselineOvulationDate,
    required int cycleDay,
    List<LhTestEntry>? historicalEntries,
  }) {
    if (sortedEntries.isEmpty) {
      return LhPredictionResult(
        baselineOvulationDate: baselineOvulationDate,
        predictedOvulationDate: baselineOvulationDate,
        currentTcRatio: null,
        previousTcRatio: null,
        lhVelocity: null,
        expectedVelocity: LhInterpretationModel.baselineExpectedVelocityPerDay,
        velocityDifference: null,
        cycleDay: cycleDay,
        predictionConfidence: minConfidence,
        explanation: 'No LH data yet. Using baseline cycle prediction.',
      );
    }

    final current = sortedEntries.last;
    final hasRatio =
        current.tcRatio != null && current.entryType == LhEntryType.aiScan;

    if (!hasRatio) {
      final isPositive = current.manualResult == LhManualResult.positive;
      DateTime predicted;
      String explanation;
      if (isPositive) {
        // PRD §27: manual positive → high surge, calibrated post-surge timing.
        predicted = current.timestamp
            .add(Duration(hours: LhInterpretationModel.ovulationShiftHours));
        explanation =
            'Manual positive logged. Ovulation window estimated at 24–36 hours post-surge using calibrated timing.';
      } else {
        predicted = baselineOvulationDate;
        explanation =
            'Manual negative logged. Using baseline cycle prediction until quantitative data is available.';
      }
      return LhPredictionResult(
        baselineOvulationDate: baselineOvulationDate,
        predictedOvulationDate: predicted,
        currentTcRatio: null,
        previousTcRatio: null,
        lhVelocity: null,
        expectedVelocity: LhInterpretationModel.baselineExpectedVelocityPerDay,
        velocityDifference: null,
        cycleDay: cycleDay,
        predictionConfidence: isPositive ? 0.6 : minConfidence,
        explanation: explanation,
      );
    }

    final currentRatio = current.tcRatio!;

    // Previous quantitative entry (actual elapsed time, PRD §21).
    LhTestEntry? previousQuantitative;
    for (int i = sortedEntries.length - 2; i >= 0; i--) {
      if (sortedEntries[i].tcRatio != null &&
          sortedEntries[i].entryType == LhEntryType.aiScan) {
        previousQuantitative = sortedEntries[i];
        break;
      }
    }

    double? velocityPerDay;
    if (previousQuantitative != null) {
      velocityPerDay = LhInterpretationModel.velocityPerDay(
        currentRatio: currentRatio,
        currentTime: current.timestamp,
        previousRatio: previousQuantitative.tcRatio!,
        previousTime: previousQuantitative.timestamp,
      );
    }

    // PRD §19 — adaptive expectation from reliable history (recomputed
    // per-day velocities; entries flagged unreliable are excluded so one bad
    // test cannot hijack personalization).
    final reliableVelocities = _reliableHistoryVelocities(sortedEntries);
    if (historicalEntries != null) {
      for (final h in historicalEntries) {
        if (h.surgeVelocity != null &&
            h.surgeVelocity!.isFinite &&
            (h.reliability ?? 0.8) >= 0.5) {
          reliableVelocities.add(h.surgeVelocity!);
        }
      }
    }
    final expectedVelocity =
        LhInterpretationModel.expectedVelocityPerDay(reliableVelocities);
    final velocityDifference = velocityPerDay == null
        ? null
        : double.parse(
            (velocityPerDay - expectedVelocity).toStringAsFixed(3));

    final status =
        LhInterpretationModel.interpretStatus(currentRatio, velocityPerDay);

    DateTime predicted;
    String explanation;
    final isSurge = status == LhSurgeStatus.high ||
        status == LhSurgeStatus.peak ||
        currentRatio >= LhInterpretationModel.surgeThreshold;

    if (isSurge) {
      predicted = current.timestamp
          .add(Duration(hours: LhInterpretationModel.ovulationShiftHours));
      if (velocityDifference != null && velocityDifference > 0.05) {
        explanation =
            'T/C ratio ${currentRatio.toStringAsFixed(2)} — LH is rising faster than expected (${velocityPerDay!.toStringAsFixed(2)}/day vs expected ${expectedVelocity.toStringAsFixed(2)}/day). Ovulation window moved earlier.';
      } else if (velocityDifference != null && velocityDifference < -0.05) {
        explanation =
            'T/C ratio ${currentRatio.toStringAsFixed(2)} — LH surge detected but rising slower than expected. Ovulation window adjusted conservatively.';
      } else {
        explanation =
            'T/C ratio ${currentRatio.toStringAsFixed(2)} — Strong LH surge detected. Ovulation predicted within 24–36 hours.';
      }
    } else if (velocityPerDay != null && velocityDifference != null) {
      if (currentRatio < LhInterpretationModel.lowCeiling) {
        predicted = baselineOvulationDate;
        explanation =
            'T/C ratio ${currentRatio.toStringAsFixed(2)} — LH is low. Using baseline cycle prediction.';
      } else if (velocityDifference > 0.1) {
        final daysEarlier =
            (velocityDifference / expectedVelocity * 2).clamp(0.5, 3.0);
        predicted = baselineOvulationDate
            .subtract(Duration(days: daysEarlier.round()));
        explanation =
            'T/C ratio ${currentRatio.toStringAsFixed(2)} — LH is rising faster than expected (${velocityPerDay.toStringAsFixed(2)}/day). Estimated ovulation moved ${daysEarlier.round()} day(s) earlier than baseline.';
      } else if (velocityDifference > 0.02) {
        predicted = baselineOvulationDate.subtract(const Duration(days: 1));
        explanation =
            'T/C ratio ${currentRatio.toStringAsFixed(2)} — LH rising slightly faster than expected. Prediction refined.';
      } else if (velocityDifference < -0.05) {
        final daysLater =
            (velocityDifference.abs() / expectedVelocity * 2).clamp(0.5, 2.0);
        predicted =
            baselineOvulationDate.add(Duration(days: daysLater.round()));
        explanation =
            'T/C ratio ${currentRatio.toStringAsFixed(2)} — LH rising slower than expected (${velocityPerDay.toStringAsFixed(2)}/day). Estimated ovulation may be ${daysLater.round()} day(s) later than baseline.';
      } else {
        predicted = baselineOvulationDate;
        explanation =
            'T/C ratio ${currentRatio.toStringAsFixed(2)} — LH progression is on track with expected trajectory.';
      }
    } else {
      if (currentRatio >= 0.5) {
        predicted = current.timestamp.add(Duration(
            hours: LhInterpretationModel.ovulationShiftHours + 24));
        explanation =
            'T/C ratio ${currentRatio.toStringAsFixed(2)} — LH is elevated. Next test will calculate surge speed for refined prediction.';
      } else {
        predicted = baselineOvulationDate;
        explanation =
            'T/C ratio ${currentRatio.toStringAsFixed(2)} — First quantitative measurement. Velocity will be calculated with the next test.';
      }
    }

    final quantCount = sortedEntries
        .where((e) =>
            e.tcRatio != null && e.entryType == LhEntryType.aiScan)
        .length;
    final confidence = LhInterpretationModel.confidence(
        reliableCount: quantCount, isSurge: isSurge);

    return LhPredictionResult(
      baselineOvulationDate: baselineOvulationDate,
      predictedOvulationDate: predicted,
      currentTcRatio: currentRatio,
      previousTcRatio: previousQuantitative?.tcRatio,
      lhVelocity: velocityPerDay,
      expectedVelocity: expectedVelocity,
      velocityDifference: velocityDifference,
      cycleDay: cycleDay,
      predictionConfidence: confidence,
      explanation: explanation,
    );
  }

  /// Recomputes consecutive per-day velocities, skipping pairs where either
  /// endpoint is flagged unreliable (PRD §42).
  static List<double> _reliableHistoryVelocities(List<LhTestEntry> sorted) {
    final out = <double>[];
    final quant = sorted
        .where((e) =>
            e.tcRatio != null && e.entryType == LhEntryType.aiScan)
        .toList();
    for (var i = 1; i < quant.length; i++) {
      if ((quant[i].reliability ?? 0.8) < 0.5 ||
          (quant[i - 1].reliability ?? 0.8) < 0.5) {
        continue;
      }
      final v = LhInterpretationModel.velocityPerDay(
        currentRatio: quant[i].tcRatio!,
        currentTime: quant[i].timestamp,
        previousRatio: quant[i - 1].tcRatio!,
        previousTime: quant[i - 1].timestamp,
      );
      if (v != null && v.isFinite) out.add(v);
    }
    return out;
  }
}

/// PRD §41 — prediction state + §31 window.
class LhPredictionResult {
  final DateTime baselineOvulationDate;
  final DateTime predictedOvulationDate;
  final double? currentTcRatio;
  final double? previousTcRatio;
  final double? lhVelocity;
  final double expectedVelocity;
  final double? velocityDifference;
  final int cycleDay;
  final double predictionConfidence;
  final String explanation;

  const LhPredictionResult({
    required this.baselineOvulationDate,
    required this.predictedOvulationDate,
    this.currentTcRatio,
    this.previousTcRatio,
    this.lhVelocity,
    required this.expectedVelocity,
    this.velocityDifference,
    required this.cycleDay,
    required this.predictionConfidence,
    required this.explanation,
  });

  bool get hasShifted => predictedOvulationDate != baselineOvulationDate;

  int get shiftDays =>
      predictedOvulationDate.difference(baselineOvulationDate).inDays;

  /// Estimated fertile window around the predicted date (PRD §31).
  DateTime get windowStart =>
      predictedOvulationDate.subtract(const Duration(days: 1));
  DateTime get windowEnd =>
      predictedOvulationDate.add(const Duration(days: 1));
}
