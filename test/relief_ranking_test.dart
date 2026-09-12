import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/relief_ranking.dart';

void main() {
  group('rankReliefs', () {
    test('verdicts first, ordered by help rate then most tried', () {
      final ranked = rankReliefs(
        tried: {'Heat': 4, 'Rest': 3, 'Warm tea': 1},
        helped: {'Heat': 3, 'Rest': 3, 'Warm tea': 1},
      );

      // Rest 3/3 beats Heat 3/4; Warm tea (1 try) has no verdict yet.
      expect(ranked.first.name, 'Rest');
      expect(ranked[1].name, 'Heat');
      expect(ranked.first.verdict, 'Helped 3 of 3 times');
      expect(ranked.last.hasVerdict, isFalse);
    });

    test('helped is clamped to tried on corrupt data', () {
      final ranked = rankReliefs(
        tried: {'Heat': 1},
        helped: {'Heat': 9},
      );

      final heat = ranked.firstWhere((r) => r.name == 'Heat');
      expect(heat.helped, 1);
      expect(heat.verdict, isNot(contains('9')));
    });

    test('unknown and negative counts treated as untried', () {
      final ranked = rankReliefs(
        tried: {'Heat': -2},
        helped: {},
      );

      final heat = ranked.firstWhere((r) => r.name == 'Heat');
      expect(heat.tried, 0);
      expect(heat.verdict, 'Not tried yet');
    });
  });

  group('aggregateReliefs', () {
    test('sums totals, ignores corrupt entries', () {
      final totals = aggregateReliefs([
        {
          'reliefTried': {'Heat': 2, 'Rest': 1},
          'reliefHelped': {'Heat': 1},
        },
        {
          'reliefTried': {'Heat': 1, '': 5, 'Bad': -3, 'Weird': 'x'},
          'reliefHelped': {'Heat': 1, 'Rest': 0},
        },
        {'nonsense': true},
      ]);

      expect(totals.tried, {'Heat': 3, 'Rest': 1});
      expect(totals.helped, {'Heat': 2});
    });

    test('empty input yields empty totals', () {
      final totals = aggregateReliefs([]);
      expect(totals.tried, isEmpty);
      expect(totals.helped, isEmpty);
    });
  });

  group('recordEpisode', () {
    test('accumulates tried and helped per relief', () {
      final result = recordEpisode(
        tried: {'Heat': 2},
        helped: {'Heat': 1},
        reliefs: ['Heat', 'Rest'],
        helpedIt: true,
      );

      expect(result.tried['Heat'], 3);
      expect(result.helped['Heat'], 2);
      expect(result.tried['Rest'], 1);
      expect(result.helped['Rest'], 1);
    });

    test('no-help episode only bumps tried; blanks ignored', () {
      final result = recordEpisode(
        tried: {},
        helped: {},
        reliefs: ['Heat', '   '],
        helpedIt: false,
      );

      expect(result.tried['Heat'], 1);
      expect(result.helped['Heat'], isNull);
      expect(result.tried.length, 1);
    });
  });
}
