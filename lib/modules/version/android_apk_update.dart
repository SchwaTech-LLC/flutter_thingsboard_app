import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:thingsboard_app/constants/monohub_instances.dart';
import 'package:thingsboard_app/locator.dart';
import 'package:thingsboard_app/utils/services/device_info/i_device_info_service.dart';

final androidApkUpdateProvider = FutureProvider.autoDispose<AndroidApkUpdate?>((
  ref,
) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;

  final device = getIt<IDeviceInfoService>();
  final client = http.Client();
  ref.onDispose(client.close);
  return fetchAndroidApkUpdate(
    client,
    packageName: device.getApplicationId(),
    installedVersion: device.getAppVersion().versionString(),
  );
});

class AndroidApkUpdate {
  const AndroidApkUpdate(this.version, this.downloadUrl);

  final String version;
  final Uri downloadUrl;
}

Future<AndroidApkUpdate?> fetchAndroidApkUpdate(
  http.Client client, {
  required String packageName,
  required String installedVersion,
}) async {
  final origin = Uri.parse(MonoHubInstances.development);
  final request = http.Request(
    'GET',
    origin.replace(
      path: '/api/noauth/mobile',
      queryParameters: {'pkgName': packageName, 'platform': 'ANDROID'},
    ),
  )..followRedirects = false;

  try {
    final response = await client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) return null;
    final mobileInfo = jsonDecode(utf8.decode(response.bodyBytes));
    if (mobileInfo is! Map<String, dynamic>) return null;
    final versionInfo = mobileInfo['versionInfo'];
    if (versionInfo is! Map<String, dynamic>) return null;
    final latest = versionInfo['latestVersion'];
    final notes = versionInfo['latestVersionReleaseNotes'];
    if (latest is! String ||
        notes is! String ||
        !_isNewer(latest, installedVersion)) {
      return null;
    }

    // Mobile Center reserves the store link for Google Play. Use an APK
    // hyperlink in the latest version's release notes.
    for (final link in html.parseFragment(notes).querySelectorAll('a[href]')) {
      final url = Uri.tryParse(link.attributes['href']!);
      if (url != null &&
          url.scheme == 'https' &&
          url.host == origin.host &&
          url.port == origin.port &&
          url.userInfo.isEmpty &&
          url.path.startsWith('/downloads/') &&
          url.path.endsWith('.apk')) {
        return AndroidApkUpdate(latest, url);
      }
    }
  } on Exception {
    // An unavailable release feed must not interrupt login.
  }
  return null;
}

final _releaseVersion = RegExp(r'^([0-9]+)\.([0-9]+)\.([0-9]+)$');

bool _isNewer(String latest, String installed) {
  final next = _releaseVersion.firstMatch(latest);
  final current = _releaseVersion.firstMatch(installed);
  if (next == null || current == null) return false;

  for (var component = 1; component <= 3; component++) {
    final nextPart = int.tryParse(next.group(component)!);
    final currentPart = int.tryParse(current.group(component)!);
    if (nextPart == null || currentPart == null) return false;
    if (nextPart != currentPart) return nextPart > currentPart;
  }
  return false;
}
