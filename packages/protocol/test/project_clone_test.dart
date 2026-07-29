import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('clone request round trips shorthand and complete remotes', () {
    for (final request in const [
      ProjectGithubCloneRequest(
        requestId: 'request-1',
        repo: 'owner/repo',
        cloneProtocol: ProjectGithubCloneProtocol.ssh,
        targetDirectory: '/workspace',
      ),
      ProjectGithubCloneRequest(
        requestId: 'request-2',
        repo: 'https://github.com/owner/repo.git',
        targetDirectory: '/workspace',
      ),
    ]) {
      expect(
        ProjectGithubCloneRequest.fromJson(request.toJson()).toJson(),
        request.toJson(),
      );
    }
  });

  test('clone response preserves success and failure envelopes', () {
    for (final response in const [
      ProjectGithubCloneResponse(
        requestId: 'request-1',
        repo: 'owner/repo',
        checkoutPath: '/workspace/repo',
        project: WorkspaceProjectDescriptor(
          projectId: 'project',
          projectDisplayName: 'repo',
          projectRootPath: '/workspace/repo',
          projectKind: WorkspaceProjectKind.git,
        ),
        error: null,
      ),
      ProjectGithubCloneResponse(
        requestId: 'request-2',
        repo: 'owner/repo',
        checkoutPath: null,
        project: null,
        error: 'failed',
      ),
    ]) {
      expect(
        ProjectGithubCloneResponse.fromJson(response.toJson()).toJson(),
        response.toJson(),
      );
    }
  });

  test('clone boundaries reject malformed payloads', () {
    for (final json in <Map<String, Object?>>[
      {
        'type': ProjectGithubCloneRequest.type,
        'requestId': 'request',
        'repo': 'ab',
        'targetDirectory': '/workspace',
      },
      {
        'type': ProjectGithubCloneRequest.type,
        'requestId': 'request',
        'repo': 'owner/repo',
        'cloneProtocol': 'git',
        'targetDirectory': '/workspace',
      },
      {
        'type': ProjectGithubCloneResponse.type,
        'payload': {
          'requestId': 'request',
          'repo': 'owner/repo',
          'checkoutPath': 1,
          'project': null,
          'error': null,
        },
      },
    ]) {
      expect(
        () => json['type'] == ProjectGithubCloneRequest.type
            ? ProjectGithubCloneRequest.fromJson(json)
            : ProjectGithubCloneResponse.fromJson(json),
        throwsA(anything),
      );
    }
  });
}
