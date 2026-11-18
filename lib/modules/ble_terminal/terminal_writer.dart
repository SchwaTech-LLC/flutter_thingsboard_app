import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// One serialized GATT write stream. Reset invalidates all queued work; it
/// never retries a chunk whose delivery is uncertain.
class TerminalWriter {
  TerminalWriter({
    required this.write,
    required this.payloadSize,
    this.pace = const Duration(milliseconds: 60),
  });

  final Future<void> Function(List<int>) write;
  final int Function() payloadSize;
  final Duration pace;
  Future<void> _tail = Future.value();
  int _generation = 0;

  static List<int> commandBytes(String command) {
    if (command.isEmpty ||
        command.length > 240 ||
        command.codeUnits.any(
          (c) => !(c >= 32 && c <= 126 || c == 8 || c == 127),
        )) {
      throw const FormatException('Single ASCII command required');
    }
    return ascii.encode('$command\n');
  }

  Future<void> send(List<int> bytes) {
    final generation = _generation;
    final operation = _tail.then((_) async {
      for (var offset = 0; offset < bytes.length;) {
        if (generation != _generation) throw StateError('Session ended');
        // Small paced chunks also protect the firmware's 256-byte input queue.
        final size = min(20, payloadSize());
        if (size < 1) throw StateError('Invalid MTU');
        final end = min(offset + size, bytes.length);
        await write(
          bytes.sublist(offset, end),
        ).timeout(const Duration(seconds: 8));
        offset = end;
        await Future<void>.delayed(pace);
      }
      if (generation != _generation) throw StateError('Session ended');
    });
    // Failure cancels queued commands too; never continue a partial command.
    _tail = operation.catchError((Object _) {
      if (generation == _generation) _generation++;
    });
    return operation;
  }

  void reset() {
    _generation++;
  }
}
