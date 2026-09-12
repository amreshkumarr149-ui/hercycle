import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hercycle/features/splash/animated_splash_screen.dart';

void main() {
  testWidgets('splash plays full timeline and settles without crashing',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AnimatedSplashScreen()));

    // Opening frame: splash + full-artwork logo exist in tree
    // (the logo carries its own wordmark, so no separate text is drawn).
    expect(find.byType(AnimatedSplashScreen), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    // Step through the whole 5s timeline in chunks.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 500));

    // Settled final frame still intact.
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
