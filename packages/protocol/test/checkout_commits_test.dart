import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  const file = CheckoutCommitFile(
    path: 'lib/main.dart',
    additions: 3,
    deletions: 1,
    status: CheckoutCommitFileStatus.modified,
  );
  const commit = CheckoutCommit(
    sha: '0123456789abcdef',
    shortSha: '0123456',
    subject: 'Add commit history',
    authorName: 'Test Author',
    authorDate: '2026-07-30T01:02:03.000Z',
    isOnRemote: false,
    isOnBase: false,
    files: [file],
  );

  test('commit list request and response match Paseo 0.2.0 wire shape', () {
    const request = CheckoutCommitsListRequest(
      cwd: '/repo',
      requestId: 'list-1',
    );
    const response = CheckoutCommitsListResponse(
      cwd: '/repo',
      baseRef: 'origin/main',
      commits: [commit],
      error: null,
      requestId: 'list-1',
    );

    expect(request.toJson(), {
      'type': 'checkout.commits.list.request',
      'cwd': '/repo',
      'requestId': 'list-1',
    });
    expect(
      CheckoutCommitsListRequest.fromJson(request.toJson()).toJson(),
      request.toJson(),
    );
    expect(
      CheckoutCommitsListResponse.fromJson(response.toJson()).toJson(),
      response.toJson(),
    );
  });

  test('legacy commits without base classification remain decodable', () {
    final json = commit.toJson()..remove('isOnBase');
    final decoded = CheckoutCommit.fromJson(json);
    expect(decoded.isOnBase, isNull);
    expect(decoded.toJson(), json);
    expect(
      () => CheckoutCommit.fromJson({...json, 'isOnBase': 'false'}),
      throwsFormatException,
    );
  });

  test('commit file diff round-trips text, binary null, and error', () {
    const request = CheckoutCommitFileDiffRequest(
      cwd: '/repo',
      sha: '0123456789abcdef',
      path: 'lib/main.dart',
      requestId: 'diff-1',
    );
    const file = CheckoutDiffFile(
      path: 'lib/main.dart',
      isNew: false,
      isDeleted: false,
      additions: 1,
      deletions: 1,
      hunks: [
        CheckoutDiffHunk(
          oldStart: 1,
          oldCount: 1,
          newStart: 1,
          newCount: 1,
          lines: [
            CheckoutDiffLine(
              type: CheckoutDiffLineType.header,
              content: '@@ -1 +1 @@',
            ),
          ],
        ),
      ],
      status: CheckoutDiffFileStatus.ok,
    );
    const success = CheckoutCommitFileDiffResponse(
      cwd: '/repo',
      sha: '0123456789abcdef',
      path: 'lib/main.dart',
      file: file,
      error: null,
      requestId: 'diff-1',
    );
    const binary = CheckoutCommitFileDiffResponse(
      cwd: '/repo',
      sha: '0123456789abcdef',
      path: 'asset.bin',
      file: null,
      error: null,
      requestId: 'diff-2',
    );

    expect(
      CheckoutCommitFileDiffRequest.fromJson(request.toJson()).toJson(),
      request.toJson(),
    );
    expect(
      CheckoutCommitFileDiffResponse.fromJson(success.toJson()).toJson(),
      success.toJson(),
    );
    expect(
      CheckoutCommitFileDiffResponse.fromJson(binary.toJson()).toJson(),
      binary.toJson(),
    );
  });
}
