import 'package:firebase_core/firebase_core.dart';
import 'package:thingsboard_app/core/logger/tb_logger.dart';
import 'package:thingsboard_app/utils/services/endpoint/i_endpoint_service.dart';
import 'package:thingsboard_app/utils/services/firebase/i_firebase_service.dart';

class FirebaseService implements IFirebaseService {
  FirebaseService({required this.logger, required this.endpointService});

  final TbLogger logger;
  final _apps = <String>[];
  final IEndpointService endpointService;

  @override
  List<String> get apps => _apps;

  @override
  Future<FirebaseApp?> initializeApp({
    String name = defaultFirebaseAppName,
    FirebaseOptions? options,
  }) async {
    logger.debug('FirebaseService::initializeApp(name: $name)');

    try {
      final app = await Firebase.initializeApp(options: options, name: name);
      if (!_apps.contains(name)) _apps.add(name);

      return app;
    } catch (e) {
      logger.error('FirebaseService:initializeApp $e');
    }

    return null;
  }

  @override
  Future<void> clearApps() async {
    try {
      for (final app in Firebase.apps) {
        await app.delete();
      }
    } catch (e) {
      logger.error('FirebaseService:clearApps $e');
    } finally {
      _apps.clear();
    }
  }

  @override
  Future<void> removeApp({String name = defaultFirebaseAppName}) async {
    try {
      await Firebase.app(name).delete();
    } catch (e) {
      logger.error('FirebaseService:removeApp $e');
    } finally {
      _apps.remove(name);
    }
  }
}
