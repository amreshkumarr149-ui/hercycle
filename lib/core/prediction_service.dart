import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hercycle/core/cycle_predictor_state_machine.dart';
import 'package:hercycle/models/daily_log.dart';

class PredictionService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<Map<String, dynamic>> getPredictions(String userId) async {
    try {
      final userDoc =
          await _firestore.collection('users').doc(userId).get();
      final data = userDoc.data();

      DateTime? lastPeriodStartDate;
      DateTime? lastPeriodEndDate;
      int typicalCycleLength = 28;
      int typicalPeriodLength = 5;
      const int lutealPhaseLength = 14;

      if (data != null) {
        final rawStart = data['lastPeriodStartDate'];
        if (rawStart is Timestamp) {
          lastPeriodStartDate = rawStart.toDate();
        } else if (rawStart is String) {
          lastPeriodStartDate = DateTime.tryParse(rawStart);
        }
        final rawEnd = data['lastPeriodEndDate'];
        if (rawEnd is Timestamp) {
          lastPeriodEndDate = rawEnd.toDate();
        } else if (rawEnd is String) {
          lastPeriodEndDate = DateTime.tryParse(rawEnd);
        }
        final rawCycle = data['typicalCycleLength'];
        if (rawCycle is int) {
          typicalCycleLength = rawCycle.clamp(15, 60);
        } else if (rawCycle is num) {
          typicalCycleLength = rawCycle.toInt().clamp(15, 60);
        }
        final rawPeriod = data['typicalPeriodLength'];
        if (rawPeriod is int) {
          typicalPeriodLength = rawPeriod.clamp(1, 15);
        } else if (rawPeriod is num) {
          typicalPeriodLength = rawPeriod.toInt().clamp(1, 15);
        }
      }

      // Fetch daily logs for state-machine evaluation. A log read failure
      // must not crash the dashboard — fall back to profile-only calc.
      List<DailyLog> logs = [];
      try {
        final logsSnapshot = await _firestore
            .collection('users')
            .doc(userId)
            .collection('dailyLogs')
            .get();
        logs = logsSnapshot.docs
            .map((doc) {
              try {
                return DailyLog.fromFirestore(doc.data());
              } catch (_) {
                return null;
              }
            })
            .whereType<DailyLog>()
            .toList();
      } catch (_) {
        logs = [];
      }

      final result = CyclePredictorStateMachine.evaluate(
        lastPeriodStartDate: lastPeriodStartDate,
        lastPeriodEndDate: lastPeriodEndDate,
        typicalCycleLength: typicalCycleLength,
        typicalPeriodLength: typicalPeriodLength,
        cycleLogs: logs,
        lutealPhaseLength: lutealPhaseLength,
      );

      return {
        'currentDay': result.currentDay,
        'phaseName': result.phaseName,
        'nextPeriod': result.nextPeriodDate,
        'daysUntilNextPeriod': result.daysUntilNextPeriod,
        'ovulationDate': result.ovulationDate,
        'isOvulationLocked': result.isOvulationLocked,
        'alertMessage': result.alertMessage,
        'stateStatus': result.stateStatus,
        'message': result.alertMessage,
        'periodStart': lastPeriodStartDate,
        'periodEnd': lastPeriodEndDate,
        'observedBleedDays': result.observedBleedDays,
      };
    } catch (e) {
      // Never let prediction failures blank-crash the dashboard.
      final fallback = DateTime.now().add(const Duration(days: 28));
      return {
        'currentDay': 1,
        'phaseName': 'Follicular Phase',
        'nextPeriod': fallback,
        'daysUntilNextPeriod': 28,
        'ovulationDate': null,
        'isOvulationLocked': false,
        'alertMessage': null,
        'stateStatus': 'preOvulation',
        'message': 'Predictions unavailable offline. Showing estimates.',
      };
    }
  }
}
