import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hercycle/core/app_theme.dart';
import 'package:hercycle/features/auth/login_screen.dart';
import 'package:hercycle/features/home/home_screen.dart';
import 'package:hercycle/features/calendar/calendar_screen.dart';
import 'package:hercycle/features/trends/trends_screen.dart';
import 'package:hercycle/features/luna/luna_screen.dart';
import 'package:hercycle/features/profile/profile_screen.dart';
import 'package:hercycle/core/widgets/animations.dart';
import 'package:hercycle/core/notification_service.dart';
import 'package:hercycle/core/telemetry_service.dart';
import 'package:hercycle/providers/theme_provider.dart';
import 'package:hercycle/features/splash/animated_splash_screen.dart';
import 'firebase_options.dart';

/// Boot work that used to block before first frame: Firebase + notifications.
/// Failures never block startup — screens degrade gracefully when offline.
Future<void> _bootApp() async {
  try {
    if (kIsWeb) {
      await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform);
    } else {
      await Firebase.initializeApp();
    }
  } catch (_) {
    // Offline or misconfigured backend: proceed; auth gate + screens
    // handle the degraded state with explicit messages.
  }
  // Crash reporting + analytics (installs global error handlers).
  // Internally guarded; never throws past this point.
  await TelemetryService.init();
  await NotificationService.init();
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Show the animated splash on the very first frame; boot concurrently.
  runApp(const ProviderScope(child: HerCycleApp()));
}

class HerCycleApp extends ConsumerStatefulWidget {
  const HerCycleApp({super.key});

  @override
  ConsumerState<HerCycleApp> createState() => _HerCycleAppState();
}

class _HerCycleAppState extends ConsumerState<HerCycleApp> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // Full 5s splash AND boot completion (10s cap so a stalled backend
    // can never hang the launch).
    await Future.wait([
      Future.delayed(const Duration(seconds: 5)),
      _bootApp().timeout(const Duration(seconds: 10), onTimeout: () {}),
    ]);
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HerCycle',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ref.watch(themeModeProvider),
      routes: {
        '/home': (context) => const MainNavigation(),
        '/login': (context) => const LoginScreen(),
      },
      home: _ready ? const _AuthGate() : const AnimatedSplashScreen(),
    );
  }
}

/// Firebase access is never assumed: `_bootApp` deliberately proceeds when
/// backend init fails (offline / misconfigured), and `FirebaseAuth.instance`
/// throws in that state. These helpers degrade to "logged out" instead.
Stream<User?>? _safeAuthStream() {
  try {
    return FirebaseAuth.instance.authStateChanges();
  } catch (_) {
    return null;
  }
}

User? _safeCurrentUser() {
  try {
    return FirebaseAuth.instance.currentUser;
  } catch (_) {
    return null;
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final stream = _safeAuthStream();
    if (stream == null) {
      // No backend: skip straight to login instead of crashing.
      return const LoginScreen();
    }
    return StreamBuilder<User?>(
        stream: stream,
        initialData: _safeCurrentUser(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return Scaffold(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const PulseGlow(
                      child: Icon(Icons.favorite, size: 60, color: Color(0xFFC26D81)),
                    ),
                    const SizedBox(height: 16),
                    Text('HerCycle', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: context.her.ink)),
                    const SizedBox(height: 24),
                    const CircularProgressIndicator(color: Color(0xFFC26D81)),
                  ],
                ),
              ),
            );
          }
          if (snapshot.hasData && snapshot.data != null) {
            return const MainNavigation();
          }
          return const LoginScreen();
        },
      );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;
  final List<Widget> _screens = [
    const HomeScreen(),
    const CalendarScreen(),
    const LunaScreen(),
    const TrendsScreen(),
    const ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFB85D6F),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, -3)),
          ],
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.transparent,
          elevation: 0,
          currentIndex: _currentIndex,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white70,
          onTap: (index) => setState(() => _currentIndex = index),
          items: [
            const BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: 'Home'),
            const BottomNavigationBarItem(icon: Icon(Icons.calendar_today_outlined), label: 'Calendar'),
            BottomNavigationBarItem(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0xFFFFD166),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.face_outlined, color: Color(0xFF4A4A4A)),
              ),
              label: 'Luna',
            ),
            const BottomNavigationBarItem(icon: Icon(Icons.show_chart), label: 'Trends'),
            const BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}
