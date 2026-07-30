import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('directory creation request and responses preserve the frozen wire', () {
    const request = ProjectCreateDirectoryRequest(
      parentPath: '/workspace',
      name: 'new-project',
      requestId: 'create-1',
    );
    expect(
      ProjectCreateDirectoryRequest.fromJson(request.toJson()).toJson(),
      request.toJson(),
    );

    for (final response in const [
      ProjectCreateDirectoryResponse(
        requestId: 'create-1',
        directoryPath: '/workspace/new-project',
        project: WorkspaceProjectDescriptor(
          projectId: 'project-1',
          projectDisplayName: 'new-project',
          projectRootPath: '/workspace/new-project',
          projectKind: WorkspaceProjectKind.nonGit,
        ),
        error: null,
        errorCode: null,
      ),
      ProjectCreateDirectoryResponse(
        requestId: 'create-2',
        directoryPath: '/workspace/existing',
        project: null,
        error: 'Directory already exists',
        errorCode: 'directory_exists',
      ),
    ]) {
      expect(
        ProjectCreateDirectoryResponse.fromJson(response.toJson()).toJson(),
        response.toJson(),
      );
    }
  });

  test('directory error codes preserve known values and tolerate new ones', () {
    expect(
      ProjectCreateDirectoryErrorCode.tryFromWire('permission_denied'),
      ProjectCreateDirectoryErrorCode.permissionDenied,
    );
    expect(ProjectCreateDirectoryErrorCode.tryFromWire('new_code'), isNull);
  });

  test('directory creation boundaries reject malformed payloads', () {
    expect(
      () => ProjectCreateDirectoryRequest.fromJson(const {
        'type': ProjectCreateDirectoryRequest.type,
        'parentPath': '/workspace',
        'name': 1,
        'requestId': 'request',
      }),
      throwsFormatException,
    );
    expect(
      () => ProjectCreateDirectoryResponse.fromJson(const {
        'type': ProjectCreateDirectoryResponse.type,
        'payload': {
          'requestId': 'request',
          'directoryPath': 1,
          'project': null,
          'error': null,
          'errorCode': null,
        },
      }),
      throwsFormatException,
    );
  });
}
