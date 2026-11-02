import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:schuly/services/auth_service.dart';
import 'package:schuly/ui/auth/sign_in_screen.dart';

Widget _app(Future<List<SignInProvider>> Function() providersLoader) => MaterialApp(
      localizationsDelegates: FLocalizations.localizationsDelegates,
      supportedLocales: FLocalizations.supportedLocales,
      home: FTheme(
        data: FThemes.zinc.light,
        child: SignInScreen(providersLoader: providersLoader),
      ),
    );

void main() {
  testWidgets('shows only configured SSO sign-in options', (tester) async {
    await tester.pumpWidget(_app(() async => const [SignInProvider('gamepowerx', 'GamepowerX', null)]));
    await tester.pumpAndSettle();

    expect(find.text('Continue with GamepowerX'), findsOneWidget);
    expect(find.text('Password'), findsNothing);
    expect(find.text('Username or email'), findsNothing);
    expect(find.text('Create an account'), findsNothing);
    expect(find.text('Forgot password?'), findsNothing);
    expect(find.text('Use a recovery code'), findsNothing);
    expect(find.text('Authentication code'), findsNothing);
  });

  testWidgets('shows an explicit empty state without local credential fallback', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_app(() async {
      calls++;
      return const [];
    }));
    await tester.pumpAndSettle();

    expect(find.textContaining('No sign-in providers are available'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byType(FButton), findsOneWidget);
    expect(find.text('Password'), findsNothing);
    expect(find.text('Create an account'), findsNothing);
    expect(find.text('Forgot password?'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('No sign-in providers are available. Check your connection or contact your administrator.'), findsOneWidget);
  });

  testWidgets('shows loading until provider discovery completes', (tester) async {
    final response = Completer<List<SignInProvider>>();
    await tester.pumpWidget(_app(() => response.future));

    expect(find.text('Loading sign-in options...'), findsOneWidget);
    expect(find.textContaining('No sign-in providers are available'), findsNothing);
    expect(find.text('Password'), findsNothing);

    response.complete(const [SignInProvider('gamepowerx', 'GamepowerX', null)]);
    await tester.pumpAndSettle();
    expect(find.text('Continue with GamepowerX'), findsOneWidget);
    expect(find.text('Loading sign-in options...'), findsNothing);
  });
}
