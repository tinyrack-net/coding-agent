import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import 'workspace_checkout_status_provider.dart';

typedef CheckoutCommitsKey = ({String serverId, String cwd});
typedef CheckoutCommitFileDiffKey = ({
  String serverId,
  String cwd,
  String sha,
  String path,
});

bool supportsCheckoutCommits(DaemonClient? client) =>
    client?.serverInfo?.features['commitsList'] == true &&
    client?.serverInfo?.features['commitBaseClassification'] == true;

final class CheckoutCommitsCacheEntry {
  const CheckoutCommitsCacheEntry({
    required this.response,
    required this.fetchedAt,
    required this.revision,
  });

  final CheckoutCommitsListResponse response;
  final DateTime fetchedAt;
  final int revision;
}

final class CheckoutCommitsCacheNotifier
    extends Notifier<Map<CheckoutCommitsKey, CheckoutCommitsCacheEntry>> {
  @override
  Map<CheckoutCommitsKey, CheckoutCommitsCacheEntry> build() => const {};

  void put(
    CheckoutCommitsKey key,
    CheckoutCommitsListResponse response,
    int revision,
  ) {
    state = Map.unmodifiable({
      ...state,
      key: CheckoutCommitsCacheEntry(
        response: response,
        fetchedAt: DateTime.now(),
        revision: revision,
      ),
    });
  }
}

final checkoutCommitsCacheProvider =
    NotifierProvider<
      CheckoutCommitsCacheNotifier,
      Map<CheckoutCommitsKey, CheckoutCommitsCacheEntry>
    >(CheckoutCommitsCacheNotifier.new);

/// A collapsed section does not mount this provider. A small revision-aware
/// cache mirrors Paseo's 30-second stale window without retaining timers.
final checkoutCommitsProvider = FutureProvider.autoDispose
    .family<CheckoutCommitsListResponse?, CheckoutCommitsKey>((ref, key) async {
      final client = ref.watch(
        checkoutStatusDaemonClientProvider(key.serverId),
      );
      final revision = ref.watch(
        checkoutCommitsInvalidationProvider.select(
          (revisions) => revisions[key] ?? 0,
        ),
      );
      final cached = ref.read(checkoutCommitsCacheProvider)[key];
      if (cached != null &&
          cached.revision == revision &&
          DateTime.now().difference(cached.fetchedAt) <
              const Duration(seconds: 30)) {
        return cached.response;
      }
      final connection = ref
          .watch(checkoutStatusConnectionProvider(key.serverId))
          .value;
      // Paseo gates on `Boolean(cwd)`, so only an empty string is rejected.
      // A whitespace-only cwd is sent and surfaces the daemon's error rather
      // than sitting idle, which is what the frozen UI shows.
      if (!supportsCheckoutCommits(client) ||
          key.cwd.isEmpty ||
          (connection ?? client?.currentState) !=
              DaemonConnectionState.connected) {
        return null;
      }
      final requestId = const Uuid().v4();
      final response = CheckoutCommitsListResponse.fromJson(
        await client!.requestSessionMessage(
          CheckoutCommitsListRequest(
            cwd: key.cwd,
            requestId: requestId,
          ).toJson(),
        ),
      );
      if (response.requestId != requestId || response.cwd != key.cwd) {
        throw const FormatException('Checkout commits response mismatch');
      }
      if (response.commits.any((commit) => commit.isOnBase == null)) {
        throw const FormatException(
          'Host omitted commit base classification',
        );
      }
      ref
          .read(checkoutCommitsCacheProvider.notifier)
          .put(key, response, revision);
      return response;
    });

final checkoutCommitFileDiffProvider = FutureProvider.autoDispose
    .family<CheckoutCommitFileDiffResponse?, CheckoutCommitFileDiffKey>((
      ref,
      key,
    ) async {
      final client = ref.watch(
        checkoutStatusDaemonClientProvider(key.serverId),
      );
      final connection = ref
          .watch(checkoutStatusConnectionProvider(key.serverId))
          .value;
      // As above: upstream's gate is `Boolean(cwd) && Boolean(sha)`.
      if (!supportsCheckoutCommits(client) ||
          key.cwd.isEmpty ||
          key.sha.isEmpty ||
          key.path.isEmpty ||
          (connection ?? client?.currentState) !=
              DaemonConnectionState.connected) {
        return null;
      }
      final requestId = const Uuid().v4();
      final response = CheckoutCommitFileDiffResponse.fromJson(
        await client!.requestSessionMessage(
          CheckoutCommitFileDiffRequest(
            cwd: key.cwd,
            sha: key.sha,
            path: key.path,
            requestId: requestId,
          ).toJson(),
        ),
      );
      if (response.requestId != requestId ||
          response.cwd != key.cwd ||
          response.sha != key.sha ||
          response.path != key.path) {
        throw const FormatException(
          'Checkout commit file diff response mismatch',
        );
      }
      return response;
    });
