import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

import 'package:agent_daemon/src/git/git_runner.dart';
import 'package:agent_daemon/src/git/git_service.dart';
import 'package:agent_daemon/src/server/legacy_checkout_service.dart';

void main() {
  test('commit and stash mutations preserve Paseo response envelopes', () async {
    final runner = _FakeGitRunner();
    final mutations = <String>[];
    final service = LegacyCheckoutService(
      git: GitService(dataDir: 'test-data', runner: runner),
      onMutation: (cwd, action) => mutations.add('$cwd:$action'),
    );

    final committed = await service.handle({
      'type': CheckoutCommitRequest.type,
      'cwd': '/repo',
      'message': 'Ship it',
      'addAll': true,
      'requestId': 'commit-1',
    });
    expect(
      CheckoutCommitResponse.fromJson(committed!),
      isA<CheckoutCommitResponse>(),
    );
    expect((committed['payload']! as Map)['success'], isTrue);

    final saved = await service.handle({
      'type': StashSaveRequest.type,
      'cwd': '/repo',
      'branch': 'feature/demo',
      'requestId': 'stash-1',
    });
    expect((saved!['payload']! as Map)['success'], isTrue);
    final popped = await service.handle({
      'type': StashPopRequest.type,
      'cwd': '/repo',
      'stashIndex': 0,
      'requestId': 'stash-2',
    });
    expect((popped!['payload']! as Map)['success'], isTrue);
    expect(
      mutations,
      containsAll(<String>[
        '/repo:commit-changes',
        '/repo:stash-push',
        '/repo:stash-pop',
      ]),
    );
    expect(
      runner.commands,
      contains(
        predicate<List<String>>(
          (command) =>
              command.join('|') ==
              'stash|push|--include-untracked|-m|paseo-auto-stash: feature/demo',
        ),
      ),
    );
  });

  test('branch validation and suggestions normalize origin refs', () async {
    final runner = _FakeGitRunner(
      responses: <String, GitResult>{
        'rev-parse refs/heads/feature': const GitResult(
          exitCode: 0,
          stdout: '',
          stderr: '',
        ),
        'rev-parse refs/heads/remote-only': const GitResult(
          exitCode: 1,
          stdout: '',
          stderr: '',
        ),
        'rev-parse refs/remotes/origin/remote-only': const GitResult(
          exitCode: 0,
          stdout: '',
          stderr: '',
        ),
      },
      defaultResponse: const GitResult(
        exitCode: 0,
        stdout: 'refs/heads/feature\t20\nrefs/heads/main\t10\n',
        stderr: '',
      ),
    );
    final service = LegacyCheckoutService(
      git: GitService(dataDir: 'test-data', runner: runner),
    );

    final local = await service.handle({
      'type': ValidateBranchRequest.type,
      'cwd': '/repo',
      'branchName': 'feature',
      'requestId': 'branch-1',
    });
    final localPayload = local!['payload']! as Map;
    expect(localPayload['exists'], isTrue);
    expect(localPayload['resolvedRef'], 'feature');
    expect(localPayload['isRemote'], isFalse);

    final remote = await service.handle({
      'type': ValidateBranchRequest.type,
      'cwd': '/repo',
      'branchName': 'remote-only',
      'requestId': 'branch-2',
    });
    final remotePayload = remote!['payload']! as Map;
    expect(remotePayload['resolvedRef'], 'origin/remote-only');
    expect(remotePayload['isRemote'], isTrue);

    final suggestions = await service.handle({
      'type': BranchSuggestionsRequest.type,
      'cwd': '/repo',
      'query': 'fea',
      'requestId': 'branch-3',
    });
    final suggestionsPayload = suggestions!['payload']! as Map;
    expect(suggestionsPayload['branches'], ['feature']);
  });

  test('stash listing filters Paseo entries by default', () async {
    final runner = _FakeGitRunner(
      defaultResponse: const GitResult(
        exitCode: 0,
        stdout:
            'stash@{0}\u0000paseo-auto-stash: feature\nstash@{1}\u0000manual save\n',
        stderr: '',
      ),
    );
    final service = LegacyCheckoutService(
      git: GitService(dataDir: 'test-data', runner: runner),
    );
    final response = await service.handle({
      'type': StashListRequest.type,
      'cwd': '/repo',
      'requestId': 'stash-list',
    });
    final parsed = StashListResponse.fromJson(response!);
    expect(parsed.entries, hasLength(1));
    expect(parsed.entries.single.branch, 'feature');
    expect(parsed.entries.single.isPaseo, isTrue);
  });

  test('editor bridge returns explicit unsupported response', () async {
    final service = LegacyEditorService();
    final response = await service.handle({
      'type': ListAvailableEditorsRequest.type,
      'requestId': 'editor-1',
    });
    final parsed = ListAvailableEditorsResponse.fromJson(response!);
    expect(parsed.editors, isEmpty);
    expect(parsed.error, contains('no longer supported'));
  });
}

final class _FakeGitRunner extends GitRunner {
  _FakeGitRunner({this.responses = const {}, this.defaultResponse});

  final Map<String, GitResult> responses;
  final GitResult? defaultResponse;
  final commands = <List<String>>[];

  @override
  Future<GitResult> run(
    List<String> args, {
    required String cwd,
    bool check = true,
  }) async {
    commands.add(args);
    final key = args.length >= 3 && args.first == 'rev-parse'
        ? '${args[0]} ${args[3]}'
        : args.length >= 3 && args.first == 'for-each-ref'
        ? args.last
        : args.join(' ');
    final result =
        responses[key] ??
        defaultResponse ??
        const GitResult(exitCode: 0, stdout: '', stderr: '');
    if (check && !result.ok)
      throw GitException(
        args: args,
        exitCode: result.exitCode,
        stderr: result.stderr,
        stdout: result.stdout,
      );
    return result;
  }
}
