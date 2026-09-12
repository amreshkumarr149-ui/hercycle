import 'package:flutter/material.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hercycle/features/auth/auth_service.dart';
import 'package:hercycle/models/user_profile.dart';
import 'package:hercycle/services/user_service.dart';
import 'package:intl/intl.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _cycleLengthController = TextEditingController(text: '28');
  final _periodLengthController = TextEditingController(text: '5');

  DateTime? _dob;
  DateTime? _lastPeriodDate;
  DateTime? _lastPeriodEndDate;
  String? _selectedBloodGroup;
  String? _selectedHadSex;
  
  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _cycleLengthController.dispose();
    _periodLengthController.dispose();
    super.dispose();
  }

  final List<String> _bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
  final List<String> _sexOptions = ['Yes', 'No', 'Prefer not to say'];

  Future<void> _register() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    if (_nameController.text.trim().isEmpty ||
        email.isEmpty ||
        password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please fill in Name, Email, and Password")));
      return;
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please enter a valid email address")));
      return;
    }
    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Password must be at least 6 characters")));
      return;
    }
    final cycleLen = int.tryParse(_cycleLengthController.text.trim());
    if (cycleLen == null || cycleLen < 15 || cycleLen > 60) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Cycle length must be between 15 and 60 days")));
      return;
    }
    final periodLen = int.tryParse(_periodLengthController.text.trim());
    if (periodLen == null || periodLen < 1 || periodLen > 15) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Period length must be between 1 and 15 days")));
      return;
    }
    if (_dob == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please select your date of birth")));
      return;
    }
    if (_lastPeriodDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please select your last period start date")));
      return;
    }
    if (_lastPeriodEndDate != null &&
        _lastPeriodEndDate!.isBefore(_lastPeriodDate!)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Period end date cannot be before the start date")));
      return;
    }

    setState(() => _isLoading = true);
    final ctx = context;
    try {
      // 1. Create Auth User
      final user = await ref.read(authServiceProvider).signUp(
        email,
        password,
      );

      if (user != null) {
        // 2. Build UserProfile with all collected data (including optional fields with Skip)
        final profile = UserProfile(
          name: _nameController.text.trim(),
          email: email,
          dateOfBirth: _dob,
          lastPeriodStartDate: _lastPeriodDate,
          lastPeriodEndDate: _lastPeriodEndDate,
          typicalCycleLength: cycleLen,
          typicalPeriodLength: periodLen,
          bloodGroup: _selectedBloodGroup,
          hadSexRecently: _selectedHadSex,
        );

        // 3. Save to Firestore
        await UserService().saveProfile(user.uid, profile);

        // 3b. Verify the write actually landed (server or local cache)
        // before leaving — never navigate on an unconfirmed save.
        final verified = await UserService().verifyProfile(user.uid);
        if (!mounted) return;
        if (!verified) {
          // ignore: use_build_context_synchronously
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(
                content: Text(
                    "Couldn't confirm your profile was saved. Check your connection and database rules, then tap again to retry.")),
          );
          return;
        }

        if (!mounted) return;
        // 4. Navigate to Home
        // ignore: use_build_context_synchronously
        Navigator.of(ctx).pushNamedAndRemoveUntil('/home', (route) => false);
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(e.message ?? "Sign up failed")));
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
      appBar: AppBar(title: const Text('Create Account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text("Join HerCycle ♡", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: context.her.ink)),
              const SizedBox(height: 8),
              Text("Track your cycle, symptoms, and wellness in one place.", style: TextStyle(color: context.her.muted)),
              const SizedBox(height: 24),

              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Full Name *', prefixIcon: Icon(Icons.person)),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email *', prefixIcon: Icon(Icons.email)),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _passwordController,
                decoration: InputDecoration(
                  labelText: 'Password (min 6 chars) *',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                obscureText: _obscurePassword,
              ),
              const SizedBox(height: 16),

              // Date of Birth Picker
              InkWell(
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: DateTime(2000, 1, 1),
                    firstDate: DateTime(1940, 1, 1),
                    lastDate: DateTime.now(),
                  );
                  if (date != null) setState(() => _dob = date);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Date of Birth *', prefixIcon: Icon(Icons.cake)),
                  child: Text(_dob == null ? 'Select Date of Birth' : DateFormat('yyyy-MM-dd').format(_dob!)),
                ),
              ),
              const SizedBox(height: 16),

              // Last Period Date Picker
              InkWell(
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now(),
                    firstDate: DateTime(2020, 1, 1),
                    lastDate: DateTime.now(),
                  );
                  if (date != null) setState(() => _lastPeriodDate = date);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'First Period Start Date *', prefixIcon: Icon(Icons.calendar_today)),
                  child: Text(_lastPeriodDate == null ? 'Select Start Date' : DateFormat('yyyy-MM-dd').format(_lastPeriodDate!)),
                ),
              ),
              const SizedBox(height: 16),

              // Last Period End Date Picker
              InkWell(
                onTap: () async {
                  final first = _lastPeriodDate ?? DateTime.now().subtract(const Duration(days: 5));
                  final date = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now(),
                    firstDate: first,
                    lastDate: DateTime.now(),
                  );
                  if (date != null) setState(() => _lastPeriodEndDate = date);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Period Ending Date (Optional)', prefixIcon: Icon(Icons.event_available)),
                  child: Text(_lastPeriodEndDate == null ? 'Select End Date' : DateFormat('yyyy-MM-dd').format(_lastPeriodEndDate!)),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _cycleLengthController,
                decoration: const InputDecoration(labelText: 'Typical Cycle Length (days)', prefixIcon: Icon(Icons.loop)),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _periodLengthController,
                decoration: const InputDecoration(labelText: 'Typical Period Length (days)', prefixIcon: Icon(Icons.water_drop)),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),

              // Blood Group Dropdown with Skip option
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Blood Group (Optional)', prefixIcon: Icon(Icons.bloodtype)),
                items: [
                  const DropdownMenuItem<String>(value: null, child: Text('Skip (Not specified)')),
                  ..._bloodGroups.map((bg) => DropdownMenuItem(value: bg, child: Text(bg))),
                ],
                onChanged: (val) => setState(() => _selectedBloodGroup = val),
              ),
              const SizedBox(height: 16),

              // Had sex recently with Skip option
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Had sex recently? (Optional)', prefixIcon: Icon(Icons.favorite_border)),
                items: [
                  const DropdownMenuItem<String>(value: null, child: Text('Skip (Not specified)')),
                  ..._sexOptions.map((opt) => DropdownMenuItem(value: opt, child: Text(opt))),
                ],
                onChanged: (val) => setState(() => _selectedHadSex = val),
              ),
              const SizedBox(height: 32),

              ElevatedButton(
                onPressed: _isLoading ? null : _register,
                child: _isLoading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Complete Registration & Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
