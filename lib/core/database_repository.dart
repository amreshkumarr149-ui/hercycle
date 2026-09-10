import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hercycle/models/daily_log.dart';

class DatabaseRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> saveLog(String userId, DailyLog log) async {
    final docRef = _firestore
        .collection('users')
        .doc(userId)
        .collection('dailyLogs')
        .doc(log.date);

    await docRef.set(log.toFirestore());

    // Keep lastPeriodStartDate in sync with period logs (both directions).
    // - period=true on a date >= stored start  -> advance the start.
    // - period=false on the stored start date  -> recompute latest start
    //   from remaining logs so predictions don't go stale.
    try {
      final userDocRef = _firestore.collection('users').doc(userId);
      final userDoc = await userDocRef.get();
      final data = userDoc.data();
      if (data == null) return;
      final parsedDate = DateTime.tryParse(log.date);
      if (parsedDate == null) return;
      final rawExisting = data['lastPeriodStartDate'];
      final DateTime? existing =
          rawExisting is Timestamp ? rawExisting.toDate() : null;
      final sameDay = existing != null &&
          parsedDate.year == existing.year &&
          parsedDate.month == existing.month &&
          parsedDate.day == existing.day;

      if (log.period) {
        if (existing == null ||
            parsedDate.isAfter(existing) ||
            sameDay) {
          await userDocRef.update({
            'lastPeriodStartDate': Timestamp.fromDate(parsedDate),
          });
        }
      } else if (sameDay) {
        // Period unchecked on the recorded start date: find the newest
        // remaining period=true log and roll the start back to it.
        final recent = await _firestore
            .collection('users')
            .doc(userId)
            .collection('dailyLogs')
            .orderBy('date', descending: true)
            .limit(90)
            .get();
        DateTime? newest;
        for (final doc in recent.docs) {
          final d = doc.data();
          if (d['period'] == true) {
            final pd = DateTime.tryParse(d['date']?.toString() ?? '');
            if (pd != null) {
              newest = pd;
              break;
            }
          }
        }
        if (newest != null) {
          await userDocRef.update({
            'lastPeriodStartDate': Timestamp.fromDate(newest),
          });
        }
      }
    } catch (e) {
      // Non-blocking catch for profile sync
    }
  }

  Future<List<DailyLog>> getAllLogs(String userId, {int limit = 1000}) async {
    final snapshot = await _firestore
        .collection('users')
        .doc(userId)
        .collection('dailyLogs')
        .orderBy('date')
        .limit(limit)
        .get();
    return snapshot.docs
        .map((doc) {
          try {
            return DailyLog.fromFirestore(doc.data());
          } catch (_) {
            return null;
          }
        })
        .whereType<DailyLog>()
        .toList();
  }

  Future<DailyLog?> getLog(String userId, String date) async {
    final doc = await _firestore
        .collection('users')
        .doc(userId)
        .collection('dailyLogs')
        .doc(date)
        .get();
    if (doc.exists) {
      return DailyLog.fromFirestore(doc.data()!);
    }
    return null;
  }
}
