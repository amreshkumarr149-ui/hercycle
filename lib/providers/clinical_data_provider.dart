import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/core/disease_risk_screener.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/auth_user_provider.dart';

/// Shared fetch of everything the analytics screens need: PCOS/fibroid/
/// endometriosis screening results, all daily logs (newest first), the user
/// profile, and whether the data came from the offline cache.
///
/// Watches [authUserProvider] so account switches refetch instead of serving
/// the previous account's cached report. A single malformed log document is
/// skipped rather than failing the whole fetch.
final clinicalDataProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
  final user =
      ref.watch(authUserProvider).value ?? safeCurrentUser();
  if (user == null) {
    return {
      'risks': <RiskAssessmentResult>[],
      'logs': <DailyLog>[],
      'user': null,
      'fromCache': false,
    };
  }

  final userSnap = await FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .get();
  final userData = userSnap.data();

  final logsSnap = await FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .collection('dailyLogs')
      .orderBy('date', descending: true)
      .get();

  final logs = <DailyLog>[];
  for (final d in logsSnap.docs) {
    try {
      logs.add(DailyLog.fromFirestore(d.data()));
    } catch (_) {
      // Skip a single malformed document rather than failing the report.
    }
  }
  final rawCycle = userData?['typicalCycleLength'];
  final typicalCycleLength =
      rawCycle is int ? rawCycle : (rawCycle is num ? rawCycle.toInt() : 28);
  final risks = DiseaseRiskScreener.evaluate(
      allLogs: logs, typicalCycleLength: typicalCycleLength);

  return {
    'risks': risks,
    'logs': logs,
    'user': userData,
    'fromCache':
        userSnap.metadata.isFromCache || logsSnap.metadata.isFromCache,
  };
});
