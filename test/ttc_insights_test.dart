import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/ttc_insights.dart';

void main() {
  group('ttcStatus', () {
    test('tracked ovulation: peak, test day, coverage', () {
      final s = ttcStatus(
        today: DateTime(2026, 9, 11),
        ovulationDate: DateTime(2026, 9, 14),
        nextPeriod: DateTime(2026, 9, 28),
        intimacyDates: {'2026-09-10', '2026-09-12', '2026-08-01'},
      );

      expect(s.peakDay, DateTime(2026, 9, 14));
      expect(s.testDay, DateTime(2026, 9, 28));
      expect(s.daysToPeak, 3);
      expect(s.daysToTest, 17);
      expect(s.fertileDays, 7);
      // Fertile Sep 9-15: Sep 10 + Sep 12 covered; Aug date ignored.
      expect(s.coveredDays, 2);
      expect(s.coverage, closeTo(2 / 7, 1e-9));
      expect(s.estimated, isFalse);
    });

    test('no ovulation date degrades to mid-cycle estimate', () {
      final s = ttcStatus(
        today: DateTime(2026, 9, 11),
        nextPeriod: DateTime(2026, 9, 28),
      );

      expect(s.peakDay, DateTime(2026, 9, 14));
      expect(s.estimated, isTrue);
      expect(s.coveredDays, 0);
      expect(s.coverage, 0);
    });

    test('no anchors yields nulls, never throws', () {
      final s = ttcStatus(today: DateTime(2026, 9, 11));

      expect(s.peakDay, isNull);
      expect(s.testDay, isNull);
      expect(s.daysToPeak, isNull);
      expect(s.daysToTest, isNull);
      expect(s.coveredDays, 0);
      expect(s.fertileDays, 0);
      expect(s.coverage, 0);
    });

    test('passed peak reports negative countdowns', () {
      final s = ttcStatus(
        today: DateTime(2026, 9, 20),
        ovulationDate: DateTime(2026, 9, 14),
      );

      expect(s.daysToPeak, -6);
      expect(s.testDay, DateTime(2026, 9, 28));
    });

    test('full coverage caps at 1.0', () {
      final s = ttcStatus(
        today: DateTime(2026, 9, 11),
        ovulationDate: DateTime(2026, 9, 14),
        intimacyDates: {
          for (var d = 9; d <= 15; d++)
            '2026-09-${d.toString().padLeft(2, '0')}'
        },
      );

      expect(s.coveredDays, 7);
      expect(s.coverage, 1.0);
    });
  });
}
