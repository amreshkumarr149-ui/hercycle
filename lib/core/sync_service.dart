import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hercycle/core/database_repository.dart';
import 'package:hercycle/core/telemetry_service.dart';
import 'package:hercycle/models/daily_log.dart';

/// Dates (yyyy-MM-dd) with daily-log writes not yet confirmed on the server.
final pendingSyncProvider = StateProvider<Set<String>>((ref) => {});

/// Offline outbox for daily logs: failed saves persist as JSON across
/// restarts and can be retried explicitly (sync chip) or automatically at
/// launch. Firestore's own cache still applies writes locally first; the
/// outbox is the source of truth for "not yet confirmed".
class SyncService {
  SyncService._();
  static const _key = 'hercycle_outbox_v1';

  static Future<List<Map<String, dynamic>>> _loadQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key) ?? [];
      return raw
          .map((s) {
            try {
              final decoded = jsonDecode(s);
              return decoded is Map<String, dynamic> ? decoded : null;
            } catch (_) {
              return null;
            }
          })
          .whereType<Map<String, dynamic>>()
          .where((op) =>
              op['userId'] is String &&
              op['date'] is String &&
              op['log'] is Map)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveQueue(List<Map<String, dynamic>> queue) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _key, queue.map((op) => jsonEncode(op)).toList());
    } catch (_) {}
  }

  static void _setPending(WidgetRef ref, Set<String> dates) {
    try {
      ref.read(pendingSyncProvider.notifier).state = dates;
    } catch (_) {}
  }

  static String _opKey(Map<String, dynamic> op) =>
      '${op['userId']}|${op['date']}|${op['queuedAt'] ?? ''}';

  /// Pending dates for one user only. The on-disk queue may hold ops from a
  /// previously signed-in account; those must never surface in (or be
  /// retried under) the current account — Firestore rules would deny them
  /// and the chip would show phantom items.
  static Set<String> _pendingFor(
      List<Map<String, dynamic>> queue, String userId) {
    return {
      for (final op in queue)
        if (op['userId'] == userId) op['date'].toString()
    };
  }

  /// Queue a failed save (deduplicated per user+date) and mark it pending.
  static Future<void> enqueue(
      WidgetRef ref, String userId, DailyLog log) async {
    final queue = await _loadQueue();
    queue.removeWhere(
        (op) => op['userId'] == userId && op['date'] == log.date);
    queue.add({
      'userId': userId,
      'date': log.date,
      'log': log.toFirestore(),
      'queuedAt': DateTime.now().toIso8601String(),
    });
    await _saveQueue(queue);
    _setPending(ref, _pendingFor(queue, userId));
  }

  /// Clear a date after a confirmed save.
  static Future<void> markSynced(
      WidgetRef ref, String userId, String date) async {
    final queue = await _loadQueue();
    queue.removeWhere((op) => op['userId'] == userId && op['date'] == date);
    await _saveQueue(queue);
    _setPending(ref, _pendingFor(queue, userId));
  }

  /// Restore pending dates at startup (call once from Home initState).
  /// Scoped to [userId]: another account's queued ops stay stored but
  /// hidden until that account signs back in.
  static Future<void> restore(WidgetRef ref, String userId) async {
    final queue = await _loadQueue();
    _setPending(ref, _pendingFor(queue, userId));
  }

  /// Retry every queued op belonging to [userId]. Returns (succeeded,
  /// failed). Reloads the queue before persisting so an op enqueued
  /// concurrently (e.g. user taps save mid-retry) is never dropped.
  static Future<(int, int)> retryAll(WidgetRef ref, String userId) async {
    final mine = (await _loadQueue())
        .where((op) => op['userId'] == userId)
        .toList();
    if (mine.isEmpty) {
      _setPending(ref, _pendingFor(await _loadQueue(), userId));
      return (0, 0);
    }
    final repo = DatabaseRepository();
    var ok = 0;
    var failed = 0;
    final succeededKeys = <String>{};
    for (final op in mine) {
      try {
        final payload = Map<String, dynamic>.from(op['log'] as Map);
        payload['date'] = op['date'].toString();
        final log = DailyLog.fromFirestore(payload);
        await repo.saveLog(userId, log);
        succeededKeys.add(_opKey(op));
        ok++;
      } catch (e) {
        failed++;
        await TelemetryService.recordError(e, StackTrace.current,
            reason: 'sync-retry');
      }
    }
    final fresh = await _loadQueue();
    fresh.removeWhere((op) =>
        op['userId'] == userId && succeededKeys.contains(_opKey(op)));
    await _saveQueue(fresh);
    _setPending(ref, _pendingFor(fresh, userId));
    if (ok > 0) {
      await TelemetryService.logEvent('sync_retry_completed');
    }
    return (ok, failed);
  }
}
