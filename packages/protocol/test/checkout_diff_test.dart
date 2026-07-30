import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('uncommitted compare discards baseRef and default flags on wire', () {
    final request = SubscribeCheckoutDiffRequest.fromJson({
      'type': SubscribeCheckoutDiffRequest.type,
      'subscriptionId': 'sub-1',
      'cwd': '/repo',
      'compare': {
        'mode': 'uncommitted',
        'baseRef': 'origin/main',
        'ignoreWhitespace': false,
      },
      'requestId': 'req-1',
    });

    expect(request.compare.baseRef, isNull);
    expect(request.toJson(), {
      'type': SubscribeCheckoutDiffRequest.type,
      'subscriptionId': 'sub-1',
      'cwd': '/repo',
      'compare': {'mode': 'uncommitted'},
      'requestId': 'req-1',
    });
  });

  test('response and update preserve the frozen payload shape', () {
    const payload = CheckoutDiffPayload(
      subscriptionId: 'sub-1',
      cwd: '/repo',
      files: [
        CheckoutDiffFile(
          path: 'lib/a.dart',
          isNew: false,
          isDeleted: false,
          additions: 1,
          deletions: 1,
          status: CheckoutDiffFileStatus.ok,
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
                CheckoutDiffLine(
                  type: CheckoutDiffLineType.remove,
                  content: 'old',
                ),
                CheckoutDiffLine(
                  type: CheckoutDiffLineType.add,
                  content: 'new',
                ),
              ],
            ),
          ],
        ),
      ],
      error: null,
    );
    final response = SubscribeCheckoutDiffResponse(
      payload: payload,
      requestId: 'req-1',
    );

    final decoded = SubscribeCheckoutDiffResponse.fromJson(response.toJson());
    expect(decoded.requestId, 'req-1');
    expect(decoded.payload.files.single.path, 'lib/a.dart');
    expect(
      decoded.payload.files.single.hunks.single.lines.map((line) => line.type),
      [
        CheckoutDiffLineType.header,
        CheckoutDiffLineType.remove,
        CheckoutDiffLineType.add,
      ],
    );
    expect(
      CheckoutDiffUpdate.fromJson(
        CheckoutDiffUpdate(payload).toJson(),
      ).payload.subscriptionId,
      'sub-1',
    );
  });

  test('legacy conversion restores line numbers and hunk header', () {
    final payload = checkoutDiffPayloadFromLegacy(
      subscriptionId: 'sub-1',
      cwd: '/repo',
      diff: const DiffResponse(
        files: [
          DiffFile(
            path: 'a.txt',
            status: DiffFileStatus.modified,
            additions: 1,
            deletions: 1,
            hunks: [
              DiffHunk(
                header: '@@ -3,2 +3,2 @@ section',
                lines: [
                  DiffLine(
                    type: DiffLineType.context,
                    text: 'same',
                    oldLineNo: 3,
                    newLineNo: 3,
                  ),
                  DiffLine(type: DiffLineType.del, text: 'old', oldLineNo: 4),
                  DiffLine(type: DiffLineType.add, text: 'new', newLineNo: 4),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    final restored = payload.toLegacyDiff().files.single;
    expect(restored.hunks.single.header, '@@ -3,2 +3,2 @@ section');
    expect(restored.hunks.single.lines[0].oldLineNo, 3);
    expect(restored.hunks.single.lines[1].oldLineNo, 4);
    expect(restored.hunks.single.lines[2].newLineNo, 4);
  });

  test('too-large placeholders survive both conversion directions', () {
    final payload = checkoutDiffPayloadFromLegacy(
      subscriptionId: 'sub-1',
      cwd: '/repo',
      diff: const DiffResponse(
        files: [
          DiffFile(
            path: 'generated.js',
            status: DiffFileStatus.modified,
            tooLarge: true,
            additions: 1000,
            deletions: 900,
          ),
        ],
      ),
    );

    expect(payload.files.single.status, CheckoutDiffFileStatus.too_large);
    final restored = payload.toLegacyDiff().files.single;
    expect(restored.tooLarge, isTrue);
    expect(restored.binary, isFalse);
  });
}
