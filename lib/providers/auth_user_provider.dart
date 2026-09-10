import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Single source of truth for the signed-in user. Data providers watch this
/// so switching accounts (or logging out) instantly drops the previous
/// user's cached data instead of showing a stale name/predictions.
final authUserProvider =
    StreamProvider<User?>((ref) => FirebaseAuth.instance.authStateChanges());
