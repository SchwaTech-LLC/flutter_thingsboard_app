import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:thingsboard_app/config/routes/router.dart';
import 'package:thingsboard_app/config/themes/app_colors.dart';
import 'package:thingsboard_app/constants/monohub_instances.dart';
import 'package:thingsboard_app/core/logger/tb_logger.dart';
import 'package:thingsboard_app/locator.dart';
import 'package:thingsboard_app/modules/notification/service/i_notifications_local_service.dart';
import 'package:thingsboard_app/modules/notification/service/notifications_local_service.dart';
import 'package:thingsboard_app/thingsboard_client.dart';
import 'package:thingsboard_app/utils/services/endpoint/i_endpoint_service.dart';
import 'package:thingsboard_app/utils/services/tb_client_service/i_tb_client_service.dart';
import 'package:thingsboard_app/utils/utils.dart';

class NotificationService {
  static FirebaseMessaging _messaging = FirebaseMessaging.instance;
  late NotificationDetails _notificationDetails;
  final TbLogger _log = getIt();
  final ThingsboardClient _tbClient = getIt<ITbClientService>().client;
  final INotificationsLocalService _localService = NotificationsLocalService();
  StreamSubscription? _foregroundMessageSubscription;
  StreamSubscription? _onMessageOpenedAppSubscription;
  StreamSubscription? _onTokenRefreshSubscription;

  String? _fcmToken;
  Future<void> _pending = Future.value();

  Future<void> _serialize(Future<void> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.catchError((Object error) {
      _log.error("Notification setup failed", error);
    });
    return next;
  }

  Future<void> _cancelListeners() async {
    await _foregroundMessageSubscription?.cancel();
    await _onMessageOpenedAppSubscription?.cancel();
    await _onTokenRefreshSubscription?.cancel();
  }

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  Future<void> init() => _serialize(_initialize);

  Future<void> _initialize() async {
    await _cancelListeners();
    // Development push remains disabled until its server is configured.
    if (await getIt<IEndpointService>().getEndpoint() !=
            MonoHubInstances.production ||
        !_tbClient.isAuthenticated()) {
      return;
    }
    await _initFlutterLocalNotificationsPlugin();
    _log.debug('NotificationService::init()');

    final message = await FirebaseMessaging.instance.getInitialMessage();
    if (message != null) {
      NotificationService.handleClickOnNotification(message.data);
    }

    _onMessageOpenedAppSubscription = FirebaseMessaging.onMessageOpenedApp
        .listen((message) {
          NotificationService.handleClickOnNotification(message.data);
        });

    final settings = await _requestPermission();
    _log.debug(
      'Notification authorizationStatus: ${settings.authorizationStatus}',
    );
    if (settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional) {
      await _configFirebaseMessaging();
      await _getAndSaveToken();

      _onTokenRefreshSubscription = _messaging.onTokenRefresh.listen((token) {
        unawaited(
          _serialize(() async {
            if (!_tbClient.isAuthenticated() ||
                await getIt<IEndpointService>().getEndpoint() !=
                    MonoHubInstances.production) {
              return;
            }
            final previous = _fcmToken;
            if (previous != null && previous != token) {
              await _tbClient.getUserService().removeMobileSession(
                previous,
                requestConfig: RequestConfig(ignoreErrors: true),
              );
            }
            await _saveToken(token);
            _fcmToken = token;
          }).catchError((Object error) {
            _log.error('Notification token refresh failed', error);
          }),
        );
      });

      _subscribeOnForegroundMessage();
      await updateNotificationsCount();
    }
  }

  Future<void> updateNotificationsCount() async {
    final localService = NotificationsLocalService();

    await localService.updateNotificationsCount(
      await _getNotificationsCountRemote(),
    );
  }

  Future<String?> getToken() async {
    try {
      return _fcmToken = await _messaging.getToken();
    } catch (_) {
      return null;
    }
  }

  Future<RemoteMessage?> initialMessage() {
    return _messaging.getInitialMessage();
  }

  Future<void> logout() => _serialize(_logout);

  Future<void> _logout() async {
    await _cancelListeners();
    getIt<TbLogger>().debug('NotificationService::logout()');
    if (_fcmToken != null) {
      getIt<TbLogger>().debug(
        'NotificationService::logout() removeMobileSession',
      );
      await _tbClient.getUserService().removeMobileSession(
        _fcmToken!,
        requestConfig: RequestConfig(ignoreErrors: true),
      );
    }

    await _messaging.setAutoInitEnabled(false);
    await _messaging.deleteToken();
    _fcmToken = null;
    await flutterLocalNotificationsPlugin.cancelAll();
    await _localService.clearNotificationBadgeCount();
  }

  Future<void> _configFirebaseMessaging() async {
    await _messaging.setAutoInitEnabled(true);
  }

  Future<void> _initFlutterLocalNotificationsPlugin() async {
    const initializationSettingsAndroid = AndroidInitializationSettings(
      '@drawable/ic_launcher_foreground',
    );

    const initializationSettingsIOS = DarwinInitializationSettings();

    const initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (response) {
        if (response.notificationResponseType ==
            NotificationResponseType.selectedNotification) {
          final data =
              json.decode(response.payload ?? '') as Map<String, dynamic>;
          handleClickOnNotification(data);
        }
      },
    );

    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      color: AppColors.appPrimaryColor,
      'general',
      // translate-me-ignore-next-line
      'General notifications',
      importance: Importance.max,
      priority: Priority.high,
      // translate-me-ignore-next-line
      channelDescription: 'This channel is used for general notifications',
      showWhen: false,
    );

    const iOSPlatformChannelSpecifics = DarwinNotificationDetails();

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            'general',
            'General notifications',
            description: 'This channel is used for general notifications',
            importance: Importance.max,
          ),
        );

    _notificationDetails = NotificationDetails(
      android: androidPlatformChannelSpecifics,
      iOS: iOSPlatformChannelSpecifics,
    );
  }

  Future<NotificationSettings> _requestPermission() async {
    _messaging = FirebaseMessaging.instance;
    final result = await _messaging.requestPermission(provisional: true);

    if (result.authorizationStatus == AuthorizationStatus.denied) {
      return result;
    }

    return result;
  }

  Future<String?> _resetToken(String? token) async {
    if (token != null) {
      await _tbClient.getUserService().removeMobileSession(token);
    }

    await _messaging.deleteToken();
    return await getToken();
  }

  Future<void> _getAndSaveToken() async {
    String? fcmToken = await getToken();
    if (fcmToken == null) {
      throw StateError(
        'Firebase could not obtain a device notification token.',
      );
    }
    _log.debug('FCM token available');

    final MobileSessionInfo? mobileInfo = await _tbClient
        .getUserService()
        .getMobileSession(fcmToken);
    if (mobileInfo != null) {
      final int timeAfterCreatedToken =
          DateTime.now().millisecondsSinceEpoch - mobileInfo.fcmTokenTimestamp;
      if (timeAfterCreatedToken > const Duration(days: 30).inMilliseconds) {
        fcmToken = await _resetToken(fcmToken);
        if (fcmToken != null) {
          await _saveToken(fcmToken);
        }
      }
    } else {
      await _saveToken(fcmToken);
    }
  }

  Future<void> _saveToken(String token) async {
    await _tbClient.getUserService().saveMobileSession(
      token,
      MobileSessionInfo(DateTime.now().millisecondsSinceEpoch),
    );
  }

  Future<void> showNotification(RemoteMessage message) async {
    final notification = message.notification;

    if (notification != null) {
      flutterLocalNotificationsPlugin.show(
        notification.hashCode,
        notification.title,
        notification.body,
        _notificationDetails,
        payload: json.encode(message.data),
      );

      _localService.increaseNotificationBadgeCount();
    }
  }

  void _subscribeOnForegroundMessage() {
    _foregroundMessageSubscription = FirebaseMessaging.onMessage.listen((
      message,
    ) {
      _log.debug('Message:$message');
      if (message.sentTime == null) {
        final map = message.toMap();
        map['sentTime'] = DateTime.now().millisecondsSinceEpoch;
        showNotification(RemoteMessage.fromMap(map));
      } else {
        showNotification(message);
      }
    });
  }

  static void handleClickOnNotification(
    Map<String, dynamic> data, {
    bool isOnNotificationsScreenAlready = false,
  }) {
    if (data['enabled'] == true || data['onClick.enabled'] == 'true') {
      switch (data['linkType'] ?? data['onClick.linkType']) {
        case 'DASHBOARD':
          String? dashboardId;
          if ((data['dashboardId'] ?? data['onClick.dashboardId']) != null) {
            dashboardId =
                (data['dashboardId'] ?? data['onClick.dashboardId']).toString();
          }
          EntityId? entityId;
          if ((data['stateEntityId'] ?? data['onClick.stateEntityId']) !=
                  null &&
              (data['stateEntityType'] ?? data['onClick.stateEntityType']) !=
                  null) {
            entityId = EntityId.fromTypeAndUuid(
              entityTypeFromString(
                (data['stateEntityType'] ?? data['onClick.stateEntityType'])
                    .toString(),
              ),
              (data['stateEntityId'] ?? data['onClick.stateEntityId'])
                  .toString(),
            );
          }

          final state = Utils.createDashboardEntityState(
            entityId,
            stateId:
                (data['dashboardState'] ?? data['onClick.dashboardState'])
                    .toString(),
          );

          if (dashboardId != null) {
            getIt<ThingsboardAppRouter>().navigateToDashboard(
              dashboardId,
              state: state,
            );
          }

        case 'LINK':
          final rawLink = data['link'] ?? data['onClick.link'];
          if (rawLink != null) {
            final link = (data['link'] ?? data['onClick.link']).toString();
            if (Uri.parse(link).isAbsolute) {
              getIt<ThingsboardAppRouter>().navigateTo(
                '/url/${Uri.encodeComponent(link)}',
              );
            } else if (link == '/notifications' &&
                !isOnNotificationsScreenAlready) {
              getIt<ThingsboardAppRouter>().navigateTo(link);
            } else {
              getIt<ThingsboardAppRouter>().navigateTo(link);
            }
          }
      }
    } else {
      if (!isOnNotificationsScreenAlready) {
        getIt<ThingsboardAppRouter>().navigateTo('/notifications');
      }
    }
  }

  Future<int> _getNotificationsCountRemote() async {
    try {
      return _tbClient.getNotificationService().getUnreadNotificationsCount(
        'MOBILE_APP',
        requestConfig: RequestConfig(ignoreErrors: true),
      );
    } catch (_) {
      return 0;
    }
  }
}
