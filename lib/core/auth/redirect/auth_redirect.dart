import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:thingsboard_app/config/routes/v2/redirects/redirect.dart';
import 'package:thingsboard_app/config/routes/v2/routes_config/routes/ble_terminal_routes.dart';
import 'package:thingsboard_app/config/routes/v2/routes_config/routes/login_routes.dart';
import 'package:thingsboard_app/config/routes/v2/routes_config/routes/noauth_routes.dart';
import 'package:thingsboard_app/config/routes/v2/routes_config/routes/ui_utils_routes.dart';
import 'package:thingsboard_app/core/auth/login/models/login_state.dart';
import 'package:thingsboard_app/core/auth/login/provider/login_provider.dart';
import 'package:thingsboard_app/thingsboard_client.dart';

String? bleTerminalAuthRedirect(LoginState login) {
  if (login.isUserLoaded && login.isFullyAuthenticated()) return null;
  if (login.userScope == Authority.PRE_VERIFICATION_TOKEN) {
    return LoginRoutes.login + LoginRoutes.mfaConfirm;
  }
  if (login.userScope == Authority.MFA_CONFIGURATION_TOKEN) {
    return LoginRoutes.login + LoginRoutes.mfaForce;
  }
  return Uri(
    path: LoginRoutes.login,
    queryParameters: {'redirect': BleTerminalRoutes.terminal},
  ).toString();
}

bool isLoginPath(GoRouterState state) {
  return state.uri.pathSegments.contains('login');
}

class AuthRedirect implements Redirect {
  @override
  Future<String?> redirect(
    BuildContext context,
    GoRouterState state,
    Ref ref,
  ) async {
    final login = ref.read(loginProvider);
    final path = state.fullPath;

    if (state.uri.path == BleTerminalRoutes.terminal) {
      return bleTerminalAuthRedirect(login);
    }

    if (path == LoginRoutes.login + LoginRoutes.mfaConfigure) {
      return null;
    }
    if (path == UiUtilsRoutes.qrCodeScan) {
      return null;
    }
    if (path == noAuthPath) {
      return null;
    }
    final loginPath = isLoginPath(state);
    if (!login.isUserLoaded && !loginPath) {
      return '/login${path?.isEmpty == true ? '' : '?redirect=$path'}';
    }

    // if (login.isUserLoaded &&
    //     ![
    //       Authority.PRE_VERIFICATION_TOKEN,
    //       Authority.MFA_CONFIGURATION_TOKEN,
    //     ].contains(login.userScope) &&
    //     isLoginPath(state)) {
    //   final redirect = state.uri.queryParameters['ridirect'];
    //   if (redirect != null && redirect.isNotEmpty) {
    //     return redirect;
    //   }
    //   return '/home';
    // }
    return null;
  }
}
