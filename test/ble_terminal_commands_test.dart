import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thingsboard_app/generated/l10n.dart';
import 'package:thingsboard_app/modules/ble_terminal/ble_terminal_page.dart';
import 'package:thingsboard_app/modules/ble_terminal/ble_terminal_session.dart';
import 'package:thingsboard_app/modules/ble_terminal/saved_terminal_commands.dart';

import 'ble_terminal_test.dart'
    show FakeTransport, MemoryStorage, device, testTerminalPasskey;

Widget terminalApp(FakeTransport transport, SavedTerminalCommands store) =>
    MaterialApp(
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: S.delegate.supportedLocales,
      home: BleTerminalPage(
        transport: transport,
        commandStore: store,
        terminalPasskey: testTerminalPasskey,
      ),
    );

void main() {
  test(
    'saved commands reload, edit and delete across store recreation; invalid commands do not overwrite them',
    () async {
      final storage = MemoryStorage();
      final store = SavedTerminalCommands(storage);
      await store.save([
        const SavedTerminalCommand(label: 'Heap', command: 'heap'),
      ]);
      final reopened = SavedTerminalCommands(storage);
      expect((await reopened.load()).single.command, 'heap');
      await reopened.save([
        const SavedTerminalCommand(label: 'Name', command: 'devName'),
      ]);
      expect((await store.load()).single.command, 'devName');
      await expectLater(
        store.save([
          const SavedTerminalCommand(label: 'Bulk', command: 'help\nheap'),
        ]),
        throwsFormatException,
      );
      expect((await reopened.load()).single.command, 'devName');
      await reopened.save([]);
      expect(await store.load(), isEmpty);
    },
  );

  testWidgets(
    'add persists without sending, failed save retains input, saved button sends once and survives page reopening',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = MemoryStorage();
      final store = SavedTerminalCommands(storage);
      final transport = FakeTransport();
      await tester.pumpWidget(terminalApp(transport, store));
      await tester.pumpAndSettle();
      final session =
          tester.element(find.byType(Scaffold)).read<BleTerminalSession>();
      await tester.runAsync(() async {
        await session.connect(device);
        transport.connections.add(true);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('Add button'), findsNothing);
      expect(find.byTooltip('Send command'), findsNothing);
      await tester.runAsync(() async {
        transport.notify('BLE terminal unlocked\napp> ');
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      final output = find.byKey(const ValueKey('terminal-output'));
      transport.notify('\x1b[31merror\x1b[0m plain');
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      final displayed = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(displayed.textSpan!.toPlainText(), session.state.transcript);
      final errorSpan = displayed.textSpan!.children!
          .whereType<TextSpan>()
          .singleWhere((span) => span.text == 'error');
      expect(errorSpan.style!.color, const Color(0xffcd3131));
      expect(session.state.transcript, isNot(contains('\x1b')));
      expect(tester.getSize(output).height, greaterThan(580));
      tester.view.viewInsets = const FakeViewPadding(bottom: 310);
      await tester.pumpAndSettle();
      expect(tester.getSize(output).height, greaterThan(250));
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add button'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Heap');
      await tester.enterText(fields.at(1), 'help\nheap');
      await tester.tap(find.text('Save button'));
      await tester.pumpAndSettle();
      expect(await store.load(), isEmpty);
      expect(transport.writes.length, 1);
      await tester.enterText(fields.at(1), 'heap');
      storage.failWrites = true;
      await tester.tap(find.text('Save button'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester.widget<TextFormField>(fields.at(1)).controller!.text,
        'heap',
      );
      storage.failWrites = false;
      await tester.tap(find.text('Save button'));
      await tester.pumpAndSettle();
      expect((await store.load()).single.label, 'Heap');
      expect(transport.writes.length, 1);
      // Dismiss the field keyboard before tapping the shortcut.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Heap'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(ascii.decode(transport.writes.last), 'heap\n');
      expect(transport.writes.length, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() => transport.dispose());
      final secondTransport = FakeTransport();
      await tester.pumpWidget(
        terminalApp(secondTransport, SavedTerminalCommands(storage)),
      );
      await tester.pumpAndSettle();
      // Saved buttons can be managed before connecting; they never auto-send.
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved command buttons'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Heap'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'Free memory');
      await tester.tap(find.text('Save button'));
      await tester.pumpAndSettle();
      expect((await store.load()).single.label, 'Free memory');
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved command buttons'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Free memory'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(await store.load(), isEmpty);
      expect(secondTransport.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() => secondTransport.dispose());
    },
  );
}
