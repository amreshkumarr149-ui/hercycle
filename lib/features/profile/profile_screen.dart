import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:hercycle/features/auth/login_screen.dart';
import 'package:hercycle/services/user_service.dart';
import 'package:hercycle/core/notification_service.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Map<String, dynamic>? _userData;
  bool _isLoading = true;
  bool _isDeleting = false;
  String? _loadError;
  bool _fromCache = false;
  bool _notifEnabled = false;
  int _notifHour = 21;
  int _notifMinute = 0;
  bool _notifSaving = false;

  String get _notifTimeLabel {
    final t = TimeOfDay(hour: _notifHour, minute: _notifMinute);
    return t.format(context);
  }

  Future<void> _setNotifEnabled(bool value) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (value) {
      final granted = await NotificationService.requestPermission();
      if (!mounted) return;
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Notifications are blocked — allow them in system settings to use reminders.')),
        );
        return;
      }
    }
    final previous = _notifEnabled;
    setState(() {
      _notifEnabled = value;
      _notifSaving = true;
    });
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'notificationEnabled': value}, SetOptions(merge: true));
      if (value) {
        await NotificationService.scheduleDailyReminder(
            hour: _notifHour, minute: _notifMinute);
      } else {
        await NotificationService.cancelDailyReminder();
      }
    } catch (e) {
      // Roll the switch back: the setting was NOT saved or scheduled.
      if (!mounted) return;
      setState(() => _notifEnabled = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save reminder setting: $e')),
      );
    } finally {
      if (mounted) setState(() => _notifSaving = false);
    }
  }

  Future<void> _pickNotifTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _notifHour, minute: _notifMinute),
    );
    if (picked == null || !mounted) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final prevHour = _notifHour;
    final prevMinute = _notifMinute;
    setState(() {
      _notifHour = picked.hour;
      _notifMinute = picked.minute;
      _notifSaving = true;
    });
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(
              {'notificationHour': picked.hour, 'notificationMinute': picked.minute},
              SetOptions(merge: true));
      if (_notifEnabled) {
        await NotificationService.scheduleDailyReminder(
            hour: picked.hour, minute: picked.minute);
      }
    } catch (e) {
      // Roll the time back: the new time was NOT saved or scheduled.
      if (!mounted) return;
      setState(() {
        _notifHour = prevHour;
        _notifMinute = prevMinute;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save reminder time: $e')),
      );
    } finally {
      if (mounted) setState(() => _notifSaving = false);
    }
  }

  Future<void> _goToLogin() async {
    if (!mounted) return;
    final ctx = context;
    // ignore: use_build_context_synchronously
    Navigator.of(ctx).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  /// Double-confirmed permanent deletion of all Firestore data + the auth
  /// account itself. Data deletion always runs first so tracked records are
  /// gone even if the auth deletion needs a fresh login.
  Future<void> _deleteEverything() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final step1 = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete all my data?'),
        content: const Text(
          'This permanently deletes your profile, every daily log, cycle record and health report data. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Keep my data'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(d, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (step1 != true || !mounted) return;
    final step2 = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Final confirmation'),
        content: const Text(
          'Really erase everything and delete this account?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(d, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Yes, delete everything'),
          ),
        ],
      ),
    );
    if (step2 != true || !mounted) return;
    setState(() => _isDeleting = true);
    try {
      await UserService().deleteAllUserData(user.uid);
      try {
        await user.delete();
      } on FirebaseAuthException catch (e) {
        if (e.code == 'requires-recent-login') {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Your tracked data was deleted. For safety, log out and log back in, then retry to remove the account itself.')),
          );
          await FirebaseAuth.instance.signOut();
          try {
            await GoogleSignIn().signOut();
          } catch (_) {}
          await _goToLogin();
          return;
        }
        rethrow;
      }
      await FirebaseAuth.instance.signOut();
      try {
        await GoogleSignIn().signOut();
      } catch (_) {}
      await _goToLogin();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All your data was permanently deleted.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  DateTime? _parseDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  String _fmtDay(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// "2026-08-04 → 2026-08-08 (5 days)" from the tracked start/end dates.
  String _lastPeriodLabel() {
    final start = _parseDate(_userData?['lastPeriodStartDate']);
    if (start == null) return 'Not specified';
    final end = _parseDate(_userData?['lastPeriodEndDate']);
    if (end == null || end.isBefore(DateTime(start.year, start.month, start.day))) {
      return 'Started ${_fmtDay(start)}';
    }
    final days = end.difference(DateTime(start.year, start.month, start.day)).inDays + 1;
    return '${_fmtDay(start)} → ${_fmtDay(end)} ($days days)';
  }

  Future<void> _loadUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }
    // Server-first with local-cache fallback; failures surface loudly.
    final got = await UserService().getUserDoc(user.uid);
    if (!mounted) return;
    final data = got?['data'] as Map<String, dynamic>?;
    setState(() {
      _userData = data;
      _isLoading = false;
      _fromCache = got?['fromCache'] == true;
      _loadError = data == null
          ? (got?['error'] as String? ?? 'Profile not found.')
          : null;
      _notifEnabled = data?['notificationEnabled'] == true;
      final h = data?['notificationHour'];
      final m = data?['notificationMinute'];
      if (h is num) _notifHour = h.toInt().clamp(0, 23);
      if (m is num) _notifMinute = m.toInt().clamp(0, 59);
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile & Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : (_loadError != null && _userData == null)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.cloud_off_outlined,
                            size: 48, color: Colors.grey),
                        const SizedBox(height: 16),
                        Text(_loadError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 14, height: 1.5)),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _loadUserData,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: CircleAvatar(
                    radius: 50,
                    backgroundColor: const Color(0xFFF9C8D2),
                    child: Text(
                      (_userData?['name'] != null && _userData!['name'].isNotEmpty)
                          ? _userData!['name'][0].toUpperCase()
                          : 'U',
                      style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Color(0xFFC26D81)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    _userData?['name'] ?? 'User',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A)),
                  ),
                ),
                Center(
                  child: Text(
                    _userData?['email'] ?? user?.email ?? '',
                    style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  ),
                ),
                if (_fromCache)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('Offline mode — showing saved data',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                              fontStyle: FontStyle.italic)),
                    ),
                  ),
                const SizedBox(height: 32),
                const Text('Cycle & Health Info', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.pink.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    child: Column(
                      children: [
                      ListTile(
                        leading: const Icon(Icons.calendar_month, color: Color(0xFFC26D81)),
                        title: const Text('Typical Cycle Length'),
                        trailing: Text('${_userData?['typicalCycleLength'] ?? 28} days', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.water_drop, color: Color(0xFFC26D81)),
                        title: const Text('Typical Period Length'),
                        trailing: Text('${_userData?['typicalPeriodLength'] ?? 5} days', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.bloodtype, color: Color(0xFFC26D81)),
                        title: const Text('Blood Group'),
                        trailing: Text(_userData?['bloodGroup'] ?? 'Not specified', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.date_range, color: Color(0xFFC26D81)),
                        title: const Text('Last Period'),
                        trailing: Text(_lastPeriodLabel(), style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.favorite_border, color: Color(0xFFC26D81)),
                        title: const Text('Had sex recently'),
                        trailing: Text(_userData?['hadSexRecently'] ?? 'Not specified', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('Reminders', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF4A4A4A))),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.pink.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    child: Column(
                      children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.notifications_outlined, color: Color(0xFFC26D81)),
                        title: const Text('Daily logging reminder'),
                        subtitle: Text(_notifEnabled
                            ? 'Every day at $_notifTimeLabel'
                            : 'Off'),
                        value: _notifEnabled,
                        onChanged: _notifSaving ? null : _setNotifEnabled,
                      ),
                      if (_notifEnabled)
                        ListTile(
                          leading: const Icon(Icons.schedule, color: Color(0xFFC26D81)),
                          title: const Text('Reminder time'),
                          trailing: Text(_notifTimeLabel,
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          onTap: _notifSaving ? null : _pickNotifTime,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      await FirebaseAuth.instance.signOut();
                    } catch (_) {
                      // Sign-out is local; continue to login regardless.
                    }
                    try {
                      await GoogleSignIn().signOut();
                    } catch (_) {
                      // No active Google session; safe to ignore.
                    }
                    if (!mounted) return;
                    final ctx = context;
                    // ignore: use_build_context_synchronously
                    Navigator.of(ctx).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                      (route) => false,
                    );
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Log Out'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: (_isLoading || _isDeleting) ? null : _deleteEverything,
                  icon: _isDeleting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.delete_forever_outlined),
                  label: Text(_isDeleting
                      ? 'Deleting…'
                      : 'Delete account & all my data'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade700,
                    side: BorderSide(color: Colors.red.shade300),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ],
            ),
    );
  }
}
