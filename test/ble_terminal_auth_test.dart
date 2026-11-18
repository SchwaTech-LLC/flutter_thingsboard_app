import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:thingsboard_app/config/routes/v2/routes_config/routes/ble_terminal_routes.dart';
import 'package:thingsboard_app/core/auth/login/models/login_state.dart';
import 'package:thingsboard_app/core/auth/login/provider/login_provider.dart';
import 'package:thingsboard_app/core/auth/redirect/auth_redirect.dart';
import 'package:thingsboard_app/thingsboard_client.dart';

class TestLogin extends AutoDisposeNotifier<LoginState> implements Login {
  @override
  LoginState build() => const LoginState(isUserLoaded: false);
  void setLogin(LoginState next) => state = next;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('terminal requires a loaded user and completed MFA', () {
    for (final login in [
      const LoginState(isUserLoaded: false),
      const LoginState(isUserLoaded: true),
      const LoginState(isUserLoaded: false, userScope: Authority.CUSTOMER_USER),
      const LoginState(
        isUserLoaded: true,
        userScope: Authority.PRE_VERIFICATION_TOKEN,
      ),
      const LoginState(
        isUserLoaded: true,
        userScope: Authority.MFA_CONFIGURATION_TOKEN,
      ),
    ]) {
      expect(bleTerminalAuthRedirect(login), isNotNull);
    }
    expect(
      bleTerminalAuthRedirect(
        const LoginState(
          isUserLoaded: true,
          userScope: Authority.CUSTOMER_USER,
        ),
      ),
      isNull,
    );
  });

  testWidgets('deep links and pushed terminal routes revoke access on logout', (
    tester,
  ) async {
    final provider = Provider<GoRouter>((ref) {
      final refresh = ValueNotifier(0);
      ref.listen(loginProvider, (_, next) => refresh.value++);
      final router = GoRouter(
        initialLocation: BleTerminalRoutes.terminal,
        refreshListenable: refresh,
        redirect:
            (context, state) => AuthRedirect().redirect(context, state, ref),
        routes: [
          GoRoute(
            path: '/',
            builder:
                (context, state) => Scaffold(
                  body: TextButton(
                    onPressed: () => context.push(BleTerminalRoutes.terminal),
                    child: const Text('Open terminal'),
                  ),
                ),
          ),
          GoRoute(
            path: '/login',
            builder: (context, state) => const Scaffold(body: Text('Login')),
            routes: [
              GoRoute(
                path: 'mfaConfirm',
                builder: (context, state) => const Text('Confirm MFA'),
              ),
              GoRoute(
                path: 'mfaForce',
                builder: (context, state) => const Text('Set up MFA'),
              ),
            ],
          ),
          GoRoute(
            path: BleTerminalRoutes.terminal,
            builder:
                (context, state) =>
                    const Scaffold(body: Text('Protected terminal')),
          ),
        ],
      );
      ref.onDispose(() {
        router.dispose();
        refresh.dispose();
      });
      return router;
    });
    final container = ProviderContainer(
      overrides: [loginProvider.overrideWith(TestLogin.new)],
    );
    addTearDown(container.dispose);
    final router = container.read(provider);
    final login = container.read(loginProvider.notifier) as TestLogin;
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('Protected terminal'), findsNothing);
    expect(find.text('Login'), findsOneWidget);
    for (final entry
        in {
          Authority.PRE_VERIFICATION_TOKEN: 'Confirm MFA',
          Authority.MFA_CONFIGURATION_TOKEN: 'Set up MFA',
        }.entries) {
      login.setLogin(LoginState(isUserLoaded: true, userScope: entry.key));
      router.go(BleTerminalRoutes.terminal);
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('Protected terminal'), findsNothing);
    }
    login.setLogin(
      const LoginState(isUserLoaded: true, userScope: Authority.CUSTOMER_USER),
    );
    router.go('/');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open terminal'));
    await tester.pumpAndSettle();
    expect(find.text('Protected terminal'), findsOneWidget);
    login.setLogin(const LoginState(isUserLoaded: false));
    await tester.pumpAndSettle();
    expect(find.text('Protected terminal'), findsNothing);
    expect(find.text('Login'), findsOneWidget);
  });
}
