import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/core/sync_service.dart';
import 'package:hercycle/features/calendar/calendar_screen.dart';
import 'package:hercycle/features/home/home_screen.dart';
import 'package:hercycle/features/logging/daily_logging_screen.dart';
import 'package:hercycle/features/luna/luna_screen.dart';
import 'package:hercycle/features/profile/profile_screen.dart';
import 'package:hercycle/features/sos/sos_screen.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/auth_user_provider.dart';
import 'package:hercycle/providers/clinical_data_provider.dart';
import 'package:hercycle/providers/prediction_provider.dart';

/// No-backend render proof: with Firebase never initialized, every screen
/// must render its logged-out/empty state instead of throwing on
/// `FirebaseAuth.instance`. Catches the whole safe-auth bug class.
void main() {
  Map<String, dynamic> prediction() => {
        'currentDay': 5,
        'phaseName': 'Follicular Phase',
        'nextPeriod': DateTime(2026, 10, 9),
        'daysUntilNextPeriod': 28,
        'ovulationDate': null,
        'isOvulationLocked': false,
        'alertMessage': null,
        'message': null,
        'periodStart': null,
        'periodEnd': null,
        'observedBleedDays': null,
      };

  Map<String, dynamic> profile() => {
        'data': {
          'name': 'Test',
          'email': 't@t.com',
          'typicalCycleLength': 28,
          'typicalPeriodLength': 5,
        },
        'fromCache': false,
      };

  List<Override> noBackend() => [
        authUserProvider
            .overrideWith((ref) => Stream<User?>.value(null)),
        predictionProvider.overrideWith((ref) async => prediction()),
        userProfileProvider.overrideWith((ref) async => profile()),
        todayLogProvider.overrideWith((ref) async => null),
        clinicalDataProvider.overrideWith((ref) async => {
              'risks': [],
              'logs': <DailyLog>[],
              'user': null,
              'fromCache': false,
            }),
      ];

  Future<void> settle(WidgetTester tester) async {
    // Timed pumps, never pumpAndSettle: screens with looping animations
    // (e.g. the SOS breathing pacer) schedule frames forever by design.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));
    // Entrance-animation delay timers must not be pending at teardown.
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('home renders without a backend', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: noBackend(),
      child: MaterialApp(
          theme: AppTheme.light, home: const HomeScreen()),
    ));
    await settle(tester);

    expect(find.text('HerCycle'), findsOneWidget);
    expect(find.textContaining('Test'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(refReadsPending(tester), isTrue);
  });

  testWidgets('home survives 2x text scale without overflow', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: noBackend(),
      child: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: MaterialApp(
            theme: AppTheme.light, home: const HomeScreen()),
      ),
    ));
    await settle(tester);

    expect(find.text('HerCycle'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar renders without a backend', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
          theme: AppTheme.light, home: const CalendarScreen()),
    ));
    await settle(tester);

    expect(find.text('Cycle Information'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sos renders without a backend', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
          theme: AppTheme.light, home: const SosScreen()),
    ));
    await settle(tester);

    expect(find.text('Cramp SOS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile renders without a backend', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
          theme: AppTheme.light, home: const ProfileScreen()),
    ));
    await settle(tester);

    expect(find.text('Profile & Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('daily logging renders without a backend', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
          theme: AppTheme.light,
          home: const DailyLoggingScreen(date: '2026-09-11')),
    ));
    await settle(tester);

    expect(find.text('Log for 2026-09-11'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('luna renders without a backend', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: noBackend(),
      child: MaterialApp(
          theme: AppTheme.light, home: const LunaScreen()),
    ));
    await settle(tester);

    expect(find.byType(LunaScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// The pending-sync chip defaults to empty with no queued ops.
bool refReadsPending(WidgetTester tester) {
  final ctx = tester.element(find.byType(HomeScreen));
  return ProviderScope.containerOf(ctx)
      .read(pendingSyncProvider)
      .isEmpty;
}
