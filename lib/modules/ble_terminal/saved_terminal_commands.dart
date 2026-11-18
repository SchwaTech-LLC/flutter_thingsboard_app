import 'dart:convert';

import 'package:thingsboard_app/modules/ble_terminal/terminal_writer.dart';
import 'package:thingsboard_app/thingsboard_client.dart';

class SavedTerminalCommand {
  const SavedTerminalCommand({required this.label, required this.command});

  final String label;
  final String command;

  void validate() {
    if (label.trim().isEmpty || label.length > 40) {
      throw const FormatException('Command label required');
    }
    TerminalWriter.commandBytes(command);
  }
}

/// Device-local shortcuts, independent of connection history and auth tokens.
class SavedTerminalCommands {
  SavedTerminalCommands(this.storage);

  final TbStorage storage;
  static const _key = 'bleTerminal.savedCommands';

  Future<List<SavedTerminalCommand>> load() async {
    if (!await storage.containsKey(_key)) return [];
    final entries = jsonDecode(await storage.getItem(_key) as String) as List;
    return entries.map((entry) {
      final fields = entry as Map<String, dynamic>;
      final saved = SavedTerminalCommand(
        label: fields['label'] as String,
        command: fields['command'] as String,
      );
      saved.validate();
      return saved;
    }).toList();
  }

  Future<void> save(List<SavedTerminalCommand> commands) async {
    for (final command in commands) {
      command.validate();
    }
    await storage.setItem(
      _key,
      jsonEncode(
        commands.map((c) => {'label': c.label, 'command': c.command}).toList(),
      ),
    );
  }
}
