/// ANSI SGR metadata. Null colors inherit the terminal's default colors.
class TerminalStyle {
  const TerminalStyle({this.foreground, this.background, this.bold = false});

  final int? foreground;
  final int? background;
  final bool bold;

  @override
  bool operator ==(Object other) =>
      other is TerminalStyle &&
      foreground == other.foreground &&
      background == other.background &&
      bold == other.bold;
  @override
  int get hashCode => Object.hash(foreground, background, bold);
}

class TerminalTextRun {
  const TerminalTextRun(this.text, this.style);
  final String text;
  final TerminalStyle style;
}

/// Incremental terminal rendering. Authentication output is never retained or
/// exposed: the firmware echoes the passkey, including across notifications.
class TerminalParser {
  TerminalParser({this.limit = 32768});

  final int limit;
  String _display = '';
  String _auth = '';
  int _cursor = 0;
  int _lineStart = 0;
  String _escape = '';
  String _sgr = '';
  bool _sgrInvalid = false;
  TerminalStyle _style = const TerminalStyle();
  // Metadata uses the same UTF-16 offsets and bound as the plain transcript.
  final List<TerminalStyle> _styles = [];
  bool _unlockMessage = false;
  bool _acceptUnlock = false;
  bool unlocked = false;
  bool invalidPasskey = false;
  bool pairingFailed = false;
  bool pairingUnauthenticated = false;

  String get text => _display;

  List<TerminalTextRun> get runs {
    final result = <TerminalTextRun>[];
    for (var start = 0; start < _display.length;) {
      var end = start + 1;
      while (end < _display.length && _styles[end] == _styles[start]) {
        end++;
      }
      result.add(
        TerminalTextRun(_display.substring(start, end), _styles[start]),
      );
      start = end;
    }
    return List.unmodifiable(result);
  }

  void beginUnlock() {
    _auth = '';
    _unlockMessage = false;
    _acceptUnlock = true;
    invalidPasskey = false;
    pairingUnauthenticated = false;
  }

  void reset() {
    clear();
    _auth = '';
    _escape = '';
    _sgr = '';
    _sgrInvalid = false;
    _style = const TerminalStyle();
    _unlockMessage = false;
    _acceptUnlock = false;
    unlocked = false;
    invalidPasskey = false;
    pairingFailed = false;
    pairingUnauthenticated = false;
  }

  void clear() {
    _display = '';
    _styles.clear();
    _cursor = 0;
    _lineStart = 0;
  }

  void add(String chunk) {
    for (final rune in chunk.runes) {
      if (_consumeEscape(rune)) continue;
      if (!unlocked) {
        // No passkey digits, control characters, or unknown firmware text are
        // saved in the authentication window or the exportable transcript.
        if (rune >= 48 && rune <= 57) continue;
        if (rune == 13 || rune == 10) {
          _auth += '\n';
        } else if (rune >= 32 && rune <= 126) {
          _auth += String.fromCharCode(rune);
        }
        if (_auth.length > 512) _auth = _auth.substring(_auth.length - 512);
        if (_auth.contains('Invalid passkey')) {
          invalidPasskey = true;
          _acceptUnlock = false;
          _auth = '';
        }
        if (_auth.contains('BLE pairing is not authenticated')) {
          pairingUnauthenticated = true;
          _acceptUnlock = false;
          _auth = '';
        }
        if (_auth.contains('BLE pairing failed. Disconnecting.') ||
            _auth.contains('BLE pairing timed out. Disconnecting.')) {
          pairingFailed = true;
        }
        if (_acceptUnlock && _auth.contains('BLE terminal unlocked')) {
          _unlockMessage = true;
          _auth = '';
        }
        if (_unlockMessage && _auth.endsWith('app> ')) {
          unlocked = true;
          _auth = '';
          _display += 'app> ';
          _styles.addAll(List.filled(5, _style));
          _cursor = _display.length;
        }
        continue;
      }
      if (rune == 13) {
        _cursor = _lineStart;
      } else if (rune == 10) {
        _display += '\n';
        _styles.add(_style);
        _cursor = _display.length;
        _lineStart = _cursor;
      } else if (rune == 8 || rune == 127) {
        if (_cursor > _lineStart) {
          _display = _display.replaceRange(_cursor - 1, _cursor, '');
          _styles.removeAt(_cursor - 1);
          _cursor--;
        }
      } else if (rune >= 32 && rune != 0x9b) {
        final character = String.fromCharCode(rune);
        final end = _cursor < _display.length ? _cursor + 1 : _cursor;
        _display = _display.replaceRange(_cursor, end, character);
        _styles.replaceRange(
          _cursor,
          end,
          List.filled(character.length, _style),
        );
        _cursor += character.length;
      }
      if (_display.length > limit) {
        final removed = _display.length - limit;
        _display = _display.substring(removed);
        _styles.removeRange(0, removed);
        _cursor = (_cursor - removed).clamp(0, _display.length);
        _lineStart = (_lineStart - removed).clamp(0, _display.length);
      }
    }
  }

  bool _consumeEscape(int rune) {
    if (_escape.isEmpty) {
      if (rune == 27 || rune == 0x9b) {
        _escape = rune == 27 ? 'esc' : 'csi';
        _sgr = '';
        _sgrInvalid = false;
        return true;
      }
      return false;
    }
    if (_escape == 'esc') {
      _escape = rune == 91 ? 'csi' : (rune == 93 ? 'osc' : '');
    } else if (_escape == 'csi') {
      if (rune >= 0x40 && rune <= 0x7e) {
        if (rune == 0x6d && unlocked && !_sgrInvalid) _applySgr();
        _escape = '';
        _sgr = '';
      } else if (_sgr.length < 128 &&
          (rune >= 48 && rune <= 57 || rune == 59)) {
        _sgr += String.fromCharCode(rune);
      } else {
        _sgrInvalid = true;
      }
    } else if (_escape == 'osc') {
      if (rune == 7) _escape = '';
      if (rune == 27) _escape = 'oscEnd';
    } else if (_escape == 'oscEnd') {
      _escape = rune == 92 ? '' : 'osc';
    }
    return true;
  }

  void _applySgr() {
    final parsed =
        _sgr
            .split(';')
            .map((part) => part.isEmpty ? 0 : int.tryParse(part))
            .toList();
    if (parsed.any((value) => value == null)) return;
    final values = parsed.cast<int>();
    var foreground = _style.foreground;
    var background = _style.background;
    var bold = _style.bold;
    for (var i = 0; i < values.length; i++) {
      final code = values[i];
      if (code == 0) {
        foreground = null;
        background = null;
        bold = false;
      } else if (code == 1) {
        bold = true;
      } else if (code == 22) {
        bold = false;
      } else if (code == 39) {
        foreground = null;
      } else if (code == 49) {
        background = null;
      } else if (code >= 30 && code <= 37) {
        foreground = _palette[code - 30];
      } else if (code >= 40 && code <= 47) {
        background = _palette[code - 40];
      } else if (code >= 90 && code <= 97) {
        foreground = _palette[code - 90 + 8];
      } else if (code >= 100 && code <= 107) {
        background = _palette[code - 100 + 8];
      } else if (code == 38 || code == 48) {
        if (i + 1 >= values.length) return;
        final mode = values[++i];
        int? color;
        if (mode == 5) {
          if (i + 1 >= values.length) return;
          final index = values[++i];
          if (index >= 0 && index <= 255) color = _indexedColor(index);
        } else if (mode == 2) {
          if (i + 3 >= values.length) return;
          final r = values[++i];
          final g = values[++i];
          final b = values[++i];
          if ([r, g, b].every((value) => value >= 0 && value <= 255)) {
            color = 0xff000000 | r << 16 | g << 8 | b;
          }
        } else {
          return;
        }
        if (color != null) {
          if (code == 38) {
            foreground = color;
          } else {
            background = color;
          }
        }
      }
    }
    _style = TerminalStyle(
      foreground: foreground,
      background: background,
      bold: bold,
    );
  }

  // A readable conventional terminal palette on the dark transcript surface.
  static const _palette = [
    0xff000000,
    0xffcd3131,
    0xff0dbc79,
    0xffe5e510,
    0xff2472c8,
    0xffbc3fbc,
    0xff11a8cd,
    0xffe5e5e5,
    0xff666666,
    0xfff14c4c,
    0xff23d18b,
    0xfff5f543,
    0xff3b8eea,
    0xffd670d6,
    0xff29b8db,
    0xffffffff,
  ];

  static int _indexedColor(int index) {
    if (index < 16) return _palette[index];
    if (index >= 232) {
      final gray = 8 + (index - 232) * 10;
      return 0xff000000 | gray << 16 | gray << 8 | gray;
    }
    final cube = index - 16;
    const levels = [0, 95, 135, 175, 215, 255];
    return 0xff000000 |
        levels[cube ~/ 36] << 16 |
        levels[cube ~/ 6 % 6] << 8 |
        levels[cube % 6];
  }
}
