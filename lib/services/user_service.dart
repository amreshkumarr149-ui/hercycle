import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hercycle/models/user_profile.dart';

class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> saveProfile(String userId, UserProfile profile) async {
    await _firestore.collection('users').doc(userId).set(profile.toFirestore(), SetOptions(merge: true));
  }

  /// Reads the user document, server-first with a local-cache fallback so
  /// offline users still see their data. Returns null only when the document
  /// is missing everywhere. Never throws — callers decide how to surface it.
  /// Result shape: {'data': Map?, 'fromCache': bool, 'error': String?}.
  Future<Map<String, dynamic>?> getUserDoc(String userId) async {
    try {
      final doc =
          await _firestore.collection('users').doc(userId).get().timeout(
                const Duration(seconds: 15),
              );
      if (doc.exists) {
        return {
          'data': doc.data(),
          'fromCache': doc.metadata.isFromCache,
        };
      }
    } catch (e) {
      // Fall through to cache.
      final cached = await _readCached(userId);
      if (cached != null) return cached;
      return {'data': null, 'fromCache': false, 'error': friendlyError(e)};
    }
    try {
      return await _readCached(userId);
    } catch (_) {
      return {'data': null, 'fromCache': false};
    }
  }

  Future<Map<String, dynamic>?> _readCached(String userId) async {
    try {
      final cached = await _firestore
          .collection('users')
          .doc(userId)
          .get(const GetOptions(source: Source.cache));
      if (cached.exists) {
        return {'data': cached.data(), 'fromCache': true};
      }
    } catch (_) {}
    return null;
  }

  /// Confirms a profile write actually landed (server or local cache) by
  /// reading the document back and checking name + email are present.
  Future<bool> verifyProfile(String userId) async {
    final got = await getUserDoc(userId);
    final data = got?['data'] as Map<String, dynamic>?;
    final name = data?['name']?.toString() ?? '';
    final email = data?['email']?.toString() ?? '';
    return name.isNotEmpty && email.isNotEmpty;
  }

  /// Maps Firestore failures to actionable user-facing messages.
  static String friendlyError(Object e) {
    if (e is FirebaseException) {
      switch (e.code) {
        case 'permission-denied':
          return 'Database access blocked (permission-denied). Publish firestore.rules to your Firebase project, then retry.';
        case 'unavailable':
          return 'No connection to the database. Check your internet connection, then retry.';
        case 'deadline-exceeded':
          return 'Database request timed out. Check your connection, then retry.';
      }
      return 'Database error (${e.code}): ${e.message ?? 'unknown error'}';
    }
    return 'An error occurred: $e';
  }

  /// Permanently deletes every Firestore document owned by [userId]:
  /// daily logs, cycle records, then the profile itself. Batched in chunks
  /// of 400 (Firestore batch limit). Throws on failure so callers can react.
  Future<void> deleteAllUserData(String userId) async {
    for (final sub in ['dailyLogs', 'cycles']) {
      while (true) {
        final snap = await _firestore
            .collection('users')
            .doc(userId)
            .collection(sub)
            .limit(400)
            .get();
        if (snap.docs.isEmpty) break;
        final batch = _firestore.batch();
        for (final d in snap.docs) {
          batch.delete(d.reference);
        }
        await batch.commit();
        if (snap.docs.length < 400) break;
      }
    }
    await _firestore.collection('users').doc(userId).delete();
  }
}
