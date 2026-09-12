import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:hercycle/features/auth/login_screen.dart';
import 'package:hercycle/services/user_service.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/core/notification_service.dart';
import 'package:hercycle/providers/theme_provider.dart';
import 'package:hercycle/providers/prediction_provider.dart';
import 'package:hercycle/providers/clinical_data_provider.dart';
import 'package:hercycle/providers/auth_user_provider.dart';

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
    final user = safeCurrentUser();
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
    final user = safeCurrentUser();
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
    final user = safeCurrentUser();
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

  static const _bloodGroups = [
    'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'
  ];
  static const _sexOptions = ['Yes', 'No', 'Prefer not to say'];

  /// Writes a partial profile patch with merge semantics (untouched fields
  /// are preserved server-side, same as [UserService.saveProfile]). Throws
  /// on failure so callers can keep the edit dialog open with the error.
  Future<void> _savePatch(Map<String, dynamic> patch) async {
    final user = safeCurrentUser();
    if (user == null) throw StateError('You are not logged in.');
    final encoded = <String, dynamic>{};
    for (final e in patch.entries) {
      final v = e.value;
      if (v == null) {
        encoded[e.key] = FieldValue.delete();
      } else if (v is DateTime) {
        encoded[e.key] = Timestamp.fromDate(v);
      } else {
        encoded[e.key] = v;
      }
    }
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set(encoded, SetOptions(merge: true));
  }

  /// Silent refresh after an edit (no full-screen spinner flash), then
  /// invalidate everything derived from profile fields.
  Future<void> _refreshAfterEdit(String message) async {
    final user = safeCurrentUser();
    if (user == null || !mounted) return;
    try {
      final got = await UserService().getUserDoc(user.uid);
      if (!mounted) return;
      setState(() {
        _userData = got?['data'] as Map<String, dynamic>?;
        _fromCache = got?['fromCache'] == true;
      });
      ref.invalidate(predictionProvider);
      ref.invalidate(clinicalDataProvider);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved, but refresh failed: ${UserService.friendlyError(e)}')),
      );
    }
  }

  int? _ageOn(DateTime dob, DateTime today) {
    var age = today.year - dob.year;
    if (today.month < dob.month ||
        (today.month == dob.month && today.day < dob.day)) {
      age--;
    }
    return age;
  }

  String _dobLabel() {
    final dob = _parseDate(_userData?['dateOfBirth']);
    if (dob == null) return 'Not specified';
    final age = _ageOn(
        DateTime(dob.year, dob.month, dob.day),
        (() {
          final n = DateTime.now();
          return DateTime(n.year, n.month, n.day);
        })());
    return '${_fmtDay(dob)} (age $age)';
  }

  /// Generic text/number edit dialog. [validate] returns an error string or
  /// null when the raw input is acceptable. The dialog stays open with the
  /// error shown until input validates AND the save succeeds.
  Future<void> _editTextField({
    required String title,
    required String initial,
    required TextInputType keyboardType,
    required String? Function(String) validate,
    required Map<String, dynamic> Function(String) toPatch,
    required String successMessage,
  }) async {
    final controller = TextEditingController(text: initial);
    var saved = false;
    // Hoisted out of the StatefulBuilder so the analyzer sees the mutations.
    var saving = false;
    String? error;
    await showDialog(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setSheet) {
          return AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              keyboardType: keyboardType,
              autofocus: true,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                errorText: error,
              ),
              onChanged: (_) {
                if (error != null) setSheet(() => error = null);
              },
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(d),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: saving
                    ? null
                    : () async {
                        final problem = validate(controller.text.trim());
                        if (problem != null) {
                          setSheet(() => error = problem);
                          return;
                        }
                        setSheet(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          await _savePatch(toPatch(controller.text.trim()));
                        } catch (e) {
                          if (d.mounted) {
                            setSheet(() {
                              saving = false;
                              error = UserService.friendlyError(e);
                            });
                          }
                          return;
                        }
                        if (d.mounted) Navigator.pop(d);
                        saved = true;
                      },
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (saved && mounted) await _refreshAfterEdit(successMessage);
  }

  /// Choice dialog (blood group, had-sex). Tapping an option saves
  /// immediately; failures keep the dialog open with the error on top.
  Future<void> _editChoice({
    required String title,
    required String? current,
    required List<String> options,
    required String field,
    required String successMessage,
  }) async {
    var saved = false;
    // Hoisted out of the StatefulBuilder so the analyzer sees the mutations.
    var saving = false;
    String? error;
    await showDialog(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setSheet) {
          Future<void> pick(String? value) async {
            if (saving) return;
            setSheet(() {
              saving = true;
              error = null;
            });
            try {
              await _savePatch({field: value});
            } catch (e) {
              if (d.mounted) {
                setSheet(() {
                  saving = false;
                  error = UserService.friendlyError(e);
                });
              }
              return;
            }
            if (d.mounted) Navigator.pop(d);
            saved = true;
          }

          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: RadioGroup<String?>(
                groupValue: current,
                onChanged: (v) => pick(v),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(error!,
                            style: const TextStyle(
                                color: Color(0xFFC62828), fontSize: 12)),
                      ),
                    for (final opt in ['Not specified', ...options])
                      RadioListTile<String?>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(opt),
                        value: opt == 'Not specified' ? null : opt,
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(d),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
    if (saved && mounted) await _refreshAfterEdit(successMessage);
  }

  Future<void> _editName() {
    final current = _userData?['name']?.toString() ?? '';
    return _editTextField(
      title: 'Edit name',
      initial: current,
      keyboardType: TextInputType.name,
      validate: (v) {
        if (v.isEmpty) return 'Name cannot be empty.';
        if (v.length > 60) return 'Keep it under 60 characters.';
        return null;
      },
      toPatch: (v) => {'name': v},
      successMessage: 'Name updated ✓',
    );
  }

  Future<void> _editCycleLength() {
    final current =
        ((_userData?['typicalCycleLength'] as num?)?.toInt() ?? 28).toString();
    return _editTextField(
      title: 'Typical cycle length (days)',
      initial: current,
      keyboardType: TextInputType.number,
      validate: (v) {
        final n = int.tryParse(v);
        if (n == null) return 'Enter a whole number.';
        if (n < 15 || n > 60) return 'Must be between 15 and 60 days.';
        return null;
      },
      toPatch: (v) => {'typicalCycleLength': int.parse(v)},
      successMessage: 'Cycle length updated — predictions refreshed ✓',
    );
  }

  Future<void> _editPeriodLength() {
    final current =
        ((_userData?['typicalPeriodLength'] as num?)?.toInt() ?? 5).toString();
    return _editTextField(
      title: 'Typical period length (days)',
      initial: current,
      keyboardType: TextInputType.number,
      validate: (v) {
        final n = int.tryParse(v);
        if (n == null) return 'Enter a whole number.';
        if (n < 1 || n > 15) return 'Must be between 1 and 15 days.';
        return null;
      },
      toPatch: (v) => {'typicalPeriodLength': int.parse(v)},
      successMessage: 'Period length updated — predictions refreshed ✓',
    );
  }

  Future<void> _editDob() async {
    final current = _parseDate(_userData?['dateOfBirth']);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? today.subtract(const Duration(days: 365 * 25)),
      firstDate: DateTime(today.year - 120),
      // No future dates, and at least a plausible minimum age.
      lastDate: today,
    );
    if (picked == null || !mounted) return;
    final day = DateTime(picked.year, picked.month, picked.day);
    if (day.isAfter(today)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Date of birth cannot be in the future.')));
      return;
    }
    try {
      await _savePatch({'dateOfBirth': day});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: ${UserService.friendlyError(e)}')),
      );
      return;
    }
    await _refreshAfterEdit('Date of birth updated ✓');
  }

  /// Start + end pickers in one dialog; end must not precede start.
  /// Clearing the end date deletes it (predictions fall back to the
  /// typical period length).
  Future<void> _editLastPeriod() async {
    var start = _parseDate(_userData?['lastPeriodStartDate']);
    var end = _parseDate(_userData?['lastPeriodEndDate']);
    var saved = false;
    // Hoisted out of the StatefulBuilder so the analyzer sees the mutations.
    var saving = false;
    String? error;
    await showDialog(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setSheet) {
          Future<void> pick(bool isStart) async {
            final picked = await showDatePicker(
              context: d,
              initialDate: (isStart ? start : end) ?? DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime.now(),
            );
            if (picked == null) return;
            setSheet(() {
              if (isStart) {
                start = DateTime(picked.year, picked.month, picked.day);
              } else {
                end = DateTime(picked.year, picked.month, picked.day);
              }
              error = null;
            });
          }

          return AlertDialog(
            title: const Text('Last period'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(error!,
                        style: const TextStyle(
                            color: Color(0xFFC62828), fontSize: 12)),
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Start date *'),
                  trailing: Text(
                      start == null ? 'Select' : _fmtDay(start!),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  onTap: () => pick(true),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('End date (optional)'),
                  trailing: Text(end == null ? 'Select' : _fmtDay(end!),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  onTap: () => pick(false),
                ),
                if (end != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed:
                          saving ? null : () => setSheet(() => end = null),
                      child: const Text('Clear end date'),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(d),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (start == null) {
                          setSheet(() =>
                              error = 'Pick a start date first.');
                          return;
                        }
                        if (end != null && end!.isBefore(start!)) {
                          setSheet(() => error =
                              'End date cannot be before the start date.');
                          return;
                        }
                        setSheet(() {
                          saving = true;
                          error = null;
                        });
                        try {
                          await _savePatch({
                            'lastPeriodStartDate': start!,
                            'lastPeriodEndDate': end,
                          });
                        } catch (e) {
                          if (d.mounted) {
                            setSheet(() {
                              saving = false;
                              error = UserService.friendlyError(e);
                            });
                          }
                          return;
                        }
                        if (d.mounted) Navigator.pop(d);
                        saved = true;
                      },
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (saved && mounted) {
      await _refreshAfterEdit('Last period updated — predictions refreshed ✓');
    }
  }

  /// Tappable profile row with an edit affordance. Read-only rows should
  /// use a plain [ListTile] instead so nothing looks editable that isn't.
  Widget _infoTile({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFFC26D81)),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(value,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 4),
          Icon(Icons.edit_outlined, size: 16, color: context.her.muted),
        ],
      ),
      onTap: onTap,
    );
  }

  Future<void> _loadUserData() async {
    final user = safeCurrentUser();
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
    final user = safeCurrentUser();

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
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: context.her.ink),
                  ),
                ),
                Center(
                  child: Text(
                    _userData?['email'] ?? user?.email ?? '',
                    style: TextStyle(fontSize: 14, color: context.her.muted),
                  ),
                ),
                if (_fromCache)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Offline mode — showing saved data',
                          style: TextStyle(
                              fontSize: 11,
                              color: context.her.muted,
                              fontStyle: FontStyle.italic)),
                    ),
                  ),
                const SizedBox(height: 32),
                Text('Personal Details', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.her.ink)),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: context.her.card,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.pink.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Material(
                    color: context.her.card,
                    borderRadius: BorderRadius.circular(20),
                    child: Column(
                      children: [
                        _infoTile(
                          icon: Icons.person_outline,
                          title: 'Name',
                          value: (_userData?['name']?.toString().isNotEmpty == true)
                              ? _userData!['name'].toString()
                              : 'Not specified',
                          onTap: _editName,
                        ),
                        const Divider(height: 1),
                        _infoTile(
                          icon: Icons.cake_outlined,
                          title: 'Date of Birth',
                          value: _dobLabel(),
                          onTap: _editDob,
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.email_outlined, color: Color(0xFFC26D81)),
                          title: const Text('Email'),
                          subtitle: const Text('Managed by your sign-in account',
                              style: TextStyle(fontSize: 11)),
                          trailing: Text(
                            _userData?['email']?.toString().isNotEmpty == true
                                ? _userData!['email'].toString()
                                : (user?.email ?? 'Not specified'),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Cycle & Health Info', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.her.ink)),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: context.her.card,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.pink.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Material(
                    color: context.her.card,
                    borderRadius: BorderRadius.circular(20),
                    child: Column(
                      children: [
                      _infoTile(
                        icon: Icons.calendar_month,
                        title: 'Typical Cycle Length',
                        value: '${(_userData?['typicalCycleLength'] as num?)?.toInt() ?? 28} days',
                        onTap: _editCycleLength,
                      ),
                      const Divider(height: 1),
                      _infoTile(
                        icon: Icons.water_drop,
                        title: 'Typical Period Length',
                        value: '${(_userData?['typicalPeriodLength'] as num?)?.toInt() ?? 5} days',
                        onTap: _editPeriodLength,
                      ),
                      const Divider(height: 1),
                      _infoTile(
                        icon: Icons.bloodtype,
                        title: 'Blood Group',
                        value: _userData?['bloodGroup']?.toString() ?? 'Not specified',
                        onTap: () => _editChoice(
                          title: 'Blood group',
                          current: _userData?['bloodGroup']?.toString(),
                          options: _bloodGroups,
                          field: 'bloodGroup',
                          successMessage: 'Blood group updated ✓',
                        ),
                      ),
                      const Divider(height: 1),
                      _infoTile(
                        icon: Icons.date_range,
                        title: 'Last Period',
                        value: _lastPeriodLabel(),
                        onTap: _editLastPeriod,
                      ),
                      const Divider(height: 1),
                      _infoTile(
                        icon: Icons.favorite_border,
                        title: 'Had sex recently',
                        value: _userData?['hadSexRecently']?.toString() ?? 'Not specified',
                        onTap: () => _editChoice(
                          title: 'Had sex recently',
                          current: _userData?['hadSexRecently']?.toString(),
                          options: _sexOptions,
                          field: 'hadSexRecently',
                          successMessage: 'Updated ✓',
                        ),
                      ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Trying to Conceive', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.her.ink)),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: context.her.card,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.pink.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Material(
                    color: context.her.card,
                    borderRadius: BorderRadius.circular(20),
                    child: SwitchListTile(
                      secondary: const Icon(Icons.favorite,
                          color: Color(0xFFC26D81)),
                      title: const Text('Trying-for-a-baby mode'),
                      subtitle: const Text(
                          'Home shows fertile coverage, peak countdown and test-day reminders'),
                      value: _userData?['ttcMode'] == true,
                      onChanged: (val) async {
                        final previous = _userData?['ttcMode'] == true;
                        setState(() {
                          _userData = {
                            ...?_userData,
                            'ttcMode': val,
                          };
                        });
                        try {
                          await _savePatch({'ttcMode': val});
                        } catch (e) {
                          if (!context.mounted) return;
                          setState(() {
                            _userData = {
                              ...?_userData,
                              'ttcMode': previous,
                            };
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(
                                    'Could not save: ${UserService.friendlyError(e)}')),
                          );
                          return;
                        }
                        if (!context.mounted) return;
                        ref.invalidate(predictionProvider);
                        ref.invalidate(clinicalDataProvider);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text(val
                                  ? 'Trying-to-conceive mode on 💗'
                                  : 'Trying-to-conceive mode off')),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Reminders', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.her.ink)),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: context.her.card,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.pink.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Material(
                    color: context.her.card,
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
                const SizedBox(height: 20),
                Text('Appearance', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.her.ink)),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: context.her.card,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.pink.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Material(
                    color: context.her.card,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.settings_suggest_outlined)),
                          ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                          ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                        ],
                        selected: {ref.watch(themeModeProvider)},
                        onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).setMode(s.first),
                      ),
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
