import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/features/trends/trends_screen.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/clinical_data_provider.dart';

DailyLog bleedDay(String date) => DailyLog(
      date: date,
      period: true,
      symptoms: const ['Cramps'],
      mood: 'Calm',
    );

String _d(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

List<DailyLog> twoCycles() {
  final logs = <DailyLog>[];
  // Three period starts 28 days apart -> two complete cycles.
  for (final start in [
    DateTime(2026, 5, 1),
    DateTime(2026, 5, 29),
    DateTime(2026, 6, 26),
  ]) {
    for (var i = 0; i < 5; i++) {
      logs.add(bleedDay(_d(start.add(Duration(days: i)))));
    }
  }
  logs.add(DailyLog(
      date: '2026-06-10', period: false, symptoms: const ['Headache'], mood: 'Tired'));
  return logs;
}

void main() {
  testWidgets('trends charts render from engine data', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        clinicalDataProvider.overrideWith((ref) async => {
              'risks': [],
              'logs': twoCycles(),
              'user': {'typicalCycleLength': 28},
              'fromCache': false,
            }),
      ],
      child: const MaterialApp(home: TrendsScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Cycle Length History'), findsOneWidget);
    expect(find.byType(LineChart), findsOneWidget);
    // Below-the-fold content: ListView builds lazily, so scroll first.
    await tester.scrollUntilVisible(
        find.text('Symptom Frequency'), 500);
    expect(find.text('Symptom Frequency'), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);
    // Scroll fully to the bottom so every lazily-built staggered
    // entrance mounts, let all motion settle (no new mounts after
    // this point), then flush entrance delay timers before teardown.
    await tester.scrollUntilVisible(
        find.textContaining('Reliability'), 500);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('trends shows empty states without crashing', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        clinicalDataProvider.overrideWith((ref) async => {
              'risks': [],
              'logs': <DailyLog>[],
              'user': null,
              'fromCache': false,
            }),
      ],
      child: const MaterialApp(home: TrendsScreen()),
    ));
    await tester.pumpAndSettle();

    // Chart cards fall back to guidance text, app stays intact.
    expect(find.text('Cycle Length History'), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);
    expect(find.byType(BarChart), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
