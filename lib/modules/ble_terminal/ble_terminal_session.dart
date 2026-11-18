import 'dart:async';
import 'dart:convert';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:thingsboard_app/modules/ble_terminal/ble_terminal_transport.dart';
import 'package:thingsboard_app/modules/ble_terminal/terminal_parser.dart';
import 'package:thingsboard_app/modules/ble_terminal/terminal_writer.dart';

enum TerminalPhase {
  disconnected,
  scanning,
  connecting,
  securing,
  locked,
  unlocked,
  error,
}

class BleTerminalState {
  const BleTerminalState({
    this.phase = TerminalPhase.disconnected,
    this.devices = const [],
    this.device,
    this.transcript = '',
    this.textRuns = const [],
    this.history = const [],
    this.failure,
    this.busy = false,
    this.invalidPasskey = false,
  });

  final TerminalPhase phase;
  final List<TerminalDevice> devices;
  final TerminalDevice? device;
  final String transcript;
  final List<TerminalTextRun> textRuns;
  final List<String> history;
  final TerminalFailure? failure;
  final bool busy;
  final bool invalidPasskey;

  BleTerminalState copyWith({
    TerminalPhase? phase,
    List<TerminalDevice>? devices,
    TerminalDevice? device,
    String? transcript,
    List<TerminalTextRun>? textRuns,
    List<String>? history,
    TerminalFailure? failure,
    bool? busy,
    bool? invalidPasskey,
    bool clearFailure = false,
    bool clearDevice = false,
  }) => BleTerminalState(
    phase: phase ?? this.phase,
    devices: devices ?? this.devices,
    device: clearDevice ? null : device ?? this.device,
    transcript: transcript ?? this.transcript,
    textRuns: textRuns ?? this.textRuns,
    history: history ?? this.history,
    failure: clearFailure ? null : failure ?? this.failure,
    busy: busy ?? this.busy,
    invalidPasskey: invalidPasskey ?? this.invalidPasskey,
  );
}

class BleTerminalSession extends Cubit<BleTerminalState> {
  BleTerminalSession(
    this.transport, {
    String terminalPasskey = configuredPasskey,
    Duration securityTimeout = const Duration(seconds: 28),
    Duration unlockTimeout = const Duration(seconds: 10),
  }) : _terminalPasskey = terminalPasskey,
       _securityTimeout = securityTimeout,
       _unlockTimeout = unlockTimeout,
       super(const BleTerminalState()) {
    _writer = TerminalWriter(
      write: transport.write,
      payloadSize: () => transport.payloadSize,
    );
  }

  static const configuredPasskey = String.fromEnvironment('bleTerminalPasskey');
  static final _sixDigits = RegExp(r'^[0-9]{6}$');

  final BleTerminalTransport transport;
  final String _terminalPasskey;
  final Duration _securityTimeout;
  final Duration _unlockTimeout;
  final TerminalParser _parser = TerminalParser();
  late final TerminalWriter _writer;
  // Cancelled via captured subscriptions in stopScan/disconnect/close.
  // ignore: cancel_subscriptions
  StreamSubscription<TerminalDevice>? _scan;
  // ignore: cancel_subscriptions
  StreamSubscription<bool>? _connection;
  StreamSubscription<String>? _notifications;
  Timer? _deadline;
  int _epoch = 0;
  bool _notificationFailed = false;
  bool _closing = false;
  bool _disconnecting = false;
  Future<void>? _disconnectFuture;

  bool _current(int epoch) => !_closing && !isClosed && epoch == _epoch;

  Future<void> scan() async {
    if (_disconnecting || state.busy || state.device != null) return;
    await disconnect();
    final epoch = _epoch;
    emit(
      state.copyWith(
        phase: TerminalPhase.scanning,
        devices: [],
        clearFailure: true,
      ),
    );
    try {
      await transport.ready();
      if (!_current(epoch)) return;
      final devices = <String, TerminalDevice>{};
      _scan = transport.scan().listen(
        (device) {
          if (!_current(epoch)) return;
          devices[device.id] = device;
          // Bound the discovery list too; keep the closest visible devices.
          final sorted =
              devices.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
          if (sorted.length > 100) devices.remove(sorted.last.id);
          emit(state.copyWith(devices: List.unmodifiable(sorted.take(100))));
        },
        onError: (Object _) {
          if (_current(epoch)) {
            unawaited(disconnect(failure: TerminalFailure.connection));
          }
        },
      );
      _deadline = Timer(
        const Duration(seconds: 12),
        () => unawaited(stopScan()),
      );
    } catch (error) {
      if (_current(epoch)) {
        await disconnect(failure: _failure(error, TerminalFailure.connection));
      }
    }
  }

  Future<void> stopScan() async {
    if (state.phase == TerminalPhase.scanning) _epoch++;
    _deadline?.cancel();
    _deadline = null;
    final scan = _scan;
    _scan = null;
    await scan?.cancel();
    if (!_closing && !isClosed && state.phase == TerminalPhase.scanning) {
      emit(state.copyWith(phase: TerminalPhase.disconnected));
    }
  }

  Future<void> connect(TerminalDevice device) async {
    if (_disconnecting || state.busy || state.device != null) return;
    await disconnect();
    final epoch = _epoch;
    _parser.reset();
    emit(
      state.copyWith(
        phase: TerminalPhase.connecting,
        device: device,
        devices: [],
        transcript: '',
        textRuns: const [],
        history: [],
        busy: false,
        invalidPasskey: false,
        clearFailure: true,
      ),
    );
    try {
      await transport.ready();
      if (!_current(epoch)) return;
      _deadline = Timer(const Duration(seconds: 15), () {
        if (_current(epoch)) {
          unawaited(disconnect(failure: TerminalFailure.connection));
        }
      });
      _connection = transport
          .connect(device.id)
          .listen(
            (connected) {
              if (!_current(epoch)) return;
              if (connected && state.phase == TerminalPhase.connecting) {
                unawaited(_prepare(epoch, device.id));
              } else if (!connected) {
                unawaited(disconnect(failure: TerminalFailure.connection));
              }
            },
            onError: (Object _) {
              if (_current(epoch)) {
                unawaited(disconnect(failure: TerminalFailure.connection));
              }
            },
            onDone: () {
              if (_current(epoch)) {
                unawaited(disconnect(failure: TerminalFailure.connection));
              }
            },
          );
    } catch (error) {
      if (_current(epoch)) {
        await disconnect(failure: _failure(error, TerminalFailure.connection));
      }
    }
  }

  Future<void> _prepare(int epoch, String id) async {
    _deadline?.cancel();
    emit(state.copyWith(phase: TerminalPhase.securing));
    _deadline = Timer(_securityTimeout, () {
      if (_current(epoch)) {
        unawaited(disconnect(failure: TerminalFailure.security));
      }
    });
    try {
      await transport.discover(id).timeout(const Duration(seconds: 25));
      if (!_current(epoch)) return;
      _subscribe(epoch);
      // Do not wait for banners: an authenticated GATT write establishes security
      // even if initial notifications were emitted before subscription.
      var secure = false;
      for (var attempt = 0; attempt < 4 && _current(epoch); attempt++) {
        try {
          await transport.secure().timeout(const Duration(seconds: 25));
          secure = true;
          break;
        } on TimeoutException {
          // An in-flight native GATT operation cannot safely be retried.
          rethrow;
        } catch (_) {
          if (attempt == 3) rethrow;
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      if (!_current(epoch) || !secure) return;
      _deadline?.cancel();
      if (_notificationFailed) {
        await _notifications?.cancel();
        if (!_current(epoch)) return;
        _subscribe(epoch);
      }
      // Default 23-byte MTU remains safe if negotiation is unsupported/fails.
      try {
        await transport.negotiateMtu().timeout(const Duration(seconds: 3));
      } catch (_) {}
      if (!_current(epoch)) return;
      if (_notificationFailed) {
        throw const TerminalException(TerminalFailure.notifications);
      }
      _deadline?.cancel();
      emit(state.copyWith(phase: TerminalPhase.locked));
      await _unlock();
    } catch (error) {
      if (_current(epoch)) {
        await disconnect(failure: _failure(error, TerminalFailure.security));
      }
    }
  }

  void _subscribe(int epoch) {
    _notificationFailed = false;
    _notifications = transport
        .notifications()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) {
            if (!_current(epoch)) return;
            _parser.add(text);
            if (_parser.pairingFailed) {
              unawaited(disconnect(failure: TerminalFailure.pairingFailed));
            } else if (_parser.pairingUnauthenticated) {
              unawaited(disconnect(failure: TerminalFailure.security));
            } else if (_parser.invalidPasskey) {
              _deadline?.cancel();
              emit(
                state.copyWith(
                  phase: TerminalPhase.locked,
                  invalidPasskey: true,
                  busy: false,
                ),
              );
            } else if (_parser.unlocked &&
                state.phase == TerminalPhase.locked) {
              _deadline?.cancel();
              emit(
                state.copyWith(
                  phase: TerminalPhase.unlocked,
                  transcript: _parser.text,
                  textRuns: _parser.runs,
                  invalidPasskey: false,
                  busy: false,
                  clearFailure: true,
                ),
              );
            } else if (state.phase == TerminalPhase.unlocked) {
              emit(
                state.copyWith(
                  transcript: _parser.text,
                  textRuns: _parser.runs,
                ),
              );
            }
          },
          onError: (Object _) {
            if (!_current(epoch)) return;
            if (state.phase == TerminalPhase.securing) {
              _notificationFailed = true;
            } else {
              unawaited(disconnect(failure: TerminalFailure.notifications));
            }
          },
          onDone: () {
            if (!_current(epoch)) return;
            if (state.phase == TerminalPhase.securing) {
              _notificationFailed = true;
            } else {
              unawaited(disconnect(failure: TerminalFailure.notifications));
            }
          },
        );
  }

  Future<void> _unlock() async {
    if (state.phase != TerminalPhase.locked || state.busy) return;
    if (_terminalPasskey.length != 6 ||
        !_sixDigits.hasMatch(_terminalPasskey)) {
      emit(state.copyWith(invalidPasskey: true));
      return;
    }
    final epoch = _epoch;
    _parser.beginUnlock();
    emit(state.copyWith(busy: true, invalidPasskey: false, clearFailure: true));
    _deadline = Timer(_unlockTimeout, () {
      if (_current(epoch)) {
        unawaited(disconnect(failure: TerminalFailure.unlockTimeout));
      }
    });
    try {
      // Keep as text: leading zeros are meaningful. Never add this to history.
      await _writer.send(ascii.encode('$_terminalPasskey\n'));
    } catch (_) {
      if (_current(epoch)) await disconnect(failure: TerminalFailure.write);
    } finally {
      if (_current(epoch) &&
          (state.phase == TerminalPhase.unlocked || state.invalidPasskey)) {
        emit(state.copyWith(busy: false));
      }
    }
  }

  Future<void> sendCommand(String command) async {
    if (state.phase != TerminalPhase.unlocked || state.busy) return;
    List<int> bytes;
    try {
      bytes = TerminalWriter.commandBytes(command);
    } on FormatException {
      emit(state.copyWith(failure: TerminalFailure.invalidInput));
      return;
    }
    final epoch = _epoch;
    final history = [...state.history.where((c) => c != command), command];
    if (history.length > 30) history.removeAt(0);
    emit(
      state.copyWith(
        busy: true,
        history: List.unmodifiable(history),
        clearFailure: true,
      ),
    );
    try {
      // Firmware echoes commands. Adding a local echo would duplicate output.
      await _writer.send(bytes);
    } catch (_) {
      if (_current(epoch)) await disconnect(failure: TerminalFailure.write);
    } finally {
      if (_current(epoch)) emit(state.copyWith(busy: false));
    }
  }

  void clearDisplay() {
    _parser.clear();
    emit(state.copyWith(transcript: '', textRuns: const []));
  }

  Future<void> disconnect({TerminalFailure? failure}) {
    return _disconnectFuture ??= _disconnect(failure).whenComplete(() {
      _disconnectFuture = null;
    });
  }

  Future<void> _disconnect(TerminalFailure? failure) async {
    _disconnecting = true;
    _epoch++;
    _deadline?.cancel();
    _deadline = null;
    _writer.reset();
    _parser.reset();
    final scan = _scan;
    final notifications = _notifications;
    final connection = _connection;
    _scan = null;
    _notifications = null;
    _connection = null;
    if (!_closing && !isClosed) {
      emit(
        state.copyWith(
          phase:
              failure == null
                  ? TerminalPhase.disconnected
                  : TerminalPhase.error,
          failure: failure,
          clearFailure: failure == null,
          clearDevice: true,
          busy: false,
          invalidPasskey: false,
          history: [],
        ),
      );
    }
    try {
      var cancellationFailed = false;
      // Attempt every cancellation even if one native cleanup operation fails.
      // Cancelling reactive BLE's connection subscription disconnects GATT.
      for (final subscription in [scan, notifications, connection]) {
        try {
          await subscription?.cancel();
        } catch (_) {
          cancellationFailed = true;
        }
      }
      if (cancellationFailed && failure == null && !_closing && !isClosed) {
        emit(
          state.copyWith(
            phase: TerminalPhase.error,
            failure: TerminalFailure.connection,
          ),
        );
      }
    } finally {
      _disconnecting = false;
    }
  }

  TerminalFailure _failure(Object error, TerminalFailure fallback) =>
      error is TerminalException ? error.failure : fallback;

  @override
  Future<void> close() async {
    _closing = true;
    await disconnect();
    return super.close();
  }
}
