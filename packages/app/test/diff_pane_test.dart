import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/external_url_launcher.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/changes_preferences_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/diff/diff_pane.dart';
import 'package:coding_agent_app/workspace/workspace_file_open.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _cwd = '/work/demo';

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({this.diff = const DiffResponse(files: [])})
    : super(uri: Uri.parse('ws://fake'));

  final requests = <(String, Map<String, Object?>)>[];
  final sessionRequests = <Map<String, Object?>>[];
  final DiffResponse diff;
  bool failNextGet = false;
  final downloadRequests = <(String, String)>[];

  @override
  Future<Uri> requestFileDownloadUri({
    required String cwd,
    required String path,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    downloadRequests.add((cwd, path));
    return Uri.parse('http://fake/api/files/download?token=once');
  }

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Stream<CheckoutDiffUpdate> get checkoutDiffUpdates => const Stream.empty();

  @override
  Stream<CheckoutStatusUpdate> get checkoutStatusUpdates =>
      const Stream.empty();

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    if (type == MessageTypes.diffGetRequest) {
      if (failNextGet) {
        failNextGet = false;
        throw StateError('diff unavailable');
      }
      return diff.toJson();
    }
    return const {};
  }

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    sessionRequests.add(message);
    if (message['type'] == CheckoutStatusRequest.type) {
      return CheckoutStatusResponse(
        CheckoutStatusGitNonPaseo(
          cwd: message['cwd']! as String,
          repoRoot: _cwd,
          mainRepoRoot: null,
          currentBranch: 'feature',
          isDirty: false,
          baseRef: 'main',
          aheadBehind: null,
          aheadOfOrigin: null,
          behindOfOrigin: null,
          hasRemote: false,
          remoteUrl: null,
          error: null,
          requestId: message['requestId']! as String,
        ),
      ).toJson();
    }
    if (message['type'] == SubscribeCheckoutDiffRequest.type) {
      return SubscribeCheckoutDiffResponse(
        payload: CheckoutDiffPayload(
          subscriptionId: message['subscriptionId']! as String,
          cwd: message['cwd']! as String,
          files: const [],
          error: null,
        ),
        requestId: message['requestId']! as String,
      ).toJson();
    }
    return const {};
  }
}

Future<ProviderContainer> pumpDiffPane(
  WidgetTester tester, {
  FakeDaemonClient? client,
  bool live = false,
  bool compact = false,
  String? focusPath,
  int? focusRequestId,
  bool changesTabOpen = false,
  VoidCallback? onToggleChangesTab,
  ValueChanged<String>? onChangesFilePress,
  ValueChanged<WorkspaceFileOpenRequest>? onOpenWorkspaceFile,
  ValueChanged<String>? onAddToChat,
  ExternalUrlLauncher? launcher,
}) async {
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client ?? FakeDaemonClient()),
      changesPreferencesStorageProvider.overrideWithValue(
        _MemoryChangesStorage(),
      ),
      if (launcher != null)
        externalUrlLauncherProvider.overrideWithValue(launcher),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: ScaffoldPage(
          content: DiffPane(
            cwd: _cwd,
            serverId: live ? 'server-1' : null,
            workspaceId: live ? 'workspace-1' : null,
            compact: compact,
            focusPath: focusPath,
            focusRequestId: focusRequestId,
            changesTabOpen: changesTabOpen,
            onToggleChangesTab: onToggleChangesTab,
            onChangesFilePress: onChangesFilePress,
            onOpenWorkspaceFile: onOpenWorkspaceFile,
            onAddToChat: onAddToChat,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
  return container;
}

void main() {
  testWidgets('compact Changes toolbar exposes the open-tab toggle state', (
    tester,
  ) async {
    var toggleCount = 0;
    await pumpDiffPane(
      tester,
      compact: true,
      onToggleChangesTab: () => toggleCount++,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('changes-open-tab')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Open Changes tab',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('changes-open-tab')));
    expect(toggleCount, 1);

    await pumpDiffPane(
      tester,
      compact: true,
      changesTabOpen: true,
      onToggleChangesTab: () => toggleCount++,
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Close Changes tab',
      ),
      findsOneWidget,
    );
    final selectedToggle = tester.widget<IconButton>(
      find.byKey(const ValueKey('changes-open-tab')),
    );
    final toggleContext = tester.element(
      find.byKey(const ValueKey('changes-open-tab')),
    );
    expect(
      selectedToggle.style?.backgroundColor?.resolve(const {}),
      toggleContext.paseoPalette.surface3,
    );
  });

  testWidgets('forwards a file focus request into the diff viewport', (
    tester,
  ) async {
    final files = [
      for (var index = 0; index < 30; index++)
        DiffFile(
          path: 'lib/file_${index.toString().padLeft(2, '0')}.dart',
          status: DiffFileStatus.modified,
        ),
    ];
    const targetPath = 'lib/file_15.dart';

    await pumpDiffPane(
      tester,
      client: FakeDaemonClient(diff: DiffResponse(files: files)),
      focusPath: targetPath,
      focusRequestId: 1,
    );
    await tester.pumpAndSettle();

    final viewportTop = tester
        .getTopLeft(find.byKey(const ValueKey('git-diff-scroll')))
        .dy;
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('diff-file-15'))).dy,
      closeTo(viewportTop, 1),
    );
  });

  testWidgets('renders the diff and the cwd label', (tester) async {
    await pumpDiffPane(tester);

    expect(find.text('No changes'), findsOneWidget);
    expect(find.text(_cwd), findsOneWidget);
  });

  testWidgets('the refresh button re-issues diff.get.request', (tester) async {
    final client = FakeDaemonClient();
    final container = await pumpDiffPane(tester, client: client);
    expect(container.read(daemonClientProvider), same(client));

    client.requests.clear();
    await tester.tap(find.byKey(const ValueKey('changes-options-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      client.requests.any((r) => r.$1 == MessageTypes.diffGetRequest),
      isTrue,
    );
  });

  testWidgets('a fetch failure shows an inline error', (tester) async {
    final client = FakeDaemonClient()..failNextGet = true;
    await pumpDiffPane(tester, client: client);

    expect(find.textContaining('Failed to load diff'), findsOneWidget);
  });

  testWidgets('layout toggle persists the requested split preference', (
    tester,
  ) async {
    final container = await pumpDiffPane(tester);

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            widget.message == 'Switch to side-by-side diff',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('changes-toggle-layout')));
    await tester.pumpAndSettle();

    expect(
      container.read(changesPreferencesProvider).requireValue.layout,
      ChangesLayout.split,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && widget.message == 'Switch to unified diff',
      ),
      findsOneWidget,
    );
  });

  testWidgets('view and expand controls drive the Paseo diff list', (
    tester,
  ) async {
    const diff = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/nested/change.dart',
          status: DiffFileStatus.modified,
          additions: 1,
          hunks: [
            DiffHunk(
              header: '@@ -0,0 +1 @@',
              lines: [
                DiffLine(
                  type: DiffLineType.add,
                  text: 'added line',
                  newLineNo: 1,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final container = await pumpDiffPane(
      tester,
      client: FakeDaemonClient(diff: diff),
    );

    expect(find.text('lib/nested/change.dart'), findsOneWidget);
    expect(find.text('added line'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Show folder tree',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Expand all files',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('changes-options-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrap long lines'));
    await tester.pumpAndSettle();
    expect(
      container.read(changesPreferencesProvider).requireValue.wrapLines,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('changes-toggle-expand-all')));
    await tester.pumpAndSettle();
    expect(find.text('added line'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == 'Collapse all files',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('changes-toggle-view-mode')));
    await tester.pumpAndSettle();
    expect(
      container.read(changesPreferencesProvider).requireValue.viewMode,
      ChangesViewMode.tree,
    );
    expect(find.text('lib/nested'), findsOneWidget);
    expect(find.text('change.dart'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && widget.message == 'Show flat file list',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('changes-toggle-expand-all')));
    await tester.pumpAndSettle();
    expect(find.text('added line'), findsNothing);
    expect(find.text('change.dart'), findsNothing);
    expect(find.text('lib/nested'), findsOneWidget);
  });

  testWidgets('live mode follows base status and toggles whitespace compare', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpDiffPane(tester, client: client, live: true);

    expect(find.text('Against main'), findsOneWidget);
    expect(
      client.sessionRequests
          .where(
            (request) => request['type'] == SubscribeCheckoutDiffRequest.type,
          )
          .single['compare'],
      {'mode': 'base', 'baseRef': 'main'},
    );

    await tester.tap(find.byKey(const ValueKey('changes-options-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide whitespace'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    final diffRequests = client.sessionRequests
        .where(
          (request) => request['type'] == SubscribeCheckoutDiffRequest.type,
        )
        .toList();
    expect(diffRequests, hasLength(2));
    expect(diffRequests.last['compare'], {
      'mode': 'base',
      'baseRef': 'main',
      'ignoreWhitespace': true,
    });
  });

  testWidgets('compact diff keeps view, expand, and options controls', (
    tester,
  ) async {
    const diff = DiffResponse(
      files: [
        DiffFile(
          path: 'lib/change.dart',
          status: DiffFileStatus.modified,
          additions: 1,
        ),
      ],
    );
    await pumpDiffPane(
      tester,
      client: FakeDaemonClient(diff: diff),
      compact: true,
    );

    expect(
      find.byKey(const ValueKey('changes-toggle-view-mode')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('changes-toggle-expand-all')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('changes-options-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('changes-toggle-layout')), findsNothing);
  });

  testWidgets(
    'file actions open, attach, and download through workspace APIs',
    (tester) async {
      const diff = DiffResponse(
        files: [
          DiffFile(
            path: 'lib/change.dart',
            status: DiffFileStatus.modified,
            additions: 1,
          ),
        ],
      );
      final client = FakeDaemonClient(diff: diff);
      final launcher = _FakeExternalUrlLauncher();
      WorkspaceFileOpenRequest? opened;
      final attached = <String>[];
      await pumpDiffPane(
        tester,
        client: client,
        launcher: launcher,
        onOpenWorkspaceFile: (request) => opened = request,
        onAddToChat: attached.add,
      );

      Future<void> choose(String label) async {
        await tester.tap(find.byKey(const ValueKey('diff-file-0-actions')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      await choose('Open file');
      expect(opened?.location.path, 'lib/change.dart');
      expect(opened?.disposition, OpenFileDisposition.main);

      await choose('Add to chat…');
      expect(attached, ['lib/change.dart']);

      await choose('Download');
      expect(client.downloadRequests, [(_cwd, 'lib/change.dart')]);
      expect(launcher.opened, ['http://fake/api/files/download?token=once']);
    },
  );
}

final class _FakeExternalUrlLauncher implements ExternalUrlLauncher {
  final opened = <String>[];

  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return true;
  }
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
