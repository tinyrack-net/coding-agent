import 'package:agent_protocol/agent_protocol.dart';

enum ForgeCheckStatus {
  success('success'),
  failure('failure'),
  pending('pending'),
  skipped('skipped');

  const ForgeCheckStatus(this.wireName);

  final String wireName;
}

ForgeCheckStatus mapForgeCheckStatus(String status) => switch (status) {
  'success' => ForgeCheckStatus.success,
  'failure' => ForgeCheckStatus.failure,
  'pending' => ForgeCheckStatus.pending,
  'skipped' || 'cancelled' => ForgeCheckStatus.skipped,
  _ => ForgeCheckStatus.pending,
};

final class ForgeMergeCapability {
  const ForgeMergeCapability({
    required this.directMergeReady,
    required this.canEnableAutoMerge,
    required this.autoMergeEnabled,
    required this.canDisableAutoMerge,
    required this.mergeBlockedByQueue,
    required this.allowedMethods,
    required this.preferredMethod,
  });

  final bool directMergeReady;
  final bool canEnableAutoMerge;
  final bool autoMergeEnabled;
  final bool canDisableAutoMerge;
  final bool mergeBlockedByQueue;
  final List<String> allowedMethods;
  final String? preferredMethod;
}

final class GiteaMergeFacts {
  const GiteaMergeFacts({
    required this.mergeable,
    required this.hasMerged,
    required this.ciStatus,
  });

  final bool mergeable;
  final bool hasMerged;
  final String? ciStatus;

  static GiteaMergeFacts? parse(Object? value) {
    if (value is! Map || value['forge'] != 'gitea') return null;
    final mergeable = value['mergeable'];
    final hasMerged = value['hasMerged'];
    final ciStatus = value['ciStatus'];
    if (mergeable != null && mergeable is! bool) return null;
    if (hasMerged != null && hasMerged is! bool) return null;
    if (ciStatus != null && ciStatus is! String) return null;
    return GiteaMergeFacts(
      mergeable: mergeable as bool? ?? false,
      hasMerged: hasMerged as bool? ?? false,
      ciStatus: ciStatus as String?,
    );
  }
}

ForgeMergeCapability? deriveGiteaMergeCapability(Object? facts) {
  final gitea = GiteaMergeFacts.parse(facts);
  if (gitea == null) return null;
  return ForgeMergeCapability(
    directMergeReady: gitea.mergeable && !gitea.hasMerged,
    canEnableAutoMerge: false,
    autoMergeEnabled: false,
    canDisableAutoMerge: false,
    mergeBlockedByQueue: false,
    allowedMethods: const ['merge', 'squash', 'rebase'],
    preferredMethod: null,
  );
}

final class ForgeFallbackCheck {
  const ForgeFallbackCheck({
    required this.provider,
    required this.name,
    required this.status,
    required this.url,
  });

  final String provider;
  final String name;
  final ForgeCheckStatus status;
  final String url;

  CheckoutPrCheck toCheckoutPrCheck() =>
      CheckoutPrCheck(name: name, status: status.wireName, url: url);
}

List<ForgeFallbackCheck> getGiteaNativeFallbackChecks(
  CheckoutPrStatus status,
  String forge,
) {
  final facts = GiteaMergeFacts.parse(status.forgeSpecific);
  final ciStatus = facts?.ciStatus;
  if (ciStatus == null || ciStatus.isEmpty) return const [];
  return [
    ForgeFallbackCheck(
      provider: forge,
      name: 'CI',
      status: _mapGiteaCiStatus(ciStatus),
      url: status.url,
    ),
  ];
}

/// Matches Paseo's PR-pane data builder: usable native checks win, otherwise a
/// registered forge may synthesize aggregate checks from `forgeSpecific`.
List<CheckoutPrCheck> resolvePullRequestChecks(CheckoutPrStatus status) {
  final nativeChecks = status.checks
      .where((check) => check.url != null)
      .map(
        (check) => CheckoutPrCheck(
          name: check.name,
          status: mapForgeCheckStatus(check.status).wireName,
          url: check.url,
          workflow: check.workflow,
          duration: check.duration,
          checkRunId: check.checkRunId,
          workflowRunId: check.workflowRunId,
        ),
      )
      .toList(growable: false);
  if (nativeChecks.isNotEmpty) return nativeChecks;
  return getGiteaNativeFallbackChecks(
    status,
    status.forge,
  ).map((check) => check.toCheckoutPrCheck()).toList(growable: false);
}

ForgeCheckStatus _mapGiteaCiStatus(String status) =>
    status == 'warning' || status == 'error'
    ? ForgeCheckStatus.failure
    : mapForgeCheckStatus(status);
