import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('parses file explorer defaults and binary capability', () {
    final defaults = FileExplorerRequest.fromJson({
      'type': 'file_explorer_request',
      'cwd': r'C:\repo',
      'mode': 'list',
      'requestId': 'r1',
    });
    expect(defaults.path, '.');
    expect(defaults.mode, FileExplorerMode.list);
    expect(defaults.acceptBinary, isFalse);

    final binary = FileExplorerRequest.fromJson({
      'cwd': '/repo',
      'path': 'image.png',
      'mode': 'file',
      'requestId': 'r2',
      'acceptBinary': true,
    });
    expect(binary.mode, FileExplorerMode.file);
    expect(binary.acceptBinary, isTrue);
  });

  test('parses subscribe, unsubscribe, and optimistic write requests', () {
    final subscribe = FileSubscribeRequest.fromJson({
      'cwd': '/repo',
      'path': 'a.txt',
      'subscriptionId': 's1',
      'requestId': 'r1',
    });
    expect(subscribe.subscriptionId, 's1');
    final unsubscribe = FileUnsubscribeRequest.fromJson({
      'subscriptionId': 's1',
      'requestId': 'r2',
    });
    expect(unsubscribe.requestId, 'r2');
    final write = FileWriteRequest.fromJson({
      'cwd': '/repo',
      'path': 'a.txt',
      'content': 'next',
      'expectedModifiedAt': '2026-01-01T00:00:00.000Z',
      'expectedRevision': 'opaque',
      'requestId': 'r3',
    });
    expect(write.expectedRevision, 'opaque');
    expect(write.content, 'next');
    final icon = ProjectIconRequest.fromJson({
      'cwd': '/repo',
      'requestId': 'icon',
    });
    expect(icon.cwd, '/repo');
  });

  test('rejects malformed file session messages', () {
    expect(
      () => FileExplorerRequest.fromJson({
        'cwd': '/repo',
        'mode': 'wat',
        'requestId': 'r',
      }),
      throwsFormatException,
    );
    expect(
      () => FileSubscribeRequest.fromJson({
        'cwd': '/repo',
        'path': 'a',
        'subscriptionId': 1,
        'requestId': 'r',
      }),
      throwsFormatException,
    );
    expect(
      () => FileUnsubscribeRequest.fromJson({
        'subscriptionId': 's',
        'requestId': 1,
      }),
      throwsFormatException,
    );
    expect(
      () => FileWriteRequest.fromJson({
        'cwd': '/repo',
        'path': 'a',
        'content': 'x',
        'expectedModifiedAt': 'now',
        'expectedRevision': 1,
        'requestId': 'r',
      }),
      throwsFormatException,
    );
    expect(
      () => ProjectIconRequest.fromJson({'cwd': '/repo', 'requestId': 1}),
      throwsFormatException,
    );
  });
}
