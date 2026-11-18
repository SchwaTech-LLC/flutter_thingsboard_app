import 'dart:async';

import 'package:collection/collection.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

enum TerminalFailure {
  permissions,
  bluetoothOff,
  unsupported,
  locationDisabled,
  missingUart,
  connection,
  security,
  notifications,
  write,
  invalidInput,
  unlockTimeout,
  pairingFailed,
}

class TerminalException implements Exception {
  const TerminalException(this.failure);
  final TerminalFailure failure;
}

class TerminalDevice {
  const TerminalDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });
  final String id;
  final String name;
  final int rssi;
}

abstract class BleTerminalTransport {
  Future<void> ready();
  Stream<TerminalDevice> scan();
  Stream<bool> connect(String id);
  Future<void> discover(String id);
  Stream<List<int>> notifications();
  Future<void> secure();
  Future<void> negotiateMtu();
  int get payloadSize;
  Future<void> write(List<int> bytes);
}

class ReactiveBleTerminalTransport implements BleTerminalTransport {
  ReactiveBleTerminalTransport({FlutterReactiveBle? ble})
    : _ble = ble ?? FlutterReactiveBle();

  static final service = Uuid.parse('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final rx = Uuid.parse('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');
  static final tx = Uuid.parse('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');
  final FlutterReactiveBle _ble;
  QualifiedCharacteristic? _rx;
  QualifiedCharacteristic? _tx;
  int _payloadSize = 20;
  int _connectionGeneration = 0;

  @override
  int get payloadSize => _payloadSize;

  @override
  Future<void> ready() async {
    if (kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      throw const TerminalException(TerminalFailure.unsupported);
    }
    List<Permission> permissions;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final info = await DeviceInfoPlugin().androidInfo;
      permissions =
          info.version.sdkInt >= 31
              ? [Permission.bluetoothScan, Permission.bluetoothConnect]
              : [Permission.locationWhenInUse];
    } else {
      permissions = [Permission.bluetooth];
    }
    final statuses = await permissions.request();
    if (statuses.values.any((status) => !status.isGranted)) {
      throw const TerminalException(TerminalFailure.permissions);
    }
    await _ble.initialize();
    final status =
        _ble.status == BleStatus.unknown
            ? await _ble.statusStream
                .firstWhere((s) => s != BleStatus.unknown)
                .timeout(const Duration(seconds: 5))
            : _ble.status;
    if (status != BleStatus.ready) {
      throw TerminalException(switch (status) {
        BleStatus.poweredOff => TerminalFailure.bluetoothOff,
        BleStatus.unsupported => TerminalFailure.unsupported,
        BleStatus.locationServicesDisabled => TerminalFailure.locationDisabled,
        _ => TerminalFailure.permissions,
      });
    }
  }

  @override
  Stream<TerminalDevice> scan() => _ble
      .scanForDevices(withServices: [service], scanMode: ScanMode.lowLatency)
      .map((d) => TerminalDevice(id: d.id, name: d.name, rssi: d.rssi));

  @override
  Stream<bool> connect(String id) {
    _connectionGeneration++;
    _rx = null;
    _tx = null;
    _payloadSize = 20;
    return _ble
        .connectToDevice(
          id: id,
          servicesWithCharacteristicsToDiscover: {
            service: [rx, tx],
          },
          connectionTimeout: const Duration(seconds: 12),
        )
        .where(
          (s) =>
              s.connectionState == DeviceConnectionState.connected ||
              s.connectionState == DeviceConnectionState.disconnected,
        )
        .map((s) => s.connectionState == DeviceConnectionState.connected);
  }

  @override
  Future<void> discover(String id) async {
    final generation = _connectionGeneration;
    await _ble.discoverAllServices(id);
    final services = await _ble.getDiscoveredServices(id);
    if (generation != _connectionGeneration) throw StateError('Session ended');
    final uart = services.firstWhereOrNull((s) => s.id == service);
    final input = uart?.characteristics.firstWhereOrNull((c) => c.id == rx);
    final output = uart?.characteristics.firstWhereOrNull((c) => c.id == tx);
    if (input == null ||
        output == null ||
        !output.isNotifiable ||
        !output.isReadable ||
        !input.isWritableWithResponse) {
      throw const TerminalException(TerminalFailure.missingUart);
    }
    _rx = QualifiedCharacteristic(
      deviceId: id,
      serviceId: service,
      characteristicId: rx,
    );
    _tx = QualifiedCharacteristic(
      deviceId: id,
      serviceId: service,
      characteristicId: tx,
    );
  }

  @override
  Stream<List<int>> notifications() => _ble.subscribeToCharacteristic(_tx!);

  @override
  Future<void> secure() async {
    // RX requires authenticated access. An acknowledged empty GATT write
    // triggers native pairing without adding any UART characters or commands.
    // On iOS a TX read can be satisfied by an unrelated notification, so it
    // cannot reliably establish authenticated access while subscribed.
    await _ble.writeCharacteristicWithResponse(_rx!, value: const []);
  }

  @override
  Future<void> negotiateMtu() async {
    final generation = _connectionGeneration;
    final mtu = await _ble.requestMtu(deviceId: _rx!.deviceId, mtu: 185);
    if (generation != _connectionGeneration) return;
    _payloadSize = (mtu - 3).clamp(1, 180);
  }

  @override
  Future<void> write(List<int> bytes) =>
      _ble.writeCharacteristicWithResponse(_rx!, value: bytes);
}
