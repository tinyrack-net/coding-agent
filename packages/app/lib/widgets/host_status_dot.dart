import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../state/daemon_providers.dart';

enum HostRuntimeConnectionStatus { idle, connecting, online, offline, error }

const hostStatusOnlineColor = Color(0xFF4ADE80);
const hostStatusConnectingColor = Color(0xFFF59E0B);
const hostStatusOfflineColor = Color(0xFFEF4444);

HostRuntimeConnectionStatus hostRuntimeConnectionStatusFromDaemon(
  DaemonConnectionState? state,
) => switch (state) {
  null ||
  DaemonConnectionState.connecting => HostRuntimeConnectionStatus.connecting,
  DaemonConnectionState.connected => HostRuntimeConnectionStatus.online,
  DaemonConnectionState.disconnected => HostRuntimeConnectionStatus.offline,
  DaemonConnectionState.versionMismatch => HostRuntimeConnectionStatus.error,
};

Color hostStatusDotColor(HostRuntimeConnectionStatus status) =>
    switch (status) {
      HostRuntimeConnectionStatus.online => hostStatusOnlineColor,
      HostRuntimeConnectionStatus.connecting => hostStatusConnectingColor,
      HostRuntimeConnectionStatus.idle ||
      HostRuntimeConnectionStatus.offline ||
      HostRuntimeConnectionStatus.error => hostStatusOfflineColor,
    };

class HostStatusDot extends ConsumerWidget {
  const HostStatusDot({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(hostConnectionStateProvider(serverId));
    final status = hostRuntimeConnectionStatusFromDaemon(connection.value);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: hostStatusDotColor(status),
        shape: BoxShape.circle,
      ),
      child: const SizedBox.square(dimension: 8),
    );
  }
}
