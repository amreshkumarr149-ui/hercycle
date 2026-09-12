import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hercycle/core/week_planner.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Local notifications for HerCycle. All calls are safe to fire-and-forget:
/// failures (denied permission, unsupported platform) are swallowed so they
/// can never crash logging or startup flows.
class NotificationService {
  NotificationService._();
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const int dailyId = 1001;
  static const int mucusTriggerId = 2001;
  static const int lhTriggerId = 2002;
  static const int periodId = 3001;
  static const int plannerId = 4001;

  static const AndroidNotificationDetails _dailyAndroid =
      AndroidNotificationDetails(
    'hercycle_daily',
    'Daily reminders',
    channelDescription: 'Gentle reminders to log how you are feeling.',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
  );

  static const AndroidNotificationDetails _triggerAndroid =
      AndroidNotificationDetails(
    'hercycle_triggers',
    'Cycle alerts',
    channelDescription:
        'Fertile-window and ovulation alerts from your tracked data.',
    importance: Importance.high,
    priority: Priority.high,
  );

  static const DarwinNotificationDetails _darwin =
      DarwinNotificationDetails();

  /// Must be called once at startup (after Firebase init). Never throws.
  static Future<void> init() async {
    if (_initialized) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/launcher_icon'),
        iOS: DarwinInitializationSettings(),
      );
      await _plugin.initialize(settings: settings);
      try {
        tzdata.initializeTimeZones();
        final info = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(info.identifier));
      } catch (_) {
        // Timezone DB unavailable: scheduled reminders fall back to UTC-based
        // offsets; instant trigger notifications still work.
      }
      _initialized = true;
    } catch (_) {
      // Notifications unavailable on this device — app works without them.
    }
  }

  static Future<bool> requestPermission() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      var granted = true;
      if (android != null) {
        granted = (await android.requestNotificationsPermission()) ?? false;
      }
      if (ios != null) {
        granted = (await ios.requestPermissions(
                alert: true, badge: true, sound: true)) ??
            false;
      }
      return granted;
    } catch (_) {
      return false;
    }
  }

  static tz.TZDateTime _nextDaily(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  /// (Re)schedules the daily logging reminder. Inexact mode avoids the
  /// exact-alarm permission on Android.
  static Future<void> scheduleDailyReminder(
      {required int hour, required int minute}) async {
    try {
      await _plugin.zonedSchedule(
        id: dailyId,
        title: "Don't forget to log today ❤️",
        body:
            'How are you feeling? A quick check-in keeps your predictions accurate.',
        scheduledDate: _nextDaily(hour, minute),
        notificationDetails: const NotificationDetails(
            android: _dailyAndroid, iOS: _darwin),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {}
  }

  static Future<void> cancelDailyReminder() async {
    try {
      await _plugin.cancel(id: dailyId);
    } catch (_) {}
  }

  /// Fires when a mucus shift into the fertile pattern is saved.
  static Future<void> notifyMucusShift() async {
    try {
      await _plugin.show(
        id: mucusTriggerId,
        title: 'Fertile window opening',
        body: 'Mucus shift detected: start LH testing tomorrow.',
        notificationDetails: const NotificationDetails(
            android: _triggerAndroid, iOS: _darwin),
      );
    } catch (_) {}
  }

  /// Fires when the first positive LH test of the cycle is saved.
  static Future<void> notifyLhPeak() async {
    try {
      await _plugin.show(
        id: lhTriggerId,
        title: 'LH Peak detected!',
        body:
            'Ovulation and next period dates locked. You can stop testing for this cycle.',
        notificationDetails: const NotificationDetails(
            android: _triggerAndroid, iOS: _darwin),
      );
    } catch (_) {}
  }

  /// Reads the user's stored reminder prefs and applies them. Called on app
  /// start (also re-arms the alarm after a device reboot) and after the
  /// Profile settings change. Never throws.
  static Future<void> ensureDailyReminder(String userId) async {
    try {
      final prefs = await _reminderPrefs(userId);
      if (!prefs.enabled) {
        await cancelDailyReminder();
        return;
      }
      await scheduleDailyReminder(hour: prefs.hour, minute: prefs.minute);
    } catch (_) {}
  }

  static Future<({bool enabled, int hour, int minute})> _reminderPrefs(
      String userId) async {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .get();
    final data = doc.data();
    final hour = (data?['notificationHour'] is num)
        ? (data!['notificationHour'] as num).toInt().clamp(0, 23)
        : 21;
    final minute = (data?['notificationMinute'] is num)
        ? (data!['notificationMinute'] as num).toInt().clamp(0, 59)
        : 0;
    return (
      enabled: data?['notificationEnabled'] == true,
      hour: hour,
      minute: minute
    );
  }

  /// Schedules a one-shot "period expected in 2 days" alert from the
  /// predicted next-period date. Same notification ID every time, so a
  /// shifted prediction transparently replaces the old alarm. Skips (and
  /// cancels any stale alarm) when reminders are off, the date is missing,
  /// or the 2-day window already passed — no spam, ever. Never throws.
  static Future<void> syncPeriodReminder(
      String userId, DateTime? nextPeriod) async {
    try {
      final prefs = await _reminderPrefs(userId);
      if (!prefs.enabled || nextPeriod == null) {
        await cancelPeriodReminder();
        return;
      }
      final at = DateTime(nextPeriod.year, nextPeriod.month, nextPeriod.day,
              prefs.hour, prefs.minute)
          .subtract(const Duration(days: 2));
      if (!at.isAfter(DateTime.now())) {
        await cancelPeriodReminder();
        return;
      }
      await _plugin.zonedSchedule(
        id: periodId,
        title: 'Period expected soon 🌸',
        body:
            'Your period is expected in 2 days. Log symptoms to keep predictions accurate.',
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        notificationDetails: const NotificationDetails(
            android: _triggerAndroid, iOS: _darwin),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (_) {}
  }

  static Future<void> cancelPeriodReminder() async {
    try {
      await _plugin.cancel(id: periodId);
    } catch (_) {}
  }

  /// Evening lookahead for the Week Planner: one gentle nudge at 20:00
  /// when tomorrow is tagged rest / PMS-likely / period. High and calm
  /// tomorrows never ping. Same ID every time, so refreshed predictions
  /// replace the alarm and dull tomorrows cancel it — no spam, ever.
  /// Follows the master reminder switch (no separate toggle). Never throws.
  static Future<void> syncPlannerNudge({
    required String userId,
    required Map<String, dynamic>? prediction,
    required List<DailyLog>? logs,
    required Map<String, dynamic>? profile,
    required bool fromCache,
  }) async {
    try {
      final prefs = await _reminderPrefs(userId);
      if (!prefs.enabled || prediction == null) {
        await cancelPlannerNudge();
        return;
      }
      final rawDay = prediction['currentDay'];
      final currentDay =
          rawDay is int ? rawDay : int.tryParse('$rawDay') ?? 1;
      final typicalCycle =
          (profile?['typicalCycleLength'] as num?)?.toInt() ?? 28;
      final typicalPeriod =
          (profile?['typicalPeriodLength'] as num?)?.toInt() ?? 5;
      final nextPeriod = prediction['nextPeriod'];
      final ovulationDate = prediction['ovulationDate'];
      final planned = planWeek(
        today: DateTime.now(),
        currentDay: currentDay,
        typicalCycleLength: typicalCycle,
        typicalPeriodLength: typicalPeriod,
        nextPeriod: nextPeriod is DateTime ? nextPeriod : null,
        ovulationDate: ovulationDate is DateTime ? ovulationDate : null,
        ovulationLocked: prediction['isOvulationLocked'] == true,
        lutealSignals:
            lutealSignalsFrom(logs: logs, profile: profile, fromCache: fromCache),
      );
      if (planned.days.length < 2) {
        await cancelPlannerNudge();
        return;
      }
      final tomorrow = planned.days[1];
      final nudge = plannerNudgeFor(tomorrow,
          personalized: planned.personalized);
      if (nudge == null) {
        await cancelPlannerNudge();
        return;
      }
      final at = DateTime(tomorrow.date.year, tomorrow.date.month,
          tomorrow.date.day, 20, 0);
      if (!at.isAfter(DateTime.now())) {
        await cancelPlannerNudge();
        return;
      }
      await _plugin.zonedSchedule(
        id: plannerId,
        title: nudge.title,
        body: nudge.body,
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        notificationDetails: const NotificationDetails(
            android: _triggerAndroid, iOS: _darwin),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (_) {}
  }

  static Future<void> cancelPlannerNudge() async {
    try {
      await _plugin.cancel(id: plannerId);
    } catch (_) {}
  }

  static const int testDayId = 5001;

  /// One-shot pregnancy-test-day reminder for TTC mode. Scheduled at the
  /// user's reminder hour on the suggested test day; refreshed/cancelled
  /// alongside predictions. Copy never claims conception — testing does.
  /// Never throws.
  static Future<void> syncTestDayReminder(
      String userId, DateTime? testDay) async {
    try {
      final prefs = await _reminderPrefs(userId);
      if (!prefs.enabled || testDay == null) {
        await cancelTestDayReminder();
        return;
      }
      final at = DateTime(testDay.year, testDay.month, testDay.day,
          prefs.hour, prefs.minute);
      if (!at.isAfter(DateTime.now())) {
        await cancelTestDayReminder();
        return;
      }
      await _plugin.zonedSchedule(
        id: testDayId,
        title: 'Pregnancy test day 💗',
        body:
            'If you are trying, today is a good day to test — good luck, whatever the result.',
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        notificationDetails: const NotificationDetails(
            android: _triggerAndroid, iOS: _darwin),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } catch (_) {}
  }

  static Future<void> cancelTestDayReminder() async {
    try {
      await _plugin.cancel(id: testDayId);
    } catch (_) {}
  }

  static bool isWetMucus(String mucus) {
    final m = mucus.toLowerCase();
    return m.contains('creamy') ||
        m.contains('watery') ||
        m.contains('eggwhite') ||
        m.contains('slippery');
  }
}
