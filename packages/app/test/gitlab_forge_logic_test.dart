import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/forge_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GitlabMergeFacts', () {
    test('applies every frozen default', () {
      final facts = GitlabMergeFacts.parse({'forge': 'gitlab'});
      expect(facts, isNotNull);
      expect(facts!.detailedMergeStatus, isNull);
      expect(facts.mergeStatus, isNull);
      expect(facts.hasConflicts, isFalse);
      expect(facts.blockingDiscussionsResolved, isTrue);
      expect(facts.approvalsRequired, 0);
      expect(facts.approvalsGiven, 0);
      expect(facts.pipelineStatus, isNull);
      expect(facts.pipelineId, isNull);
      expect(facts.pipelineUrl, isNull);
      expect(facts.mergeWhenPipelineSucceeds, isFalse);
    });

    test('accepts passthrough fields and finite numeric facts', () {
      final facts = GitlabMergeFacts.parse(
        _facts(
          approvalsRequired: 2.5,
          approvalsGiven: 1,
          pipelineId: 306,
          extra: const {'future': true},
        ),
      );
      expect(facts, isNotNull);
      expect(facts!.approvalsRequired, 2.5);
      expect(facts.pipelineId, 306);
    });

    test('rejects wrong families and schema-mismatched facts', () {
      for (final value in [
        null,
        {'approvalsRequired': 2},
        {'forge': 'github'},
        {'forge': 'gitlab', 'detailedMergeStatus': false},
        {'forge': 'gitlab', 'hasConflicts': null},
        {'forge': 'gitlab', 'blockingDiscussionsResolved': 'yes'},
        {'forge': 'gitlab', 'approvalsRequired': 'two'},
        {'forge': 'gitlab', 'approvalsGiven': double.infinity},
        {'forge': 'gitlab', 'pipelineId': '306'},
        {'forge': 'gitlab', 'pipelineUrl': false},
        {'forge': 'gitlab', 'mergeWhenPipelineSucceeds': null},
      ]) {
        expect(GitlabMergeFacts.parse(value), isNull, reason: '$value');
      }
    });
  });

  group('GitLab pipeline status', () {
    test('maps all frozen terminal and active vocabularies', () {
      for (final raw in ['success', 'passed']) {
        expect(mapGitlabPipelineStatus(raw), ForgeCheckStatus.success);
      }
      expect(mapGitlabPipelineStatus('failed'), ForgeCheckStatus.failure);
      for (final raw in ['canceled', 'cancelled', 'skipped']) {
        expect(mapGitlabPipelineStatus(raw), ForgeCheckStatus.skipped);
      }
      for (final raw in [
        'running',
        'pending',
        'created',
        'waiting_for_resource',
        'preparing',
        'scheduled',
        'manual',
        'anything-else',
      ]) {
        expect(mapGitlabPipelineStatus(raw), ForgeCheckStatus.pending);
      }
    });

    test('identifies exactly the live polling statuses', () {
      for (final raw in [
        'created',
        'waiting_for_resource',
        'preparing',
        'pending',
        'running',
        'scheduled',
      ]) {
        expect(isGitlabPipelineActiveStatus(raw), isTrue, reason: raw);
      }
      for (final raw in ['manual', 'success', 'failed', 'canceled']) {
        expect(isGitlabPipelineActiveStatus(raw), isFalse, reason: raw);
      }
    });
  });

  group('deriveGitlabMergeCapability', () {
    test('uses detailed merge status when present', () {
      expect(
        _capability(detailedMergeStatus: 'mergeable')!.directMergeReady,
        isTrue,
      );
      for (final status in [
        'ci_still_running',
        'discussions_not_resolved',
        'blocked',
      ]) {
        expect(
          _capability(detailedMergeStatus: status)!.directMergeReady,
          isFalse,
        );
      }
    });

    test('falls back to conflict-free legacy can_be_merged', () {
      expect(
        _capability(
          detailedMergeStatus: null,
          mergeStatus: 'can_be_merged',
        )!.directMergeReady,
        isTrue,
      );
      expect(
        _capability(
          detailedMergeStatus: null,
          mergeStatus: 'can_be_merged',
          hasConflicts: true,
        )!.directMergeReady,
        isFalse,
      );
      expect(
        _capability(
          detailedMergeStatus: null,
          mergeStatus: 'cannot_be_merged',
        )!.directMergeReady,
        isFalse,
      );
    });

    test('enables auto-merge only for an active pipeline', () {
      for (final status in [
        'created',
        'waiting_for_resource',
        'preparing',
        'pending',
        'running',
        'scheduled',
      ]) {
        expect(
          _capability(pipelineStatus: status)!.canEnableAutoMerge,
          isTrue,
          reason: status,
        );
      }
      expect(
        _capability(pipelineStatus: 'success')!.canEnableAutoMerge,
        isFalse,
      );
      expect(_capability(pipelineStatus: null)!.canEnableAutoMerge, isFalse);
    });

    test('reflects merge-when-pipeline-succeeds and fixed methods', () {
      final enabled = _capability(
        pipelineStatus: 'running',
        mergeWhenPipelineSucceeds: true,
      )!;
      expect(enabled.autoMergeEnabled, isTrue);
      expect(enabled.canDisableAutoMerge, isTrue);
      expect(enabled.canEnableAutoMerge, isFalse);
      expect(enabled.mergeBlockedByQueue, isFalse);
      expect(enabled.allowedMethods, ['merge', 'squash', 'rebase']);
      expect(enabled.preferredMethod, isNull);
    });
  });

  group('GitLab native summaries', () {
    test('derives pipeline summary and preserves raw status and URL', () {
      final facts = GitlabMergeFacts.parse(
        _facts(
          pipelineStatus: 'running',
          pipelineId: 306,
          pipelineUrl: 'https://gitlab.com/group/repo/-/pipelines/306',
        ),
      )!;
      final summary = deriveGitlabPipelineSummary(facts)!;
      expect(summary.id, 306);
      expect(summary.status, ForgeCheckStatus.pending);
      expect(summary.rawStatus, 'running');
      expect(summary.url, 'https://gitlab.com/group/repo/-/pipelines/306');
      expect(
        deriveGitlabPipelineSummary(
          GitlabMergeFacts.parse(_facts(pipelineId: null))!,
        ),
        isNull,
      );
    });

    test('derives approvals only when required', () {
      final approvals = deriveGitlabApprovals(
        GitlabMergeFacts.parse(
          _facts(approvalsRequired: 2, approvalsGiven: 1),
        )!,
      )!;
      expect(approvals.given, 1);
      expect(approvals.required, 2);
      expect(
        deriveGitlabApprovals(
          GitlabMergeFacts.parse(_facts(approvalsRequired: 0))!,
        ),
        isNull,
      );
    });

    test('is registered at the neutral capability boundary', () {
      expect(deriveForgeMergeCapability(_facts())?.directMergeReady, isTrue);
      expect(
        deriveForgeMergeCapability({..._facts(), 'approvalsRequired': 'two'}),
        isNull,
      );
    });
  });

  group('GitLab pipeline view derivations', () {
    test('counts mapped jobs and excludes skipped jobs', () {
      final counts = countGitlabPipelineJobs([
        const CheckoutPipelineStage(
          name: 'test',
          status: 'running',
          jobs: [
            CheckoutPipelineJob(
              id: 1,
              name: 'passed',
              stage: 'test',
              status: 'success',
              rawStatus: 'success',
              url: null,
              allowFailure: false,
              durationSeconds: 1,
            ),
            CheckoutPipelineJob(
              id: 2,
              name: 'failed',
              stage: 'test',
              status: 'failed',
              rawStatus: 'failed',
              url: null,
              allowFailure: false,
              durationSeconds: null,
            ),
            CheckoutPipelineJob(
              id: 3,
              name: 'pending',
              stage: 'test',
              status: 'future_status',
              rawStatus: 'future_status',
              url: null,
              allowFailure: false,
              durationSeconds: null,
            ),
            CheckoutPipelineJob(
              id: 4,
              name: 'skipped',
              stage: 'test',
              status: 'skipped',
              rawStatus: 'skipped',
              url: null,
              allowFailure: false,
              durationSeconds: null,
            ),
          ],
        ),
      ]);

      expect(counts.passed, 1);
      expect(counts.failed, 1);
      expect(counts.pending, 1);
      expect(counts.total, 3);
    });

    test('formats positive durations with Paseo compact rules', () {
      expect(formatGitlabPipelineDuration(null), '');
      expect(formatGitlabPipelineDuration(0), '');
      expect(formatGitlabPipelineDuration(double.infinity), '');
      expect(formatGitlabPipelineDuration(47.9), '47s');
      expect(formatGitlabPipelineDuration(60), '1m');
      expect(formatGitlabPipelineDuration(132), '2m 12s');
      expect(formatGitlabPipelineDuration(3600), '1h');
      expect(formatGitlabPipelineDuration(3900), '1h 5m');
    });
  });
}

ForgeMergeCapability? _capability({
  String? detailedMergeStatus = 'mergeable',
  String? mergeStatus,
  bool hasConflicts = false,
  String? pipelineStatus = 'success',
  bool mergeWhenPipelineSucceeds = false,
}) => deriveGitlabMergeCapability(
  _facts(
    detailedMergeStatus: detailedMergeStatus,
    mergeStatus: mergeStatus,
    hasConflicts: hasConflicts,
    pipelineStatus: pipelineStatus,
    mergeWhenPipelineSucceeds: mergeWhenPipelineSucceeds,
  ),
);

Map<String, Object?> _facts({
  String? detailedMergeStatus = 'mergeable',
  String? mergeStatus,
  bool hasConflicts = false,
  bool blockingDiscussionsResolved = true,
  num approvalsRequired = 0,
  num approvalsGiven = 0,
  String? pipelineStatus = 'success',
  num? pipelineId,
  String? pipelineUrl,
  bool mergeWhenPipelineSucceeds = false,
  Map<String, Object?> extra = const {},
}) => {
  'forge': 'gitlab',
  'detailedMergeStatus': detailedMergeStatus,
  'mergeStatus': mergeStatus,
  'hasConflicts': hasConflicts,
  'blockingDiscussionsResolved': blockingDiscussionsResolved,
  'approvalsRequired': approvalsRequired,
  'approvalsGiven': approvalsGiven,
  'pipelineStatus': pipelineStatus,
  'pipelineId': pipelineId,
  'pipelineUrl': pipelineUrl,
  'mergeWhenPipelineSucceeds': mergeWhenPipelineSucceeds,
  ...extra,
};
