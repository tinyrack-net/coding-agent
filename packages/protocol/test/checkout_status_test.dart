import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('checkout status request matches the frozen wire shape', () {
    const request = CheckoutStatusRequest(cwd: '/repo', requestId: 'status-1');

    expect(CheckoutStatusRequest.fromJson(request.toJson()).cwd, '/repo');
    expect(request.toJson(), {
      'type': 'checkout_status_request',
      'cwd': '/repo',
      'requestId': 'status-1',
    });
  });

  test('non-git response requires the frozen nullable fields', () {
    final response = CheckoutStatusResponse.fromJson({
      'type': 'checkout_status_response',
      'payload': _notGitPayload(),
    });

    expect(response.payload, isA<CheckoutStatusNotGit>());
    expect(response.payload.isGit, isFalse);
    expect(response.payload.repoRoot, isNull);
    expect(response.toJson()['payload'], _notGitPayload());

    final missing = _notGitPayload()..remove('isDirty');
    expect(
      () => CheckoutStatusResponse.fromJson({
        'type': 'checkout_status_response',
        'payload': missing,
      }),
      throwsFormatException,
    );
  });

  test('non-owned Git response defaults an omitted main repo root to null', () {
    final payload = _gitPayload()..remove('mainRepoRoot');
    final response = CheckoutStatusResponse.fromJson({
      'type': 'checkout_status_response',
      'payload': payload,
    });

    final status = response.payload as CheckoutStatusGitNonPaseo;
    expect(status.repoRoot, '/repo');
    expect(status.mainRepoRoot, isNull);
    expect(status.currentBranch, 'feature');
    expect(status.aheadBehind?.ahead, 2);
    expect(status.aheadBehind?.behind, 1);
    expect(status.aheadOfOrigin, 3);
    expect(status.behindOfOrigin, 4);
  });

  test('owned worktree requires base and main repo roots', () {
    final payload = _gitPayload()
      ..['isPaseoOwnedWorktree'] = true
      ..['mainRepoRoot'] = '/main'
      ..['baseRef'] = 'main';
    final status =
        CheckoutStatusResponse.fromJson({
              'type': 'checkout_status_response',
              'payload': payload,
            }).payload
            as CheckoutStatusGitPaseo;

    expect(status.mainRepoRoot, '/main');
    expect(status.baseRef, 'main');
    expect(status.toJson(), payload);

    payload['baseRef'] = null;
    expect(
      () => CheckoutStatusPayload.fromJson(payload),
      throwsFormatException,
    );
  });

  test('checkout update carries an optional normalized PR status payload', () {
    final update = CheckoutStatusUpdate.fromJson({
      'type': 'checkout_status_update',
      'payload': {
        ..._gitPayload(),
        'prStatus': {
          'cwd': '/repo',
          'status': null,
          'githubFeaturesEnabled': true,
          'forge': 'gitlab',
          'error': null,
          'requestId': 'subscription:/repo',
        },
      },
    });

    expect(update.payload.isDirty, isTrue);
    expect(update.prStatus?.forge, 'gitlab');
    expect(update.toJson()['payload'], {
      ..._gitPayload(),
      'prStatus': {
        'cwd': '/repo',
        'status': null,
        'githubFeaturesEnabled': true,
        'forge': 'gitlab',
        'error': null,
        'requestId': 'subscription:/repo',
      },
    });
  });
}

Map<String, Object?> _notGitPayload() => {
  'cwd': '/directory',
  'isGit': false,
  'isPaseoOwnedWorktree': false,
  'repoRoot': null,
  'currentBranch': null,
  'isDirty': null,
  'baseRef': null,
  'aheadBehind': null,
  'aheadOfOrigin': null,
  'behindOfOrigin': null,
  'hasRemote': false,
  'remoteUrl': null,
  'error': null,
  'requestId': 'status-1',
};

Map<String, Object?> _gitPayload() => {
  'cwd': '/repo',
  'isGit': true,
  'isPaseoOwnedWorktree': false,
  'repoRoot': '/repo',
  'mainRepoRoot': null,
  'currentBranch': 'feature',
  'isDirty': true,
  'baseRef': 'main',
  'aheadBehind': {'ahead': 2, 'behind': 1},
  'aheadOfOrigin': 3,
  'behindOfOrigin': 4,
  'hasRemote': true,
  'remoteUrl': 'git@example.test:org/repo.git',
  'error': null,
  'requestId': 'status-1',
};
