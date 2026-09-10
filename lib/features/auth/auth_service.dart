import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:hercycle/models/user_profile.dart';
import 'package:hercycle/services/user_service.dart';
import 'package:hercycle/core/telemetry_service.dart';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Lazily created on first mobile use only. Constructing GoogleSignIn on
  /// web without a client ID throws an async assertion (google_sign_in_web),
  /// so it must never be instantiated on web at all.
  GoogleSignIn? _googleSignIn;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<User?> signUp(String email, String password) async {
    try {
      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = userCredential.user;
      if (user != null) {
        await TelemetryService.setUserId(user.uid);
        await TelemetryService.logEvent('sign_up');
      }
      return user;
    } on FirebaseAuthException {
      rethrow;
    } catch (e) {
      rethrow;
    }
  }

  Future<User?> signIn(String email, String password) async {
    try {
      final userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = userCredential.user;
      if (user != null) {
        await TelemetryService.setUserId(user.uid);
        await TelemetryService.logEvent('login');
      }
      return user;
    } on FirebaseAuthException {
      rethrow;
    } catch (e) {
      rethrow;
    }
  }

  Future<User?> signInWithGoogle() async {
    try {
      final UserCredential userCredential;
      if (kIsWeb) {
        // Web goes through Firebase's OAuth popup directly: no
        // google-signin-client_id meta tag or native client needed.
        userCredential = await _auth.signInWithPopup(GoogleAuthProvider());
      } else {
        _googleSignIn ??= GoogleSignIn();
        final GoogleSignInAccount? googleUser =
            await _googleSignIn!.signIn();
        if (googleUser == null) return null; // User cancelled
        final GoogleSignInAuthentication googleAuth =
            await googleUser.authentication;
        final AuthCredential credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );
        userCredential =
            await _auth.signInWithCredential(credential);
      }
      final user = userCredential.user;
      if (user != null) {
        await _ensureProfileDocument(user);
        await TelemetryService.setUserId(user.uid);
        await TelemetryService.logEvent('login_google');
      }
      return user;
    } catch (e) {
      rethrow;
    }
  }

  /// Creates the Firestore user profile on first sign-in (any method) so
  /// name/email are always present. Never throws: a profile-write failure
  /// must not fail authentication itself.
  Future<void> _ensureProfileDocument(User user) async {
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      if (!userDoc.exists) {
        final profile = UserProfile(
          name: user.displayName ?? user.email?.split('@')[0] ?? 'User',
          email: user.email ?? '',
        );
        await UserService().saveProfile(user.uid, profile);
      }
    } catch (_) {}
  }

  Future<void> signOut() async {
    await TelemetryService.clearUser();
    await TelemetryService.logEvent('logout');
    await _auth.signOut();
    try {
      await _googleSignIn?.signOut();
    } catch (_) {}
  }
}
