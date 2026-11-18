import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:thingsboard_app/generated/l10n.dart';
import 'package:thingsboard_app/locator.dart';
import 'package:thingsboard_app/modules/ble_terminal/ble_terminal_session.dart';
import 'package:thingsboard_app/modules/ble_terminal/ble_terminal_transport.dart';
import 'package:thingsboard_app/modules/ble_terminal/saved_terminal_commands.dart';
import 'package:thingsboard_app/modules/ble_terminal/terminal_writer.dart';
import 'package:thingsboard_app/thingsboard_client.dart';

class BleTerminalPage extends StatelessWidget {
  const BleTerminalPage({
    super.key,
    this.transport,
    this.commandStore,
    this.terminalPasskey = BleTerminalSession.configuredPasskey,
  });
  final BleTerminalTransport? transport;
  final SavedTerminalCommands? commandStore;
  final String terminalPasskey;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create:
        (_) => BleTerminalSession(
          transport ?? ReactiveBleTerminalTransport(),
          terminalPasskey: terminalPasskey,
        ),
    child: _TerminalView(commandStore: commandStore),
  );
}

class _TerminalView extends StatefulWidget {
  const _TerminalView({this.commandStore});
  final SavedTerminalCommands? commandStore;
  @override
  State<_TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<_TerminalView>
    with WidgetsBindingObserver {
  final _command = TextEditingController();
  final _scroll = ScrollController();
  late final BleTerminalSession _session;
  late final SavedTerminalCommands _store;
  List<SavedTerminalCommand> _saved = [];
  bool _loaded = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _session = context.read<BleTerminalSession>();
    _store = widget.commandStore ?? SavedTerminalCommands(getIt<TbStorage>());
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadCommands());
  }

  Future<void> _loadCommands() async {
    try {
      final saved = await _store.load();
      if (mounted) {
        setState(() {
          _saved = saved;
          _loaded = true;
          _loadFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<bool> _saveCommands(List<SavedTerminalCommand> saved) async {
    try {
      await _store.save(saved);
      if (!mounted) return false;
      setState(() => _saved = saved);
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).bleCommandsSaveFailed)),
        );
      }
      return false;
    }
  }

  Future<void> _editCommand([int? index]) async {
    if (!_loaded) return;
    await showDialog<void>(
      context: context,
      builder:
          (_) => _CommandDialog(
            previous: index == null ? null : _saved[index],
            initialCommand: _command.text,
            onSave: (command) {
              final next = List<SavedTerminalCommand>.of(_saved);
              if (index == null) {
                next.add(command);
              } else {
                next[index] = command;
              }
              return _saveCommands(next);
            },
            onDelete:
                index == null
                    ? null
                    : () => _saveCommands(List.of(_saved)..removeAt(index)),
          ),
    );
  }

  Future<void> _manageCommands() async {
    final s = S.of(context);
    final index = await showDialog<int>(
      context: context,
      builder:
          (context) => SimpleDialog(
            title: Text(s.bleSavedCommands),
            children: [
              if (_saved.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(s.bleNoSavedCommands),
                ),
              for (var i = 0; i < _saved.length; i++)
                ListTile(
                  title: Text(_saved[i].label),
                  subtitle: Text(_saved[i].command),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => Navigator.pop(context, i),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, -1),
                child: Text(s.bleAddCommand),
              ),
            ],
          ),
    );
    if (index != null && mounted) await _editCommand(index < 0 ? null : index);
  }

  @override
  void didChangeMetrics() {
    _followOutput();
  }

  void _followOutput() {
    final follow =
        !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.offset < 80;
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _session.setForeground(true);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _session.setForeground(false);
      case AppLifecycleState.detached:
        _session.setForeground(false);
        unawaited(_session.disconnect());
      case AppLifecycleState.inactive:
        // Native pairing can make the app inactive.
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _command.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final command = _command.text;
    try {
      TerminalWriter.commandBytes(command);
      _command.clear();
    } on FormatException {
      /* Preserve invalid pasted input for correction. */
    }
    unawaited(_session.sendCommand(command));
  }

  Future<void> _export(String transcript) async {
    try {
      await FilePicker.platform.saveFile(
        dialogTitle: S.of(context).bleExport,
        fileName: 'ble-terminal.txt',
        type: FileType.custom,
        allowedExtensions: ['txt'],
        bytes: Uint8List.fromList(utf8.encode(transcript)),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(S.of(context).bleExportFailed)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return BlocConsumer<BleTerminalSession, BleTerminalState>(
      listener: (context, state) {
        if (state.device == null) _command.clear();
        _followOutput();
      },
      builder: (context, state) {
        final hasDevice = state.device != null;
        final unlocked = state.phase == TerminalPhase.unlocked;
        return Scaffold(
          appBar: AppBar(
            title: Text(s.bleTerminal),
            actions: [
              TextButton(
                onPressed: _session.clearDisplay,
                child: Text(s.bleClear),
              ),
              PopupMenuButton<String>(
                onSelected: (action) {
                  switch (action) {
                    case 'copy':
                      unawaited(
                        Clipboard.setData(
                          ClipboardData(text: state.transcript),
                        ),
                      );
                    case 'export':
                      unawaited(_export(state.transcript));
                    case 'saved':
                      unawaited(_manageCommands());
                    case 'help':
                      showDialog<void>(
                        context: context,
                        builder:
                            (context) => AlertDialog(
                              title: Text(s.bleHelp),
                              content: SingleChildScrollView(
                                child: Text(
                                  '${s.blePairingGuidance}\n\n${s.bleCommandGuidance}',
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: Text(s.done),
                                ),
                              ],
                            ),
                      );
                  }
                },
                itemBuilder:
                    (_) => [
                      PopupMenuItem(
                        value: 'copy',
                        enabled: state.transcript.isNotEmpty,
                        child: Text(s.bleCopy),
                      ),
                      PopupMenuItem(
                        value: 'export',
                        enabled: state.transcript.isNotEmpty,
                        child: Text(s.bleExport),
                      ),
                      PopupMenuItem(
                        value: 'saved',
                        enabled: _loaded,
                        child: Text(s.bleSavedCommands),
                      ),
                      PopupMenuItem(value: 'help', child: Text(s.bleHelp)),
                    ],
              ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: LayoutBuilder(
                builder:
                    (context, constraints) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: math.max(
                              48,
                              constraints.maxHeight - (unlocked ? 120 : 0) - 48,
                            ),
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      unlocked
                                          ? Icons.bluetooth_connected
                                          : Icons.bluetooth,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Semantics(
                                        liveRegion: true,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _phase(s, state.phase),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style:
                                                  Theme.of(
                                                    context,
                                                  ).textTheme.bodyMedium,
                                            ),
                                            if (hasDevice)
                                              Text(
                                                state.device!.name.isEmpty
                                                    ? s.bleUnnamed
                                                    : state.device!.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style:
                                                    Theme.of(
                                                      context,
                                                    ).textTheme.bodySmall,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    if (hasDevice)
                                      IconButton(
                                        tooltip: s.bleDisconnect,
                                        onPressed: () => _session.disconnect(),
                                        icon: const Icon(
                                          Icons.bluetooth_disabled,
                                        ),
                                      ),
                                    if (!hasDevice)
                                      TextButton.icon(
                                        onPressed:
                                            state.phase ==
                                                    TerminalPhase.scanning
                                                ? _session.stopScan
                                                : _session.scan,
                                        icon: Icon(
                                          state.phase == TerminalPhase.scanning
                                              ? Icons.stop
                                              : Icons.bluetooth_searching,
                                        ),
                                        label: Text(
                                          state.phase == TerminalPhase.scanning
                                              ? s.bleStopScan
                                              : s.bleScanAction,
                                        ),
                                      ),
                                  ],
                                ),
                                if (state.phase == TerminalPhase.connecting ||
                                    state.phase == TerminalPhase.reconnecting ||
                                    state.phase == TerminalPhase.securing)
                                  const LinearProgressIndicator(),
                                if (state.failure != null)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Text(
                                      _failure(s, state.failure!),
                                      style: TextStyle(
                                        color:
                                            Theme.of(context).colorScheme.error,
                                      ),
                                    ),
                                  ),
                                if (state.failure ==
                                    TerminalFailure.permissions)
                                  TextButton(
                                    onPressed: openAppSettings,
                                    child: Text(s.bleSettings),
                                  ),
                                if (state.phase == TerminalPhase.locked) ...[
                                  if (state.invalidPasskey)
                                    Text(
                                      s.bleInvalidPasskey,
                                      style: TextStyle(
                                        color:
                                            Theme.of(context).colorScheme.error,
                                      ),
                                    ),
                                  if (state.busy) Text(s.bleAwaitUnlock),
                                ],
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child:
                              !hasDevice &&
                                      (state.phase == TerminalPhase.scanning ||
                                          state.devices.isNotEmpty ||
                                          state.transcript.isEmpty)
                                  ? state.devices.isEmpty
                                      ? Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(24),
                                          child: Text(
                                            s.bleScanGuidance,
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      )
                                      : ListView.builder(
                                        itemCount: state.devices.length,
                                        itemBuilder: (context, index) {
                                          final device = state.devices[index];
                                          return ListTile(
                                            leading: const Icon(
                                              Icons.bluetooth,
                                            ),
                                            title: Text(
                                              device.name.isEmpty
                                                  ? s.bleUnnamed
                                                  : device.name,
                                            ),
                                            subtitle: Text(
                                              '${device.id} · ${device.rssi} dBm',
                                            ),
                                            trailing: const Icon(
                                              Icons.chevron_right,
                                            ),
                                            onTap:
                                                () => _session.connect(device),
                                          );
                                        },
                                      )
                                  : DecoratedBox(
                                    key: const ValueKey('terminal-output'),
                                    decoration: BoxDecoration(
                                      color: const Color(0xff111827),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Scrollbar(
                                      controller: _scroll,
                                      child: SingleChildScrollView(
                                        controller: _scroll,
                                        padding: const EdgeInsets.all(12),
                                        child: SelectableText.rich(
                                          TextSpan(
                                            children: [
                                              for (final run in state.textRuns)
                                                TextSpan(
                                                  text: run.text,
                                                  style: TextStyle(
                                                    color:
                                                        run.style.foreground ==
                                                                null
                                                            ? null
                                                            : Color(
                                                              run
                                                                  .style
                                                                  .foreground!,
                                                            ),
                                                    backgroundColor:
                                                        run.style.background ==
                                                                null
                                                            ? null
                                                            : Color(
                                                              run
                                                                  .style
                                                                  .background!,
                                                            ),
                                                    fontWeight:
                                                        run.style.bold
                                                            ? FontWeight.bold
                                                            : FontWeight.normal,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 15,
                                            height: 1.35,
                                            color: Color(0xfff3f4f6),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                        ),
                        if (unlocked) ...[
                          SizedBox(
                            height: 48,
                            child:
                                _loadFailed
                                    ? TextButton(
                                      onPressed: _loadCommands,
                                      child: Text(s.bleCommandsLoadFailed),
                                    )
                                    : Row(
                                      children: [
                                        Expanded(
                                          child: SingleChildScrollView(
                                            scrollDirection: Axis.horizontal,
                                            child: Row(
                                              children: [
                                                for (final saved in _saved)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          right: 6,
                                                        ),
                                                    child: Tooltip(
                                                      message: saved.command,
                                                      child: OutlinedButton(
                                                        onPressed:
                                                            state.busy
                                                                ? null
                                                                : () => _session
                                                                    .sendCommand(
                                                                      saved
                                                                          .command,
                                                                    ),
                                                        child: Text(
                                                          saved.label,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        TextButton.icon(
                                          onPressed:
                                              _loaded ? _editCommand : null,
                                          icon: const Icon(Icons.add, size: 18),
                                          label: Text(s.bleAddCommand),
                                        ),
                                      ],
                                    ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _command,
                                  enabled: !state.busy,
                                  // Keep multiline input so pasted newlines reach validation.
                                  minLines: 1,
                                  maxLines: 2,
                                  keyboardType: TextInputType.text,
                                  textInputAction: TextInputAction.send,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  decoration: InputDecoration(
                                    hintText: s.bleCommand,
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    border: const OutlineInputBorder(),
                                  ),
                                  onSubmitted: (_) {
                                    if (!state.busy) _send();
                                  },
                                ),
                              ),
                              PopupMenuButton<String>(
                                tooltip: s.bleHistory,
                                enabled:
                                    !state.busy && state.history.isNotEmpty,
                                onSelected:
                                    (command) => _command.text = command,
                                itemBuilder:
                                    (_) =>
                                        state.history.reversed
                                            .map(
                                              (command) => PopupMenuItem(
                                                value: command,
                                                child: Text(command),
                                              ),
                                            )
                                            .toList(),
                                icon: const Icon(Icons.history),
                              ),
                              IconButton(
                                tooltip: s.bleSend,
                                onPressed: state.busy ? null : _send,
                                icon: const Icon(Icons.send),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _phase(S s, TerminalPhase phase) => switch (phase) {
    TerminalPhase.disconnected => s.bleDisconnected,
    TerminalPhase.scanning => s.bleScanning,
    TerminalPhase.connecting => s.bleConnecting,
    TerminalPhase.reconnecting => s.bleReconnecting,
    TerminalPhase.securing => s.bleSecuring,
    TerminalPhase.locked => s.bleLocked,
    TerminalPhase.unlocked => s.bleUnlocked,
    TerminalPhase.error => s.bleError,
  };
  String _failure(S s, TerminalFailure failure) => switch (failure) {
    TerminalFailure.permissions => s.blePermissionError,
    TerminalFailure.bluetoothOff => s.bleBluetoothOff,
    TerminalFailure.unsupported => s.bleUnsupported,
    TerminalFailure.locationDisabled => s.bleLocationDisabled,
    TerminalFailure.missingUart => s.bleMissingUart,
    TerminalFailure.connection => s.bleConnectionError,
    TerminalFailure.security ||
    TerminalFailure.pairingFailed => s.bleSecurityError,
    TerminalFailure.notifications => s.bleNotificationError,
    TerminalFailure.write => s.bleWriteError,
    TerminalFailure.invalidInput => s.bleInputError,
    TerminalFailure.unlockTimeout => s.bleUnlockTimeout,
  };
}

class _CommandDialog extends StatefulWidget {
  const _CommandDialog({
    this.previous,
    required this.initialCommand,
    required this.onSave,
    this.onDelete,
  });
  final SavedTerminalCommand? previous;
  final String initialCommand;
  final Future<bool> Function(SavedTerminalCommand) onSave;
  final Future<bool> Function()? onDelete;
  @override
  State<_CommandDialog> createState() => _CommandDialogState();
}

class _CommandDialogState extends State<_CommandDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.previous?.label);
  late final _command = TextEditingController(
    text: widget.previous?.command ?? widget.initialCommand,
  );
  bool _saving = false;
  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    super.dispose();
  }

  Future<void> _persist(Future<bool> Function() operation) async {
    setState(() => _saving = true);
    final success = await operation();
    if (!mounted) return;
    if (success) {
      Navigator.pop(context);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(
          widget.previous == null ? s.bleAddCommand : s.bleEditCommand,
        ),
        content: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  maxLength: 40,
                  enabled: !_saving,
                  decoration: InputDecoration(labelText: s.bleButtonLabel),
                  validator:
                      (value) =>
                          value == null || value.trim().isEmpty
                              ? s.bleLabelRequired
                              : null,
                ),
                TextFormField(
                  controller: _command,
                  minLines: 1,
                  maxLines: 3,
                  enabled: !_saving,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.text,
                  decoration: InputDecoration(
                    labelText: s.bleCommand,
                    helperText: s.bleCommandGuidance,
                    helperMaxLines: 4,
                  ),
                  validator: (value) {
                    try {
                      TerminalWriter.commandBytes(value ?? '');
                      return null;
                    } on FormatException {
                      return s.bleInputError;
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (widget.onDelete != null)
            TextButton(
              onPressed: _saving ? null : () => _persist(widget.onDelete!),
              child: Text(s.delete),
            ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed:
                _saving
                    ? null
                    : () {
                      if (_form.currentState!.validate()) {
                        _persist(
                          () => widget.onSave(
                            SavedTerminalCommand(
                              label: _name.text.trim(),
                              command: _command.text,
                            ),
                          ),
                        );
                      }
                    },
            child: Text(s.bleSaveCommand),
          ),
        ],
      ),
    );
  }
}
