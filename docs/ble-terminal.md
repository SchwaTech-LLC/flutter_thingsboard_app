# BLE Terminal

Open **BLE Terminal** from **More** after completing ThingsBoard login, including
any required two-factor verification. `/bleTerminal` uses the normal app route
handlers and redirects. Direct links require login too; logout removes the page
and closes its Bluetooth session. There is no terminal entry on the login screen.
Once authenticated, terminal data travels directly over BLE.

The transcript fills the available height, with a compact connection row above
and command input below. Clear, copy, export, pairing help, and saved-button
management are in the app bar menu. Output uses larger, high-contrast monospace
text and remains scrollable with the keyboard open.

ANSI SGR colors from device logs are displayed, including standard/bright colors,
256-color and semicolon-form RGB foreground/background colors, bold, and reset
codes. Escape sequences can span BLE notifications. Other CSI/OSC controls are
stripped; links and terminal commands are not executed. Copy and export remain
plain text. Authentication output never enters either the text or color spans.

Tap **Add button** to save a name and one command. Saving does not send it. Tap a
saved button to send through the same validated, paced writer as typed commands;
this requires an unlocked terminal. The button row scrolls horizontally. Use
**Saved command buttons** in the menu to edit or delete a button. Buttons use the
app's existing encrypted local storage and persist across reconnects, page
reopening, logouts, and app restarts. They are local to this app installation;
uninstalling or clearing app data removes them. Passkeys are never automatically
saved or copied into this editor.

Scan for devices advertising Nordic UART Service
`6E400001-B5A3-F393-E0A9-E50E24DCCA9E`. Results show advertised names, BLE identifiers,
and RSSI, deduplicated by BLE identifier. Names may be truncated and identifiers
are not ThingsBoard device IDs.

Complete the native Android/iOS pairing dialog once using the device's six-digit
passkey, including its leading zero. Bonded reconnects normally skip this dialog.
After authenticated GATT access succeeds, the app sends the configured firmware
passkey once automatically; there is no terminal passkey field or unlock button.
Commands remain disabled until both `BLE terminal unlocked` and the subsequent
`app> ` prompt arrive through notifications. A rejection stays locked without
retrying; check firmware compatibility and disconnect. A timeout disconnects.

Set `bleTerminalPasskey` to the six-digit firmware value as a JSON string in the
ignored `config/thingsboard.local.json` file and pass it via
`--dart-define-from-file`. Keep the real value out of version control. Automatic
unlock stays locked when the value is missing or malformed. The passkey is
recoverable from the built app. ThingsBoard login and native Bluetooth
authentication are still required.

Use `help` to discover commands supported by the particular firmware build.
Nothing is executed automatically. Commands are single ASCII inputs of at most
240 characters, with one LF appended. Backspace and delete bytes are accepted;
embedded CR/LF and non-ASCII pastes are rejected. Firmware echo is displayed once,
without local command echo. Asynchronous logs are part of the same stream, with
no inferred request/response boundaries.

## Implementation

- `ble_terminal_transport.dart`: Android/iOS permissions, service-filtered scans,
  GATT connection/discovery, TX subscription, authenticated RX operations, MTU.
- `ble_terminal_session.dart`: Cubit state, bounded security/unlock waits,
  disconnect cleanup, sanitized transcript and up to 30 history entries.
- `terminal_parser.dart`: incremental prompts/authentication detection, CR/LF,
  destructive backspace/delete, fragmented ANSI SGR color metadata, stripping
  other CSI/OSC escape sequences, and a transcript and metadata capped at 32,768
  UTF-16 code units.
- `terminal_writer.dart`: serialized acknowledged writes, chunks capped at
  `min(20, negotiated payload)`, 60 ms pacing, cancellation of queued chunks.
- `ble_terminal_page.dart`: scan/connect, native pairing guidance, unlock status,
  full-height terminal, command history, disconnect, clear, clipboard and export.
- `saved_terminal_commands.dart`: validated command buttons in existing encrypted
  device storage, separate from session history and authentication tokens.

TX notifications are subscribed immediately after characteristic discovery.
Security is established with an **empty write with response to authenticated RX**.
This is a GATT access check that adds no UART characters. TX snapshots are never
read into the transcript. The package's iOS read API can complete from a
notification, so a concurrent TX read is unsuitable as proof of authentication.
The expected firmware exposes RX Write and TX Read/Notify; missing capabilities
produce a recoverable error. Automatic terminal unlock does not replace or bypass
the native OS pairing dialog.

Security has a 28-second overall deadline after connection, with up to four
sequential attempts for completed GATT failures. A pending operation timeout
disconnects instead of starting overlapping retries. Unlock has a 10-second
confirmation deadline. Subscription can be retried once after authenticated
access is established. Uncertain write delivery disconnects and cancels remaining
chunks; commands are never automatically resent. Each new secured connection
gets one new automatic terminal-unlock attempt.

All authentication output is hidden, including unknown messages and fragmented
passkey echoes. Only recognized status is shown outside the transcript. The
embedded passkey is never put in history or editable controls. Raw
transport exceptions are not displayed or logged. Clipboard/export use the same
sanitized transcript. A new connection starts a fresh display. Disconnect
retains sanitized output for copying/exporting and clears history/authentication.

Leaving the page cancels scans, notifications, deadlines and the GATT connection.
Backgrounding ends normal sessions. Native pairing can temporarily pause the
activity, so securing is allowed to continue under its deadline. Connect again
from the terminal after returning. Forget stale bonds in phone Bluetooth
settings and clear the device bond using its documented procedure.

## Dependency and platforms

The existing `flutter_esp_ble_prov` dependency handles provisioning, not arbitrary
UART GATT operations, and remains in use for that feature. The terminal uses the
BSD-licensed `flutter_reactive_ble` 5.4.0 compatible with Flutter 3.29 / Dart 3.7.
Newer mobile releases require Dart 3.11. The platform interface is pinned to 5.4.0
because newer releases contain Flutter configuration unsupported by this SDK.
Official documentation checked:

- https://pub.dev/packages/flutter_reactive_ble/versions/5.4.0
- https://github.com/PhilipsHue/flutter_reactive_ble/blob/v5.4.0/README.md

Android 12+ requests Nearby devices scan/connect permissions. Android 11 and
earlier requests location permission and needs enabled location services for BLE
scan. Legacy Bluetooth permissions are capped at API 30; BLE hardware is optional.
Existing location permissions remain available for app mapping/provisioning.
iOS 13+ Bluetooth descriptions are set in both Debug and Release plists; the
existing permission-handler Bluetooth macro remains enabled. No Bluetooth
background mode was added.

## Automated checks

```sh
flutter pub get
dart run intl_utils:generate
flutter analyze lib/modules/ble_terminal test/ble_terminal_test.dart
flutter test
flutter build apk --debug --dart-define-from-file=config/thingsboard.local.json
```

Regression tests cover fragmented authentication/prompts, invalid passkeys,
secret echo suppression, terminal control sequences, bounded display, reconnect
reset, newline framing, MTU-aware serialization, queued-write cancellation,
missed banners, scan deduplication/cancellation, security/unlock timeout,
login/MFA gating and logout redirects, persistent button creation/edit/deletion,
explicit sends, failed-save recovery, and phone layouts with the keyboard open.
New localization strings use
the existing English ARB and generated `S` accessors; other locales fall back to
English until translations are supplied.

The automated suite covers Dart and Flutter behavior. Physical validation of
automatic unlock remains pending on Android and iOS.

## Physical Android/iOS validation required

Run each scenario on a real Android and iOS phone with the deployed ESP32
firmware. Record OS/device/firmware version and actual negotiated MTU. Use the
supplied deployed passkey without putting it in screenshots, logs or reports.

| Scenario | Expected result |
| --- | --- |
| Logged out / incomplete MFA | No login-screen entry. Direct terminal links redirect to login or required MFA; no BLE scan or connection starts. After full login, open from More. Logout closes an active terminal. |
| Saved command buttons | Add without sending, restart the app, log in and reconnect. Buttons remain saved and only send when tapped after terminal unlock. Edit/delete persists too. |
| First pairing, no bond | Native passkey dialog appears; enter the exact supplied six-digit value. Confirm authenticated RX probe succeeds before the app sends one automatic unlock. Commands wait for both confirmation markers. |
| Bonded reconnect | OS may skip pairing. One automatic unlock is sent after security succeeds; commands wait for confirmation. No old command is resent. |
| Wrong OS passkey / cancel | Pairing fails/disconnects or bounded security wait ends with recovery guidance. No terminal access. |
| Firmware passkey mismatch | Fragmented `Invalid passkey` keeps terminal locked and shows a configuration error without retrying; no digits appear in display/history/copy/export. |
| Pairing timeout | Leave native dialog unanswered. Firmware disconnects at about 30 seconds; app reports a bounded security/connection error and permits a fresh scan/connect. |
| Stale bond | Reset only the device's bond according to its documented procedure. Failed phone reconnect provides guidance to forget the phone bond and pair again. |
| Missed initial banner | Delay TX subscription or connect to an already bonded device. Authenticated empty write reaches locked state without relying on banners. Separate unlock confirmation is still required. |
| Fragmented / asynchronous output | Exercise `help` and available read-only diagnostics. Test MTU 23 (20-byte payload) and a larger negotiated MTU; verify long lines, prompts, CR/LF, edits, color/OSC codes, logs interspersed with output. Firmware's 180-byte notifications must be checked for truncation at the actual MTU. |
| Disconnect during command | Move out of range or power off ESP32 during a long command. Remaining chunks stop, history/authentication reset, and reconnect requires unlock. Inspect device state before manual resend because delivery is uncertain. |
| Permissions / Bluetooth off | Deny permissions, disable Bluetooth, disable location on Android <=11, then restore each. Clear guidance and a new scan recover without loops. |
| Unsupported GATT / subscription failure | A service-advertising test peripheral with missing RX/TX/properties, or failed CCC subscription, produces a recoverable error. |
| Lifecycle / keyboard / export | Pair through the native dialog while the activity pauses. Navigate away or background the app when unlocked and verify cleanup. Use commands with the keyboard open, clear/copy/export output, and verify automatic-unlock echoes are absent. |

iOS build validation requires macOS/Xcode and CocoaPods installation for the new
plugin. Unit/widget tests do not establish native MITM/Secure Connections behavior,
bond persistence, firmware queue timing or notification integrity at low MTU.
