import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:thingsboard_app/generated/l10n.dart';
import 'package:thingsboard_app/modules/version/android_apk_update.dart';
import 'package:url_launcher/url_launcher.dart';

class AndroidApkUpdateButton extends ConsumerWidget {
  const AndroidApkUpdateButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(androidApkUpdateProvider).asData?.value;
    if (update == null) return const SizedBox.shrink();

    return OutlinedButton.icon(
      icon: const Icon(Icons.system_update),
      label: Text(S.of(context).updateTo(update.version)),
      onPressed: () async {
        try {
          if (await launchUrl(
            update.downloadUrl,
            mode: LaunchMode.externalApplication,
          )) {
            return;
          }
        } on Exception {
          // Show the same error when no browser handled the URL.
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).apkDownloadFailed)),
          );
        }
      },
    );
  }
}
