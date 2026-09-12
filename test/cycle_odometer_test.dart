import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/features/home/cycle_odometer.dart';

void main() {
  group('odometerSegments', () {
    test('lays out bleed, fertile, luteal bands for a textbook 28-day cycle',
        () {
      // Ovulation day 14: fertile 9..15, luteal from 15.
      final segs = odometerSegments(
          cycleLen: 28, periodLen: 5, ovulationDay: 14);

      expect(segs, hasLength(28));
      expect(segs.sublist(0, 5),
          everyElement(OdometerPhase.menstrual));
      expect(segs[5], OdometerPhase.follicular); // day 6
      expect(segs[8], OdometerPhase.fertile); // day 9
      expect(segs[13], OdometerPhase.ovulation); // day 14, tracked
      expect(segs[15], OdometerPhase.luteal); // day 16
      expect(segs.last, OdometerPhase.luteal);
    });

    test('estimated ovulation stays inside the fertile band', () {
      final segs =
          odometerSegments(cycleLen: 28, periodLen: 5);

      expect(segs, hasLength(28));
      // Estimate day 14 -> fertile 9..15, no distinct ovulation marker.
      expect(segs.contains(OdometerPhase.ovulation), isFalse);
      expect(segs[13], OdometerPhase.fertile);
    });

    test('out-of-range ovulation falls back to mid-cycle estimate', () {
      final segs = odometerSegments(
          cycleLen: 28, periodLen: 5, ovulationDay: 99);

      expect(segs.contains(OdometerPhase.ovulation), isFalse);
      expect(segs[13], OdometerPhase.fertile);
    });

    test('fertile never paints over bleeding days', () {
      // Absurd early ovulation collapses into a single mid-bleed-safe day.
      final segs =
          odometerSegments(cycleLen: 28, periodLen: 5, ovulationDay: 2);

      expect(segs.sublist(0, 5),
          everyElement(OdometerPhase.menstrual));
    });

    test('degenerate lengths still yield a valid ring', () {
      final segs =
          odometerSegments(cycleLen: 3, periodLen: 40, ovulationDay: -5);

      expect(segs.length, inInclusiveRange(15, 60));
      expect(segs.first, OdometerPhase.menstrual);
    });

    test('late days are luteal, never crash the layout', () {
      final segs =
          odometerSegments(cycleLen: 28, periodLen: 5, ovulationDay: 14);

      expect(segs[27], OdometerPhase.luteal);
    });
  });

  group('odometerAngle', () {
    test('day 1 at top, clockwise, late days clamp to final segment', () {
      expect(odometerAngle(1, 28), closeTo(-math.pi / 2, 1e-9));
      expect(odometerAngle(8, 28),
          closeTo(-math.pi / 2 + 7 / 28 * math.pi * 2, 1e-9));
      expect(odometerAngle(99, 28), closeTo(odometerAngle(28, 28), 1e-9));
      expect(odometerAngle(0, 28), closeTo(odometerAngle(1, 28), 1e-9));
    });
  });
}
