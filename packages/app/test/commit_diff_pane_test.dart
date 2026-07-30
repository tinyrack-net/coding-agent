import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/changes_preferences_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/diff/commit_diff_pane.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _sha = 'abcdef0123456789';

final class _CommitDaemonClient extends DaemonClient {
  _CommitDaemonClient() : super(uri: Uri.parse('ws://fake')) {
    serverInfo = const ServerInfoStatus(
      serverId: 'server-1',
      hostname: 'test',
      version: '0.2.0',
      desktopManaged: false,
      features: {'commitsList': true, 'commitBaseClassification': true},
    );
  }

  final requests = <Map<String, Object?>>[];

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add(message);
    if (message['type'] == CheckoutCommitsListRequest.type) {
      return CheckoutCommitsListResponse(
        cwd: '/repo',
        baseRef: 'main',
        commits: const [
          CheckoutCommit(
            sha: _sha,
            shortSha: 'abcdef0',
            subject: 'Text and binary',
            authorName: 'Test',
            authorDate: '2026-07-30T00:00:00.000Z',
            isOnRemote: false,
            isOnBase: false,
            files: [
              CheckoutCommitFile(
                path: 'lib/main.dart',
                additions: 1,
                deletions: 0,
                status: CheckoutCommitFileStatus.modified,
              ),
              CheckoutCommitFile(
                path: 'asset.bin',
                additions: 0,
                deletions: 0,
                status: CheckoutCommitFileStatus.added,
              ),
            ],
          ),
        ],
        error: null,
        requestId: message['requestId']! as String,
      ).toJson();
    }
    if (message['type'] == CheckoutCommitFileDiffRequest.type) {
      final path = message['path']! as String;
      return CheckoutCommitFileDiffResponse(
        cwd: '/repo',
        sha: _sha,
        path: path,
        file: path == 'asset.bin'
            ? null
            : const CheckoutDiffFile(
                path: 'lib/main.dart',
                isNew: false,
                isDeleted: false,
                additions: 1,
                deletions: 0,
                hunks: [
                  CheckoutDiffHunk(
                    oldStart: 1,
                    oldCount: 0,
                    newStart: 1,
                    newCount: 1,
                    lines: [
                      CheckoutDiffLine(
                        type: CheckoutDiffLineType.header,
                        content: '@@ -1,0 +1 @@',
                      ),
                      CheckoutDiffLine(
                        type: CheckoutDiffLineType.add,
                        content: 'void main() {}',
                      ),
                    ],
                  ),
                ],
                status: CheckoutDiffFileStatus.ok,
              ),
        error: null,
        requestId: message['requestId']! as String,
      ).toJson();
    }
    throw StateError('Unexpected request: ${message['type']}');
  }
}

void main() {
  testWidgets('loads all commit files in parallel and synthesizes binary', (
    tester,
  ) async {
    final client = _CommitDaemonClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          daemonClientProvider.overrideWithValue(client),
          changesPreferencesStorageProvider.overrideWithValue(
            _MemoryChangesStorage(),
          ),
        ],
        child: const FluentApp(
          home: ScaffoldPage(
            content: CommitDiffPane(
              serverId: 'server-1',
              cwd: '/repo',
              sha: _sha,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('lib/main.dart'), findsOneWidget);
    expect(find.text('asset.bin'), findsOneWidget);
    await tester.tap(find.text('asset.bin'));
    await tester.pumpAndSettle();
    expect(find.text('Binary file'), findsOneWidget);
    expect(
      client.requests.where(
        (request) => request['type'] == CheckoutCommitFileDiffRequest.type,
      ),
      hasLength(2),
    );
    expect(
      find.byKey(const ValueKey('commit-diff-layout-toggle')),
      findsOneWidget,
    );
  });

  testWidgets('shows host upgrade guidance without both capabilities', (
    tester,
  ) async {
    final client = _CommitDaemonClient()
      ..serverInfo = const ServerInfoStatus(
        serverId: 'server-1',
        hostname: 'test',
        version: 'old',
        desktopManaged: false,
      );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [daemonClientProvider.overrideWithValue(client)],
        child: const FluentApp(
          home: ScaffoldPage(
            content: CommitDiffPane(
              serverId: 'server-1',
              cwd: '/repo',
              sha: _sha,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Update the host to view commit diffs.'), findsOneWidget);
    expect(client.requests, isEmpty);
  });
}

final class _MemoryChangesStorage implements ChangesPreferencesStorage {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }
}
