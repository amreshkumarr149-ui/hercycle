import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/week_planner.dart';

void main() {
  group('planWeek', () {
    test('tags period, fertile and PMS days from tracked anchors', () {
      final today = DateTime(2026, 9, 11);
      // Day 12 of 28; ovulation Sep 14 (fertile Sep 9-15); next period Sep 25.
      final result = planWeek(
        today: today,
        currentDay: 12,
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
        nextPeriod: DateTime(2026, 9, 25),
        ovulationDate: DateTime(2026, 9, 14),
        lutealSignals: const [
          LutealSignal(name: 'Headache', cyclesAffected: 3),
        ],
      );

      expect(result.days, hasLength(7));
      expect(result.personalized, isTrue);

      // Sep 11: fertile window (ovu-5..ovu+1) -> high.
      expect(result.days[0].energy, DayEnergy.high);
      // Sep 14: ovulation day -> high with fertile reason.
      expect(result.days[3].energy, DayEnergy.high);
      // Sep 16-17: luteal + repeat signal -> PMS likely.
      expect(result.days[5].energy, DayEnergy.pmsLikely);
      expect(result.days[6].energy, DayEnergy.pmsLikely);
      expect(result.days[6].reasons.join(' '), contains('Headache'));
    });

    test('withholds PMS tag below the repeat threshold', () {
      final today = DateTime(2026, 9, 11);
      final result = planWeek(
        today: today,
        currentDay: 24, // luteal
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
        nextPeriod: DateTime(2026, 9, 15),
        lutealSignals: const [
          LutealSignal(name: 'Cramps', cyclesAffected: 1),
        ],
      );

      expect(
        result.days.where((d) => d.energy == DayEnergy.pmsLikely),
        isEmpty,
      );
    });

    test('falls back to phase-only tags with no history', () {
      final today = DateTime(2026, 9, 11);
      final result = planWeek(
        today: today,
        currentDay: 3, // menstrual
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
      );

      expect(result.personalized, isFalse);
      expect(result.days[0].energy, DayEnergy.rest);
      // Day 8 -> follicular -> high.
      expect(result.days[5].energy, DayEnergy.high);
    });

    test('tags predicted bleeding window as period', () {
      final today = DateTime(2026, 9, 11);
      final result = planWeek(
        today: today,
        currentDay: 27,
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
        nextPeriod: DateTime(2026, 9, 12),
      );

      expect(result.days[1].energy, DayEnergy.period);
      expect(result.days[1].reasons.join(' '), contains('today'));
    });

    test('overdue days stay period-tagged, never flip to luteal', () {
      final today = DateTime(2026, 9, 11);
      // Period was due Sep 4 (5-day window ended Sep 9); still unlogged.
      final result = planWeek(
        today: today,
        currentDay: 36,
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
        nextPeriod: DateTime(2026, 9, 4),
      );

      expect(result.days[0].energy, DayEnergy.period);
      expect(
          result.days[0].reasons.join(' '), contains('log it when it starts'));
      expect(
        result.days.where((d) => d.energy == DayEnergy.pmsLikely),
        isEmpty,
      );
    });

    test('zero threshold falls back to 2 instead of flagging everything',
        () {
      final today = DateTime(2026, 9, 11);
      final result = planWeek(
        today: today,
        currentDay: 24, // luteal
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
        nextPeriod: DateTime(2026, 9, 15),
        lutealSignals: const [
          LutealSignal(name: 'Cramps', cyclesAffected: 1),
        ],
        pmsThreshold: 0,
      );

      expect(
        result.days.where((d) => d.energy == DayEnergy.pmsLikely),
        isEmpty,
      );
    });

    test('signals normalize: trim, dedupe, drop empties and negatives', () {
      final today = DateTime(2026, 9, 11);
      final result = planWeek(
        today: today,
        currentDay: 24, // luteal
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
        nextPeriod: DateTime(2026, 9, 15),
        lutealSignals: const [
          LutealSignal(name: '  Headache  ', cyclesAffected: 2),
          LutealSignal(name: 'headache', cyclesAffected: 3),
          LutealSignal(name: '   ', cyclesAffected: 9),
          LutealSignal(name: 'Nausea', cyclesAffected: -4),
        ],
      );

      final pms = result.days
          .where((d) => d.energy == DayEnergy.pmsLikely)
          .toList();
      expect(pms, isNotEmpty);
      // Merged duplicate keeps first-seen display name + strongest count.
      expect(pms.first.reasons.join(' '), contains('Headache (3 cycles)'));
      expect(pms.first.reasons.join(' '), isNot(contains('Nausea')));
    });

    test('non-positive current day never renders Day 0 or negatives', () {
      final today = DateTime(2026, 9, 11);
      final result = planWeek(
        today: today,
        currentDay: 0,
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
      );

      expect(result.days.first.cycleDay, 1);
      expect(
        result.days.every((d) => d.cycleDay >= 1),
        isTrue,
      );
    });

    test('stale ovulation anchor past next period is ignored', () {
      final today = DateTime(2026, 9, 11);
      // Ovulation Sep 20 but next period Sep 12: new cycle started.
      final result = planWeek(
        today: today,
        currentDay: 30,
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
        nextPeriod: DateTime(2026, 9, 12),
        ovulationDate: DateTime(2026, 9, 20),
      );

      // Sep 15-17 would be "fertile" off the stale anchor; they must not be.
      expect(result.days[4].energy, isNot(DayEnergy.high));
      expect(result.days[5].energy, isNot(DayEnergy.high));
    });

    test('lutealSignalsFrom degrades to empty on bad input', () {
      expect(
        lutealSignalsFrom(logs: null, profile: null, fromCache: false),
        isEmpty,
      );
    });

    test('locked ovulation surfaces confirmation', () {
      final today = DateTime(2026, 9, 11);
      final result = planWeek(
        today: today,
        currentDay: 14,
        typicalCycleLength: 28,
        typicalPeriodLength: 5,
        ovulationDate: DateTime(2026, 9, 11),
        ovulationLocked: true,
      );

      expect(result.days[0].energy, DayEnergy.high);
      expect(result.days[0].reasons.join(' '), contains('confirmed'));
    });
  });

  group('plannerNudgeFor', () {
    PlannedDay day(DayEnergy energy,
            [List<String> reasons = const ['Day 1']]) =>
        PlannedDay(
            date: DateTime(2026, 9, 12),
            cycleDay: 1,
            energy: energy,
            reasons: reasons);

    test('rest, PMS and period tomorrows nudge; high and calm stay silent',
        () {
      expect(
          plannerNudgeFor(day(DayEnergy.rest), personalized: true)?.title,
          contains('restful'));
      expect(
          plannerNudgeFor(day(DayEnergy.period), personalized: false)?.title,
          contains('Period'));
      expect(plannerNudgeFor(day(DayEnergy.high), personalized: true),
          isNull);
      expect(plannerNudgeFor(day(DayEnergy.calm), personalized: false),
          isNull);
    });

    test('PMS nudge carries the personal pattern when available', () {
      final nudge = plannerNudgeFor(
        day(DayEnergy.pmsLikely,
            ['Day 24', 'Your pattern: Headache (3 cycles)']),
        personalized: true,
      );

      expect(nudge?.title, contains('PMS'));
      expect(nudge?.body, contains('Headache'));
    });

    test('PMS nudge falls back gracefully without a pattern line', () {
      final nudge = plannerNudgeFor(
        day(DayEnergy.pmsLikely),
        personalized: false,
      );

      expect(nudge?.title, contains('PMS'));
      expect(nudge?.body, isNotEmpty);
    });
  });
}
