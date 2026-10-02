import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:thingsboard_app/constants/monohub_instances.dart';
import 'package:thingsboard_app/core/auth/login/provider/oauth_provider.dart';
import 'package:thingsboard_app/core/auth/login/widgets/login_widget.dart';
import 'package:thingsboard_app/generated/l10n.dart';
import 'package:thingsboard_app/locator.dart';
import 'package:thingsboard_app/utils/services/endpoint/i_endpoint_service.dart';
import 'package:thingsboard_client/thingsboard_client.dart';

class Endpoints extends Mock implements IEndpointService {}

void main() {
  testWidgets(
    'both instances are available on a small login screen without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final endpoints = Endpoints();
      final changes = ValueNotifier<String?>(null);
      when(() => endpoints.listenEndpointChanges).thenReturn(changes);
      when(
        () => endpoints.getCachedEndpoint(),
      ).thenReturn(MonoHubInstances.development);
      getIt.registerSingleton<IEndpointService>(endpoints);
      addTearDown(() async {
        await getIt.reset();
        changes.dispose();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            oauthProvider.overrideWith(
              (ref) => const LoginMobileInfo(
                oAuth2Clients: [],
                storeInfo: null,
                versionInfo: null,
              ),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: [S.delegate],
            home: Scaffold(body: LoginWidget()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.text('MonoHub — Production'), findsNothing);
      expect(find.text('MonoHub — Development'), findsNothing);
      await tester.tap(find.byTooltip('Connection settings'));
      await tester.pumpAndSettle();
      expect(find.text('MonoHub — Production'), findsWidgets);
      expect(find.text('MonoHub — Development'), findsWidgets);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
