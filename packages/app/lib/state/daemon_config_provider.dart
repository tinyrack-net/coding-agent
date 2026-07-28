import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';

class DaemonConfigNotifier extends AsyncNotifier<MutableDaemonConfig?> {
  StreamSubscription<DaemonConfigChangedStatus>? _changeSubscription;
  StreamSubscription<DaemonConnectionState>? _connectionSubscription;

  @override
  Future<MutableDaemonConfig?> build() async {
    final client = ref.watch(daemonClientProvider);
    _changeSubscription = client.daemonConfigChanges.listen((change) {
      state = AsyncData(change.config);
    });
    _connectionSubscription = client.connectionState.listen((connection) {
      if (connection == DaemonConnectionState.connected) {
        unawaited(refresh());
      } else if (connection == DaemonConnectionState.disconnected) {
        state = const AsyncData(null);
      }
    });
    ref.onDispose(() {
      _changeSubscription?.cancel();
      _connectionSubscription?.cancel();
    });
    if (client.currentState != DaemonConnectionState.connected) return null;
    return client.getDaemonConfig();
  }

  Future<MutableDaemonConfig?> refresh() async {
    final client = ref.read(daemonClientProvider);
    if (client.currentState != DaemonConnectionState.connected) {
      state = const AsyncData(null);
      return null;
    }
    state = const AsyncLoading();
    final next = await AsyncValue.guard(client.getDaemonConfig);
    state = next;
    return next.value;
  }

  Future<MutableDaemonConfig> patch(MutableDaemonConfigPatch patch) async {
    final client = ref.read(daemonClientProvider);
    final next = await client.patchDaemonConfig(patch);
    state = AsyncData(next);
    return next;
  }

  Future<MutableDaemonConfig> setTerminalAgentHooks(bool enabled) =>
      patch(MutableDaemonConfigPatch(enableTerminalAgentHooks: enabled));
}

final daemonConfigProvider =
    AsyncNotifierProvider<DaemonConfigNotifier, MutableDaemonConfig?>(
      DaemonConfigNotifier.new,
    );
