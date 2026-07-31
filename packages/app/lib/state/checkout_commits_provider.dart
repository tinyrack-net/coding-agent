import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import '../git/paseo_git_queries.dart'
    show canFetchCheckoutCommits, checkoutCommitsQueryEnabled;
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
      // The gate lives in paseo_git_queries.dart, which ports it with the
      // upstream test suite. An inline copy here already drifted once — it
      // trimmed `cwd` where upstream uses plain JS truthiness, so a
      // whitespace-only cwd sat idle instead of surfacing the daemon's error.
      if (!checkoutCommitsQueryEnabled(
        enabled: true,
        capabilityPresent: supportsCheckoutCommits(client),
        canFetch: canFetchCheckoutCommits(
          cwd: key.cwd,
          hasClient: client != null,
          isConnected:
              (connection ?? client?.currentState) ==
              DaemonConnectionState.connected,
        ),
      )) {
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
        throw const FormatException('Host omitted commit base classification');
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
      // Upstream's `commitFileDiffsEnabled` additionally requires the commits
      // query to have loaded, because without a commit's file list there is
      // nothing to fetch a diff for. Here the caller supplies `path`, so that
      // precondition is already met by construction and the non-empty `path`
      // check stands in for it; the rest of the gate is the shared one.
      if (!supportsCheckoutCommits(client) ||
          key.sha.isEmpty ||
          key.path.isEmpty ||
          !canFetchCheckoutCommits(
            cwd: key.cwd,
            hasClient: client != null,
            isConnected:
                (connection ?? client?.currentState) ==
                DaemonConnectionState.connected,
          )) {
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
