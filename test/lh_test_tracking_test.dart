import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/lh_calibration.dart';
import 'package:hercycle/core/lh_interpretation_model.dart';
import 'package:hercycle/core/lh_strip_cv_pipeline.dart';
import 'package:hercycle/core/lh_prediction_engine.dart';
import 'package:hercycle/core/cycle_predictor_state_machine.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/models/lh_test_entry.dart';

void main() {
  group('LH Test Tracking & Surge Velocity Tests', () {
    test('CV Pipeline classifies Low vs High vs Peak correctly', () {
      final resLow = LhStripCvPipeline.analyzeStrip(imagePath: 'strip_low.png');
      expect(resLow.success, isTrue);

      final resHigh = LhStripCvPipeline.analyzeStrip(imagePath: 'strip_high_0.92.png');
      expect(resHigh.success, isTrue);
      expect(resHigh.tcRatio, greaterThanOrEqualTo(0.8));

      final resPeak = LhStripCvPipeline.analyzeStrip(imagePath: 'strip_peak_1.45.png');
      expect(resPeak.success, isTrue);
      expect(resPeak.tcRatio, greaterThanOrEqualTo(1.15));
      expect(resPeak.surgeStatus, equals(LhSurgeStatus.peak));
    });

    test('Surge Velocity formula calculates linear slope (Ratio2 - Ratio1) / (Time2 - Time1)', () {
      final t1 = DateTime(2026, 6, 1, 8, 0);
      final t2 = DateTime(2026, 6, 1, 14, 0);

      final entry1 = LhTestEntry(
        id: '1', userId: 'u1', timestamp: t1,
        entryType: LhEntryType.aiScan, tcRatio: 0.3, surgeStatus: LhSurgeStatus.low,
      );

      final entry2 = LhTestEntry(
        id: '2', userId: 'u1', timestamp: t2,
        entryType: LhEntryType.aiScan, tcRatio: 0.9, surgeStatus: LhSurgeStatus.high,
      );

      final velocity = LhStripCvPipeline.calculateVelocity(entry1, entry2);
      expect(velocity, closeTo(0.1, 0.001));
    });

    test('State machine locks ovulation and shifts window upon positive / high LH test', () {
      final start = DateTime(2026, 6, 1);
      final logs = [
        DailyLog(date: '2026-06-01', period: true, symptoms: [], mood: '', flowIntensity: 'Medium'),
        DailyLog(date: '2026-06-12', period: false, symptoms: [], mood: '', lhTest: 'Positive', lhRatio: 1.3),
      ];

      final evaluation = CyclePredictorStateMachine.evaluate(
        lastPeriodStartDate: start,
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
        cycleLogs: logs,
        lutealPhaseLength: 14,
        nowOverride: DateTime(2026, 6, 13),
      );

      expect(evaluation.isOvulationLocked, isTrue);
      expect(evaluation.stateStatus, equals('lhPeakLocked'));
      expect(evaluation.ovulationDate, isNotNull);
      expect(evaluation.alertMessage?.contains('LH Surge detected'), isTrue);
    });

    test('LhTestEntry serialization round-trip', () {
      final entry = LhTestEntry(
        id: 'test_123', userId: 'user_abc',
        timestamp: DateTime(2026, 6, 1, 10, 30),
        entryType: LhEntryType.aiScan, imageUrl: '/local/path/strip.jpg',
        tcRatio: 1.15, surgeStatus: LhSurgeStatus.high,
        surgeVelocity: 0.08, notes: 'Clear test line',
        baselineOvulationDate: DateTime(2026, 6, 15),
        predictedOvulationDate: DateTime(2026, 6, 14),
        predictionConfidence: 0.85,
        predictionUpdatedAt: DateTime(2026, 6, 13),
        expectedVelocity: 0.15,
        velocityDifference: 0.05,
      );

      final map = entry.toFirestore();
      final restored = LhTestEntry.fromFirestore(map);

      expect(restored.id, equals(entry.id));
      expect(restored.userId, equals(entry.userId));
      expect(restored.entryType, equals(entry.entryType));
      expect(restored.tcRatio, equals(entry.tcRatio));
      expect(restored.surgeStatus, equals(entry.surgeStatus));
      expect(restored.notes, equals(entry.notes));
      expect(restored.baselineOvulationDate, equals(entry.baselineOvulationDate));
      expect(restored.predictedOvulationDate, equals(entry.predictedOvulationDate));
      expect(restored.predictionConfidence, equals(entry.predictionConfidence));
      expect(restored.expectedVelocity, equals(entry.expectedVelocity));
      expect(restored.velocityDifference, equals(entry.velocityDifference));
    });

    test('LhTestEntry.withPrediction copies entry with new prediction fields', () {
      final entry = LhTestEntry(
        id: 'test_1', userId: 'u1',
        timestamp: DateTime(2026, 6, 1),
        entryType: LhEntryType.aiScan, tcRatio: 0.5,
        surgeStatus: LhSurgeStatus.low,
      );

      final updated = entry.withPrediction(
        baselineOvulationDate: DateTime(2026, 6, 14),
        predictedOvulationDate: DateTime(2026, 6, 13),
        predictionConfidence: 0.7,
      );

      expect(updated.id, equals(entry.id));
      expect(updated.tcRatio, equals(entry.tcRatio));
      expect(updated.predictedOvulationDate, equals(DateTime(2026, 6, 13)));
      expect(updated.predictionConfidence, equals(0.7));
    });
  });

  group('LH Prediction Engine Tests', () {
    test('Empty entries returns baseline prediction with low confidence', () {
      final baseline = DateTime(2026, 9, 16);
      final result = LhPredictionEngine.compute(
        sortedEntries: [],
        baselineOvulationDate: baseline,
        cycleDay: 10,
      );

      expect(result.predictedOvulationDate, equals(baseline));
      expect(result.predictionConfidence, equals(LhPredictionEngine.minConfidence));
      expect(result.hasShifted, isFalse);
      expect(result.lhVelocity, isNull);
      expect(result.explanation, contains('No LH data'));
    });

    test('Single AI scan with low ratio returns baseline prediction', () {
      final baseline = DateTime(2026, 9, 16);
      final entries = [
        LhTestEntry(
          id: '1', userId: 'u1', timestamp: DateTime(2026, 9, 10),
          entryType: LhEntryType.aiScan, tcRatio: 0.2, surgeStatus: LhSurgeStatus.low,
        ),
      ];

      final result = LhPredictionEngine.compute(
        sortedEntries: entries,
        baselineOvulationDate: baseline,
        cycleDay: 10,
      );

      expect(result.predictedOvulationDate, equals(baseline));
      expect(result.currentTcRatio, equals(0.2));
      expect(result.lhVelocity, isNull);
      expect(result.explanation, contains('First quantitative'));
    });

    test('Surge threshold (ratio >= 0.8) triggers ovulation window 24-36h post-detection', () {
      final baseline = DateTime(2026, 9, 16);
      final now = DateTime(2026, 9, 13, 8, 0);
      final entries = [
        LhTestEntry(
          id: '1', userId: 'u1', timestamp: now.subtract(const Duration(days: 1)),
          entryType: LhEntryType.aiScan, tcRatio: 0.3, surgeStatus: LhSurgeStatus.low,
        ),
        LhTestEntry(
          id: '2', userId: 'u1', timestamp: now,
          entryType: LhEntryType.aiScan, tcRatio: 0.9, surgeStatus: LhSurgeStatus.high,
        ),
      ];

      final result = LhPredictionEngine.compute(
        sortedEntries: entries,
        baselineOvulationDate: baseline,
        cycleDay: 13,
      );

      expect(result.predictedOvulationDate, equals(now.add(const Duration(hours: 30))));
      expect(result.hasShifted, isTrue);
      expect(result.shiftDays, lessThanOrEqualTo(2));
      expect(result.explanation, isNotEmpty);
      expect(result.explanation, anyOf(
        contains('surge'),
        contains('rising faster'),
        contains('ovulation'),
      ));
    });

    test('Velocity faster than expected moves ovulation earlier', () {
      final baseline = DateTime(2026, 9, 16);
      final entries = [
        LhTestEntry(
          id: '1', userId: 'u1', timestamp: DateTime(2026, 9, 11),
          entryType: LhEntryType.aiScan, tcRatio: 0.15, surgeStatus: LhSurgeStatus.low,
        ),
        LhTestEntry(
          id: '2', userId: 'u1', timestamp: DateTime(2026, 9, 12),
          entryType: LhEntryType.aiScan, tcRatio: 0.5, surgeStatus: LhSurgeStatus.low,
        ),
        LhTestEntry(
          id: '3', userId: 'u1', timestamp: DateTime(2026, 9, 13),
          entryType: LhEntryType.aiScan, tcRatio: 0.7, surgeStatus: LhSurgeStatus.low,
        ),
      ];

      final result = LhPredictionEngine.compute(
        sortedEntries: entries,
        baselineOvulationDate: baseline,
        cycleDay: 13,
      );

      expect(result.lhVelocity, isNotNull);
      expect(result.lhVelocity!, greaterThan(0));
      expect(result.shiftDays, lessThanOrEqualTo(0));
      expect(result.explanation, isNotEmpty);
    });

    test('Velocity slower than expected moves ovulation later', () {
      final baseline = DateTime(2026, 9, 16);
      final entries = [
        LhTestEntry(
          id: '1', userId: 'u1', timestamp: DateTime(2026, 9, 10),
          entryType: LhEntryType.aiScan, tcRatio: 0.15, surgeStatus: LhSurgeStatus.low,
        ),
        LhTestEntry(
          id: '2', userId: 'u1', timestamp: DateTime(2026, 9, 12),
          entryType: LhEntryType.aiScan, tcRatio: 0.2, surgeStatus: LhSurgeStatus.low,
        ),
      ];

      final result = LhPredictionEngine.compute(
        sortedEntries: entries,
        baselineOvulationDate: baseline,
        cycleDay: 12,
      );

      expect(result.lhVelocity, isNotNull);
      expect(result.lhVelocity!, lessThan(LhPredictionEngine.calibratedExpectedVelocityPerDay));
      expect(result.shiftDays, greaterThanOrEqualTo(0));
    });

    test('Manual positive uses calibrated post-surge window without velocity', () {
      final baseline = DateTime(2026, 9, 16);
      final entries = [
        LhTestEntry(
          id: '1', userId: 'u1', timestamp: DateTime(2026, 9, 13, 8, 0),
          entryType: LhEntryType.manual, manualResult: LhManualResult.positive,
          surgeStatus: LhSurgeStatus.high,
        ),
      ];

      final result = LhPredictionEngine.compute(
        sortedEntries: entries,
        baselineOvulationDate: baseline,
        cycleDay: 13,
      );

      expect(result.currentTcRatio, isNull);
      expect(result.lhVelocity, isNull);
      expect(result.predictedOvulationDate,
          equals(DateTime(2026, 9, 13, 8, 0).add(const Duration(hours: 30))));
      expect(result.explanation, contains('Manual positive'));
    });

    test('Manual negative uses baseline prediction', () {
      final baseline = DateTime(2026, 9, 16);
      final entries = [
        LhTestEntry(
          id: '1', userId: 'u1', timestamp: DateTime(2026, 9, 12),
          entryType: LhEntryType.manual, manualResult: LhManualResult.negative,
          surgeStatus: LhSurgeStatus.low,
        ),
      ];

      final result = LhPredictionEngine.compute(
        sortedEntries: entries,
        baselineOvulationDate: baseline,
        cycleDay: 12,
      );

      expect(result.predictedOvulationDate, equals(baseline));
      expect(result.explanation, contains('Manual negative'));
    });

    test('Confidence increases with more quantitative data points', () {
      final baseline = DateTime(2026, 9, 16);
      final entries2 = [
        LhTestEntry(
          id: '1', userId: 'u1', timestamp: DateTime(2026, 9, 11),
          entryType: LhEntryType.aiScan, tcRatio: 0.15, surgeStatus: LhSurgeStatus.low,
        ),
        LhTestEntry(
          id: '2', userId: 'u1', timestamp: DateTime(2026, 9, 12),
          entryType: LhEntryType.aiScan, tcRatio: 0.25, surgeStatus: LhSurgeStatus.low,
        ),
      ];

      final entries5 = [
        ...entries2,
        LhTestEntry(
          id: '3', userId: 'u1', timestamp: DateTime(2026, 9, 13),
          entryType: LhEntryType.aiScan, tcRatio: 0.35, surgeStatus: LhSurgeStatus.low,
        ),
        LhTestEntry(
          id: '4', userId: 'u1', timestamp: DateTime(2026, 9, 14),
          entryType: LhEntryType.aiScan, tcRatio: 0.45, surgeStatus: LhSurgeStatus.low,
        ),
        LhTestEntry(
          id: '5', userId: 'u1', timestamp: DateTime(2026, 9, 15),
          entryType: LhEntryType.aiScan, tcRatio: 0.55, surgeStatus: LhSurgeStatus.low,
        ),
      ];

      final result2 = LhPredictionEngine.compute(
        sortedEntries: entries2, baselineOvulationDate: baseline, cycleDay: 12,
      );
      final result5 = LhPredictionEngine.compute(
        sortedEntries: entries5, baselineOvulationDate: baseline, cycleDay: 15,
      );

      expect(result5.predictionConfidence, greaterThanOrEqualTo(result2.predictionConfidence));
    });

    test('Velocity calculation normalizes to per-day', () {
      final baseline = DateTime(2026, 9, 16);
      final entries = [
        LhTestEntry(
          id: '1', userId: 'u1', timestamp: DateTime(2026, 9, 11, 8, 0),
          entryType: LhEntryType.aiScan, tcRatio: 0.3, surgeStatus: LhSurgeStatus.low,
        ),
        LhTestEntry(
          id: '2', userId: 'u1', timestamp: DateTime(2026, 9, 12, 8, 0),
          entryType: LhEntryType.aiScan, tcRatio: 0.6, surgeStatus: LhSurgeStatus.low,
        ),
      ];

      final result = LhPredictionEngine.compute(
        sortedEntries: entries, baselineOvulationDate: baseline, cycleDay: 12,
      );

      // (0.6 - 0.3) / 24h * 24 = 0.3 per day
      expect(result.lhVelocity, closeTo(0.3, 0.01));
      expect(result.currentTcRatio, equals(0.6));
      expect(result.previousTcRatio, equals(0.3));
    });

    test('Prediction window spans one day each side of predicted date', () {
      final baseline = DateTime(2026, 9, 16);
      final result = LhPredictionEngine.compute(
        sortedEntries: [],
        baselineOvulationDate: baseline,
        cycleDay: 10,
      );
      expect(result.windowStart, equals(baseline.subtract(const Duration(days: 1))));
      expect(result.windowEnd, equals(baseline.add(const Duration(days: 1))));
    });
  });

  group('PRD v1.0 — Calibration (LH-CAL-v1)', () {
    test('Anchor points calibrate exactly', () {
      expect(LhCalibration.calibrate(0.0), equals(0.0));
      expect(LhCalibration.calibrate(0.40), equals(0.54));
      expect(LhCalibration.calibrate(0.59), equals(0.90));
      expect(LhCalibration.calibrate(1.03), equals(1.15));
    });

    test('Mid-anchor values interpolate', () {
      final v = LhCalibration.calibrate(0.285);
      expect(v, greaterThan(0.32));
      expect(v, lessThan(0.54));
    });

    test('Out-of-range values clamp to edges', () {
      expect(LhCalibration.calibrate(-1.0), equals(0.0));
      expect(LhCalibration.calibrate(99.0), equals(2.20));
    });

    test('Calibration version is pinned', () {
      expect(LhCalibration.version, equals('LH-CAL-v1'));
      expect(LhInterpretationModel.calibrationVersion, equals('LH-CAL-v1'));
    });
  });

  group('PRD v1.0 — Single-source interpretation (LH-INTERPRET-v2)', () {
    test('Status thresholds: low / rising / high / peak', () {
      expect(LhInterpretationModel.interpretStatus(0.2, null),
          equals(LhSurgeStatus.low));
      expect(LhInterpretationModel.interpretStatus(0.5, 0.2),
          equals(LhSurgeStatus.rising));
      expect(LhInterpretationModel.interpretStatus(0.5, -0.1),
          equals(LhSurgeStatus.low));
      expect(LhInterpretationModel.interpretStatus(0.9, null),
          equals(LhSurgeStatus.high));
      expect(LhInterpretationModel.interpretStatus(1.2, null),
          equals(LhSurgeStatus.peak));
    });

    test('Velocity uses actual elapsed time', () {
      final v = LhInterpretationModel.velocityPerDay(
        currentRatio: 0.6,
        currentTime: DateTime(2026, 9, 12, 8),
        previousRatio: 0.3,
        previousTime: DateTime(2026, 9, 11, 8),
      );
      expect(v, closeTo(0.3, 0.001));
    });

    test('Velocity returns null for non-positive intervals', () {
      final v = LhInterpretationModel.velocityPerDay(
        currentRatio: 0.6,
        currentTime: DateTime(2026, 9, 11, 8),
        previousRatio: 0.3,
        previousTime: DateTime(2026, 9, 11, 8),
      );
      expect(v, isNull);
    });

    test('New users get baseline expectation; adaptation needs history', () {
      expect(LhInterpretationModel.expectedVelocityPerDay([]),
          equals(LhInterpretationModel.baselineExpectedVelocityPerDay));
      expect(LhInterpretationModel.expectedVelocityPerDay([0.4, 0.5]),
          equals(LhInterpretationModel.baselineExpectedVelocityPerDay));
      final adapted =
          LhInterpretationModel.expectedVelocityPerDay([0.4, 0.45, 0.5, 0.42]);
      expect(adapted, greaterThan(LhInterpretationModel.baselineExpectedVelocityPerDay));
    });

    test('Pipeline failures carry error codes for retake/manual UI', () {
      final noControl =
          LhStripCvPipeline.analyzeStrip(imagePath: 'strip_nocontrol.png');
      expect(noControl.success, isFalse);
      expect(noControl.errorCode, equals(LhErrorCode.controlLineMissing));

      final poor =
          LhStripCvPipeline.analyzeStrip(imagePath: 'strip_blur.png');
      expect(poor.success, isFalse);
      expect(poor.errorCode, equals(LhErrorCode.poorQuality));
    });

    test('Successful scans carry raw + calibrated + versions', () {
      final res =
          LhStripCvPipeline.analyzeStrip(imagePath: 'strip_high_demo.png');
      expect(res.success, isTrue);
      expect(res.rawRatio, closeTo(0.59, 0.001));
      expect(res.tcRatio, closeTo(0.90, 0.001));
      expect(res.calibrationVersion, equals('LH-CAL-v1'));
      expect(res.interpretationVersion, equals('LH-INTERPRET-v2'));
    });

    test('Versioned schema round-trips raw, reliability and versions', () {
      final entry = LhTestEntry(
        id: 'v1',
        userId: 'u1',
        timestamp: DateTime(2026, 9, 13, 8),
        entryType: LhEntryType.aiScan,
        rawRatio: 0.59,
        calibratedRatio: 0.9,
        surgeStatus: LhSurgeStatus.high,
        reliability: 0.8,
        detectionVersion: 'YOLO-LH-v1',
        calibrationVersion: 'LH-CAL-v1',
        interpretationVersion: 'LH-INTERPRET-v2',
      );
      final restored = LhTestEntry.fromFirestore(entry.toFirestore());
      expect(restored.rawRatio, equals(0.59));
      expect(restored.tcRatio, equals(0.9));
      expect(restored.reliability, equals(0.8));
      expect(restored.calibrationVersion, equals('LH-CAL-v1'));
      expect(restored.interpretationVersion, equals('LH-INTERPRET-v2'));
    });

    test('Legacy tc_ratio records still load (no forced reinterpretation)', () {
      final restored = LhTestEntry.fromFirestore({
        'id': 'old',
        'user_id': 'u1',
        'timestamp': '2026-09-10T08:00:00',
        'entry_type': 'AI_SCAN',
        'tc_ratio': 0.7,
        'surge_status': 'LOW',
      });
      expect(restored.tcRatio, equals(0.7));
      expect(restored.calibrationVersion, isNull);
    });
  });
}
