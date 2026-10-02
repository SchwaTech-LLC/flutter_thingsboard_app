import 'package:event_bus/event_bus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:thingsboard_app/constants/monohub_instances.dart';
import 'package:thingsboard_app/core/auth/login/provider/login_provider.dart';
import 'package:thingsboard_app/locator.dart';
import 'package:thingsboard_app/utils/services/communication/communication_service.dart';
import 'package:thingsboard_app/utils/services/communication/i_communication_service.dart';
import 'package:thingsboard_app/utils/services/device_info/i_device_info_service.dart';
import 'package:thingsboard_app/utils/services/endpoint/i_endpoint_service.dart';
import 'package:thingsboard_app/utils/services/firebase/i_firebase_service.dart';
import 'package:thingsboard_app/utils/services/overlay_service/i_overlay_service.dart';
import 'package:thingsboard_app/utils/services/tb_client_service/i_tb_client_service.dart';
import 'package:thingsboard_client/thingsboard_client.dart';

class Client extends Mock implements ThingsboardClient {}

class ClientService extends Mock implements ITbClientService {}

class Endpoints extends Mock implements IEndpointService {}

class Device extends Mock implements IDeviceInfoService {}

class Firebase extends Mock implements IFirebaseService {}

class Overlay extends Mock implements IOverlayService {}

void main() {
  late Client client;
  late Endpoints endpoints;
  late ProviderContainer container;
  late List<String> operations;

  setUp(() {
    client = Client();
    endpoints = Endpoints();
    operations = [];
    final service = ClientService();
    final firebase = Firebase();
    when(() => service.client).thenReturn(client);
    when(() => firebase.apps).thenReturn([]);
    when(() => client.isAuthenticated()).thenReturn(false);
    when(
      () => endpoints.getEndpoint(),
    ).thenAnswer((_) async => MonoHubInstances.development);
    when(
      () => client.logout(requestConfig: any(named: 'requestConfig')),
    ).thenAnswer((_) async {
      operations.add('logout');
    });
    when(() => client.reInit(any())).thenAnswer((call) async {
      operations.add('client:${call.positionalArguments.first}');
    });
    when(() => endpoints.setEndpoint(any())).thenAnswer((call) async {
      operations.add('save:${call.positionalArguments.first}');
    });
    getIt.registerSingleton<ITbClientService>(service);
    getIt.registerSingleton<IEndpointService>(endpoints);
    getIt.registerSingleton<IDeviceInfoService>(Device());
    getIt.registerSingleton<IFirebaseService>(firebase);
    getIt.registerSingleton<IOverlayService>(Overlay());
    getIt.registerSingleton<ICommunicationService>(
      CommunicationService(EventBus()),
    );
    container = ProviderContainer();
    container.listen(loginProvider, (_, _) {});
  });

  tearDown(() async {
    // Let the provider's initial user-loading task finish before disposal.
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    await getIt.reset();
  });

  test(
    'clears old session before moving client and saving selection',
    () async {
      await container
          .read(loginProvider.notifier)
          .selectInstance(MonoHubInstances.production);
      expect(operations, [
        'logout',
        'client:${MonoHubInstances.production}',
        'save:${MonoHubInstances.production}',
      ]);
    },
  );

  test('selecting the current instance does not log out', () async {
    await container
        .read(loginProvider.notifier)
        .selectInstance(MonoHubInstances.development);
    expect(operations, isEmpty);
  });

  test('failed switch restores the previous endpoint', () async {
    when(
      () => client.reInit(MonoHubInstances.production),
    ).thenThrow(StateError('failed'));
    await expectLater(
      container
          .read(loginProvider.notifier)
          .selectInstance(MonoHubInstances.production),
      throwsStateError,
    );
    expect(operations, [
      'logout',
      'client:${MonoHubInstances.development}',
      'save:${MonoHubInstances.development}',
    ]);
  });

  test('rejects unknown servers before touching the session', () async {
    await expectLater(
      container
          .read(loginProvider.notifier)
          .selectInstance('https://other.example'),
      throwsArgumentError,
    );
    expect(operations, isEmpty);
  });
}
