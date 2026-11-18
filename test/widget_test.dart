import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sandan_facility_app/main.dart';

// Note: the background uses an endlessly repeating AnimationController for
// its drifting glow orbs, so these tests use bounded `pump(duration)` calls
// instead of `pumpAndSettle`, which would never settle.
void main() {
  // flutter_secure_storage's platform channel has no responder under
  // `flutter test` (no real platform embedder is running), so calls to it
  // would hang forever instead of erroring — mock it to fail fast, which
  // AuthService.restoreSession() already treats as "no stored session".
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    throw MissingPluginException();
  });


  testWidgets('App launches into the splash screen', (tester) async {
    await tester.pumpWidget(const SandanApp());
    await tester.pump();

    expect(find.text('FACILITY & MAINTENANCE'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    // Let the splash timer fire and the fade transition to login finish.
    await tester.pump(const Duration(milliseconds: 2300));
    await tester.pump(const Duration(milliseconds: 800));
  });

  testWidgets('Login form validates empty fields', (tester) async {
    await tester.pumpWidget(const SandanApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2300));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 900)); // entrance stagger

    expect(find.text('Welcome back'), findsOneWidget);

    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.text('Enter your email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
  });
}
