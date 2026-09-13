import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/lh_strip_cv_pipeline.dart';
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
      expect(resPeak.tcRatio, greaterThanOrEqualTo(1.2));
      expect(resPeak.surgeStatus, equals(LhSurgeStatus.peak));
    });

    test('Surge Velocity formula calculates linear slope (Ratio2 - Ratio1) / (Time2 - Time1)', () {
      final t1 = DateTime(2026, 6, 1, 8, 0);
      final t2 = DateTime(2026, 6, 1, 14, 0); // 6 hours later

      final entry1 = LhTestEntry(
        id: '1',
        userId: 'u1',
        timestamp: t1,
        entryType: LhEntryType.aiScan,
        tcRatio: 0.3,
        surgeStatus: LhSurgeStatus.low,
      );

      final entry2 = LhTestEntry(
        id: '2',
        userId: 'u1',
        timestamp: t2,
        entryType: LhEntryType.aiScan,
        tcRatio: 0.9,
        surgeStatus: LhSurgeStatus.high,
      );

      final velocity = LhStripCvPipeline.calculateVelocity(entry1, entry2);
      // (0.9 - 0.3) / 6 hours = 0.6 / 6 = 0.1 ratio per hour
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
      // Ovulation should be locked 30 hours post-detection
      expect(evaluation.alertMessage?.contains('LH Surge detected'), isTrue);
    });

    test('LhTestEntry serialization round-trip', () {
      final entry = LhTestEntry(
        id: 'test_123',
        userId: 'user_abc',
        timestamp: DateTime(2026, 6, 1, 10, 30),
        entryType: LhEntryType.aiScan,
        imageUrl: '/local/path/strip.jpg',
        tcRatio: 1.15,
        surgeStatus: LhSurgeStatus.high,
        surgeVelocity: 0.08,
        notes: 'Clear test line',
      );

      final map = entry.toFirestore();
      final restored = LhTestEntry.fromFirestore(map);

      expect(restored.id, equals(entry.id));
      expect(restored.userId, equals(entry.userId));
      expect(restored.entryType, equals(entry.entryType));
      expect(restored.tcRatio, equals(entry.tcRatio));
      expect(restored.surgeStatus, equals(entry.surgeStatus));
      expect(restored.notes, equals(entry.notes));
    });
  });
}
