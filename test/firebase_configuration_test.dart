import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:thingsboard_app/firebase_options.dart';

void main() {
  test('Android Firebase options match the registered application', () {
    final config =
        jsonDecode(File('android/app/google-services.json').readAsStringSync())
            as Map<String, dynamic>;
    final client = (config['client'] as List).single as Map<String, dynamic>;
    final clientInfo = client['client_info'] as Map<String, dynamic>;
    final androidInfo =
        clientInfo['android_client_info'] as Map<String, dynamic>;
    final apiKey = (client['api_key'] as List).single as Map<String, dynamic>;
    final projectInfo = config['project_info'] as Map<String, dynamic>;
    expect(androidInfo['package_name'], 'com.schwatech.monohub.dev');
    expect(
      DefaultFirebaseOptions.android.appId,
      clientInfo['mobilesdk_app_id'],
    );
    expect(DefaultFirebaseOptions.android.apiKey, apiKey['current_key']);
    expect(DefaultFirebaseOptions.android.projectId, projectInfo['project_id']);
    expect(
      DefaultFirebaseOptions.android.messagingSenderId,
      projectInfo['project_number'],
    );
    expect(config.containsKey('private_key'), isFalse);
  });
}
