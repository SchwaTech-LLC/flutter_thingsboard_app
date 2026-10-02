import 'dart:async';
import 'dart:developer';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:thingsboard_app/constants/monohub_instances.dart';
import 'package:thingsboard_app/core/auth/login/models/login_state.dart';
import 'package:thingsboard_app/core/auth/login/provider/oauth_provider.dart';
import 'package:thingsboard_app/core/auth/oauth2/i_oauth2_client.dart';
import 'package:thingsboard_app/generated/l10n.dart';
import 'package:thingsboard_app/locator.dart';
import 'package:thingsboard_app/utils/services/communication/events/user_loaded_event.dart';
import 'package:thingsboard_app/utils/services/communication/i_communication_service.dart';
import 'package:thingsboard_app/utils/services/device_info/i_device_info_service.dart';
import 'package:thingsboard_app/utils/services/endpoint/i_endpoint_service.dart';
import 'package:thingsboard_app/utils/services/firebase/i_firebase_service.dart';
import 'package:thingsboard_app/utils/services/notification_service.dart';
import 'package:thingsboard_app/utils/services/overlay_service/i_overlay_service.dart';
import 'package:thingsboard_app/utils/services/tb_client_service/i_tb_client_service.dart';
import 'package:thingsboard_client/thingsboard_client.dart';

part 'login_provider.g.dart';

@riverpod
class Login extends _$Login {
  final _tbClient = getIt<ITbClientService>().client;
  final _deviceInfoService = getIt<IDeviceInfoService>();
  late final StreamSubscription<UserLoadedEvent> _listener;
  final _overlayService = getIt<IOverlayService>();
  @override
  LoginState build() {
    _listener = getIt<ICommunicationService>().on<UserLoadedEvent>().listen((
      _,
    ) async {
      await handleUserLoaded();
    });
    ref.onDispose(() => _listener.cancel());
    Future(() => handleUserLoaded());
    return const LoginState(isUserLoaded: false);
  }

  Future<void> logout() async {
    if (getIt<IFirebaseService>().apps.isNotEmpty &&
        state.isFullyAuthenticated()) {
      await getIt<NotificationService>().logout();
    }
    await _tbClient.logout(requestConfig: RequestConfig(ignoreErrors: true));
  }

  Future<void> handleUserLoaded() async {
    log('handle user loaded: ${_tbClient.getAuthUser()?.userId}');

    if (!_tbClient.isAuthenticated()) {
      state = const LoginState(isUserLoaded: false);
      return;
    }
    if (_tbClient.isPreVerificationToken() ||
        _tbClient.isMfaConfigurationToken()) {
      state = state.copyWith(
        isUserLoaded: true,
        userScope: _tbClient.getAuthUser()?.authority,
        user: null,
      );
      return;
    }
    await _onFullyLoggedIn();
  }

  Future<bool> login(String email, String password) async {
    try {
      final res = await _tbClient.login(LoginRequest(email, password));
      final user = _tbClient.getAuthUser();
      if (user != null &&
          (user.isMfaConfigurationToken() || user.isPreVerificationToken())) {
        return false;
      }
    } catch (e) {
      return false;
    }
    return true;
  }

  Future<void> selectInstance(String endpoint) async {
    if (!MonoHubInstances.labels.containsKey(endpoint)) {
      throw ArgumentError.value(endpoint, 'endpoint');
    }
    final endpoints = getIt<IEndpointService>();
    final previous = await endpoints.getEndpoint();
    if (previous == endpoint) return;
    await logout();
    try {
      await _tbClient.reInit(endpoint);
      await endpoints.setEndpoint(endpoint);
    } catch (_) {
      await _tbClient.reInit(previous);
      await endpoints.setEndpoint(previous);
      rethrow;
    } finally {
      ref.invalidate(oauthProvider);
    }
  }

  Future<void> loadUser() async {
    final mobileInfo = await _tbClient.getMobileService().getUserMobileInfo(
      MobileInfoQuery(
        platformType: _deviceInfoService.getPlatformType(),
        packageName: _deviceInfoService.getApplicationId(),
      ),
    );

    final userInfo = await _tbClient.getUserService().getUser();
    final lang = userInfo.additionalInfo?['lang'];
    final langStr = lang?.toString();
    final locale = S.delegate.supportedLocales.firstWhereOrNull(
      (l) => l.toString() == langStr || l.languageCode == langStr,
    );

    await S.load(locale ?? const Locale('en'));

    state = state.copyWith(
      isUserLoaded: true,
      user: userInfo,
      userScope: userInfo.authority,
      mobileLoginInfo: mobileInfo,
    );
  }

  Future<void> _onFullyLoggedIn() async {
    await loadUser();
    if (getIt<IFirebaseService>().apps.isNotEmpty) {
      try {
        await getIt<NotificationService>().init();
      } catch (e) {
        log('Push notification registration failed', error: e);
        _overlayService.showErrorNotification(
          (_) =>
              'Push notifications could not be enabled. Please log out and sign in again to retry.',
        );
      }
    }
  }

  Future<void> twoFaConfirmed(LoginResponse response) async {
    await _onFullyLoggedIn();
  }

  Future<bool> oauthLogin(String url) async {
    try {
      final result = await getIt<IOAuth2Client>().authenticate(url);
      if (result.success) {
        await _tbClient.setUserFromJwtToken(
          result.accessToken,
          result.refreshToken,
          true,
        );
        return true;
      } else {
        _overlayService.showErrorNotification((_) => result.error!);
      }
    } catch (e) {
      _overlayService.showErrorNotification((_) => e.toString());
    }
    return false;
  }
}
