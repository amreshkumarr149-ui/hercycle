import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Crash reporting + product analytics. Hard privacy rule enforced here:
/// event methods accept only pre-approved, non-health parameters — symptom
/// names, moods, notes, dates, pain scores and flow values must NEVER be
/// logged. Every method is best-effort and never throws.
class TelemetryService {
  TelemetryService._();

  static bool _ready = false;

  /// Call once after Firebase.initializeApp(). Installs global error
  /// handlers so uncaught framework and async errors reach Crashlytics.
  static Future<void> init() async {
    try {
      FlutterError.onError =
          FirebaseCrashlytics.instance.recordFlutterFatalError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };
      // Debug builds stay quiet; release builds report.
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(!kDebugMode);
      _ready = true;
    } catch (_) {
      // Telemetry must never break startup.
    }
  }

  static Future<void> setUserId(String? uid) async {
    try {
      if (!_ready) return;
      await FirebaseCrashlytics.instance.setUserIdentifier(uid ?? '');
      await FirebaseAnalytics.instance.setUserId(id: uid);
    } catch (_) {}
  }

  static Future<void> clearUser() async {
    try {
      if (!_ready) return;
      await FirebaseCrashlytics.instance.setUserIdentifier('');
      await FirebaseAnalytics.instance.setUserId(id: null);
    } catch (_) {}
  }

  static Future<void> logScreen(String screenName) async {
    try {
      if (!_ready) return;
      await FirebaseAnalytics.instance.logScreenView(screenName: screenName);
    } catch (_) {}
  }

  static Future<void> logEvent(String name) async {
    try {
      if (!_ready) return;
      await FirebaseAnalytics.instance.logEvent(name: name);
    } catch (_) {}
  }

  static Future<void> recordError(Object error, StackTrace stack,
      {String? reason}) async {
    try {
      if (!_ready) return;
      await FirebaseCrashlytics.instance.recordError(error, stack,
          reason: reason);
    } catch (_) {}
  }
}
