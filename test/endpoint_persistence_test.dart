import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:thingsboard_app/constants/monohub_instances.dart';
import 'package:thingsboard_app/core/select_region/model/region.dart';
import 'package:thingsboard_app/utils/services/endpoint/endpoint_service.dart';
import 'package:thingsboard_app/utils/services/local_database/i_local_database_service.dart';

class Database extends Mock implements ILocalDatabaseService {}

void main() {
  test('fresh install defaults to production', () async {
    final database = Database();
    when(() => database.getSelectedEndpoint()).thenAnswer((_) async => null);
    final endpoints = EndpointService(databaseService: database);
    expect(endpoints.getCachedEndpoint(), MonoHubInstances.production);
    expect(await endpoints.getEndpoint(), MonoHubInstances.production);
  });

  test(
    'selection is persisted before notification and restored on restart',
    () async {
      final database = Database();
      String? saved;
      when(() => database.getSelectedEndpoint()).thenAnswer((_) async => saved);
      when(
        () => database.saveSelectedRegion(Region.custom),
      ).thenAnswer((_) async {});
      when(() => database.setSelectedEndpoint(any())).thenAnswer((call) async {
        saved = call.positionalArguments.first as String;
      });
      final endpoints = EndpointService(databaseService: database);
      var notified = false;
      endpoints.listenEndpointChanges.addListener(() {
        notified = true;
        expect(saved, MonoHubInstances.production);
        expect(endpoints.getCachedEndpoint(), saved);
      });
      await endpoints.setEndpoint(MonoHubInstances.production);
      expect(notified, isTrue);
      final restarted = EndpointService(databaseService: database);
      expect(await restarted.getEndpoint(), MonoHubInstances.production);
    },
  );
}
