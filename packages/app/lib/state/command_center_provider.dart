import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../command_center/command_center.dart';

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
