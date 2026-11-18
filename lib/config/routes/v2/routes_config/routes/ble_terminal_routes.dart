import 'package:go_router/go_router.dart';
import 'package:thingsboard_app/modules/ble_terminal/ble_terminal_page.dart';

class BleTerminalRoutes {
  static const terminal = '/bleTerminal';
}

final bleTerminalRoutes = [
  GoRoute(
    path: BleTerminalRoutes.terminal,
    builder: (context, state) => const BleTerminalPage(),
  ),
];
