import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/core/database_repository.dart';
import 'package:hercycle/core/ttc_insights.dart';
import 'package:hercycle/core/week_planner.dart';
import 'package:hercycle/features/home/ttc_hero_card.dart';
import 'package:hercycle/features/home/week_planner_card.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/clinical_data_provider.dart';
import 'package:hercycle/providers/prediction_provider.dart';
import 'package:hercycle/providers/auth_user_provider.dart';
import 'package:hercycle/services/user_service.dart';
import 'package:hercycle/features/profile/complete_profile_screen.dart';
import 'package:hercycle/features/profile/profile_screen.dart';
import 'package:hercycle/features/logging/daily_logging_screen.dart';
import 'package:hercycle/features/home/article_detail_screen.dart';
import 'package:hercycle/features/home/cycle_odometer.dart';
import 'package:hercycle/features/sos/sos_screen.dart';
import 'package:hercycle/core/notification_service.dart';
import 'package:hercycle/core/sync_service.dart';
import 'package:hercycle/core/telemetry_service.dart';
import 'package:hercycle/core/widgets/animations.dart';
import 'package:intl/intl.dart';

/// Today's saved log, watched so the dashboard visibly reflects each save.
final todayLogProvider = FutureProvider<DailyLog?>((ref) async {
  final user =
      ref.watch(authUserProvider).value ?? safeCurrentUser();
  if (user == null) return null;
  final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
  try {
    return await DatabaseRepository().getLog(user.uid, todayStr);
  } catch (_) {
    return null;
  }
});

/// Profile envelope: {'data': Map?, 'fromCache': bool, 'error': String?}.
/// Server-first with local-cache fallback — a failed read surfaces as an
/// explicit error instead of silently rendering empty defaults.
final userProfileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  // Watch auth state (not a one-shot currentUser read) so logging out and
  // signing in as a different account refetches instead of showing the
  // previous account's name from the provider cache.
  final user = ref.watch(authUserProvider).value ?? safeCurrentUser();
  if (user == null) return null;
  return UserService().getUserDoc(user.uid);
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String _selectedMucus = '';

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _loadTodayMucus();
    _bootstrapSession();
    _restoreSync();
  }

  /// Restore the offline outbox and retry anything still queued — a restart
  /// with connectivity back heals itself without user action.
  Future<void> _restoreSync() async {
    final userId = safeCurrentUid();
    if (userId == null) return;
    await SyncService.restore(ref, userId);
    if (!mounted) return;
    final pending = ref.read(pendingSyncProvider);
    if (pending.isEmpty) return;
    final (ok, failed) = await SyncService.retryAll(ref, userId);
    if (!mounted) return;
    if (ok > 0) {
      ref.invalidate(predictionProvider);
      ref.invalidate(todayLogProvider);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(failed == 0
              ? 'Synced $ok waiting change${ok == 1 ? '' : 's'} ✓'
              : 'Synced $ok, $failed still waiting')));
    }
  }

  Future<void> _retrySync() async {
    if (_retrying) return;
    final userId = safeCurrentUid();
    if (userId == null) return;
    setState(() => _retrying = true);
    try {
      final (ok, failed) = await SyncService.retryAll(ref, userId);
      if (!mounted) return;
      if (ok > 0) {
        ref.invalidate(predictionProvider);
        ref.invalidate(todayLogProvider);
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok == 0 && failed == 0
              ? 'Nothing waiting to sync'
              : failed == 0
                  ? 'All caught up ✓'
                  : 'Synced $ok, $failed still waiting — still offline?')));
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  /// Enforces the one-time medical-consent gate, then re-arms the daily
  /// reminder (covers device reboots). Reminders are never scheduled before
  /// consent is on record, and the single profile read serves both purposes.
  /// Best-effort: never blocks the dashboard.
  Future<void> _bootstrapSession() async {
    final user = safeCurrentUser();
    if (user == null) return;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _consentThenReminders(user.uid));
  }

  Future<void> _consentThenReminders(String uid) async {
    if (!mounted) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (!mounted) return;
      if (doc.data()?['consentAcceptedAt'] == null) {
        final accepted = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Health Tracking Consent'),
            content: const Text(
              'I understand this app is for educational and tracking purposes only and is not a substitute for professional medical diagnosis or treatment.\n\nHerCycle never diagnoses conditions — patterns it notices are only ever suggestions to discuss with a healthcare professional.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Decline'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('I Understand & Accept'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (accepted == true) {
          try {
            await FirebaseFirestore.instance
                .collection('users')
                .doc(uid)
                .set(
                    {'consentAcceptedAt': Timestamp.fromDate(DateTime.now())},
                    SetOptions(merge: true));
          } catch (_) {
            // Offline: consent not recorded — gate re-checks next launch,
            // and reminders stay off until then.
            return;
          }
        } else {
          // Consent is mandatory: declining signs the user back out.
          await FirebaseAuth.instance.signOut();
          return;
        }
      }
      await NotificationService.ensureDailyReminder(uid);
    } catch (_) {
      // Offline: the gate re-checks on the next launch with connectivity.
    }
  }

  Future<void> _loadTodayMucus() async {
    final userId = safeCurrentUid();
    if (userId == null) return;
    try {
      final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final existing = await DatabaseRepository().getLog(userId, todayStr);
      if (!mounted || existing == null || existing.mucus.isEmpty) return;
      setState(() => _selectedMucus = existing.mucus);
    } catch (_) {
      // Offline: leave unselected rather than crashing.
    }
  }

  Future<void> _saveMucus(String mucus) async {
    setState(() => _selectedMucus = mucus);
    final userId = safeCurrentUid();
    if (userId != null) {
      final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      DailyLog? existing;
      try {
        existing = await DatabaseRepository().getLog(userId, todayStr);
      } catch (_) {
        // Offline read: proceed with defaults; the save below queues.
        existing = null;
      }
      final log = DailyLog(
        date: todayStr,
        period: existing?.period ?? false,
        symptoms: existing?.symptoms ?? [],
        mood: existing?.mood ?? '',
        mucus: mucus,
        lhTest: existing?.lhTest ?? '',
        flowIntensity: existing?.flowIntensity ?? 'None',
        painScore: existing?.painScore ?? 0,
        pelvicPressure: existing?.pelvicPressure ?? false,
        backBowelPain: existing?.backBowelPain ?? false,
        notes: existing?.notes ?? '',
      );
      final wasWet = existing != null &&
          NotificationService.isWetMucus(existing.mucus);
      try {
        await DatabaseRepository().saveLog(userId, log);
        await SyncService.markSynced(ref, userId, todayStr);
      } catch (e) {
        // Offline: queue for later instead of pretending it saved.
        await SyncService.enqueue(ref, userId, log);
        await TelemetryService.recordError(e, StackTrace.current,
            reason: 'mucus-save');
        if (!mounted) return;
        setState(() => _selectedMucus = existing?.mucus ?? '');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No connection — mucus will sync later')));
        return;
      }
      await TelemetryService.logEvent('mucus_logged');
      if (NotificationService.isWetMucus(mucus) && !wasWet) {
        NotificationService.notifyMucusShift();
      }
      // Mucus shifts drive state-machine alerts — refresh predictions and
      // the Today's Log strip now.
      ref.invalidate(predictionProvider);
      ref.invalidate(todayLogProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Mucus logged: $mucus')));
      }
    }
  }

  /// Warm one-liner matched to the current cycle phase. Static strings —
  /// encouragement only, never medical claims.
  String _positiveNote(String phaseName, int day, bool locked) {
    if (locked) {
      return 'Ovulation confirmed ✓ — your body did something amazing.';
    }
    final p = phaseName.toLowerCase();
    final variants = p.contains('menstrual')
        ? [
            'Rest is productive too — be gentle with yourself today. 🌸',
            'Warm drinks, slow mornings — you deserve soft days. 🌸',
          ]
        : p.contains('ovulation')
            ? [
                'You may feel extra social and energized — enjoy it! ✨',
                'Peak energy days — a great time for things you love. ✨',
              ]
            : p.contains('luteal')
                ? [
                    'Wind down kindly — cravings and feelings are valid. 🌙',
                    'Slow evenings and early nights — recharge mode on. 🌙',
                  ]
                : [
                    'Fresh-cycle energy is building — plant something new. 🌱',
                    'Your body is resetting — small goals, steady steps. 🌱',
                  ];
    return variants[day % variants.length];
  }

  void _showNotificationSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final pending = ref.watch(pendingSyncProvider);
          final pred = ref.watch(predictionProvider);
          final nextPeriod =
              pred.valueOrNull?['nextPeriod'] as DateTime?;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Notifications',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: context.her.ink)),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_repeat,
                        color: Color(0xFFC26D81)),
                    title: const Text('Period reminder'),
                    subtitle: Text(nextPeriod != null
                        ? 'Armed for ${DateFormat('MMM dd').format(nextPeriod)}'
                        : 'Will arm once your next period is predicted'),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.bedtime_outlined,
                        color: Color(0xFFC26D81)),
                    title: const Text('Daily logging reminder'),
                    subtitle:
                        const Text('Evening nudge — time managed in Profile'),
                    trailing: TextButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ProfileScreen()));
                      },
                      child: const Text('Manage'),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.opacity,
                        color: Color(0xFFC26D81)),
                    title: const Text('Mucus-shift alerts'),
                    subtitle: const Text(
                        'Automatic — a shift to wet mucus triggers an alert'),
                  ),
                  if (pending.isNotEmpty)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.cloud_upload_outlined,
                          color: Colors.orange),
                      title: Text(
                          '${pending.length} change${pending.length == 1 ? '' : 's'} waiting to sync'),
                      trailing: TextButton(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _retrySync();
                        },
                        child: const Text('Retry'),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showOvulationWindow(
      {required bool locked,
      DateTime? ovulationDate,
      DateTime? nextPeriod}) {
    final fmt = DateFormat('MMM dd');
    late final String title;
    late final String body;
    if (locked && ovulationDate != null) {
      final start = ovulationDate.subtract(const Duration(days: 1));
      final end = ovulationDate.add(const Duration(days: 1));
      title = 'Ovulation Confirmed ✓';
      body =
          'Confirmed for ${fmt.format(ovulationDate)} via positive LH test.\n\nPeak fertile days were around ${fmt.format(start)} – ${fmt.format(end)}.';
    } else if (ovulationDate != null) {
      final start = ovulationDate.subtract(const Duration(days: 5));
      final end = ovulationDate.add(const Duration(days: 1));
      title = 'Estimated Fertile Window';
      body =
          'Estimated ovulation: ${fmt.format(ovulationDate)}.\n\nFertile window: ${fmt.format(start)} – ${fmt.format(end)}.';
    } else if (nextPeriod != null) {
      final ovu = nextPeriod.subtract(const Duration(days: 14));
      final start = ovu.subtract(const Duration(days: 5));
      final end = ovu.add(const Duration(days: 1));
      title = 'Estimated Fertile Window';
      body =
          'Estimated ovulation: ${fmt.format(ovu)} (mid-cycle estimate).\n\nFertile window: ${fmt.format(start)} – ${fmt.format(end)}.';
    } else {
      title = 'Ovulation Window';
      body =
          'Not enough tracked data yet — log your periods (and LH tests if you use them) to unlock fertile-window estimates.';
    }
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body, style: const TextStyle(fontSize: 14, height: 1.5)),
            const SizedBox(height: 12),
            Text(
              'Estimates vary from cycle to cycle and are for awareness only — not contraception.',
              style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: dialogContext.her.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Curated cycle education. Static general-health content — no personal
  /// data, no diagnosis, no medical claims beyond everyday awareness.
  List<Article> get _learnArticles => const [
        Article(
          title: 'Your 4 Cycle Phases',
          description: 'Menstrual, follicular, ovulation, luteal — in a nutshell.',
          content:
              'Menstrual: bleeding days — rest and iron-rich foods help.\n\nFollicular: energy rebuilds as estrogen rises — good days to start things.\n\nOvulation: around mid-cycle, an egg is released; mucus often turns clear and slippery.\n\nLuteal: progesterone rises — you may feel calmer, then PMS-like symptoms before bleeding.',
          category: 'Basics',
        ),
        Article(
          title: 'Cervical Mucus, Decoded',
          description: 'What dry, sticky, creamy and eggwhite mean.',
          content:
              'Dry / nothing: common right after bleeding.\n\nSticky / tacky: early fertile transition.\n\nCreamy / lotion-like: fertility rising.\n\nEggwhite / slippery and stretchy: peak fertility signal around ovulation.\n\nTracking it daily is one of the simplest awareness tools you have.',
          category: 'Body signs',
        ),
        Article(
          title: 'PMS vs PMDD',
          description: 'When monthly symptoms deserve a doctor visit.',
          content:
              'PMS (cramps, mood swings, bloating) is common in the luteal phase and eases with bleeding.\n\nPMDD is rarer and much stronger — severe mood shifts, hopelessness or anger that disrupt daily life.\n\nIf symptoms regularly stop you from working, studying or sleeping, note the pattern in HerCycle and discuss it with a healthcare professional.',
          category: 'Wellness',
        ),
        Article(
          title: 'Spotting vs Period',
          description: 'How to tell them apart — and red flags.',
          content:
              'Spotting is light — a few drops, often pink or brown, no real flow.\n\nA period has steady flow and lasts days.\n\nOccasional mid-cycle spotting around ovulation can be normal.\n\nSee a doctor if bleeding is very heavy, lasts over 7 days, happens after menopause, or comes with severe pain.',
          category: 'Know more',
        ),
      ];

  static const _articleEmoji = ['🌸', '💧', '🌙', '🩸'];

  @override
  Widget build(BuildContext context) {
    // Keep the one-shot period alert + evening planner nudge in sync
    // whenever predictions refresh.
    ref.listen(predictionProvider, (prev, next) {
      final userId = safeCurrentUid();
      if (userId == null) return;
      next.whenData((data) {
        final np = data['nextPeriod'];
        NotificationService.syncPeriodReminder(
            userId, np is DateTime ? np : null);
        final clin = ref.read(clinicalDataProvider).valueOrNull;
        final prof = ref.read(userProfileProvider).valueOrNull?['data']
            as Map<String, dynamic>?;
        final logs = clin?['logs'];
        NotificationService.syncPlannerNudge(
          userId: userId,
          prediction: data,
          logs: logs is List<DailyLog> ? logs : null,
          profile: prof,
          fromCache: clin?['fromCache'] == true,
        );
        // Test-day pointer, only while TTC mode is on (needs only
        // prediction anchors). Turning the mode off cancels any alarm.
        try {
          if (prof?['ttcMode'] == true) {
            final ovu = data['ovulationDate'];
            final status = ttcStatus(
              today: DateTime.now(),
              ovulationDate: ovu is DateTime ? ovu : null,
              nextPeriod: np is DateTime ? np : null,
            );
            NotificationService.syncTestDayReminder(
                userId, status.testDay);
          } else {
            NotificationService.cancelTestDayReminder();
          }
        } catch (_) {}
      });
    });
    final predictionAsync = ref.watch(predictionProvider);
    final userProfileAsync = ref.watch(userProfileProvider);
    final todayLogAsync = ref.watch(todayLogProvider);
    final clinicalAsync = ref.watch(clinicalDataProvider);
    final pendingCount = ref.watch(pendingSyncProvider).length;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Top header: branding left, notifications right.
              FadeSlideIn(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.face_retouching_natural,
                            size: 34, color: Color(0xFFC26D81)),
                        SizedBox(width: 8),
                        Text('HerCycle',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFC26D81))),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () async {
                            final saved = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const SosScreen()),
                            );
                            if (saved == true) {
                              ref.invalidate(todayLogProvider);
                            }
                          },
                          icon: const Icon(Icons.sos_outlined,
                              size: 26, color: Color(0xFFE53935)),
                          tooltip: 'Cramp SOS',
                        ),
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            IconButton(
                              onPressed: _showNotificationSheet,
                              icon: Icon(Icons.notifications_outlined,
                                  size: 26, color: context.her.ink),
                              tooltip: 'Notifications',
                            ),
                        if (pendingCount > 0)
                          Positioned(
                            right: 8,
                            top: 8,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.orange,
                              ),
                            ),
                          ),
                        ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              FadeSlideIn(
                delay: const Duration(milliseconds: 80),
                child: userProfileAsync.when(
                  data: (envelope) {
                    final data =
                        envelope?['data'] as Map<String, dynamic>?;
                    final fromCache = envelope?['fromCache'] == true;
                    final error = envelope?['error'] as String?;
                    final name =
                        data?['name']?.toString().trim().isNotEmpty == true
                            ? data!['name'].toString()
                            : null;
                    if (data == null && error != null) {
                      // Loud read failure: show why + retry, never blank.
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFEBEE),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Column(
                          children: [
                            Text(error,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFFC62828))),
                            const SizedBox(height: 8),
                            ElevatedButton(
                              onPressed: () =>
                                  ref.invalidate(userProfileProvider),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 8),
                                minimumSize: Size.zero,
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('Retry',
                                  style: TextStyle(fontSize: 13)),
                            ),
                          ],
                        ),
                      );
                    }
                    if (data == null || name == null) {
                      // Legacy broken account (signed up before verified
                      // saves): repair path instead of the "Sarah" fallback.
                      return Column(
                        children: [
                          Text('Welcome! ❤️',
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: context.her.ink)),
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF3E0),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: Colors.orange.shade200),
                            ),
                            child: Column(
                              children: [
                                const Text(
                                    'Your profile is not set up yet — finish setup to unlock predictions.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 13)),
                                const SizedBox(height: 8),
                                ElevatedButton(
                                  onPressed: () async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              const CompleteProfileScreen()),
                                    );
                                    ref.invalidate(userProfileProvider);
                                    ref.invalidate(predictionProvider);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 20, vertical: 8),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Text('Complete your profile',
                                      style: TextStyle(fontSize: 13)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        Text('${_getGreeting()}, $name! ❤️',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: context.her.ink)),
                        if (fromCache)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('Offline mode — showing saved data',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: context.her.muted,
                                    fontStyle: FontStyle.italic)),
                          ),
                      ],
                    );
                  },
                  loading: () => Text('Hello! ❤️',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: context.her.ink)),
                  error: (e, st) => Text('Could not load profile: $e',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFFC62828))),
                ),
              ),
              const SizedBox(height: 12),
              Consumer(
                builder: (context, ref, _) {
                  final pending = ref.watch(pendingSyncProvider);
                  if (pending.isEmpty) {
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.cloud_done_outlined,
                            size: 14, color: Colors.green),
                        const SizedBox(width: 4),
                        Text('All synced',
                            style: TextStyle(
                                fontSize: 11, color: context.her.muted)),
                      ],
                    );
                  }
                  return GestureDetector(
                    onTap: _retrying ? null : _retrySync,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(20),
                        border:
                            Border.all(color: Colors.orange.shade200),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _retrying
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.cloud_upload_outlined,
                                  size: 14, color: Colors.orange),
                          const SizedBox(width: 4),
                          Text(
                              '${pending.length} change${pending.length == 1 ? '' : 's'} waiting to sync — tap to retry',
                              style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),

              // Dynamic Cycle Wheel & State Machine Predictions
              predictionAsync.when(
                data: (data) {
                  final currentDay = data['currentDay'] ?? 1;
                  final phaseName = data['phaseName'] ?? 'Follicular Phase';
                  final nextPeriod = data['nextPeriod'] as DateTime?;
                  final daysLeft = data['daysUntilNextPeriod'] ?? 28;
                  final alertMessage = data['alertMessage'] as String?;
                  final isOvulationLocked = data['isOvulationLocked'] as bool? ?? false;
                  final message = data['message'];
                  final periodStart = data['periodStart'] as DateTime?;
                  final periodEnd = data['periodEnd'] as DateTime?;
                  final observedBleedDays = data['observedBleedDays'] as int?;
                  String? lastPeriodLine;
                  if (periodStart != null && periodEnd != null && observedBleedDays != null) {
                    lastPeriodLine =
                        'Last period: ${DateFormat('MMM dd').format(periodStart)} – ${DateFormat('MMM dd').format(periodEnd)} ($observedBleedDays days)';
                  } else if (periodStart != null) {
                    lastPeriodLine =
                        'Last period started ${DateFormat('MMM dd').format(periodStart)}';
                  }
                  // Ovulation-window summary for the dedicated card.
                  final ovuDate = data['ovulationDate'] as DateTime?;
                  final fmtDay = DateFormat('MMM dd');
                  final ovuRef = ovuDate ??
                      nextPeriod?.subtract(const Duration(days: 14));
                  final String ovuSummary;
                  if (isOvulationLocked && ovuDate != null) {
                    ovuSummary = 'Confirmed ✓ ${fmtDay.format(ovuDate)}';
                  } else if (ovuRef != null) {
                    final s = ovuRef.subtract(const Duration(days: 5));
                    final e = ovuRef.add(const Duration(days: 1));
                    ovuSummary =
                        'Est. fertile ${fmtDay.format(s)} – ${fmtDay.format(e)}';
                  } else {
                    ovuSummary = 'Log periods to unlock estimates';
                  }
                  // Week-planner inputs: profile typicals + luteal signals
                  // from the user's own symptom history.
                  final profileData = userProfileAsync.valueOrNull?['data']
                      as Map<String, dynamic>?;
                  final typicalCycle =
                      (profileData?['typicalCycleLength'] as num?)
                              ?.toInt() ??
                          28;
                  final typicalPeriod =
                      (profileData?['typicalPeriodLength'] as num?)
                              ?.toInt() ??
                          5;
                  // Planner inputs are best-effort: any failure here must
                  // never take down the dashboard — fall back to calm days.
                  // Shared helper (also used by the nudge sync) so the
                  // card and the notification can never disagree.
                  final clinData = clinicalAsync.valueOrNull;
                  final clinLogs = clinData?['logs'];
                  final lutealSignals = lutealSignalsFrom(
                    logs: clinLogs is List<DailyLog> ? clinLogs : null,
                    profile:
                        clinData?['user'] as Map<String, dynamic>?,
                    fromCache: clinData?['fromCache'] == true,
                  );
                  List<PlannedDay> plannedDays;
                  bool plannedPersonal;
                  try {
                    final planned = planWeek(
                      today: DateTime.now(),
                      currentDay: currentDay is int
                          ? currentDay
                          : int.tryParse('$currentDay') ?? 1,
                      typicalCycleLength: typicalCycle,
                      typicalPeriodLength: typicalPeriod,
                      nextPeriod: nextPeriod,
                      ovulationDate: ovuDate,
                      ovulationLocked: isOvulationLocked,
                      lutealSignals: lutealSignals,
                    );
                    plannedDays = planned.days;
                    plannedPersonal = planned.personalized;
                  } catch (_) {
                    final base = DateTime.now();
                    plannedDays = List.generate(
                      7,
                      (i) => PlannedDay(
                        date: DateTime(base.year, base.month, base.day)
                            .add(Duration(days: i)),
                        cycleDay: 1 + i,
                        energy: DayEnergy.calm,
                        reasons: const ['Steady days'],
                      ),
                    );
                    plannedPersonal = false;
                  }

                  return Column(
                    children: [
                      // State Machine Alert Banner
                      if (alertMessage != null) ...[
                        FadeSlideIn(
                          delay: const Duration(milliseconds: 100),
                          child: Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 20),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isOvulationLocked ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: isOvulationLocked ? Colors.green.shade300 : Colors.orange.shade300),
                            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 5, offset: const Offset(0, 2))],
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isOvulationLocked ? Icons.check_circle_outline : Icons.notification_important_outlined,
                                color: isOvulationLocked ? Colors.green.shade700 : Colors.orange.shade800,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  alertMessage,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                    color: isOvulationLocked ? Colors.green.shade900 : Colors.orange.shade900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          ),
                        ),
                      ],

                      // Cycle odometer: per-day phase ring + needle on today.
                      // Ovulation anchor as a 1-based cycle day; the mapper
                      // degrades stale/out-of-range anchors to the estimate.
                      ScaleFadeIn(
                        delay: const Duration(milliseconds: 150),
                        child: Builder(
                          builder: (context) {
                            final now = DateTime.now();
                            final todayDay = DateTime(
                                now.year, now.month, now.day);
                            final dayNum = currentDay is int
                                ? currentDay
                                : int.tryParse('$currentDay') ?? 1;
                            final anchorOvu = ovuDate ?? ovuRef;
                            final ovuDayNum = anchorOvu == null
                                ? null
                                : dayNum +
                                    DateTime(
                                            anchorOvu.year,
                                            anchorOvu.month,
                                            anchorOvu.day)
                                        .difference(todayDay)
                                        .inDays;
                            return CycleOdometer(
                              cycleLen: typicalCycle,
                              periodLen: typicalPeriod,
                              ovulationDay: ovuDayNum,
                              ovulationLocked: isOvulationLocked,
                              currentDay: dayNum,
                              dayLabel: 'Today: Day $dayNum',
                              phaseLabel: phaseName,
                              statusLabel: isOvulationLocked
                                  ? 'Ovulation Locked ✓'
                                  : 'Prepare / Rest / Predict',
                              statusColor: isOvulationLocked
                                  ? (Colors.green[700] ?? Colors.green)
                                  : context.her.muted,
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      const FadeSlideIn(
                        delay: Duration(milliseconds: 180),
                        child: OdometerLegend(),
                      ),
                      const SizedBox(height: 16),

                      // Positive note for today.
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 200),
                        child: Text(
                          _positiveNote(
                              phaseName, currentDay, isOvulationLocked),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13,
                              fontStyle: FontStyle.italic,
                              height: 1.5,
                              color: context.her.muted),
                        ),
                      ),
                      const SizedBox(height: 28),

                      // Predictions Card
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 250),
                        child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: context.her.card,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFF9C8D2), width: 1.5),
                          boxShadow: [
                            BoxShadow(color: Colors.pink.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4)),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.calendar_month, color: Color(0xFFC26D81), size: 20),
                                const SizedBox(width: 8),
                                Text('Predictions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.her.ink)),
                              ],
                            ),
                            const SizedBox(height: 16),
                            if (message != null && alertMessage == null)
                              Text(message, style: TextStyle(color: context.her.muted))
                            else if (nextPeriod != null)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (lastPeriodLine != null) ...[
                                    Row(
                                      children: [
                                        const Text('🩸 ', style: TextStyle(fontSize: 16)),
                                        Expanded(
                                          child: Text(lastPeriodLine, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.her.ink)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  Row(
                                    children: [
                                      const Text('💧 ', style: TextStyle(fontSize: 16)),
                                      Expanded(
                                        child: Text('Next Period in $daysLeft days', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.her.ink)),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Padding(
                                    padding: const EdgeInsets.only(left: 24.0),
                                    child: Text('Predicted: ${DateFormat('MMM dd').format(nextPeriod)} - ${DateFormat('MMM dd').format(nextPeriod.add(const Duration(days: 4)))}', style: TextStyle(color: context.her.muted, fontSize: 13)),
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      const Text('✨ ', style: TextStyle(fontSize: 16)),
                                      Expanded(
                                        child: Text(isOvulationLocked ? 'Ovulation Confirmed & Locked' : 'Estimated Ovulation & Fertile Window', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: context.her.ink)),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Padding(
                                    padding: const EdgeInsets.only(left: 24.0),
                                    child: Text(isOvulationLocked ? 'Locked based on positive LH test' : 'Fertile window estimated around mid-cycle', style: TextStyle(color: context.her.muted, fontSize: 13)),
                                  ),
                                ],
                              ),
                          ],
                        ),
                        ),
                      ),
                      // Ovulation Window Card — tap for the fertile-window popup.
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 275),
                        child: InkWell(
                          onTap: () => _showOvulationWindow(
                            locked: isOvulationLocked,
                            ovulationDate: ovuDate,
                            nextPeriod: nextPeriod,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  const Color(0xFFC26D81),
                                  const Color(0xFFC26D81)
                                      .withValues(alpha: 0.75),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                    color: Colors.pink.withValues(alpha: 0.18),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4)),
                              ],
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.25),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                      isOvulationLocked
                                          ? Icons.lock
                                          : Icons.egg_outlined,
                                      color: Colors.white,
                                      size: 22),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('Ovulation Window',
                                          style: TextStyle(
                                              fontSize: 17,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white)),
                                      const SizedBox(height: 4),
                                      Text(ovuSummary,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              color: Colors.white)),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right,
                                    color: Colors.white70),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Plan With Your Cycle — 7-day outlook from tracked data.
                      FadeSlideIn(
                        delay: const Duration(milliseconds: 290),
                        child: WeekPlannerCard(
                          days: plannedDays,
                          personalized: plannedPersonal,
                        ),
                      ),
                      // TTC hero — only while trying-to-conceive mode is on.
                      if (profileData?['ttcMode'] == true)
                        FadeSlideIn(
                          delay: const Duration(milliseconds: 310),
                          child: Builder(
                            builder: (context) {
                              final intimacy = <String>{};
                              if (clinLogs is List<DailyLog>) {
                                for (final l in clinLogs) {
                                  if (l.intimacy) intimacy.add(l.date);
                                }
                              }
                              return TtcHeroCard(
                                status: ttcStatus(
                                  today: DateTime.now(),
                                  ovulationDate: ovuDate,
                                  nextPeriod: nextPeriod,
                                  intimacyDates: intimacy,
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('Error loading predictions: $e'),
              ),
              const SizedBox(height: 20),

              // Today's saved log — proves each save landed.
              FadeSlideIn(
                delay: const Duration(milliseconds: 300),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: context.her.card,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFF9C8D2), width: 1.5),
                    boxShadow: [
                      BoxShadow(color: Colors.pink.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: todayLogAsync.when(
                    data: (entry) {
                      final log = entry;
                      final todayStr = DateFormat('yyyy-MM-dd')
                          .format(DateTime.now());
                      final todayLabel =
                          DateFormat('EEE, MMM dd').format(DateTime.now());
                      final hasAnything = log != null &&
                          (log.period ||
                              log.mood.isNotEmpty ||
                              log.symptoms.isNotEmpty ||
                              log.mucus.isNotEmpty ||
                              log.lhTest.isNotEmpty ||
                              log.flowIntensity != 'None' ||
                              log.painScore > 0 ||
                              log.pelvicPressure ||
                              log.backBowelPain);
                      final header = Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  Color(0xFFC26D81),
                                  Color(0xFFE29578),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.edit_calendar_outlined,
                                color: Colors.white, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("Today's Log",
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                        color: context.her.ink)),
                                Text(todayLabel,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: context.her.muted)),
                              ],
                            ),
                          ),
                          InkWell(
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => DailyLoggingScreen(
                                        date: todayStr)),
                              );
                              ref.invalidate(todayLogProvider);
                              ref.invalidate(predictionProvider);
                            },
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFC26D81)
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                  hasAnything ? 'Edit' : 'Log now →',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFFC26D81))),
                            ),
                          ),
                        ],
                      );
                      if (!hasAnything) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            header,
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFC26D81)
                                    .withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                'Nothing logged for today yet — even a quick mood note makes your predictions smarter. 💗',
                                style: TextStyle(
                                    color: context.her.muted,
                                    fontSize: 13,
                                    height: 1.5),
                              ),
                            ),
                          ],
                        );
                      }
                      final rows = <String>[
                        if (log.period) '🩸 Period (flow: ${log.flowIntensity})',
                        if (log.mood.isNotEmpty) '😊 ${log.mood}',
                        if (log.symptoms.isNotEmpty)
                          '💧 ${log.symptoms.map((s) {
                            final sc = log.symptomIntensity[s];
                            return sc != null ? '$s $sc/10' : s;
                          }).join(', ')}',
                        if (log.mucus.isNotEmpty) '💧 Mucus: ${log.mucus.replaceAll('\n', ' ')}',
                        if (log.lhTest.isNotEmpty) '⚲ LH: ${log.lhTest}',
                        if (log.painScore > 0) '🤕 Pain ${log.painScore}/10',
                      ];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          header,
                          const SizedBox(height: 12),
                          ...rows.asMap().entries.map((e) => FadeSlideIn(
                                delay: Duration(
                                    milliseconds: 350 + e.key * 80),
                                child: Container(
                                  width: double.infinity,
                                  margin:
                                      const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFC26D81)
                                        .withValues(alpha: 0.07),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Text(e.value,
                                      style: TextStyle(
                                          fontSize: 13,
                                          height: 1.4,
                                          color: context.her.ink)),
                                ),
                              )),
                        ],
                      );
                    },
                    loading: () => Text("Today's Log…", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.her.ink)),
                    error: (e, st) => Text("Today's Log", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: context.her.ink)),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Mucus Log Card
              FadeSlideIn(
                delay: const Duration(milliseconds: 350),
                child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: context.her.card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFF9C8D2), width: 1.5),
                  boxShadow: [
                    BoxShadow(color: Colors.pink.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4)),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.opacity, color: Color(0xFFC26D81), size: 20),
                        const SizedBox(width: 8),
                        Text('Mucus Log', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.her.ink)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        _buildMucusOption('Dry /\nnothing'),
                        _buildMucusOption('Sticky /\ntacky'),
                        _buildMucusOption('Creamy /\nlotion'),
                        _buildMucusOption('Eggwhite /\nslippery'),
                      ],
                    ),
                  ],
                ),
                ),
              ),
              const SizedBox(height: 20),

              // Learn About Your Cycle — curated educational reads.
              FadeSlideIn(
                delay: const Duration(milliseconds: 400),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.menu_book_outlined,
                            color: Color(0xFFC26D81), size: 20),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text('Learn About Your Cycle',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: context.her.ink)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Builder(
                      builder: (context) {
                        // Cards grow with the system text scale so large
                        // accessibility sizes never clip content.
                        final s = MediaQuery.textScalerOf(context)
                            .scale(1.0)
                            .clamp(1.0, 2.0);
                        return SizedBox(
                          height: 172 * s,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _learnArticles.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
                            itemBuilder: (context, i) {
                              final article = _learnArticles[i];
                              return InkWell(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          ArticleDetailScreen(
                                              article: article)),
                                ),
                                borderRadius:
                                    BorderRadius.circular(18),
                              child: Container(
                                width: (210 * s).clamp(210.0, 340.0),
                                padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: context.her.card,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                    color: const Color(0xFFF9C8D2),
                                    width: 1.5),
                                boxShadow: [
                                  BoxShadow(
                                      color: Colors.pink
                                          .withValues(alpha: 0.06),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4)),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(_articleEmoji[i],
                                          style: const TextStyle(
                                              fontSize: 26)),
                                      const SizedBox(width: 8),
                                  Flexible(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFC26D81)
                                            .withValues(alpha: 0.12),
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      child: Text(article.category,
                                          maxLines: 1,
                                          overflow:
                                              TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight:
                                                  FontWeight.bold,
                                              color: Color(0xFFC26D81))),
                                    ),
                                  ),
                                ],
                              ),
                                  const SizedBox(height: 8),
                                  Text(article.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: context.her.ink)),
                                  const SizedBox(height: 4),
                                  Text(article.description,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: context.her.muted)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMucusOption(String label) {
    final isSelected = _selectedMucus == label;
    return Expanded(
      child: GestureDetector(
        onTap: () => _saveMucus(label),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFFFFD166)
                  : (Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF3A2A34)
                      : const Color(0xFFFFF0F2)),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isSelected ? const Color(0xFFC26D81) : Colors.transparent),
            boxShadow: isSelected
                ? [BoxShadow(color: const Color(0xFFFFD166).withValues(alpha: 0.5), blurRadius: 8, offset: const Offset(0, 2))]
                : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isSelected ? Colors.black : context.her.ink,
            ),
          ),
        ),
      ),
    );
  }
}
