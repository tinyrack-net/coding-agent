import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('request uses the exact legacy checkout PR status wire shape', () {
    const request = CheckoutPrStatusRequest(cwd: '/repo', requestId: 's1');
    expect(CheckoutPrStatusRequest.fromJson(request.toJson()).toJson(), {
      'type': 'checkout_pr_status_request',
      'cwd': '/repo',
      'requestId': 's1',
    });
  });

  test('response round-trips status, checks, facts, auth, and errors', () {
    const response = CheckoutPrStatusResponse(
      cwd: '/repo',
      status: CheckoutPrStatus(
        forge: 'github',
        projectPath: 'acme/repo',
        number: 7,
        url: 'https://github.test/acme/repo/pull/7',
        title: 'Feature',
        state: 'open',
        baseRefName: 'main',
        headRefName: 'feature',
        isMerged: false,
        isDraft: true,
        mergeable: 'MERGEABLE',
        checks: [
          CheckoutPrCheck(
            name: 'build',
            status: 'success',
            url: null,
            workflow: 'CI',
            duration: '1m',
            checkRunId: 9,
            workflowRunId: 10,
          ),
        ],
        checksStatus: 'success',
        reviewDecision: 'approved',
        repoOwner: 'acme',
        repoName: 'repo',
        github: {'mergeStateStatus': 'CLEAN'},
        forgeSpecific: {'forge': 'github', 'mergeStateStatus': 'CLEAN'},
      ),
      githubFeaturesEnabled: true,
      authState: 'authenticated',
      forge: 'github',
      error: null,
      requestId: 's2',
    );
    expect(
      CheckoutPrStatusResponse.fromJson(response.toJson()).toJson(),
      response.toJson(),
    );
  });

  test(
    'compatibility defaults match Paseo and unknown mergeability is safe',
    () {
      final response = CheckoutPrStatusResponse.fromJson({
        'type': CheckoutPrStatusResponse.type,
        'payload': {
          'cwd': '/repo',
          'status': {
            'url': 'u',
            'title': 't',
            'state': 'open',
            'baseRefName': 'main',
            'headRefName': 'feature',
            'isMerged': false,
            'mergeable': 'FUTURE',
          },
          'githubFeaturesEnabled': true,
          'error': null,
          'requestId': 's3',
        },
      });
      expect(response.forge, 'github');
      expect(response.status?.forge, 'github');
      expect(response.status?.isDraft, isFalse);
      expect(response.status?.mergeable, 'UNKNOWN');
      expect(response.status?.checks, isEmpty);
    },
  );

  test('malformed boundaries are rejected', () {
    expect(
      () => CheckoutPrStatusRequest.fromJson({
        'type': CheckoutPrStatusRequest.type,
        'cwd': 1,
        'requestId': 's',
      }),
      throwsFormatException,
    );
    expect(
      () => CheckoutPrStatusResponse.fromJson({
        'type': CheckoutPrStatusResponse.type,
        'payload': {
          'cwd': '/repo',
          'status': null,
          'githubFeaturesEnabled': 'yes',
          'error': null,
          'requestId': 's',
        },
      }),
      throwsFormatException,
    );
  });
}
