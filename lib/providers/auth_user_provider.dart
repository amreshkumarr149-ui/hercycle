import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Single source of truth for the signed-in user. Data providers watch this
/// so switching accounts (or logging out) instantly drops the previous
/// user's cached data instead of showing a stale name/predictions.
final authUserProvider =
    StreamProvider<User?>((ref) => FirebaseAuth.instance.authStateChanges());

/// Null-safe current-user read for initState/save paths.
/// `FirebaseAuth.instance` throws when no default app exists (backend never
/// initialized, e.g. offline first launch) — this degrades to "logged out"
/// instead of crashing. Never throws.
User? safeCurrentUser() {
  try {
    return FirebaseAuth.instance.currentUser;
  } catch (_) {
    return null;
  }
}

/// Null-safe uid shorthand. Never throws.
String? safeCurrentUid() => safeCurrentUser()?.uid;
