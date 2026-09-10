import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/models/user_profile.dart';
import 'package:hercycle/services/user_service.dart';
import 'package:intl/intl.dart';

/// Repair path for accounts whose profile document is missing (e.g. signed
/// up before verified saves existed). Saves the essentials for the CURRENT
/// user with the same verify-before-leaving guarantee as signup.
class CompleteProfileScreen extends ConsumerStatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  ConsumerState<CompleteProfileScreen> createState() =>
      _CompleteProfileScreenState();
}

class _CompleteProfileScreenState
    extends ConsumerState<CompleteProfileScreen> {
  final _nameController = TextEditingController();
  final _cycleController = TextEditingController(text: '28');
  final _periodController = TextEditingController(text: '5');
  DateTime? _lastPeriodDate;
  DateTime? _lastPeriodEndDate;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _cycleController.dispose();
    _periodController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter your name')));
      return;
    }
    final cycleLen = int.tryParse(_cycleController.text.trim());
    if (cycleLen == null || cycleLen < 15 || cycleLen > 60) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Cycle length must be between 15 and 60 days')));
      return;
    }
    final periodLen = int.tryParse(_periodController.text.trim());
    if (periodLen == null || periodLen < 1 || periodLen > 15) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Period length must be between 1 and 15 days')));
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You are not logged in')));
      return;
    }
    if (_lastPeriodDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please select your last period start date')));
      return;
    }
    if (_lastPeriodEndDate != null &&
        _lastPeriodEndDate!.isBefore(_lastPeriodDate!)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Period end date cannot be before the start date')));
      return;
    }
    setState(() => _isLoading = true);
    final ctx = context;
    try {
      await UserService().saveProfile(
        user.uid,
        UserProfile(
          name: name,
          email: user.email ?? '',
          lastPeriodStartDate: _lastPeriodDate,
          lastPeriodEndDate: _lastPeriodEndDate,
          typicalCycleLength: cycleLen,
          typicalPeriodLength: periodLen,
        ),
      );
      final verified = await UserService().verifyProfile(user.uid);
      if (!mounted) return;
      if (!verified) {
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
            content: Text(
                "Couldn't confirm your profile was saved. Check your connection and database rules, then try again.")));
        return;
      }
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      Navigator.pop(ctx, true);
    } catch (e) {
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text(UserService.friendlyError(e))));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Complete Profile')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Your profile is missing — add these details to unlock your dashboard and predictions.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                  labelText: 'Full Name *', prefixIcon: Icon(Icons.person)),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now(),
                  firstDate: DateTime(2020, 1, 1),
                  lastDate: DateTime.now(),
                );
                if (date != null) {
                  setState(() => _lastPeriodDate = date);
                }
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'First Period Start Date *',
                    prefixIcon: Icon(Icons.calendar_today)),
                child: Text(_lastPeriodDate == null
                    ? 'Select Start Date'
                    : DateFormat('yyyy-MM-dd').format(_lastPeriodDate!)),
              ),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: () async {
                final first =
                    _lastPeriodDate ?? DateTime.now().subtract(const Duration(days: 5));
                final date = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now(),
                  firstDate: first,
                  lastDate: DateTime.now(),
                );
                if (date != null) {
                  setState(() => _lastPeriodEndDate = date);
                }
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Period Ending Date (Optional)',
                    prefixIcon: Icon(Icons.event_available)),
                child: Text(_lastPeriodEndDate == null
                    ? 'Select End Date'
                    : DateFormat('yyyy-MM-dd').format(_lastPeriodEndDate!)),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _cycleController,
              decoration: const InputDecoration(
                  labelText: 'Typical Cycle Length (days)',
                  prefixIcon: Icon(Icons.loop)),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _periodController,
              decoration: const InputDecoration(
                  labelText: 'Typical Period Length (days)',
                  prefixIcon: Icon(Icons.water_drop)),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isLoading ? null : _save,
              child: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Save Profile'),
            ),
          ],
        ),
      ),
    );
  }
}
