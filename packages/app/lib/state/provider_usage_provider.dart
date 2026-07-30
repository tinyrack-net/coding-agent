import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';

final providerUsageProvider = FutureProvider<ProviderUsageListResponse>((
  ref,
) async {
  final client = ref.watch(daemonClientProvider);
  final state = await ref.watch(connectionStateProvider.future);
  if (state != DaemonConnectionState.connected) {
    throw StateError('Connect to this host to see provider usage');
  }
  if (client.serverInfo?.features['providerUsageList'] != true) {
    throw UnsupportedError('Update the host to see provider usage');
  }
  return client.listProviderUsage();
});

final hostProviderUsageProvider = FutureProvider.autoDispose
    .family<ProviderUsageListResponse, String>((ref, serverId) async {
      final client = ref.watch(hostDaemonClientProvider(serverId));
      if (client == null) {
        throw StateError('Connect to this host to see provider usage');
      }
      final state = await ref.watch(
        hostConnectionStateProvider(serverId).future,
      );
      if (state != DaemonConnectionState.connected) {
        throw StateError('Connect to this host to see provider usage');
      }
      if (client.serverInfo?.features['providerUsageList'] != true) {
        throw UnsupportedError('Update the host to see provider usage');
      }
      return client.listProviderUsage();
    });
