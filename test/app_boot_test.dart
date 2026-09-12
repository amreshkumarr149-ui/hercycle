import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/features/auth/login_screen.dart';
import 'package:hercycle/main.dart';

/// Startup regression test: with no Firebase backend initialized (offline /
/// misconfigured, exactly what `_bootApp` tolerates), the app must land on
/// the login screen instead of red-screening on `FirebaseAuth.instance`.
void main() {
  testWidgets('app boots to login without a Firebase backend',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: HerCycleApp()));
    // Splash lasts 5s and boot is capped at 10s; advance past both.
    // (pumpAndSettle can't be used: bare delayed futures schedule no
    // frames, so it would settle early while still on the splash.)
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 11));
    // Flush any leftover boot timers (e.g. the 10s boot cap) so the
    // test binding's no-timers-pending invariant holds at teardown.
    await tester.pump(const Duration(seconds: 15));

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Log In'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
