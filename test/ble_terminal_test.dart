import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thingsboard_app/generated/l10n.dart';
import 'package:thingsboard_app/modules/ble_terminal/ble_terminal_page.dart';
import 'package:thingsboard_app/modules/ble_terminal/ble_terminal_session.dart';
import 'package:thingsboard_app/modules/ble_terminal/ble_terminal_transport.dart';
import 'package:thingsboard_app/modules/ble_terminal/saved_terminal_commands.dart';
import 'package:thingsboard_app/modules/ble_terminal/terminal_parser.dart';
import 'package:thingsboard_app/modules/ble_terminal/terminal_writer.dart';

import 'package:thingsboard_app/thingsboard_client.dart';

const testTerminalPasskey = '012345';

class MemoryStorage implements TbStorage {
  final values = <dynamic, dynamic>{};
  bool failWrites = false;
  @override
  Future<bool> containsKey(dynamic key) async => values.containsKey(key);
  @override
  Future<dynamic> getItem(dynamic key, {dynamic defaultValue}) async =>
      values[key] ?? defaultValue;
  @override
  Future<void> setItem(dynamic key, dynamic value) async {
    if (failWrites) throw StateError('Unavailable storage');
    values[key] = value;
  }

  @override
  Future<void> deleteItem(dynamic key) async {
    values.remove(key);
  }
}

class FakeTransport implements BleTerminalTransport {
  final scans = StreamController<TerminalDevice>.broadcast(sync: true);
  final connections = StreamController<bool>.broadcast(sync: true);
  final output = StreamController<List<int>>.broadcast(sync: true);
  final writes = <List<int>>[];
  final connectionIds = <String>[];
  final discoveryIds = <String>[];
  int notificationSubscriptions = 0;
  Completer<void>? _nextConnection;
  Completer<void>? readyGate;
  Completer<void>? securityGate;
  Completer<void>? writeGate;
  bool subscribedBeforeSecurity = false;
  bool securityFails = false;

  @override
  int get payloadSize => 20;
  @override
  Future<void> ready({bool requestPermissions = true}) async {
    await readyGate?.future;
  }

  @override
  Stream<TerminalDevice> scan() => scans.stream;

  Future<void> nextConnection() => (_nextConnection ??= Completer<void>())
      .future
      .timeout(const Duration(seconds: 5));

  @override
  Stream<bool> connect(String id) {
    connectionIds.add(id);
    _nextConnection?.complete();
    _nextConnection = null;
    return connections.stream;
  }

  @override
  Future<void> discover(String id) async => discoveryIds.add(id);
  @override
  Stream<List<int>> notifications() {
    notificationSubscriptions++;
    return output.stream;
  }

  @override
  Future<void> secure() async {
    subscribedBeforeSecurity = output.hasListener;
    await securityGate?.future;
    if (securityFails) throw StateError('Not authenticated');
  }

  @override
  Future<void> negotiateMtu() async {}
  @override
  Future<void> write(List<int> bytes) async {
    writes.add(List.of(bytes));
    await writeGate?.future;
  }

  void notify(String text) => output.add(utf8.encode(text));
  Future<void> dispose() async {
    await scans.close();
    await connections.close();
    await output.close();
  }
}

const device = TerminalDevice(id: 'ble-id', name: 'truncated', rssi: -45);

Future<void> flush() => Future<void>.delayed(Duration.zero);

Widget terminalApp(FakeTransport transport) => MaterialApp(
  localizationsDelegates: const [
    S.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: S.delegate.supportedLocales,
  home: BleTerminalPage(
    terminalPasskey: testTerminalPasskey,
    transport: transport,
    commandStore: SavedTerminalCommands(MemoryStorage()),
  ),
);

Future<void> connectLocked(
  BleTerminalSession session,
  FakeTransport transport,
) async {
  await session.connect(device);
  transport.connections.add(true);
  await flush();
  expect(session.state.phase, TerminalPhase.locked);
}

Future<void> unlockSession(
  BleTerminalSession session,
  FakeTransport transport,
) async {
  transport.notify(
    '${ascii.decode(transport.writes.last)}BLE terminal unlocked\r\napp> ',
  );
  await Future<void>.delayed(const Duration(milliseconds: 80));
  expect(session.state.phase, TerminalPhase.unlocked);
}

void main() {
  test('a malformed build passkey leaves the terminal locked', () async {
    final transport = FakeTransport();
    final session = BleTerminalSession(transport, terminalPasskey: '01234');
    addTearDown(() async {
      await session.close();
      await transport.dispose();
    });
    await connectLocked(session, transport);
    expect(session.state.invalidPasskey, isTrue);
    await session.sendCommand('help');
    expect(transport.writes, isEmpty);
  });

  test(
    'a silently closed notification stream revokes terminal access',
    () async {
      final transport = FakeTransport();
      final session = BleTerminalSession(
        transport,
        terminalPasskey: testTerminalPasskey,
      );
      addTearDown(() async {
        await session.close();
        await transport.dispose();
      });
      await connectLocked(session, transport);
      await unlockSession(session, transport);
      await transport.output.close();
      await flush();
      expect(session.state.phase, TerminalPhase.error);
      expect(session.state.failure, TerminalFailure.notifications);
      await session.sendCommand('help');
      expect(transport.writes.length, 1);
    },
  );

  test(
    'pairing and unlock waits are bounded, with no secret or command resend',
    () async {
      final transport = FakeTransport()..securityGate = Completer<void>();
      final session = BleTerminalSession(
        transport,
        terminalPasskey: testTerminalPasskey,
        securityTimeout: const Duration(milliseconds: 30),
        unlockTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(() async {
        await session.close();
        await transport.dispose();
      });
      await session.connect(device);
      transport.connections.add(true);
      await flush();
      expect(session.state.phase, TerminalPhase.securing);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(session.state.phase, TerminalPhase.error);
      expect(session.state.failure, TerminalFailure.security);
      transport.securityGate!.complete();
      await flush();
      await session.disconnect();
      transport.securityGate = null;
      await session.connect(device);
      transport.connections.add(true);
      await flush();
      expect(session.state.phase, TerminalPhase.locked);
      expect(session.state.busy, isTrue);
      await session.sendCommand('help');
      expect(transport.writes.length, 1);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(session.state.failure, TerminalFailure.unlockTimeout);
      expect(session.state.transcript, isEmpty);
    },
  );

  testWidgets(
    'automatic unlock needs no passkey controls and commands fit a small screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.reset);
      final transport = FakeTransport();
      await tester.pumpWidget(terminalApp(transport));
      await tester.pumpAndSettle();
      final session =
          tester.element(find.byType(Scaffold)).read<BleTerminalSession>();
      await session.connect(device);
      transport.connections.add(true);
      await tester.pumpAndSettle();
      final passkey = find.byWidgetPredicate(
        (w) => w is TextField && w.obscureText,
      );
      expect(passkey, findsNothing);
      expect(find.text('Unlock terminal'), findsNothing);
      expect(ascii.decode(transport.writes.single), '012345\n');
      expect(tester.takeException(), isNull);
      transport.notify('012345\nBLE terminal unlocked\napp> ');
      await tester.pumpAndSettle();
      expect(session.state.phase, TerminalPhase.unlocked);
      expect(find.text('app> '), findsOneWidget);
      final clear = find.widgetWithText(TextButton, 'Clear Log');
      await tester.tap(clear);
      await tester.pump();
      expect(find.text('app> '), findsNothing);
      expect(session.state.textRuns, isEmpty);
      await tester.tap(clear);
      await tester.pump();
      final send = find.byTooltip('Send command');
      final command = find.byWidgetPredicate(
        (w) => w is TextField && !w.obscureText,
      );
      await tester.enterText(command, 'help');
      await tester.tap(send);
      await tester.pump();
      expect(ascii.decode(transport.writes.last), 'help\n');
      transport.notify('\x1b[31mresponse\x1b[0m');
      await tester.pumpAndSettle();
      expect(find.text('response'), findsOneWidget);
      expect(transport.notificationSubscriptions, 1);
      await tester.enterText(command, 'help\nheap');
      await tester.tap(send);
      await tester.pump();
      expect(session.state.failure, TerminalFailure.invalidInput);
      expect(transport.writes.length, 2);
      expect(tester.widget<TextField>(command).controller!.text, 'help\nheap');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await transport.dispose();
    },
  );

  testWidgets('app switching keeps the existing BLE link subscribed', (
    tester,
  ) async {
    final transport = FakeTransport();
    await tester.pumpWidget(terminalApp(transport));
    Future<void> changeLifecycle(AppLifecycleState state) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          SystemChannels.lifecycle.name,
          const StringCodec().encodeMessage(state.toString()),
          (_) {},
        );
    final session =
        tester.element(find.byType(Scaffold)).read<BleTerminalSession>();
    await session.connect(device);
    transport.connections.add(true);
    await tester.pumpAndSettle();
    transport.notify('BLE terminal unlocked\napp> ');
    await tester.pump(const Duration(milliseconds: 80));
    expect(session.state.phase, TerminalPhase.unlocked);

    await changeLifecycle(AppLifecycleState.paused);
    await tester.pump();
    expect(transport.connections.hasListener, isTrue);
    expect(transport.output.hasListener, isTrue);
    await changeLifecycle(AppLifecycleState.resumed);
    await tester.pump();
    expect(transport.connectionIds, [device.id]);
    transport.notify('still connected');
    await tester.pumpAndSettle();
    expect(session.state.transcript, 'app> still connected');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await transport.dispose();
  });

  test(
    'background link loss restores RX, TX, and terminal state once',
    () async {
      final transport = FakeTransport();
      final session = BleTerminalSession(
        transport,
        terminalPasskey: testTerminalPasskey,
      );
      addTearDown(() async {
        await session.close();
        await transport.dispose();
      });
      await connectLocked(session, transport);
      await unlockSession(session, transport);
      transport.notify('previous output');
      await session.sendCommand('help');
      session.setForeground(false);
      transport.connections.add(false);
      await flush();
      expect(session.state.phase, TerminalPhase.reconnecting);
      expect(transport.connectionIds, [device.id]);
      expect(transport.output.hasListener, isFalse);
      final reconnected = transport.nextConnection();
      session.setForeground(true);
      await reconnected;
      expect(transport.connectionIds, [device.id, device.id]);
      transport.connections.add(true);
      await flush();
      await session.sendCommand('heap');
      expect(transport.writes.length, 3); // Two unlocks and one manual command.
      transport.notify('BLE terminal unlocked\napp> new output');
      expect(transport.discoveryIds, [device.id, device.id]);
      expect(transport.notificationSubscriptions, 2);
      expect(session.state.transcript, 'app> previous output\napp> new output');
      expect(session.state.history, ['help']);
      await session.sendCommand('heap');
      expect(ascii.decode(transport.writes.last), 'heap\n');
    },
  );

  test('resume retries a late disconnect with a bounded backoff', () async {
    final transport = FakeTransport();
    final session = BleTerminalSession(
      transport,
      terminalPasskey: testTerminalPasskey,
    );
    addTearDown(() async {
      await session.close();
      await transport.dispose();
    });
    await connectLocked(session, transport);
    await unlockSession(session, transport);
    session.setForeground(false);
    session.setForeground(true);
    for (final delay in [
      Duration.zero,
      const Duration(seconds: 1),
      const Duration(seconds: 2),
    ]) {
      final next = transport.nextConnection();
      final elapsed = Stopwatch()..start();
      transport.connections.add(false);
      await next;
      expect(elapsed.elapsed, greaterThanOrEqualTo(delay));
    }
    transport.connections.add(false);
    await flush();
    expect(transport.connectionIds, hasLength(4));
    expect(session.state.phase, TerminalPhase.error);
    expect(session.state.device, isNull);
    expect(transport.connections.hasListener, isFalse);
  });

  test('manual disconnect cancels recovery while waiting to retry', () async {
    final transport = FakeTransport();
    final session = BleTerminalSession(
      transport,
      terminalPasskey: testTerminalPasskey,
    );
    addTearDown(() async {
      await session.close();
      await transport.dispose();
    });
    await connectLocked(session, transport);
    await unlockSession(session, transport);
    session.setForeground(false);
    transport.connections.add(false);
    final next = transport.nextConnection();
    session.setForeground(true);
    await next;
    transport.connections.add(false);
    await flush();
    expect(session.state.phase, TerminalPhase.reconnecting);
    await session.disconnect();
    session.setForeground(false);
    session.setForeground(true);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(transport.connectionIds, hasLength(2));
    expect(session.state.phase, TerminalPhase.disconnected);
    expect(transport.connections.hasListener, isFalse);
    expect(transport.output.hasListener, isFalse);
  });

  test(
    'auth and secret echoes fragmented at every character stay out of transcript',
    () {
      final parser = TerminalParser()..beginUnlock();
      for (final char
          in '00\x1b[31m1234\x1b[0m\r\nBLE terminal unlocked\r\napp> '.split(
            '',
          )) {
        parser.add(char);
        expect(parser.text, isNot(contains('001234')));
        expect(parser.runs.map((run) => run.text).join(), parser.text);
      }
      expect(parser.unlocked, isTrue);
      expect(parser.text, 'app> ');
      expect(parser.runs.single.style, const TerminalStyle());
      parser.add('help\r\ncommands\r\napp> ');
      expect(parser.text, 'app> help\ncommands\napp> ');
    },
  );

  test('connection, pairing banners, or a prompt alone cannot unlock', () {
    final parser = TerminalParser();
    parser.add(
      'BLE pairing authenticated. Enter terminal passkey and press Send/Enter.\napp> ',
    );
    expect(parser.unlocked, isFalse);
    parser.add('BLE terminal unlocked\napp> ');
    expect(parser.unlocked, isFalse);
    parser.beginUnlock();
    parser.add('app> BLE terminal unlocked');
    expect(parser.unlocked, isFalse);
    parser.add('\r\napp>');
    expect(parser.unlocked, isFalse);
    parser.add(' ');
    expect(parser.unlocked, isTrue);
  });

  test(
    'fragmented invalid passkey rejects unlock and permits a fresh attempt',
    () {
      final parser = TerminalParser()..beginUnlock();
      parser.add('001234Invalid pass');
      parser.add('key\r\npasskey> ');
      expect(parser.invalidPasskey, isTrue);
      expect(parser.unlocked, isFalse);
      expect(parser.text, isEmpty);
      parser.beginUnlock();
      parser.add('BLE terminal unlocked\napp> ');
      expect(parser.invalidPasskey, isFalse);
      expect(parser.unlocked, isTrue);
    },
  );

  test(
    'CR LF, destructive backspace, ANSI and OSC are rendered safely and bounded',
    () {
      final parser = TerminalParser(limit: 64)..beginUnlock();
      parser.add('BLE terminal unlocked\napp> abc\b\x7fX\r\n');
      parser.add('old\rnew\n\x1b[3');
      parser.add('1mred\x1b[0m\x1b]title');
      parser.add('\x1b\\\napp> ');
      expect(parser.text, 'app> aX\nnew\nred\napp> ');
      parser.add('x' * 200);
      expect(parser.text.length, 64);
      parser.reset();
      parser.add('secret echo\napp> ');
      expect(parser.unlocked, isFalse);
      expect(parser.text, isEmpty);
    },
  );

  test(
    'fragmented ANSI SGR retains colors and resets without leaking escape text',
    () {
      final parser = TerminalParser()..beginUnlock();
      parser.add('BLE terminal unlocked\napp> ');
      parser.clear();
      for (final char
          in '\x1b[0;31mError\x1b[0m plain \x1b[1;93mWarning\x1b[22;39m plain'
              .split('')) {
        parser.add(char);
      }
      expect(parser.text, 'Error plain Warning plain');
      expect(parser.runs.map((run) => run.text), [
        'Error',
        ' plain ',
        'Warning',
        ' plain',
      ]);
      expect(parser.runs.first.style.foreground, 0xffcd3131);
      expect(parser.runs[1].style, const TerminalStyle());
      expect(parser.runs[2].style.foreground, 0xfff5f543);
      expect(parser.runs[2].style.bold, isTrue);
      expect(parser.runs.last.style, const TerminalStyle());
      parser.add(
        '\x1b[38;5;196;48;2;12;34;56mIndexed\x1b[38;2;255;128;64;49mRGB',
      );
      expect(parser.runs[4].style.foreground, 0xffff0000);
      expect(parser.runs[4].style.background, 0xff0c2238);
      expect(parser.runs.last.style.foreground, 0xffff8040);
      expect(parser.runs.last.style.background, isNull);
      parser.add(
        '\x1b[38;2;999;0;0m invalid\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x07',
      );
      expect(parser.runs.last.style.foreground, 0xffff8040);
      expect(parser.text, endsWith('RGB invalidlink'));
      expect(parser.runs.map((run) => run.text).join(), parser.text);
    },
  );

  test(
    'colored transcript metadata follows edits, trimming, clear and reconnect reset',
    () {
      final parser = TerminalParser(limit: 12)..beginUnlock();
      parser.add('BLE terminal unlocked\napp> ');
      parser.clear();
      parser.add('\x1b[31mold\r\x1b[32mnew\bX');
      expect(parser.text, 'neX');
      expect(parser.runs.single.style.foreground, 0xff0dbc79);
      parser.add('\n\x1b[34m${'z' * 20}');
      expect(parser.text, 'z' * 12);
      expect(parser.runs.single.text, parser.text);
      expect(parser.runs.single.style.foreground, 0xff2472c8);
      parser.clear();
      expect(parser.runs, isEmpty);
      parser.reset();
      parser.beginUnlock();
      parser.add('BLE terminal unlocked\napp> ');
      expect(parser.runs.single.style, const TerminalStyle());
    },
  );

  test(
    'single command framing rejects multiline paste, non-ASCII and queue overflow',
    () {
      expect(ascii.decode(TerminalWriter.commandBytes('help')), 'help\n');
      for (final command in ['', 'help\nheap', 'help\r', 'é', 'x' * 241]) {
        expect(
          () => TerminalWriter.commandBytes(command),
          throwsFormatException,
        );
      }
      expect(TerminalWriter.commandBytes('x' * 240).length, 241);
    },
  );

  test('writes serialize across commands and use actual MTU payload', () async {
    var active = 0;
    var maxActive = 0;
    final chunks = <List<int>>[];
    final writer = TerminalWriter(
      payloadSize: () => 7,
      pace: Duration.zero,
      write: (bytes) async {
        active++;
        if (active > maxActive) maxActive = active;
        chunks.add(bytes);
        await flush();
        active--;
      },
    );
    await Future.wait([
      writer.send(TerminalWriter.commandBytes('abcdefghijk')),
      writer.send(TerminalWriter.commandBytes('heap')),
    ]);
    expect(maxActive, 1);
    expect(chunks.every((c) => c.length <= 7), isTrue);
    expect(
      ascii.decode(chunks.expand((c) => c).toList()),
      'abcdefghijk\nheap\n',
    );
  });

  test(
    'disconnect cancels remaining chunks and queued writes, without poisoning reconnect',
    () async {
      final gate = Completer<void>();
      final chunks = <List<int>>[];
      final writer = TerminalWriter(
        payloadSize: () => 3,
        pace: Duration.zero,
        write: (bytes) async {
          chunks.add(bytes);
          await gate.future;
        },
      );
      final first = writer.send(ascii.encode('long command\n'));
      final queued = writer.send(ascii.encode('heap\n'));
      final firstCheck = expectLater(first, throwsStateError);
      final queuedCheck = expectLater(queued, throwsStateError);
      await flush();
      writer.reset();
      final reconnect = writer.send(ascii.encode('ip\n'));
      gate.complete();
      await Future.wait([firstCheck, queuedCheck, reconnect]);
      expect(ascii.decode(chunks.expand((c) => c).toList()), 'lonip\n');
    },
  );

  test(
    'write failure cancels queued commands and never retries partial delivery',
    () async {
      var count = 0;
      final writer = TerminalWriter(
        payloadSize: () => 20,
        pace: Duration.zero,
        write: (_) {
          count++;
          return Future.error(StateError('Write failed'));
        },
      );
      final first = writer.send(ascii.encode('help\n'));
      final second = writer.send(ascii.encode('heap\n'));
      await Future.wait([
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ]);
      expect(count, 1);
    },
  );

  test(
    'missed initial banners still reach locked, but secure GATT cannot authorize commands',
    () async {
      final transport = FakeTransport();
      final session = BleTerminalSession(
        transport,
        terminalPasskey: testTerminalPasskey,
      );
      addTearDown(() async {
        await session.close();
        await transport.dispose();
      });
      await connectLocked(session, transport);
      expect(transport.subscribedBeforeSecurity, isTrue);
      await session.sendCommand('help');
      expect(transport.writes.length, 1); // automatic unlock, no command
      await unlockSession(session, transport);
      expect(ascii.decode(transport.writes.first), '012345\n');
      expect(session.state.transcript, 'app> ');
      expect(session.state.history, isEmpty);
      await session.sendCommand('help');
      expect(session.state.history, ['help']);
      expect(session.state.transcript, 'app> '); // no local duplicate echo
      transport.notify('help\r\nresponse\r\napp> ');
      expect(session.state.transcript, 'app> help\nresponse\napp> ');
      await session.disconnect();
      await connectLocked(session, transport);
      await session.sendCommand('heap');
      expect(session.state.history, isEmpty);
      expect(transport.writes.length, 3); // one unlock per connection + help
    },
  );

  test(
    'wrong terminal passkey stays locked, clears busy, and is never saved',
    () async {
      final transport = FakeTransport();
      final session = BleTerminalSession(
        transport,
        terminalPasskey: testTerminalPasskey,
      );
      addTearDown(() async {
        await session.close();
        await transport.dispose();
      });
      await connectLocked(session, transport);
      transport.notify('012');
      transport.notify('345\r\nInvalid pass');
      transport.notify('key\r\npasskey> ');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(session.state.phase, TerminalPhase.locked);
      expect(session.state.invalidPasskey, isTrue);
      expect(session.state.busy, isFalse);
      expect(session.state.transcript, isEmpty);
      expect(session.state.history, isEmpty);
      await session.sendCommand('help');
      expect(
        transport.writes.length,
        1,
      ); // rejection never retries or sends commands
    },
  );

  test(
    'stop scan invalidates permission request; duplicate advertisements update RSSI',
    () async {
      final transport = FakeTransport()..readyGate = Completer<void>();
      final session = BleTerminalSession(
        transport,
        terminalPasskey: testTerminalPasskey,
      );
      addTearDown(() async {
        await session.close();
        await transport.dispose();
      });
      final scan = session.scan();
      await flush();
      await session.stopScan();
      transport.readyGate!.complete();
      await scan;
      expect(transport.scans.hasListener, isFalse);
      transport.readyGate = null;
      await session.scan();
      transport.scans.add(device);
      transport.scans.add(
        const TerminalDevice(id: 'ble-id', name: 'updated', rssi: -32),
      );
      expect(session.state.devices.length, 1);
      expect(session.state.devices.single.rssi, -32);
    },
  );

  test(
    'old security completion after disconnect cannot authenticate a new session',
    () async {
      final transport = FakeTransport()..securityGate = Completer<void>();
      final session = BleTerminalSession(
        transport,
        terminalPasskey: testTerminalPasskey,
      );
      addTearDown(() async {
        await session.close();
        await transport.dispose();
      });
      await session.connect(device);
      transport.connections.add(true);
      await flush();
      expect(session.state.phase, TerminalPhase.securing);
      expect(transport.writes, isEmpty);
      await session.disconnect();
      transport.securityGate!.complete();
      await flush();
      expect(session.state.phase, TerminalPhase.disconnected);
      expect(transport.output.hasListener, isFalse);
      expect(transport.connections.hasListener, isFalse);
      expect(transport.writes, isEmpty);
    },
  );

  test(
    'unexpected disconnect during a long command drops pending chunks and authentication',
    () async {
      final transport = FakeTransport();
      final session = BleTerminalSession(
        transport,
        terminalPasskey: testTerminalPasskey,
      );
      addTearDown(() async {
        await session.close();
        await transport.dispose();
      });
      await connectLocked(session, transport);
      await unlockSession(session, transport);
      transport.writeGate = Completer<void>();
      final command = session.sendCommand('x' * 80);
      await flush();
      transport.connections.add(false);
      transport.writeGate!.complete();
      await command;
      expect(session.state.phase, TerminalPhase.error);
      expect(session.state.device, isNull);
      expect(session.state.history, isEmpty);
      expect(transport.writes.length, 2); // unlock + first command chunk
    },
  );
}
