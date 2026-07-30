import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../command_center/command_center.dart';

enum CommandCenterOverlay { commandCenter, shortcuts }

final class CommandCenterOverlayRequest {
  const CommandCenterOverlayRequest({
    required this.serial,
    required this.overlay,
  });

  final int serial;
  final CommandCenterOverlay overlay;
}

final class CommandCenterOverlayRequestNotifier
    extends Notifier<CommandCenterOverlayRequest?> {
  var _serial = 0;

  @override
  CommandCenterOverlayRequest? build() => null;

  void openCommandCenter() {
    state = CommandCenterOverlayRequest(
      serial: ++_serial,
      overlay: CommandCenterOverlay.commandCenter,
    );
  }

  void openShortcuts() {
    state = CommandCenterOverlayRequest(
      serial: ++_serial,
      overlay: CommandCenterOverlay.shortcuts,
    );
  }
}

final commandCenterOverlayRequestProvider =
    NotifierProvider<
      CommandCenterOverlayRequestNotifier,
      CommandCenterOverlayRequest?
    >(CommandCenterOverlayRequestNotifier.new);

final class CommandCenterRegistryNotifier
    extends Notifier<CommandCenterSnapshot> {
  final CommandCenterRegistry _registry = CommandCenterRegistry();

  @override
  CommandCenterSnapshot build() {
    final unsubscribe = _registry.subscribe(() {
      state = _registry.snapshot;
    });
    ref.onDispose(unsubscribe);
    return _registry.snapshot;
  }

  void replace(CommandCenterRegistration registration) {
    _registry.replace(registration);
  }

  void remove(CommandCenterRegistrationOwner owner) {
    _registry.remove(owner);
  }
}

final commandCenterRegistryProvider =
    NotifierProvider<CommandCenterRegistryNotifier, CommandCenterSnapshot>(
      CommandCenterRegistryNotifier.new,
    );
