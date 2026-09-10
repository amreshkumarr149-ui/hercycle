import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hercycle/core/database_repository.dart';
import 'package:hercycle/models/daily_log.dart';
import 'package:hercycle/providers/prediction_provider.dart';
import 'package:hercycle/providers/auth_user_provider.dart';
import 'package:hercycle/services/user_service.dart';
import 'package:hercycle/features/profile/complete_profile_screen.dart';
import 'package:hercycle/core/notification_service.dart';
import 'package:hercycle/core/sync_service.dart';
import 'package:hercycle/core/telemetry_service.dart';
import 'package:hercycle/core/widgets/animations.dart';
import 'package:intl/intl.dart';

/// Today's saved log, watched so the dashboard visibly reflects each save.
final todayLogProvider = FutureProvider<DailyLog?>((ref) async {
  final user =
      ref.watch(authUserProvider).value ?? FirebaseAuth.instance.currentUser;
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
  final user = ref.watch(authUserProvider).value ?? FirebaseAuth.instance.currentUser;
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
    final userId = FirebaseAuth.instance.currentUser?.uid;
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
    final userId = FirebaseAuth.instance.currentUser?.uid;
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
    final user = FirebaseAuth.instance.currentUser;
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
    final userId = FirebaseAuth.instance.currentUser?.uid;
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
    final userId = FirebaseAuth.instance.currentUser?.uid;
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

  @override
  Widget build(BuildContext context) {
    // Keep the one-shot period alert in sync whenever predictions refresh.
    ref.listen(predictionProvider, (prev, next) {
      final userId = FirebaseAuth.instance.currentUser?.uid;
      if (userId == null) return;
      next.whenData((data) {
        final np = data['nextPeriod'];
        NotificationService.syncPeriodReminder(
            userId, np is DateTime ? np : null);
      });
    });
    final predictionAsync = ref.watch(predictionProvider);
    final userProfileAsync = ref.watch(userProfileProvider);
    final todayLogAsync = ref.watch(todayLogProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFFFF9F9),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Top Logo & Branding
              const FadeSlideIn(
                child: Column(
                  children: [
                    Icon(Icons.face_retouching_natural, size: 50, color: Color(0xFFC26D81)),
                    Text('HerCycle', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFFC26D81))),
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
                          const Text('Welcome! ❤️',
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF4A4A4A))),
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
                            style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF4A4A4A))),
                        if (fromCache)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text('Offline mode — showing saved data',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                    fontStyle: FontStyle.italic)),
                          ),
                      ],
                    );
                  },
                  loading: () => const Text('Hello! ❤️',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF4A4A4A))),
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
                    return const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cloud_done_outlined,
                            size: 14, color: Colors.green),
                        SizedBox(width: 4),
                        Text('All synced',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey)),
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

                      // Circular Cycle Wheel
                      ScaleFadeIn(
                        delay: const Duration(milliseconds: 150),
                        child: Container(
                        width: 300,
                        height: 300,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const SweepGradient(
                            colors: [
                              Color(0xFFE53935), // Menses (Red)
                              Color(0xFFFB8C00), // Ovulation phase (Orange)
                              Color(0xFF00ACC1), // Luteal phase (Teal)
                              Color(0xFFE53935),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(color: Colors.pink.withValues(alpha: 0.15), blurRadius: 20, offset: const Offset(0, 8)),
                          ],
                        ),
                        child: Center(
                          child: Container(
                            width: 250,
                            height: 250,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                PulseGlow(
                                  duration: const Duration(milliseconds: 1600),
                                  child: Icon(isOvulationLocked ? Icons.lock : Icons.star, color: isOvulationLocked ? Colors.green : const Color(0xFFFFD166), size: 28),
                                ),
                                const SizedBox(height: 4),
                                Text('Today: Day $currentDay', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
                                const SizedBox(height: 4),
                                Text("You're in your\n$phaseName!", textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFC26D81))),
                                const SizedBox(height: 4),
                                Text(isOvulationLocked ? 'Ovulation Locked ✓' : 'Prepare / Rest / Predict', style: TextStyle(fontSize: 12, color: isOvulationLocked ? Colors.green[700] : Colors.grey[600], fontStyle: FontStyle.italic)),
                              ],
                            ),
                          ),
                        ),
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
                          color: Colors.white,
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
                              children: const [
                                Icon(Icons.calendar_month, color: Color(0xFFC26D81), size: 20),
                                SizedBox(width: 8),
                                Text('Predictions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
                              ],
                            ),
                            const SizedBox(height: 16),
                            if (message != null && alertMessage == null)
                              Text(message, style: TextStyle(color: Colors.grey[600]))
                            else if (nextPeriod != null)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (lastPeriodLine != null) ...[
                                    Row(
                                      children: [
                                        const Text('🩸 ', style: TextStyle(fontSize: 16)),
                                        Expanded(
                                          child: Text(lastPeriodLine, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF4A4A4A))),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  Row(
                                    children: [
                                      const Text('💧 ', style: TextStyle(fontSize: 16)),
                                      Text('Next Period in $daysLeft days', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF4A4A4A))),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Padding(
                                    padding: const EdgeInsets.only(left: 24.0),
                                    child: Text('Predicted: ${DateFormat('MMM dd').format(nextPeriod)} - ${DateFormat('MMM dd').format(nextPeriod.add(const Duration(days: 4)))}', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      const Text('✨ ', style: TextStyle(fontSize: 16)),
                                      Text(isOvulationLocked ? 'Ovulation Confirmed & Locked' : 'Estimated Ovulation & Fertile Window', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF4A4A4A))),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Padding(
                                    padding: const EdgeInsets.only(left: 24.0),
                                    child: Text(isOvulationLocked ? 'Locked based on positive LH test' : 'Fertile window estimated around mid-cycle', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                                  ),
                                ],
                              ),
                          ],
                        ),
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
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFF9C8D2), width: 1.5),
                    boxShadow: [
                      BoxShadow(color: Colors.pink.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: todayLogAsync.when(
                    data: (entry) {
                      final log = entry;
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
                      if (!hasAnything) {
                        return const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Today's Log", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
                            SizedBox(height: 6),
                            Text('Nothing logged for today yet.', style: TextStyle(color: Colors.grey, fontSize: 13)),
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
                          const Row(
                            children: [
                              Text("Today's Log ✓", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ...rows.map((r) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(r, style: const TextStyle(fontSize: 13, color: Color(0xFF4A4A4A))),
                              )),
                        ],
                      );
                    },
                    loading: () => const Text("Today's Log…", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
                    error: (e, st) => const Text("Today's Log", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
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
                  color: Colors.white,
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
                      children: const [
                        Icon(Icons.opacity, color: Color(0xFFC26D81), size: 20),
                        SizedBox(width: 8),
                        Text('Mucus Log', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
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
            color: isSelected ? const Color(0xFFFFD166) : const Color(0xFFFFF0F2),
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
              color: isSelected ? Colors.black : const Color(0xFF4A4A4A),
            ),
          ),
        ),
      ),
    );
  }
}
