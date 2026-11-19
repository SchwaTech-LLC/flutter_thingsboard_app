import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:thingsboard_app/modules/version/android_apk_update.dart';

const _apk = 'https://monohub-dev.schwatech.com/downloads/monohub-1.10.0.apk';

MockClient _release(String version, String notes) => MockClient(
  (_) async => http.Response(
    jsonEncode({
      'versionInfo': {
        'latestVersion': version,
        'latestVersionReleaseNotes': notes,
      },
    }),
    200,
  ),
);

Future<AndroidApkUpdate?> _check(http.Client client) {
  addTearDown(client.close);
  return fetchAndroidApkUpdate(
    client,
    packageName: 'com.schwatech.monohub.dev',
    installedVersion: '1.9.9',
  );
}

void main() {
  test('reads MonoHub Dev Android metadata without authentication', () async {
    final release = _release('1.10.0', '<p><a href="$_apk">Download</a></p>');
    addTearDown(release.close);
    final update = await _check(
      MockClient((request) {
        expect(request.url.origin, 'https://monohub-dev.schwatech.com');
        expect(request.url.path, '/api/noauth/mobile');
        expect(request.url.queryParameters, {
          'pkgName': 'com.schwatech.monohub.dev',
          'platform': 'ANDROID',
        });
        expect(request.followRedirects, isFalse);
        expect(request.headers, isEmpty);
        return release.get(request.url);
      }),
    );
    expect(update?.version, '1.10.0');
    expect(update?.downloadUrl, Uri.parse(_apk));
  });

  test('only a newer release with a trusted APK link is offered', () async {
    for (final version in ['1.9.9', '1.9.8', '1.10.0-preview']) {
      expect(
        await _check(_release(version, '<a href="$_apk">APK</a>')),
        isNull,
      );
    }
    for (final link in [
      'http://monohub-dev.schwatech.com/downloads/app.apk',
      'https://monohub-dev.schwatech.com.example.org/downloads/app.apk',
      'https://monohub-dev.schwatech.com/api/app.apk',
      'https://monohub-dev.schwatech.com/downloads/app.html',
    ]) {
      expect(
        await _check(_release('1.10.0', '<a href="$link">APK</a>')),
        isNull,
      );
    }
  });

  test('an unavailable or incomplete feed leaves the app usable', () async {
    expect(
      await _check(MockClient((_) async => http.Response('Unavailable', 503))),
      isNull,
    );
    expect(await _check(_release('', '')), isNull);
  });
}
