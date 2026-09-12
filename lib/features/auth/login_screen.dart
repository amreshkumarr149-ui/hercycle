import 'package:flutter/material.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:hercycle/features/auth/auth_service.dart';
import 'package:hercycle/features/auth/signup_screen.dart';
import 'package:hercycle/core/widgets/animations.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 20),
                FadeSlideIn(
                  child: Center(
                    child: PulseGlow(
                      minScale: 0.96,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Image.asset(
                          'assets/images/logo.png',
                          width: 120,
                          height: 120,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) => const Icon(Icons.face_retouching_natural, size: 100, color: Color(0xFFC26D81)),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text("HerCycle", textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: context.her.ink)),
                const Text("Track • Understand • Feel Better", textAlign: TextAlign.center),
                const SizedBox(height: 30),
                
                const FadeSlideIn(
                  delay: Duration(milliseconds: 100),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Welcome Back ♡", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      Text("Your health. Your cycle. Your journey.\nWe're here for you."),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Google Button
                FadeSlideIn(
                  delay: const Duration(milliseconds: 200),
                  child: OutlinedButton.icon(
                  onPressed: _isLoading ? null : () async {
                    setState(() => _isLoading = true);
                    final ctx = context;
                    try {
                      final user = await ref.read(authServiceProvider).signInWithGoogle();
                      if (!mounted) return;
                      if (user != null) {
                        // ignore: use_build_context_synchronously
                        Navigator.of(ctx).pushNamedAndRemoveUntil('/home', (route) => false);
                      } else {
                        // ignore: use_build_context_synchronously
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(content: Text("Google sign-in cancelled — no account selected.")),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        // ignore: use_build_context_synchronously
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text("Google Sign-In Error: $e"))
                        );
                      }
                    } finally {
                      if (mounted) setState(() => _isLoading = false);
                    }
                  },
                  icon: const Icon(Icons.g_mobiledata, color: Colors.black),
                  label: const Text("Continue with Google", style: TextStyle(color: Colors.black)),
                  style: OutlinedButton.styleFrom(backgroundColor: const Color(0xFFF9C8D2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  ),
                ),
                
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Row(children: [Expanded(child: Divider()), Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text("or")), Expanded(child: Divider())]),
                ),

                TextField(
                  controller: _emailController, 
                  decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email)),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController, 
                  decoration: InputDecoration(
                    labelText: 'Password', 
                    prefixIcon: const Icon(Icons.lock),
                    suffixIcon: IconButton(icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _obscurePassword = !_obscurePassword)),
                  ),
                  obscureText: _obscurePassword,
                ),
                
                Align(
                  alignment: Alignment.centerRight, 
                  child: TextButton(
                    onPressed: () async {
                      final emailController = TextEditingController(text: _emailController.text);
                      await showDialog(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Reset Password'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Enter your email address and we will send you a link to reset your password.'),
                              const SizedBox(height: 16),
                              TextField(
                                controller: emailController,
                                decoration: const InputDecoration(labelText: 'Email'),
                                keyboardType: TextInputType.emailAddress,
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () async {
                                final email = emailController.text.trim();
                                if (email.isEmpty) {
                                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                                    const SnackBar(content: Text('Please enter your email'))
                                  );
                                  return;
                                }
                                try {
                                  await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
                                  if (!dialogContext.mounted) return;
                                  Navigator.pop(dialogContext);
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Password reset email sent! Check your inbox.'))
                                  );
                                } on FirebaseAuthException catch (e) {
                                  if (!dialogContext.mounted) return;
                                  // ignore: use_build_context_synchronously
                                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                                    SnackBar(content: Text(e.message ?? 'Failed to send reset email'))
                                  );
                                } catch (e) {
                                  if (!dialogContext.mounted) return;
                                  // ignore: use_build_context_synchronously
                                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                                    SnackBar(content: Text('Error: $e'))
                                  );
                                }
                              },
                              child: const Text('Send Reset Link'),
                            ),
                          ],
                        ),
                      );
                    }, 
                    child: const Text("Forgot password?")
                  ),
                ),
                
                const SizedBox(height: 20),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 300),
                  child: ElevatedButton(
                  onPressed: _isLoading ? null : () async {
                    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please fill all fields")));
                      return;
                    }
                    setState(() => _isLoading = true);
                    final ctx = context;
                    try {
                      final user = await ref.read(authServiceProvider).signIn(_emailController.text.trim(), _passwordController.text.trim());
                      if (user != null && mounted) {
                        // ignore: use_build_context_synchronously
                        Navigator.of(ctx).pushNamedAndRemoveUntil('/home', (route) => false);
                      }
                    } on FirebaseAuthException catch (e) {
                      if (!mounted) return;
                      // ignore: use_build_context_synchronously
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(e.message ?? "Authentication failed")));
                    } catch (e) {
                      if (!mounted) return;
                      // ignore: use_build_context_synchronously
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text("An error occurred: $e")));
                    } finally {
                      if (mounted) setState(() => _isLoading = false);
                    }
                  },
                  child: _isLoading 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Text("Log In"), SizedBox(width: 8), Icon(Icons.arrow_forward)]),
                  ),
                ),
                
                TextButton(
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const SignupScreen()));
                  }, 
                  child: const Text("Don't have an account? Sign Up →")
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
