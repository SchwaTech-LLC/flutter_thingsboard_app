## [ThingsBoard Mobile Application](https://thingsboard.io/products/mobile/) is an open-source project based on [Flutter](https://flutter.dev/)
Powered by [ThingsBoard](https://thingsboard.io) IoT Platform

Build your own IoT mobile application **with minimum coding efforts**

## Please be informed the Web platform is not supported, because it's a part of our main platform!

## Resources

- [Getting started](https://thingsboard.io/docs/mobile/getting-started/) - learn how to set up and run your first IoT mobile app
- [Customize your app](https://thingsboard.io/docs/mobile/customization/) - learn how to customize the app
- [Publish your app](https://thingsboard.io/docs/mobile/release/) - learn how to publish app to Google Play or App Store

## Live demo app

To be familiar with common app features try out our ThingsBoard Live mobile application available on Google Play and App Store
- [Get it on Google Play](https://play.google.com/store/apps/details?id=org.thingsboard.demo.app&pcampaignid=pcampaignidMKT-Other-global-all-co-prtnr-py-PartBadge-Mar2515-1)
- [Download on the App Store](https://apps.apple.com/us/app/thingsboard-live/id1594355695?itsct=apps_box_badge&amp;itscg=30200)

## Local instance setup

Fresh installations default to production. The top-right connection settings icon on the login screen opens a dialog offering MonoHub Production (`https://monohub.schwatech.com`) and Development (`https://monohub-dev.schwatech.com`). The selection is remembered; log out to change servers. Switching clears the session and login form before changing the API endpoint. Both domains are registered for QR app links; each server must publish the matching Android signing fingerprint (and Apple association for iOS). The existing application ID is retained so this build can update the installed development app. Register that same ID in both ThingsBoard Mobile Centers. Username/password login needs no OAuth secret; the existing development OAuth secret must not be reused for production OAuth.

This repository is pinned to Flutter 3.29.0 and Dart 3.7 or newer. On Windows, install Flutter 3.29.0, Java 17, and the Android SDK with platform 35 and build-tools 35.0.0. Then verify the toolchain with:

```powershell
flutter doctor
```

Create a local, ignored instance configuration:

```powershell
Copy-Item config\thingsboard.local.example.json config\thingsboard.local.json
```

Edit `config\thingsboard.local.json`. The minimum value is `thingsboardApiEndpoint`, for example `https://tb.example.com` (do not append `/api`). The helper also uses the app name, Android/iOS application IDs, and app-link host to configure the native shells.

Prepare the local iOS xcconfig and run or build Android with:

```powershell
.\tool\prepare-thingsboard.ps1
.\tool\run-thingsboard.ps1 -Device <android-device-id>
.\tool\run-thingsboard.ps1 -BuildApk -Mode release
```

The app reads the same JSON through Flutter's `--dart-define-from-file`; the local file is ignored so OAuth app secrets are not committed. `thingsboardAndroidAppSecret` and `thingsboardIosAppSecret` are only needed when the instance uses the mobile OAuth/SSO flow. The example uses the existing Android package ID `com.schwatech.monohub.dev`, which matches the checked-in public Firebase client configuration. Changing that ID requires a matching Firebase registration.

Android push notifications are configured for production and were verified on a phone. Development push remains disabled; iOS Firebase is not configured. Automatic alarm notifications require Mobile app delivery in the corresponding ThingsBoard notification rules. Firebase administrator private keys belong only on the server, never in Git or the APK.

The APK helper disables icon tree shaking because the app uses dynamic icons. Release builds currently use the local debug signing key for testing; store distribution requires proper release signing. QR app-link domain association and iOS setup still require separate verification.
