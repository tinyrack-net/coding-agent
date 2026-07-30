import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/attachments/memory_attachment_store.dart';
import 'package:coding_agent_app/composer/composer_image_attachment_service.dart';
import 'package:coding_agent_app/composer/composer_clipboard_reader.dart';
import 'package:coding_agent_app/composer/composer_draft_store.dart';
import 'package:coding_agent_app/composer/dictation_shortcut_controller.dart';
import 'package:coding_agent_app/keyboard/keyboard_action_dispatcher.dart';
import 'package:coding_agent_app/keyboard/shortcut_engine.dart';
import 'package:coding_agent_app/keyboard/shortcut_focus_scope.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/queued_messages_provider.dart';
import 'package:coding_agent_app/state/review_draft_provider.dart';
import 'package:coding_agent_app/state/timeline_provider.dart';
import 'package:coding_agent_app/state/workspace_attachments_provider.dart';
import 'package:coding_agent_app/widgets/composer.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';
import 'package:file_selector/file_selector.dart';

const _agent = AgentSummary(
  agentId: 'a1',
  title: 'Demo',
  cwd: '/work',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 0,
);
const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X1r0AAAAASUVORK5CYII=';

class FakeDaemonClient extends DaemonClient with LegacyAgentListFetchMixin {
  FakeDaemonClient() : super(uri: Uri.parse('ws://fake'));

  /// Only prompt/interrupt calls the test cares about; the incidental
  /// `agent.list.request` that `AgentsNotifier` issues on connect is handled
  /// separately below so it doesn't pollute assertions.
  final requests = <(String, Map<String, Object?>)>[];
  final sessionMessages = <Map<String, Object?>>[];
  Object? requestError;
  AgentSummary? knownAgent;
  List<AgentSlashCommand> commands = const [];
  List<DirectorySuggestionEntry> suggestions = const [];
  final suggestionRequests = <({String query, String? cwd, int? limit})>[];
  Object? suggestionError;
  AgentProviderNotice? sessionNotice;

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<AgentTimelinePage> fetchAgentTimeline({
    required String agentId,
    AgentTimelineDirection direction = AgentTimelineDirection.tail,
    AgentTimelineCursor? cursor,
    int limit = agentTimelineFetchPageSize,
    AgentTimelineProjection projection = AgentTimelineProjection.projected,
    Duration timeout = const Duration(seconds: 30),
  }) async => AgentTimelinePage.empty(
    agentId: agentId,
    direction: direction,
    projection: projection,
  );

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.agentListRequest) {
      final agent = knownAgent;
      return {
        'agents': agent == null ? const [] : [agent.toJson()],
      };
    }
    if (type == MessageTypes.agentTimelineFetchRequest) {
      return const TimelineFetchResponse(
        epoch: 0,
        lastSeq: 0,
        items: [],
      ).toJson();
    }
    requests.add((type, payload));
    final error = requestError;
    if (error != null) throw error;
    return const {};
  }

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    sessionMessages.add(message);
    final error = requestError;
    if (error != null) throw error;
    final type = message['type'];
    final responseType = switch (type) {
      'set_agent_mode_request' => 'set_agent_mode_response',
      'set_agent_model_request' => 'set_agent_model_response',
      'set_agent_thinking_request' => 'set_agent_thinking_response',
      'set_agent_feature_request' => 'set_agent_feature_response',
      _ => null,
    };
    if (responseType != null) {
      return {
        'type': responseType,
        'payload': {
          'requestId': message['requestId'],
          'agentId': message['agentId'],
          'accepted': true,
          'error': null,
          if (sessionNotice case final notice?) 'notice': notice.toJson(),
        },
      };
    }
    return const {};
  }

  @override
  Future<ListCommandsResponse> listCommands({
    required String agentId,
    ListCommandsDraftConfig? draftConfig,
    Duration timeout = const Duration(seconds: 30),
  }) async => ListCommandsResponse(
    agentId: agentId,
    commands: commands,
    requestId: 'commands-1',
  );

  @override
  Future<DirectorySuggestionsResponse> getDirectorySuggestions({
    required String query,
    String? cwd,
    bool? includeFiles,
    bool? includeDirectories,
    DirectorySuggestionMatchMode? matchMode,
    int? limit,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    suggestionRequests.add((query: query, cwd: cwd, limit: limit));
    final error = suggestionError;
    if (error != null) throw error;
    return DirectorySuggestionsResponse(
      directories: [
        for (final entry in suggestions)
          if (entry.kind == DirectorySuggestionKind.directory) entry.path,
      ],
      entries: suggestions,
      requestId: 'suggestions-1',
    );
  }
}

final class _ClipboardReader implements ComposerClipboardReader {
  const _ClipboardReader({this.image, this.text, this.imageError});

  final Uint8List? image;
  final String? text;
  final Object? imageError;

  @override
  Future<Uint8List?> readPngImage() async {
    final error = imageError;
    if (error != null) throw error;
    return image;
  }

  @override
  Future<String?> readText() async => text;
}

final class _MemoryDraftStore implements ComposerDraftStore {
  final drafts = <String, ComposerDraft>{};
  final cleared = <ComposerDraftLifecycle>[];

  @override
  Future<ComposerDraft?> load(String draftKey) async => drafts[draftKey];

  @override
  Future<void> save(String draftKey, ComposerDraft draft) async {
    drafts[draftKey] = draft;
  }

  @override
  Future<ComposerDraft> attachWorkspaceFile(
    String draftKey,
    ComposerWorkspaceFileAttachment attachment,
  ) async {
    final current = drafts[draftKey];
    final draft = ComposerDraft(
      text: current?.text ?? '',
      images: current?.images ?? const [],
      workspaceFiles: appendComposerWorkspaceFile(
        current?.workspaceFiles ?? const [],
        attachment,
      ),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    drafts[draftKey] = draft;
    return draft;
  }

  @override
  Future<void> clear(
    String draftKey, {
    required ComposerDraftLifecycle lifecycle,
  }) async {
    drafts.remove(draftKey);
    cleared.add(lifecycle);
  }

  @override
  Future<Set<String>> collectActiveAttachmentIds() async => {
    for (final draft in drafts.values)
      if (draft.lifecycle == ComposerDraftLifecycle.active)
        for (final image in draft.images) image.id,
  };
}

Future<ProviderContainer> pumpComposer(
  WidgetTester tester,
  FakeDaemonClient client, {
  AgentSummary agent = _agent,
  VoidCallback? onInputFocus,
  VoidCallback? onPromptSend,
  ComposerImageAttachmentService? imageAttachmentService,
  ComposerClipboardReader clipboardReader = const _ClipboardReader(),
  ComposerDraftStore? draftStore,
  ValueChanged<ComposerClientSlashCommand>? onClientSlashCommand,
  ValueListenable<bool>? voiceOverlayVisibility,
  Widget? voiceOverlay,
  DictationShortcutController? dictationShortcutController,
}) async {
  client.knownAgent = agent;
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  container.read(agentsProvider.notifier).upsert(agent);

  Widget buildComposer(bool showVoiceOverlay) => Composer(
    agentId: 'a1',
    onInputFocus: onInputFocus,
    onPromptSend: onPromptSend,
    imageAttachmentService:
        imageAttachmentService ??
        ComposerImageAttachmentService(
          store: () async => MemoryAttachmentStore(),
        ),
    clipboardReader: clipboardReader,
    draftStore: draftStore ?? _MemoryDraftStore(),
    onClientSlashCommand: onClientSlashCommand,
    showVoiceOverlay: showVoiceOverlay,
    voiceOverlay: voiceOverlay,
    dictationShortcutController: dictationShortcutController,
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: ScaffoldPage(
          content: voiceOverlayVisibility == null
              ? buildComposer(false)
              : ValueListenableBuilder<bool>(
                  valueListenable: voiceOverlayVisibility,
                  builder: (_, visible, _) => buildComposer(visible),
                ),
        ),
      ),
    ),
  );
  // Let AgentsNotifier's connect-triggered agent.list.request refresh settle.
  await tester.pump(const Duration(milliseconds: 150));
  return container;
}

void main() {
  testWidgets(
    'dictation submit while paused restores a visible interactive composer',
    (tester) async {
      final overlayVisible = ValueNotifier(true);
      addTearDown(overlayVisible.dispose);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await pumpComposer(
        tester,
        FakeDaemonClient(),
        voiceOverlayVisibility: overlayVisible,
        voiceOverlay: const ColoredBox(
          key: ValueKey('dictation-overlay'),
          color: Color(0xFF000000),
        ),
      );

      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('composer-input-surface')),
            )
            .opacity,
        0,
      );
      expect(
        tester
            .widget<IgnorePointer>(
              find.byKey(const ValueKey('composer-input-pointer-state')),
            )
            .ignoring,
        isTrue,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      overlayVisible.value = false;
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('composer-input-surface')),
            )
            .opacity,
        1,
      );
      expect(
        tester
            .widget<IgnorePointer>(
              find.byKey(const ValueKey('composer-input-pointer-state')),
            )
            .ignoring,
        isFalse,
      );
      expect(find.byType(TextBox).hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('composer-voice-overlay-surface')),
            )
            .opacity,
        0,
      );
    },
  );

  testWidgets('reports input focus and non-empty prompt send triggers', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    var inputFocusCount = 0;
    var promptSendCount = 0;
    await pumpComposer(
      tester,
      client,
      onInputFocus: () => inputFocusCount++,
      onPromptSend: () => promptSendCount++,
    );

    await tester.tap(find.byType(TextBox));
    await tester.pump();
    expect(inputFocusCount, 1);

    await tester.enterText(find.byType(TextBox), 'hello');
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));
    expect(promptSendCount, 1);
  });

  testWidgets('typing and sending a message prompts the agent and clears '
      'the field', (tester) async {
    final client = FakeDaemonClient();
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), 'hello agent');
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));

    final (type, payload) = client.requests.single;
    expect(type, MessageTypes.agentPromptRequest);
    expect(payload['agentId'], 'a1');
    expect(payload['text'], 'hello agent');
    expect(payload['clientMessageId'], isNotEmpty);

    final textField = tester.widget<TextBox>(find.byType(TextBox));
    expect(textField.controller!.text, isEmpty);
  });

  testWidgets('slash autocomplete merges client and provider commands', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..commands = const [
        AgentSlashCommand(
          name: 'review',
          description: 'Review changes',
          argumentHint: '<path>',
          kind: AgentSlashCommandKind.skill,
        ),
        AgentSlashCommand(
          name: 'compact',
          description: 'Compact context',
          argumentHint: '',
        ),
      ];
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), '/');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('composer-command-autocomplete')),
      findsOneWidget,
    );
    expect(find.text('/exit'), findsWidgets);
    expect(find.text('/clear'), findsWidgets);
    expect(find.text('/review'), findsWidgets);
    expect(find.text('/compact'), findsWidgets);
  });

  testWidgets('inline slash autocomplete exposes provider skills only', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..commands = const [
        AgentSlashCommand(
          name: 'review',
          description: 'Review changes',
          argumentHint: '',
          kind: AgentSlashCommandKind.skill,
        ),
        AgentSlashCommand(
          name: 'compact',
          description: 'Compact context',
          argumentHint: '',
        ),
      ];
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), 'please /');
    await tester.pumpAndSettle();

    expect(find.text('/review'), findsWidgets);
    expect(find.text('/compact'), findsNothing);
    expect(find.text('/exit'), findsNothing);
  });

  testWidgets('selecting autocomplete replaces only the active slash token', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..commands = const [
        AgentSlashCommand(
          name: 'review',
          description: 'Review changes',
          argumentHint: '',
          kind: AgentSlashCommandKind.skill,
        ),
      ];
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), 'please /rev');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('composer-command-autocomplete-review')),
    );
    await tester.pump(const Duration(milliseconds: 150));

    final textBox = tester.widget<TextBox>(find.byType(TextBox));
    expect(textBox.controller!.text, 'please /review ');
  });

  testWidgets('inline autocomplete keeps the caret before trailing text', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..commands = const [
        AgentSlashCommand(
          name: 'review',
          description: 'Review changes',
          argumentHint: '',
          kind: AgentSlashCommandKind.skill,
        ),
      ];
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), 'please /rev before');
    final textBox = tester.widget<TextBox>(find.byType(TextBox));
    textBox.controller!.selection = const TextSelection.collapsed(offset: 11);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('composer-command-autocomplete-review')),
    );
    await tester.pump(const Duration(milliseconds: 150));

    expect(textBox.controller!.text, 'please /review before');
    expect(textBox.controller!.selection.extentOffset, 14);
  });

  testWidgets('autocomplete keyboard selection applies provider commands', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..commands = const [
        AgentSlashCommand(
          name: 'review',
          description: 'Review changes',
          argumentHint: '',
          kind: AgentSlashCommandKind.skill,
        ),
      ];
    await pumpComposer(tester, client);

    await tester.tap(find.byType(TextBox));
    await tester.enterText(find.byType(TextBox), '/rev');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final textBox = tester.widget<TextBox>(find.byType(TextBox));
    expect(textBox.controller!.text, '/review ');
  });

  testWidgets('client autocomplete dispatches immediate clear command', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    ComposerClientSlashCommand? selected;
    await pumpComposer(
      tester,
      client,
      onClientSlashCommand: (command) => selected = command,
    );

    await tester.tap(find.byType(TextBox));
    await tester.enterText(find.byType(TextBox), '/clear');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(selected, ComposerClientSlashCommand.clear);
  });

  testWidgets('autocomplete arrows wrap and Escape clears a root token', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(tester, client);

    await tester.tap(find.byType(TextBox));
    await tester.enterText(find.byType(TextBox), '/');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('composer-command-autocomplete-clear')),
          )
          .selected,
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    final textBox = tester.widget<TextBox>(find.byType(TextBox));
    expect(textBox.controller!.text, isEmpty);
  });

  testWidgets('file mentions search the workspace and quote selection', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..suggestions = const [
        DirectorySuggestionEntry(
          path: 'src/message.dart',
          kind: DirectorySuggestionKind.file,
        ),
        DirectorySuggestionEntry(
          path: 'src/models',
          kind: DirectorySuggestionKind.directory,
        ),
      ];
    await pumpComposer(
      tester,
      client,
      agent: const AgentSummary(
        agentId: 'a1',
        title: 'Demo',
        cwd: '/work/file-search',
        provider: 'claude',
        model: 'sonnet',
        mode: AgentMode.normal,
        runState: AgentRunState.idle,
        createdAtMs: 0,
      ),
    );

    await tester.enterText(find.byType(TextBox), 'review @mess next');
    final textBox = tester.widget<TextBox>(find.byType(TextBox));
    textBox.controller!.selection = const TextSelection.collapsed(offset: 12);
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pumpAndSettle();

    expect(client.suggestionRequests.last, (
      query: 'mess',
      cwd: '/work/file-search',
      limit: 50,
    ));
    expect(
      find.byKey(const ValueKey('composer-file-autocomplete')),
      findsOneWidget,
    );
    expect(find.text('src/message.dart'), findsOneWidget);
    expect(find.byIcon(FluentIcons.page), findsOneWidget);
    expect(find.byIcon(FluentIcons.folder), findsOneWidget);

    await tester.tap(
      find.byKey(
        const ValueKey('composer-file-autocomplete-file-src/message.dart'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(textBox.controller!.text, 'review "src/message.dart" next');
    expect(textBox.controller!.selection.extentOffset, 25);
  });

  testWidgets(
    'file mention mode takes precedence and supports keyboard apply',
    (tester) async {
      final client = FakeDaemonClient()
        ..commands = const [
          AgentSlashCommand(
            name: 'review',
            description: 'Review',
            argumentHint: '',
          ),
        ]
        ..suggestions = const [
          DirectorySuggestionEntry(
            path: 'src/review.dart',
            kind: DirectorySuggestionKind.file,
          ),
        ];
      await pumpComposer(
        tester,
        client,
        agent: const AgentSummary(
          agentId: 'a1',
          title: 'Demo',
          cwd: '/work/file-precedence',
          provider: 'claude',
          model: 'sonnet',
          mode: AgentMode.normal,
          runState: AgentRunState.idle,
          createdAtMs: 0,
        ),
      );

      await tester.tap(find.byType(TextBox));
      await tester.enterText(find.byType(TextBox), '/@rev');
      await tester.pump(const Duration(milliseconds: 181));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('composer-file-autocomplete')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('composer-command-autocomplete')),
        findsNothing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final textBox = tester.widget<TextBox>(find.byType(TextBox));
      expect(textBox.controller!.text, '/"src/review.dart"');
    },
  );

  testWidgets('file mention search errors and empty results remain visible', (
    tester,
  ) async {
    final client = FakeDaemonClient()..suggestionError = StateError('offline');
    await pumpComposer(
      tester,
      client,
      agent: const AgentSummary(
        agentId: 'a1',
        title: 'Demo',
        cwd: '/work/file-error',
        provider: 'claude',
        model: 'sonnet',
        mode: AgentMode.normal,
        runState: AgentRunState.idle,
        createdAtMs: 0,
      ),
    );

    await tester.enterText(find.byType(TextBox), '@missing');
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pumpAndSettle();
    expect(find.textContaining('offline'), findsOneWidget);

    client.suggestionError = null;
    await tester.enterText(find.byType(TextBox), '@empty');
    await tester.pump(const Duration(milliseconds: 181));
    await tester.pumpAndSettle();
    expect(find.text('No files'), findsOneWidget);
  });

  testWidgets('leading/trailing whitespace is trimmed before sending', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), '  hi  ');
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));

    final (_, payload) = client.requests.single;
    expect(payload['text'], 'hi');
  });

  testWidgets('sending with empty/whitespace-only text does nothing', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), '   ');
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));

    expect(client.requests, isEmpty);
  });

  testWidgets(
    'dropped images preview and submit through the frozen image array',
    (tester) async {
      final client = FakeDaemonClient();
      await pumpComposer(tester, client);
      final target = tester.widget<DropTarget>(find.byType(DropTarget));
      final position = DropEventDetails(
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      );
      target.onDragEntered!(position);
      await tester.pump();
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('composer-image-drop-overlay')),
            )
            .opacity,
        1,
      );
      target.onDragExited!(position);
      await tester.pump();
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('composer-image-drop-overlay')),
            )
            .opacity,
        0,
      );
      target.onDragEntered!(position);

      target.onDragDone!(
        DropDoneDetails(
          files: [
            DropItemFile.fromData(
              base64Decode(_onePixelPng),
              name: 'pixel.png',
              mimeType: 'image/png',
              path: 'pixel.png',
            ),
            DropItemFile.fromData(
              base64Decode(_onePixelPng),
              name: 'second.png',
              mimeType: 'image/png',
              path: 'second.png',
            ),
          ],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNWidgets(2));
      expect(
        tester
            .widgetList<Tooltip>(find.byType(Tooltip))
            .any((tooltip) => tooltip.message == 'pixel.png'),
        isTrue,
      );
      await tester.tap(find.byIcon(FluentIcons.chrome_close).first);
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.byIcon(FluentIcons.send));
      await tester.pump(const Duration(milliseconds: 150));

      final (_, payload) = client.requests.single;
      expect(payload['text'], '');
      expect(payload['images'], [
        {'data': _onePixelPng, 'mimeType': 'image/png'},
      ]);
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets('image picker adds multiple selections to the composer', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final store = MemoryAttachmentStore();
    await pumpComposer(
      tester,
      client,
      imageAttachmentService: ComposerImageAttachmentService(
        store: () async => store,
        picker: () async => [
          XFile.fromData(
            base64Decode(_onePixelPng),
            path: 'first.png',
            name: 'first.png',
            mimeType: 'image/png',
          ),
          XFile.fromData(
            base64Decode(_onePixelPng),
            path: 'second.png',
            name: 'second.png',
            mimeType: 'image/png',
          ),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('composer-image-picker')));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNWidgets(2));
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));
    final (_, payload) = client.requests.single;
    expect(payload['images'], hasLength(2));
  });

  testWidgets('hydrates and finalizes the agent-scoped persistent draft', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final attachmentStore = MemoryAttachmentStore();
    final metadata = await attachmentStore.save(
      id: 'draft-image',
      mimeType: 'image/png',
      fileName: 'draft.png',
      bytes: base64Decode(_onePixelPng),
    );
    final draftStore = _MemoryDraftStore()
      ..drafts['agent:local:a1'] = ComposerDraft(
        text: 'restored prompt',
        images: [metadata],
        updatedAt: 1,
      );
    await pumpComposer(
      tester,
      client,
      imageAttachmentService: ComposerImageAttachmentService(
        store: () async => attachmentStore,
      ),
      draftStore: draftStore,
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextBox>(find.byType(TextBox)).controller!.text,
      'restored prompt',
    );
    expect(find.byType(Image), findsOneWidget);

    await tester.enterText(find.byType(TextBox), 'updated prompt');
    await tester.pump();
    expect(draftStore.drafts['agent:local:a1']?.text, 'updated prompt');
    expect(
      draftStore.drafts['agent:local:a1']?.images.single.id,
      'draft-image',
    );

    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));
    expect(draftStore.drafts, isEmpty);
    expect(draftStore.cleared, contains(ComposerDraftLifecycle.sent));
  });

  testWidgets('Ctrl+V attaches a clipboard image without inserting text', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(
      tester,
      client,
      clipboardReader: _ClipboardReader(
        image: base64Decode(_onePixelPng),
        text: 'must not be inserted',
      ),
    );
    await tester.tap(find.byType(TextBox));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(tester.widget<TextBox>(find.byType(TextBox)).controller!.text, '');
  });

  testWidgets('Ctrl+V preserves text paste and the current selection', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(
      tester,
      client,
      clipboardReader: const _ClipboardReader(text: 'PASTE'),
    );
    await tester.tap(find.byType(TextBox));
    final controller = tester.widget<TextBox>(find.byType(TextBox)).controller!;
    controller.value = const TextEditingValue(
      text: 'abc',
      selection: TextSelection(baseOffset: 1, extentOffset: 2),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(controller.text, 'aPASTEc');
    expect(controller.selection, const TextSelection.collapsed(offset: 6));
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('clipboard image read failure falls back to text paste', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(
      tester,
      client,
      clipboardReader: const _ClipboardReader(
        text: 'fallback',
        imageError: FormatException('bad image'),
      ),
    );
    await tester.tap(find.byType(TextBox));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextBox>(find.byType(TextBox)).controller!.text,
      'fallback',
    );
  });

  testWidgets('context-menu Paste uses the same clipboard image flow', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(
      tester,
      client,
      clipboardReader: _ClipboardReader(image: base64Decode(_onePixelPng)),
    );
    final textBox = tester.widget<TextBox>(find.byType(TextBox));
    final editableFinder = find.byType(EditableText);
    final editableState = tester.state<EditableTextState>(editableFinder);
    editableState.clipboardStatus.value = ClipboardStatus.pasteable;
    final toolbar =
        textBox.contextMenuBuilder!(
              tester.element(editableFinder),
              editableState,
            )
            as WindowsTextSelectionToolbar;
    final paste = toolbar.buttonItems.singleWhere(
      (item) => item.type == ContextMenuButtonType.paste,
    );

    paste.onPressed!();
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets(
    'workspace context attachments render, submit, dedupe, and clear',
    (tester) async {
      final client = FakeDaemonClient();
      final container = await pumpComposer(tester, client);
      const attachment = WorkspaceContextAttachment(
        kind: 'forge.change_request_comment',
        id: '42:comment-1',
        title: 'reviewer',
        subtitle: '#42 Match Paseo',
        text: 'GitHub pull request comment',
        url: 'https://example.test/comment',
      );
      final notifier = container.read(
        workspaceAttachmentsProvider(_agent.cwd).notifier,
      );
      notifier
        ..add(attachment)
        ..add(attachment);
      await tester.pump();

      expect(find.text('reviewer'), findsOneWidget);
      expect(
        container.read(workspaceAttachmentsProvider(_agent.cwd)),
        hasLength(1),
      );

      await tester.tap(find.byIcon(FluentIcons.send));
      await tester.pump(const Duration(milliseconds: 150));

      final (_, payload) = client.requests.single;
      expect(payload['text'], '');
      expect(payload['attachments'], [
        {
          'type': 'text',
          'mimeType': 'text/plain',
          'title': 'reviewer',
          'text': 'GitHub pull request comment',
        },
      ]);
      expect(container.read(workspaceAttachmentsProvider(_agent.cwd)), isEmpty);
      expect(find.text('reviewer'), findsNothing);
    },
  );

  testWidgets(
    'draft-scoped workspace files focus, submit, and stay isolated from cwd',
    (tester) async {
      final client = FakeDaemonClient();
      final container = await pumpComposer(tester, client);
      const draftKey = 'agent:local:a1';
      container
          .read(workspaceAttachmentsProvider(draftKey).notifier)
          .add(workspaceFileContextAttachment(r'.\lib\example.dart'));
      container
          .read(composerAttachmentFocusRequestProvider(draftKey).notifier)
          .request();
      await tester.pumpAndSettle();

      expect(find.text('example.dart'), findsOneWidget);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(container.read(workspaceAttachmentsProvider(_agent.cwd)), isEmpty);

      await tester.tap(find.byIcon(FluentIcons.send));
      await tester.pump(const Duration(milliseconds: 150));

      final (_, payload) = client.requests.single;
      expect(payload['attachments'], [
        {
          'type': 'text',
          'mimeType': 'text/plain',
          'title': 'example.dart',
          'text': 'Workspace file: lib/example.dart',
        },
      ]);
      expect(container.read(workspaceAttachmentsProvider(draftKey)), isEmpty);
    },
  );

  testWidgets('review attachments keep wire semantics and clear sent drafts', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final container = await pumpComposer(tester, client);
    container
        .read(reviewDraftProvider.notifier)
        .add(
          key: 'review-scope',
          filePath: 'lib/example.dart',
          side: ReviewAttachmentSide.newLine,
          lineNumber: 4,
          body: 'Please reconsider this.',
          id: 'comment-1',
          createdAt: '2026-07-30T00:00:00.000Z',
        );
    const semantic = ReviewAgentAttachment(
      cwd: '/work',
      mode: ReviewAttachmentMode.uncommitted,
      baseRef: null,
      comments: [
        ReviewAttachmentComment(
          filePath: 'lib/example.dart',
          side: ReviewAttachmentSide.newLine,
          lineNumber: 4,
          body: 'Please reconsider this.',
          context: ReviewAttachmentContext(
            hunkHeader: '@@ -4 +4 @@',
            targetLine: ReviewAttachmentContextLine(
              oldLineNumber: null,
              newLineNumber: 4,
              type: ReviewAttachmentLineType.add,
              content: 'new line',
            ),
            lines: [
              ReviewAttachmentContextLine(
                oldLineNumber: null,
                newLineNumber: 4,
                type: ReviewAttachmentLineType.add,
                content: 'new line',
              ),
            ],
          ),
        ),
      ],
    );
    container
        .read(workspaceAttachmentsProvider(_agent.cwd).notifier)
        .add(
          const WorkspaceContextAttachment(
            kind: 'review',
            id: 'working-diff-review',
            title: 'Review comments',
            subtitle: '1 draft comment',
            text: '1 inline review comment',
            url: null,
            semanticAttachment: semantic,
            reviewDraftKey: 'review-scope',
          ),
        );
    await tester.pump();

    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));

    final (_, payload) = client.requests.single;
    expect(payload['attachments'], [semantic.toJson()]);
    expect(container.read(reviewDraftProvider).drafts, isEmpty);
    expect(container.read(workspaceAttachmentsProvider(_agent.cwd)), isEmpty);
  });

  testWidgets('browser-element screenshot hands off to timeline ownership', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final store = MemoryAttachmentStore();
    final container = await pumpComposer(
      tester,
      client,
      imageAttachmentService: ComposerImageAttachmentService(
        store: () async => store,
      ),
    );
    final screenshot = await store.save(
      id: 'browser-shot',
      mimeType: 'image/png',
      fileName: 'browser.png',
      bytes: base64Decode(_onePixelPng),
    );
    container
        .read(workspaceAttachmentsProvider(_agent.cwd).notifier)
        .add(
          WorkspaceContextAttachment(
            kind: 'browser_element',
            id: 'button-1',
            title: 'Submit button',
            subtitle: 'button',
            text: '<button>Submit</button>',
            url: 'https://example.test',
            screenshot: screenshot,
          ),
        );
    await tester.pump();

    expect(
      container
          .read(workspaceScreenshotOwnersProvider.notifier)
          .attachmentIds(),
      {'browser-shot'},
    );
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));

    final (_, payload) = client.requests.single;
    expect(payload['images'], [
      {'data': _onePixelPng, 'mimeType': 'image/png'},
    ]);
    expect(
      container
          .read(workspaceScreenshotOwnersProvider.notifier)
          .attachmentIds(),
      isEmpty,
    );
    expect(await store.readBytes(screenshot), isNotEmpty);
    expect(
      container.read(timelineAttachmentOwnersProvider.notifier).attachmentIds(),
      {'browser-shot'},
    );
  });

  testWidgets('context attachment remove button removes only that attachment', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final container = await pumpComposer(tester, client);
    container
        .read(workspaceAttachmentsProvider(_agent.cwd).notifier)
        .add(
          const WorkspaceContextAttachment(
            kind: 'forge.change_request_review',
            id: '42:review-1',
            title: 'reviewer',
            subtitle: '#42 Match Paseo',
            text: 'review context',
            url: null,
          ),
        );
    await tester.pump();

    await tester.tap(find.byIcon(FluentIcons.chrome_close));
    await tester.pump(const Duration(milliseconds: 150));
    expect(container.read(workspaceAttachmentsProvider(_agent.cwd)), isEmpty);
    expect(client.requests, isEmpty);
  });

  testWidgets('a failed send restores the text and shows a snackbar', (
    tester,
  ) async {
    final client = FakeDaemonClient()..requestError = StateError('offline');
    await pumpComposer(tester, client);

    await tester.enterText(find.byType(TextBox), 'will fail');
    await tester.tap(find.byIcon(FluentIcons.send));
    await tester.pump(const Duration(milliseconds: 150));

    final textField = tester.widget<TextBox>(find.byType(TextBox));
    expect(textField.controller!.text, 'will fail');
    expect(find.textContaining('Failed to send prompt'), findsOneWidget);
    // Let AppToast's auto-dismiss timer fire so no Timer remains pending.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('busy (running) agent shows a stop button instead of send', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(runState: AgentRunState.running),
    );

    expect(find.byIcon(FluentIcons.stop), findsOneWidget);
    expect(find.byIcon(FluentIcons.send), findsNothing);
  });

  testWidgets('Enter queues while running and Edit restores the draft', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final container = await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(runState: AgentRunState.running),
    );

    await tester.tap(find.byType(TextBox));
    await tester.enterText(find.byType(TextBox), 'queue this');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(client.requests, isEmpty);
    expect(find.text('queue this'), findsOneWidget);
    final queued = container
        .read(queuedMessagesProvider)['local']!['a1']!
        .single;
    expect(queued.text, 'queue this');
    expect(
      tester.widget<TextBox>(find.byType(TextBox)).controller!.text,
      isEmpty,
    );

    await tester.tap(find.byKey(ValueKey('edit-queued-${queued.id}')));
    await tester.pump(const Duration(milliseconds: 150));

    expect(container.read(queuedMessagesProvider), isEmpty);
    expect(
      tester.widget<TextBox>(find.byType(TextBox)).controller!.text,
      'queue this',
    );
  });

  testWidgets('Send now submits a queued message while the agent is running', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final container = await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(runState: AgentRunState.running),
    );
    container
        .read(queuedMessagesProvider.notifier)
        .enqueue(
          serverId: 'local',
          agentId: 'a1',
          text: 'send immediately',
          messageId: 'queued-now',
        );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('send-queued-queued-now')));
    await tester.pump(const Duration(milliseconds: 150));

    expect(container.read(queuedMessagesProvider), isEmpty);
    expect(client.requests, hasLength(1));
    expect(client.requests.single.$1, MessageTypes.agentPromptRequest);
    expect(client.requests.single.$2['text'], 'send immediately');
  });

  testWidgets('queued images hand off to optimistic timeline ownership', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final store = MemoryAttachmentStore();
    final container = await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(runState: AgentRunState.running),
      imageAttachmentService: ComposerImageAttachmentService(
        store: () async => store,
        picker: () async => [
          XFile.fromData(
            base64Decode(_onePixelPng),
            path: 'queued.png',
            name: 'queued.png',
            mimeType: 'image/png',
          ),
        ],
      ),
    );

    await tester.tap(find.byKey(const ValueKey('composer-image-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextBox));
    await tester.enterText(find.byType(TextBox), 'with image');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 150));

    final queued = container
        .read(queuedMessagesProvider)['local']!['a1']!
        .single;
    final metadata = queued.images.single.metadata!;
    expect(await store.readBytes(metadata), isNotEmpty);

    await tester.tap(find.byKey(ValueKey('send-queued-${queued.id}')));
    await tester.pump(const Duration(milliseconds: 150));

    expect(container.read(queuedMessagesProvider), isEmpty);
    expect(await store.readBytes(metadata), isNotEmpty);
    expect(
      container.read(timelineAttachmentOwnersProvider.notifier).attachmentIds(),
      {metadata.id},
    );
  });

  testWidgets('a failed queued send is restored to the front', (tester) async {
    final client = FakeDaemonClient()..requestError = StateError('offline');
    final container = await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(runState: AgentRunState.running),
    );
    final notifier = container.read(queuedMessagesProvider.notifier)
      ..enqueue(
        serverId: 'local',
        agentId: 'a1',
        text: 'first',
        messageId: 'first',
      )
      ..enqueue(
        serverId: 'local',
        agentId: 'a1',
        text: 'second',
        messageId: 'second',
      );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('send-queued-second')));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      container
          .read(queuedMessagesProvider)['local']!['a1']!
          .map((message) => message.id),
      ['second', 'first'],
    );
    expect(notifier.attachmentIds(), isEmpty);
    expect(find.textContaining('Failed to send queued prompt'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the first queued message drains when the agent becomes idle', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    final running = _agent.copyWith(runState: AgentRunState.running);
    final container = await pumpComposer(tester, client, agent: running);
    container
        .read(queuedMessagesProvider.notifier)
        .enqueue(
          serverId: 'local',
          agentId: 'a1',
          text: 'drain me',
          messageId: 'drain',
        );
    await tester.pump();
    expect(client.requests, isEmpty);

    final idle = _agent.copyWith(runState: AgentRunState.idle);
    client.knownAgent = idle;
    container.read(agentsProvider.notifier).upsert(idle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(container.read(queuedMessagesProvider), isEmpty);
    expect(client.requests, hasLength(1));
    expect(client.requests.single.$2['text'], 'drain me');
  });

  testWidgets('shows the Paseo context-window meter when usage is known', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(
        lastUsage: const AgentUsage(
          contextWindowMaxTokens: 200000,
          contextWindowUsedTokens: 50000,
        ),
      ),
    );

    final ring = tester.widget<ProgressRing>(find.byType(ProgressRing));
    expect(ring.value, 25);
    expect(
      tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .any(
            (tooltip) =>
                tooltip.message == 'Context: 50.0K of 200.0K tokens (25%)',
          ),
      isTrue,
    );
  });

  testWidgets('context-window meter formats sub-thousand token counts', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(
        lastUsage: const AgentUsage(
          contextWindowMaxTokens: 500,
          contextWindowUsedTokens: 100,
        ),
      ),
    );

    expect(
      tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .any(
            (tooltip) => tooltip.message == 'Context: 100 of 500 tokens (20%)',
          ),
      isTrue,
    );
  });

  testWidgets('tapping stop while busy sends an interrupt request', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(runState: AgentRunState.awaitingPermission),
    );

    await tester.tap(find.byIcon(FluentIcons.stop));
    await tester.pump(const Duration(milliseconds: 150));

    final (type, payload) = client.requests.single;
    expect(type, MessageTypes.agentInterruptRequest);
    expect(payload, <String, Object?>{'agentId': 'a1'});
  });

  testWidgets('Enter sends the message; Shift+Enter inserts a newline', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(tester, client);

    await tester.tap(find.byType(TextBox));
    await tester.enterText(find.byType(TextBox), 'line one');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 150));

    // Shift+Enter must not have sent a prompt.
    expect(client.requests, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 150));

    expect(client.requests, hasLength(1));
    expect(client.requests.single.$1, MessageTypes.agentPromptRequest);
  });

  testWidgets('IME composition Enter confirms text without sending', (
    tester,
  ) async {
    final client = FakeDaemonClient();
    await pumpComposer(tester, client);

    await tester.tap(find.byType(TextBox));
    final textBox = tester.widget<TextBox>(find.byType(TextBox));
    textBox.controller!.value = const TextEditingValue(
      text: '작성',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 150));
    expect(client.requests, isEmpty);
    expect(textBox.controller!.text, '작성');

    textBox.controller!.value = textBox.controller!.value.copyWith(
      composing: TextRange.empty,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 150));
    expect(client.requests.single.$1, MessageTypes.agentPromptRequest);
  });

  testWidgets('a failed interrupt shows a snackbar', (tester) async {
    final client = FakeDaemonClient()..requestError = StateError('offline');
    await pumpComposer(
      tester,
      client,
      agent: _agent.copyWith(runState: AgentRunState.running),
    );

    await tester.tap(find.byIcon(FluentIcons.stop));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.textContaining('Failed to interrupt'), findsOneWidget);
    // Let AppToast's auto-dismiss timer fire so no Timer remains pending.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('keyboard dispatcher focuses, sends, and cycles agent mode', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..sessionNotice = const AgentProviderNotice(
        type: AgentProviderNoticeType.warning,
        message: 'Permission mode applies next turn',
      );
    await pumpComposer(tester, client);

    expect(
      keyboardActionDispatcher.dispatch(
        const KeyboardActionDefinition(
          id: 'message-input.focus',
          scope: KeyboardActionScope.messageInput,
        ),
      ),
      isTrue,
    );
    await tester.pump();
    final focusContext = FocusManager.instance.primaryFocus!.context!;
    expect(
      ShortcutFocusScope.maybeOf(focusContext),
      KeyboardFocusScope.messageInput,
    );

    await tester.enterText(find.byType(TextBox), 'from shortcut');
    expect(
      keyboardActionDispatcher.dispatch(
        const KeyboardActionDefinition(
          id: 'message-input.send',
          scope: KeyboardActionScope.messageInput,
        ),
      ),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(client.requests.single.$2['text'], 'from shortcut');

    expect(
      keyboardActionDispatcher.dispatch(
        const KeyboardActionDefinition(
          id: 'message-input.mode-cycle',
          scope: KeyboardActionScope.messageInput,
        ),
      ),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(client.sessionMessages.single['type'], 'set_agent_mode_request');
    expect(client.sessionMessages.single['modeId'], AgentMode.fullAccess.name);
    expect(find.text('Permission mode applies next turn'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Permission mode applies next turn'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Permission mode applies next turn'), findsNothing);
  });

  testWidgets('dictation shortcut queries live state after confirm', (
    tester,
  ) async {
    var recording = false;
    final actions = <String>[];
    await pumpComposer(
      tester,
      FakeDaemonClient(),
      dictationShortcutController: DictationShortcutController(
        isRecording: () => recording,
        start: () {
          actions.add('start');
          recording = true;
        },
        markTranscriptForSend: () => actions.add('send transcript'),
        confirm: () {
          actions.add('confirm');
          recording = false;
        },
      ),
    );
    const shortcut = KeyboardActionDefinition(
      id: 'message-input.dictation-toggle',
      scope: KeyboardActionScope.messageInput,
    );

    expect(keyboardActionDispatcher.dispatch(shortcut), isTrue);
    expect(keyboardActionDispatcher.dispatch(shortcut), isTrue);
    expect(keyboardActionDispatcher.dispatch(shortcut), isTrue);
    await tester.pump();

    expect(actions, ['start', 'send transcript', 'confirm', 'start']);
  });
}
