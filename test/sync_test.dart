import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hercycle/core/sync_service.dart';
import 'package:hercycle/models/daily_log.dart';

DailyLog sampleLog(String date) => DailyLog(
      date: date,
      period: true,
      symptoms: const ['Cramps'],
      mood: 'Calm',
      mucus: 'Sticky',
      lhTest: 'Negative',
      flowIntensity: 'Medium',
      painScore: 6,
      pelvicPressure: true,
      backBowelPain: false,
      symptomIntensity: const {'Cramps': 6},
      notes: 'test note',
    );

/// Captures a real WidgetRef for service calls that need one.
Future<WidgetRef> widgetRef(WidgetTester tester) async {
  late WidgetRef captured;
  await tester.pumpWidget(ProviderScope(
    child: Consumer(
      builder: (context, ref, _) {
        captured = ref;
        return const SizedBox();
      },
    ),
  ));
  return captured;
}

void main() {
  test('log payload is JSON-safe for the outbox store', () {
    final payload = sampleLog('2026-01-05').toFirestore();
    // Throws if anything (e.g. a Timestamp) is not encodable.
    final restored =
        DailyLog.fromFirestore(payload.map((k, v) => MapEntry(k, v)));
    expect(restored.date, '2026-01-05');
    expect(restored.period, isTrue);
    expect(restored.symptoms, ['Cramps']);
    expect(restored.symptomIntensity['Cramps'], 6);
    expect(restored.notes, 'test note');
  });

  testWidgets('outbox round-trip: enqueue, restore, markSynced',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final ref = await widgetRef(tester);

    await SyncService.enqueue(ref, 'uid-1', sampleLog('2026-01-05'));
    await SyncService.enqueue(ref, 'uid-1', sampleLog('2026-01-06'));
    expect(ref.read(pendingSyncProvider), {'2026-01-05', '2026-01-06'});

    // Fresh ref (simulating restart): restore must recover the queue.
    final restarted = await widgetRef(tester);
    await SyncService.restore(restarted, 'uid-1');
    expect(
        restarted.read(pendingSyncProvider), {'2026-01-05', '2026-01-06'});

    // Re-enqueue of the same date deduplicates instead of doubling.
    await SyncService.enqueue(restarted, 'uid-1', sampleLog('2026-01-05'));
    expect(restarted.read(pendingSyncProvider),
        {'2026-01-05', '2026-01-06'});

    await SyncService.markSynced(restarted, 'uid-1', '2026-01-05');
    expect(restarted.read(pendingSyncProvider), {'2026-01-06'});

    // Empty queue retry touches no network and reports zeros.
    SharedPreferences.setMockInitialValues({});
    final empty = await widgetRef(tester);
    expect(await SyncService.retryAll(empty, 'uid-1'), (0, 0));
  });

  testWidgets('corrupt outbox entries are skipped, not fatal',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'hercycle_outbox_v1': ['not-json{{{', '123'],
    });
    final ref = await widgetRef(tester);
    await SyncService.restore(ref, 'uid-1');
    expect(ref.read(pendingSyncProvider), isEmpty);
  });

  testWidgets(
      'accounts are isolated: one user never sees or retries another',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final ref = await widgetRef(tester);
    await SyncService.enqueue(ref, 'uid-1', sampleLog('2026-02-01'));
    await SyncService.enqueue(ref, 'uid-2', sampleLog('2026-02-02'));

    await SyncService.restore(ref, 'uid-1');
    expect(ref.read(pendingSyncProvider), {'2026-02-01'});

    await SyncService.restore(ref, 'uid-2');
    expect(ref.read(pendingSyncProvider), {'2026-02-02'});

    // Clearing uid-1's date must not disturb uid-2's queue entry.
    await SyncService.markSynced(ref, 'uid-1', '2026-02-01');
    await SyncService.restore(ref, 'uid-2');
    expect(ref.read(pendingSyncProvider), {'2026-02-02'});
  });
}
