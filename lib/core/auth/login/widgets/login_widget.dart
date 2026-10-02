import 'package:fluro/fluro.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:thingsboard_app/config/routes/router.dart';
import 'package:thingsboard_app/config/themes/tb_text_styles.dart';
import 'package:thingsboard_app/constants/monohub_instances.dart';
import 'package:thingsboard_app/core/auth/login/provider/login_provider.dart';
import 'package:thingsboard_app/core/auth/login/provider/oauth_provider.dart';
import 'package:thingsboard_app/core/auth/login/widgets/footer/login_footer.dart';
import 'package:thingsboard_app/core/auth/login/widgets/full_screen_loader.dart';
import 'package:thingsboard_app/core/auth/login/widgets/header/login_header.dart';
import 'package:thingsboard_app/core/auth/login/widgets/o_auth_buttons.dart';
import 'package:thingsboard_app/core/auth/login/widgets/text_divider.dart';
import 'package:thingsboard_app/core/auth/login/widgets/text_field.dart';
import 'package:thingsboard_app/core/logger/tb_logger.dart';
import 'package:thingsboard_app/generated/l10n.dart';
import 'package:thingsboard_app/locator.dart';
import 'package:thingsboard_app/thingsboard_client.dart';
import 'package:thingsboard_app/utils/services/endpoint/i_endpoint_service.dart';
import 'package:thingsboard_app/utils/ui/visibility_widget.dart';

class LoginWidget extends HookConsumerWidget {
  const LoginWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = useState(true);
    final switching = useState(false);
    final endpoints = getIt<IEndpointService>();
    useListenable(endpoints.listenEndpointChanges);
    final endpoint = endpoints.getCachedEndpoint();
    final providers = ref.watch(oauthProvider);
    final form = useMemoized(
      () => FormGroup({
        "email": FormControl(
          validators: [Validators.required, Validators.email],
        ),
        "password": FormControl(validators: [Validators.required]),
      }),
    );
    useEffect(() {
      if (providers is! AsyncLoading) {
        loading.value = false;
      }
      return null;
    }, [providers]);
    final mediaQuery = MediaQuery.of(context);
    return Stack(
      children: [
        ReactiveForm(
          formGroup: form,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight:
                        mediaQuery.size.height -
                        mediaQuery.padding.top -
                        mediaQuery.padding.bottom -
                        kToolbarHeight,
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      spacing: 16,
                      children: [
                        Align(
                          alignment: Alignment.topRight,
                          child: IconButton(
                            tooltip: 'Connection settings',
                            icon: const Icon(Icons.settings_outlined),
                            onPressed:
                                loading.value || switching.value
                                    ? null
                                    : () async {
                                      FocusScope.of(context).unfocus();
                                      final value = await showDialog<String>(
                                        context: context,
                                        builder:
                                            (dialogContext) => SimpleDialog(
                                              title: const Text(
                                                'Server connection',
                                              ),
                                              children: [
                                                for (final entry
                                                    in MonoHubInstances
                                                        .labels
                                                        .entries)
                                                  RadioListTile<String>(
                                                    title: Text(entry.value),
                                                    subtitle: Text(entry.key),
                                                    value: entry.key,
                                                    groupValue: endpoint,
                                                    onChanged:
                                                        (value) => Navigator.of(
                                                          dialogContext,
                                                        ).pop(value),
                                                  ),
                                              ],
                                            ),
                                      );
                                      if (!context.mounted ||
                                          value == null ||
                                          value == endpoint) {
                                        return;
                                      }
                                      switching.value = true;
                                      form.reset();
                                      try {
                                        await ref
                                            .read(loginProvider.notifier)
                                            .selectInstance(value);
                                      } catch (_) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Could not switch instance. Please try again.',
                                              ),
                                            ),
                                          );
                                        }
                                      } finally {
                                        if (context.mounted) {
                                          switching.value = false;
                                        }
                                      }
                                    },
                          ),
                        ),
                        const LoginHeader(),
                        Text(
                          S.of(context).loginToYourAccount,
                          style: TbTextStyles.titleMedium,
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 32),
                          child: AutofillGroup(
                            child: Column(
                              spacing: 12,
                              children: [
                                Text(
                                  S.of(context).loginWith.toUpperCase(),
                                  style: TbTextStyles.labelMedium.copyWith(
                                    fontWeight: FontWeight.w400,
                                    fontFamily: 'Roboto',
                                    letterSpacing: 0.4,
                                  ),
                                ),
                                OAuthButtons(
                                  onButtonPressed:
                                      (client) => onOauth2ButtonPressed(
                                        client,
                                        context,
                                        loading,
                                        ref,
                                      ),
                                  clients: providers.value?.oAuth2Clients ?? [],
                                ),
                                TextDivider(text: S.of(context).or),

                                Column(
                                  spacing: 24,
                                  children: [
                                    TbTextField(
                                      formControlName: "email",
                                      label: S.of(context).email,
                                      hint: S.of(context).email,
                                      autoFillHints: const [
                                        AutofillHints.email,
                                      ],
                                    ),
                                    TbTextField(
                                      formControlName: "password",
                                      label: S.of(context).password,
                                      hint: S.of(context).password,
                                      obscureText: true,
                                      autoFillHints: const [
                                        AutofillHints.password,
                                      ],
                                    ),
                                  ],
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: () => onForgotPassword(context),
                                    child: Text(
                                      S.of(context).passwordForgotText,
                                      style: TbTextStyles.labelSmall,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: ReactiveFormConsumer(
                            builder: (context, formGroup, child) {
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 12,
                                        ),
                                      ),
                                      onPressed:
                                          formGroup.invalid && formGroup.touched
                                              ? null
                                              : () async {
                                                await onLoginPressed(
                                                  context,
                                                  form,
                                                  ref,
                                                  loading,
                                                );
                                              },
                                      child: Text(
                                        S.of(context).login,
                                        style: TbTextStyles.labelMedium,
                                      ),
                                    ),
                                  ),
                                  const LoginFooter(),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        AnimatedVisibilityWidget(
          show: switching.value || loading.value || providers is AsyncLoading,
          child: const FullScreenLoader(),
        ),
      ],
    );
  }
}

Future<void> onLoginPressed(
  BuildContext context,
  FormGroup form,
  WidgetRef ref,
  ValueNotifier<bool> loading,
) async {
  FocusScope.of(context).unfocus();
  form.markAllAsTouched();
  if (form.invalid) {
    return;
  }
  final String username = form.control('email').value.toString();
  final String password = form.control('password').value.toString();
  try {
    loading.value = true;
    final res = await ref
        .read(loginProvider.notifier)
        .login(username, password);

    loading.value = res;
  } catch (e) {
    form.setErrors({"err": {}});
  }
}

Future<void> onLoginWithBarcode(BuildContext context) async {
  try {
    final Barcode? barcode = await getIt<ThingsboardAppRouter>().navigateTo(
      '/qrCodeScan',
      transition: TransitionType.nativeModal,
    );

    if (barcode != null && barcode.rawValue != null) {
      getIt<ThingsboardAppRouter>().navigateByAppLink(barcode.rawValue);
    }
  } catch (e) {
    getIt<TbLogger>().error('Login with qr code error', e);
  }
}

Future<void> onOauth2ButtonPressed(
  OAuth2ClientInfo client,
  BuildContext context,
  ValueNotifier<bool> loading,
  WidgetRef ref,
) async {
  FocusScope.of(context).unfocus();
  if (client.name == 'qr') {
    await onLoginWithBarcode(context);
    return;
  }
  loading.value = true;
  final res = await ref.read(loginProvider.notifier).oauthLogin(client.url);
  loading.value = res;
}

Future<void> onForgotPassword(BuildContext context) async {
  context.push('/login/resetPasswordRequest');
}
