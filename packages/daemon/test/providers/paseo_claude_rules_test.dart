import 'dart:io';

import 'package:agent_daemon/src/agent/paseo_agent_rules.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/providers/paseo/acp_catalog.dart';
import 'package:agent_daemon/src/providers/paseo/claude_history.dart'
    as claude_history;
import 'package:agent_daemon/src/providers/paseo/paseo_claude_rules.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Dart counterpart of upstream's `test-rewind-claude-sdk.ts` `FakeClaudeSdk`,
/// which doubles as both the SDK and the live query.
final class FakeClaudeSdk implements ClaudeRewindSdk, ClaudeRewindQuery {
  final List<String> recordedForks = [];
  final List<String> recordedForkSessionIds = [];
  final List<String> recordedFileRewinds = [];
  final List<bool> recordedDryRuns = [];

  String nextSessionId = 'forked-session-1';
  bool canRewind = true;
  String? rewindError;
  Object? rewindThrows;

  @override
  Future<ClaudeForkedSession> forkSession(
    String sessionId, {
    required String upToMessageId,
  }) async {
    recordedForkSessionIds.add(sessionId);
    recordedForks.add(upToMessageId);
    return ClaudeForkedSession(sessionId: nextSessionId);
  }

  @override
  Future<ClaudeFileRewindResult> rewindFiles(
    String messageId, {
    required bool dryRun,
  }) async {
    recordedFileRewinds.add(messageId);
    recordedDryRuns.add(dryRun);
    final failure = rewindThrows;
    if (failure != null) throw failure;
    return ClaudeFileRewindResult(canRewind: canRewind, error: rewindError);
  }
}

/// A session that routes [invokeRewindCapability] onto the ported Claude
/// rules, proving the two libraries compose the way a real Claude session
/// would wire them.
final class FakeClaudeRewindSession
    implements
        ConversationRewindingAgentSession,
        FileRewindingAgentSession,
        CombinedRewindingAgentSession {
  FakeClaudeRewindSession(this.sdk, {this.sessionId = 'session-1'});

  final FakeClaudeSdk sdk;
  String? sessionId;

  @override
  RewindCapabilities get rewindCapabilities => claudeRewindCapabilities;

  @override
  Future<void> revertConversation({required String messageId}) =>
      revertClaudeConversation(
        sdk: sdk,
        sessionId: sessionId,
        messageId: messageId,
        setSessionId: (next) => sessionId = next,
      );

  @override
  Future<void> revertFiles({required String messageId}) =>
      revertClaudeFiles(query: sdk, messageId: messageId);

  @override
  Future<void> revertBoth({required String messageId}) =>
      revertClaudeConversationAndFiles(
        sdk: sdk,
        query: sdk,
        sessionId: sessionId,
        messageId: messageId,
        setSessionId: (next) => sessionId = next,
      );

  @override
  Stream<ProviderEvent> get events => const Stream.empty();

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() async {}
}

/// Dart counterpart of upstream's `FakeTurnRunner`.
final class FakeTurnRunner {
  FakeTurnRunner(this.turnId, this.sessionId, {this.onStart});

  final String turnId;
  final String sessionId;
  final void Function()? onStart;

  void Function(ProviderTurnEvent)? _subscriber;
  int subscribeCount = 0;
  int unsubscribeCount = 0;
  int sessionIdCount = 0;
  Object? startThrows;

  Future<String> startTurn() async {
    final failure = startThrows;
    if (failure != null) throw failure;
    onStart?.call();
    return turnId;
  }

  ProviderTurnUnsubscribe subscribe(void Function(ProviderTurnEvent) listener) {
    subscribeCount += 1;
    _subscriber = listener;
    return () {
      unsubscribeCount += 1;
      _subscriber = null;
    };
  }

  String getSessionId() {
    sessionIdCount += 1;
    return sessionId;
  }

  void emit(ProviderTurnEvent event) => _subscriber?.call(event);
}

AssistantMessageItem assistant(String text, {String id = 'assistant-1'}) =>
    AssistantMessageItem(id: id, text: text, complete: true);

/// Independent formulation of the Claude SDK's `hashSuffix`, written as a
/// multiply-and-mask rather than the shift-and-subtract the port uses, so a
/// transcription slip in one does not hide in the other.
String jsStringHashOracle(String input) {
  var hash = 0;
  for (final unit in input.codeUnits) {
    hash = (hash * 31 + unit) & 0xffffffff;
  }
  if (hash >= 0x80000000) hash -= 0x100000000;
  return hash.abs().toRadixString(36);
}

Map<String, Object?> selectOption(
  String id,
  String currentValue,
  List<Map<String, Object?>> options, {
  String? category,
}) => {
  'id': id,
  'name': 'Fast',
  'type': 'select',
  'currentValue': currentValue,
  if (category != null) 'category': category,
  'options': options,
};

Map<String, Object?> fastConfigOption(String currentValue) =>
    selectOption('fast', currentValue, const [
      {'value': 'false', 'name': 'Off'},
      {'value': 'true', 'name': 'Fast'},
    ]);

void main() {
  // -------------------------------------------------------------------------
  // claude/rewind.ts
  // -------------------------------------------------------------------------
  group('Claude rewind', () {
    test('forks the conversation up to the user message', () async {
      final claude = FakeClaudeSdk();
      var sessionId = 'original-session';

      await revertClaudeConversation(
        sdk: claude,
        sessionId: sessionId,
        messageId: 'user-message-1',
        setSessionId: (next) => sessionId = next,
      );

      expect(claude.recordedForks, ['user-message-1']);
      expect(claude.recordedForkSessionIds, ['original-session']);
      expect(sessionId, 'forked-session-1');
    });

    test('translates Paseo timeline message ids before forking', () async {
      final claude = FakeClaudeSdk();
      var sessionId = 'original-session';

      await revertClaudeConversation(
        sdk: claude,
        sessionId: sessionId,
        messageId: 'timeline-message-1',
        resolveMessageId: (_) => 'claude-jsonl-message-1',
        setSessionId: (next) => sessionId = next,
      );

      expect(claude.recordedForks, ['claude-jsonl-message-1']);
      expect(sessionId, 'forked-session-1');
    });

    test('awaits an asynchronous message id resolver', () async {
      final claude = FakeClaudeSdk();

      await revertClaudeConversation(
        sdk: claude,
        sessionId: 'original-session',
        messageId: 'timeline-message-1',
        resolveMessageId: (id) async => 'async-$id',
        setSessionId: (_) {},
      );

      expect(claude.recordedForks, ['async-timeline-message-1']);
    });

    test('uses a resolver that returns an empty id verbatim', () async {
      // Upstream's `?? input.messageId` is nullish, not falsy, so an
      // empty-string resolution is a resolution and does not fall back.
      final claude = FakeClaudeSdk();

      await revertClaudeConversation(
        sdk: claude,
        sessionId: 'original-session',
        messageId: 'timeline-message-1',
        resolveMessageId: (_) => '',
        setSessionId: (_) {},
      );

      expect(claude.recordedForks, ['']);
    });

    test('refuses to fork before the Claude session exists', () async {
      final claude = FakeClaudeSdk();

      await expectLater(
        revertClaudeConversation(
          sdk: claude,
          sessionId: null,
          messageId: 'user-message-1',
          setSessionId: (_) {},
        ),
        throwsA(
          isA<ClaudeRewindError>().having(
            (error) => error.message,
            'message',
            'Claude session is not ready for rewind',
          ),
        ),
      );
      expect(claude.recordedForks, isEmpty);
    });

    test('treats an empty session id as no session at all', () async {
      // JavaScript's `!input.sessionId` is falsy for "" as well as undefined.
      final claude = FakeClaudeSdk();

      await expectLater(
        revertClaudeConversation(
          sdk: claude,
          sessionId: '',
          messageId: 'user-message-1',
          setSessionId: (_) {},
        ),
        throwsA(isA<ClaudeRewindError>()),
      );
      expect(claude.recordedForks, isEmpty);
    });

    test('rewinds tracked files to the user message', () async {
      final claude = FakeClaudeSdk();

      await revertClaudeFiles(query: claude, messageId: 'user-message-1');

      expect(claude.recordedFileRewinds, ['user-message-1']);
      expect(claude.recordedDryRuns, [false]);
    });

    test(
      'translates Paseo timeline message ids before rewinding files',
      () async {
        final claude = FakeClaudeSdk();

        await revertClaudeFiles(
          query: claude,
          messageId: 'timeline-message-1',
          resolveMessageId: (_) => 'claude-jsonl-message-1',
        );

        expect(claude.recordedFileRewinds, ['claude-jsonl-message-1']);
      },
    );

    test('surfaces the provider error when files cannot be rewound', () async {
      final claude = FakeClaudeSdk()
        ..canRewind = false
        ..rewindError = 'checkpoint pruned';

      await expectLater(
        revertClaudeFiles(query: claude, messageId: 'user-message-1'),
        throwsA(
          isA<ClaudeRewindError>().having(
            (error) => error.message,
            'message',
            'checkpoint pruned',
          ),
        ),
      );
    });

    test('falls back to a message naming the resolved id', () async {
      final claude = FakeClaudeSdk()..canRewind = false;

      await expectLater(
        revertClaudeFiles(
          query: claude,
          messageId: 'timeline-message-1',
          resolveMessageId: (_) => 'claude-jsonl-message-1',
        ),
        throwsA(
          isA<ClaudeRewindError>().having(
            (error) => error.message,
            'message',
            'No file checkpoint found for message claude-jsonl-message-1',
          ),
        ),
      );
    });

    test(
      'keeps an empty provider error rather than substituting one',
      () async {
        // Nullish coalescing again: "" is a value, so the fallback never runs.
        final claude = FakeClaudeSdk()
          ..canRewind = false
          ..rewindError = '';

        await expectLater(
          revertClaudeFiles(query: claude, messageId: 'user-message-1'),
          throwsA(
            isA<ClaudeRewindError>().having(
              (error) => error.message,
              'message',
              '',
            ),
          ),
        );
      },
    );

    test('rebinds the Claude session before composed rewind returns', () async {
      final claude = FakeClaudeSdk()..nextSessionId = 'forked-before-rehydrate';
      var sessionId = 'original-session';

      await revertClaudeConversationAndFiles(
        sdk: claude,
        query: claude,
        sessionId: sessionId,
        messageId: 'user-message-1',
        setSessionId: (next) => sessionId = next,
      );

      expect(claude.recordedFileRewinds, ['user-message-1']);
      expect(claude.recordedForks, ['user-message-1']);
      expect(sessionId, 'forked-before-rehydrate');
    });

    test('does not fork when the composed file rewind fails', () async {
      // Files first is deliberate: a failed file rewind must leave the
      // transcript untouched rather than stranding an unwanted fork.
      final claude = FakeClaudeSdk()..canRewind = false;
      var sessionId = 'original-session';

      await expectLater(
        revertClaudeConversationAndFiles(
          sdk: claude,
          query: claude,
          sessionId: sessionId,
          messageId: 'user-message-1',
          setSessionId: (next) => sessionId = next,
        ),
        throwsA(isA<ClaudeRewindError>()),
      );
      expect(claude.recordedForks, isEmpty);
      expect(sessionId, 'original-session');
    });

    test('resolves the message id once per composed leg', () async {
      final claude = FakeClaudeSdk();
      final resolved = <String>[];

      await revertClaudeConversationAndFiles(
        sdk: claude,
        query: claude,
        sessionId: 'original-session',
        messageId: 'timeline-message-1',
        setSessionId: (_) {},
        resolveMessageId: (id) {
          resolved.add(id);
          return 'claude-jsonl-message-1';
        },
      );

      expect(resolved, ['timeline-message-1', 'timeline-message-1']);
    });

    test('propagates a query that throws instead of reporting', () async {
      final claude = FakeClaudeSdk()..rewindThrows = StateError('transport');

      await expectLater(
        revertClaudeFiles(query: claude, messageId: 'user-message-1'),
        throwsA(isA<StateError>()),
      );
    });

    test('advertises every rewind mode Claude implements', () {
      expect(claudeRewindCapabilities.supportsRewindConversation, isTrue);
      expect(claudeRewindCapabilities.supportsRewindFiles, isTrue);
      expect(claudeRewindCapabilities.supportsRewindBoth, isTrue);
    });

    test(
      'dispatches all three modes through the shared capability gate',
      () async {
        final claude = FakeClaudeSdk();
        final session = FakeClaudeRewindSession(claude);

        await invokeRewindCapability(
          session,
          messageId: 'm-1',
          mode: RewindMode.conversation,
        );
        await invokeRewindCapability(
          session,
          messageId: 'm-2',
          mode: RewindMode.files,
        );
        await invokeRewindCapability(
          session,
          messageId: 'm-3',
          mode: RewindMode.both,
        );

        expect(claude.recordedForks, ['m-1', 'm-3']);
        expect(claude.recordedFileRewinds, ['m-2', 'm-3']);
        expect(session.sessionId, 'forked-session-1');
      },
    );

    test('reports its own name in toString', () {
      expect(
        const ClaudeRewindError('boom').toString(),
        'ClaudeRewindError: boom',
      );
    });
  });

  // -------------------------------------------------------------------------
  // claude/project-dir.ts
  // -------------------------------------------------------------------------
  group('Claude project directory', () {
    const noNormalize = ClaudeProjectDirectoryOptions(
      configDir: '/config',
      normalizeUnicode: false,
    );

    test('substitutes every non-alphanumeric character with a dash', () {
      expect(
        encodeClaudeProjectPath('/home/dev/my project (v2)'),
        '-home-dev-my-project--v2-',
      );
    });

    test('leaves a path at exactly the cap untruncated', () {
      final path = 'a' * claudeProjectDirLengthCap;
      expect(encodeClaudeProjectPath(path), path);
    });

    test('truncates past the cap and appends a base-36 hash', () {
      final encoded = encodeClaudeProjectPath('a' * 250);
      // Literal pinned against the real JavaScript implementation.
      expect(encoded, '${'a' * claudeProjectDirLengthCap}-wm9qhs');
      expect(
        encoded,
        '${'a' * claudeProjectDirLengthCap}-${jsStringHashOracle('a' * 250)}',
      );
    });

    test('hashes the canonical path, not the dash-substituted one', () {
      // Two paths whose first 200 encoded characters are identical must not
      // collide, which only holds if the hash sees the original text.
      final left = encodeClaudeProjectPath('${'a' * 200}/one');
      final right = encodeClaudeProjectPath('${'a' * 200}/two');
      expect(left.substring(0, 200), right.substring(0, 200));
      expect(left, isNot(right));
    });

    test('separates long paths that share a substituted prefix', () {
      expect(encodeClaudeProjectPath('b' * 250), '${'b' * 200}-g3vk8w');
    });

    test('reads CLAUDE_CONFIG_DIR when it is set', () {
      expect(
        resolveClaudeConfigDir(
          const ClaudeConfigDirEnvironment(
            variables: {'CLAUDE_CONFIG_DIR': '/custom/claude'},
            homeDirectory: '/home/dev',
          ),
        ),
        '/custom/claude',
      );
    });

    test('falls back to <home>/.claude', () {
      expect(
        resolveClaudeConfigDir(
          const ClaudeConfigDirEnvironment(
            variables: {},
            homeDirectory: '/home/dev',
          ),
        ),
        p.join('/home/dev', '.claude'),
      );
    });

    test('honours an empty CLAUDE_CONFIG_DIR because upstream does', () {
      // `??` is nullish: "" wins and yields a relative projects root. Users
      // who export an empty variable get whatever Claude itself gets.
      expect(
        resolveClaudeConfigDir(
          const ClaudeConfigDirEnvironment(
            variables: {'CLAUDE_CONFIG_DIR': ''},
            homeDirectory: '/home/dev',
          ),
        ),
        '',
      );
    });

    test('prefers HOME then USERPROFILE when reading the platform', () {
      expect(
        ClaudeConfigDirEnvironment.fromPlatform({
          'HOME': '/home/dev',
          'USERPROFILE': r'C:\Users\dev',
        }).homeDirectory,
        '/home/dev',
      );
      expect(
        ClaudeConfigDirEnvironment.fromPlatform({
          'USERPROFILE': r'C:\Users\dev',
        }).homeDirectory,
        r'C:\Users\dev',
      );
      expect(
        ClaudeConfigDirEnvironment.fromPlatform(const {}).homeDirectory,
        Directory.current.path,
      );
    });

    test('joins the config dir, projects and the encoded path', () {
      expect(
        claudeProjectDirectorySync(
          '/work/repo',
          const ClaudeProjectDirectoryOptions(
            configDir: '/config',
            normalizeUnicode: false,
            canonicalize: _identityPath,
          ),
        ),
        p.join('/config', 'projects', '-work-repo'),
      );
    });

    test('derives the config dir from the injected environment', () {
      expect(
        claudeProjectDirectorySync(
          '/work/repo',
          const ClaudeProjectDirectoryOptions(
            environment: ClaudeConfigDirEnvironment(
              variables: {'CLAUDE_CONFIG_DIR': '/custom'},
              homeDirectory: '/home/dev',
            ),
            normalizeUnicode: false,
            canonicalize: _identityPath,
          ),
        ),
        p.join('/custom', 'projects', '-work-repo'),
      );
    });

    test('falls back to the raw path when canonicalization fails', () async {
      final missing = p.join(
        Directory.systemTemp.path,
        'paseo-claude-rules-never-created-${DateTime.now().microsecondsSinceEpoch}',
      );
      expect(Directory(missing).existsSync(), isFalse);

      final expected = p.join(
        '/config',
        'projects',
        encodeClaudeProjectPath(missing),
      );
      expect(claudeProjectDirectorySync(missing, noNormalize), expected);
      await expectLater(
        claudeProjectDirectory(missing, noNormalize),
        completion(expected),
      );
    });

    test('resolves a real directory to its canonical form', () async {
      final temp = await Directory.systemTemp.createTemp('paseo-claude-rules');
      addTearDown(() => temp.delete(recursive: true));
      final nested = Directory(p.join(temp.path, 'nested', 'project'));
      await nested.create(recursive: true);
      final canonical = nested.resolveSymbolicLinksSync();

      expect(
        claudeProjectDirectorySync(nested.path, noNormalize),
        p.join('/config', 'projects', encodeClaudeProjectPath(canonical)),
      );
    });

    test('follows a symlink to its target', () async {
      final temp = await Directory.systemTemp.createTemp('paseo-claude-link');
      addTearDown(() => temp.delete(recursive: true));
      final target = Directory(p.join(temp.path, 'real-target'));
      await target.create(recursive: true);
      final link = Link(p.join(temp.path, 'via-symlink'));
      try {
        await link.create(target.path);
      } on FileSystemException {
        // Windows needs Developer Mode or elevation to create symlinks.
        return;
      }

      expect(
        claudeProjectDirectorySync(link.path, noNormalize),
        claudeProjectDirectorySync(target.path, noNormalize),
      );
    });

    test('agrees with the async entry point', () async {
      final temp = await Directory.systemTemp.createTemp('paseo-claude-sync');
      addTearDown(() => temp.delete(recursive: true));
      final dir = Directory(p.join(temp.path, 'sync path with spaces'));
      await dir.create(recursive: true);

      await expectLater(
        claudeProjectDirectory(dir.path, noNormalize),
        completion(claudeProjectDirectorySync(dir.path, noNormalize)),
      );
    });

    test('agrees with the history loader\'s fused helper', () async {
      // `claude_history.dart` already ships a canonicalize+encode helper for
      // the live transcript reader. On a platform where NFC is a no-op the two
      // must produce byte-identical paths, which pins this port against an
      // independently written implementation of the same SDK rule.
      final temp = await Directory.systemTemp.createTemp('paseo-claude-oracle');
      addTearDown(() => temp.delete(recursive: true));
      final dir = Directory(p.join(temp.path, 'proj (work) [v2]'));
      await dir.create(recursive: true);

      expect(
        claudeProjectDirectorySync(dir.path, noNormalize),
        claude_history.claudeProjectDir(dir.path, configDir: '/config'),
      );
    });

    test('applies NFC only when Unicode normalization is requested', () {
      const decomposed = '/work/cafe\u0301-nfd';
      const composed = '/work/caf\u00e9-nfd';

      expect(
        claudeProjectDirectorySync(
          decomposed,
          const ClaudeProjectDirectoryOptions(
            configDir: '/config',
            normalizeUnicode: true,
            canonicalize: _identityPath,
          ),
        ),
        p.join('/config', 'projects', encodeClaudeProjectPath(composed)),
      );
      expect(
        claudeProjectDirectorySync(
          decomposed,
          const ClaudeProjectDirectoryOptions(
            configDir: '/config',
            normalizeUnicode: false,
            canonicalize: _identityPath,
          ),
        ),
        p.join('/config', 'projects', encodeClaudeProjectPath(decomposed)),
      );
    });

    test('normalizes after canonicalizing, never before', () {
      // A macOS filesystem hands realpath back the stored (often decomposed)
      // form, so normalizing the input first would be undone. The canonicalizer
      // below stands in for that behaviour.
      const decomposed = '/work/cafe\u0301';
      expect(
        claudeProjectDirectorySync(
          '/work/caf\u00e9',
          const ClaudeProjectDirectoryOptions(
            configDir: '/config',
            normalizeUnicode: true,
            canonicalize: _decomposingPath,
          ),
        ),
        p.join(
          '/config',
          'projects',
          encodeClaudeProjectPath('/work/caf\u00e9'),
        ),
      );
      expect(decomposed.length, greaterThan('/work/caf\u00e9'.length));
    });

    test('uses the injected canonicalizer for the async entry point', () async {
      await expectLater(
        claudeProjectDirectory(
          '/work/repo',
          const ClaudeProjectDirectoryOptions(
            configDir: '/config',
            normalizeUnicode: false,
            canonicalize: _asyncCanonical,
          ),
        ),
        completion(p.join('/config', 'projects', '-canonical-repo')),
      );
    });

    test('rejects an asynchronous canonicalizer on the sync entry point', () {
      expect(
        () => claudeProjectDirectorySync(
          '/work/repo',
          const ClaudeProjectDirectoryOptions(
            configDir: '/config',
            normalizeUnicode: false,
            canonicalize: _asyncCanonical,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // cursor-acp-agent.ts
  // -------------------------------------------------------------------------
  group('Cursor ACP configuration', () {
    test('describes the fast-mode feature exactly as upstream does', () {
      expect(cursorFastFeatureOption.id, 'fast');
      expect(cursorFastFeatureOption.configId, 'fast');
      expect(cursorFastFeatureOption.category, isNull);
      expect(cursorFastFeatureOption.label, 'Fast');
      expect(cursorFastFeatureOption.description, 'Cursor fast mode');
      expect(cursorFastFeatureOption.tooltip, 'Select Cursor fast mode');
      expect(cursorFastFeatureOption.icon, 'zap');
      expect(cursorFastFeatureOption.emptyOptionLabel, isNull);
    });

    test('waits ten seconds for cursor-agent to publish its commands', () {
      expect(cursorAcpAgentClientOverrides.waitForInitialCommands, isTrue);
      expect(
        cursorAcpAgentClientOverrides.initialCommandsWaitTimeout,
        const Duration(milliseconds: 10000),
      );
      expect(
        cursorInitialCommandsWaitTimeout,
        greaterThan(defaultAcpInitialCommandsWaitTimeout),
      );
    });

    test('advertises the parameterized model picker capability', () {
      expect(cursorAcpAgentClientOverrides.clientCapabilityMeta, {
        'parameterizedModelPicker': true,
      });
      expect(cursorAcpAgentClientOverrides.configFeatureOptions, [
        cursorFastFeatureOption,
      ]);
    });

    test('leaves every knob off by default', () {
      const overrides = AcpAgentClientOverrides();
      expect(overrides.waitForInitialCommands, isFalse);
      expect(
        overrides.initialCommandsWaitTimeout,
        const Duration(milliseconds: 1500),
      );
      expect(overrides.clientCapabilityMeta, isNull);
      expect(overrides.configFeatureOptions, isEmpty);
    });

    test('exposes Cursor fast mode through provider features', () {
      final features = deriveAcpFeatures([
        fastConfigOption('false'),
      ], cursorAcpAgentClientOverrides.configFeatureOptions);

      expect(features.map((feature) => feature.toJson()).toList(), [
        {
          'type': 'select',
          'id': 'fast',
          'label': 'Fast',
          'description': 'Cursor fast mode',
          'tooltip': 'Select Cursor fast mode',
          'icon': 'zap',
          'value': 'false',
          'options': [
            {'id': 'false', 'label': 'Off', 'isDefault': true},
            {'id': 'true', 'label': 'Fast', 'isDefault': false},
          ],
        },
      ]);
    });

    test('marks the currently selected choice as the default', () {
      final features = deriveAcpFeatures(
        [fastConfigOption('true')],
        const [cursorFastFeatureOption],
      );
      final feature = features.single as AgentFeatureSelect;

      expect(feature.value, 'true');
      expect(feature.options.map((option) => option.isDefault).toList(), [
        false,
        true,
      ]);
    });

    test('drops a feature the agent build no longer publishes', () {
      expect(
        deriveAcpFeatures(const [], const [cursorFastFeatureOption]),
        isEmpty,
      );
      expect(deriveAcpFeatures(null, const [cursorFastFeatureOption]), isEmpty);
      expect(deriveAcpFeatures([fastConfigOption('false')], const []), isEmpty);
    });

    test('ignores config options of the wrong type or id', () {
      final wrongType = {...fastConfigOption('false'), 'type': 'toggle'};
      final wrongId = {...fastConfigOption('false'), 'id': 'turbo'};

      expect(
        deriveAcpFeatures([wrongType], const [cursorFastFeatureOption]),
        isEmpty,
      );
      expect(
        deriveAcpFeatures([wrongId], const [cursorFastFeatureOption]),
        isEmpty,
      );
    });

    test('matches any category when the descriptor names none', () {
      final categorized = selectOption('fast', 'false', const [
        {'value': 'false', 'name': 'Off'},
      ], category: 'speed');

      expect(
        deriveAcpFeatures([categorized], const [cursorFastFeatureOption]),
        hasLength(1),
      );
    });

    test('requires the category to match when the descriptor names one', () {
      const descriptor = AcpConfigFeatureOption(
        id: 'fast',
        configId: 'fast',
        category: 'speed',
        label: 'Fast',
      );
      final uncategorized = fastConfigOption('false');
      final categorized = selectOption('fast', 'false', const [
        {'value': 'false', 'name': 'Off'},
      ], category: 'speed');

      expect(deriveAcpFeatures([uncategorized], const [descriptor]), isEmpty);
      expect(
        deriveAcpFeatures([categorized], const [descriptor]),
        hasLength(1),
      );
    });

    test('follows the descriptor order, not the agent config order', () {
      const second = AcpConfigFeatureOption(
        id: 'turbo',
        configId: 'turbo',
        label: 'Turbo',
      );
      final features = deriveAcpFeatures(
        [
          selectOption('turbo', 'off', const [
            {'value': 'off', 'name': 'Off'},
          ]),
          fastConfigOption('false'),
        ],
        const [cursorFastFeatureOption, second],
      );

      expect(features.map((feature) => feature.id).toList(), ['fast', 'turbo']);
    });

    test('flattens grouped choices and carries the group into metadata', () {
      final grouped = selectOption('fast', 'a', const [
        {'value': 'a', 'name': 'Ungrouped'},
        {
          'group': 'Experimental',
          'options': [
            {'value': 'b', 'name': 'Beta', 'description': 'unstable'},
          ],
        },
      ]);

      final feature =
          deriveAcpFeatures([grouped], const [cursorFastFeatureOption]).single
              as AgentFeatureSelect;

      expect(feature.options.map((option) => option.toJson()).toList(), [
        {'id': 'a', 'label': 'Ungrouped', 'isDefault': true},
        {
          'id': 'b',
          'label': 'Beta',
          'description': 'unstable',
          'isDefault': false,
          'metadata': {'group': 'Experimental'},
        },
      ]);
    });

    test('labels a blank-named choice with its value', () {
      final blank = selectOption('fast', 'x', const [
        {'value': 'x', 'name': '   '},
      ]);

      final feature =
          deriveAcpFeatures([blank], const [cursorFastFeatureOption]).single
              as AgentFeatureSelect;

      expect(feature.options.single.label, 'x');
    });

    test('uses emptyOptionLabel only for the blank no-selection choice', () {
      const descriptor = AcpConfigFeatureOption(
        id: 'fast',
        configId: 'fast',
        label: 'Fast',
        emptyOptionLabel: 'Default',
      );
      final withEmpty = selectOption('fast', '', const [
        {'value': '', 'name': ''},
        {'value': 'on', 'name': ''},
      ]);

      final feature =
          deriveAcpFeatures([withEmpty], const [descriptor]).single
              as AgentFeatureSelect;

      expect(feature.options.map((option) => option.label).toList(), [
        'Default',
        'on',
      ]);
    });

    test('falls through to the value when emptyOptionLabel is blank', () {
      const descriptor = AcpConfigFeatureOption(
        id: 'fast',
        configId: 'fast',
        label: 'Fast',
        emptyOptionLabel: '',
      );
      final withEmpty = selectOption('fast', '', const [
        {'value': '', 'name': ''},
      ]);

      final feature =
          deriveAcpFeatures([withEmpty], const [descriptor]).single
              as AgentFeatureSelect;

      expect(feature.options.single.label, '');
    });

    test('reports no selection when the agent omits currentValue', () {
      final feature =
          deriveAcpFeatures(
                [
                  {
                    'id': 'fast',
                    'type': 'select',
                    'options': [
                      {'value': 'false', 'name': 'Off'},
                    ],
                  },
                ],
                const [cursorFastFeatureOption],
              ).single
              as AgentFeatureSelect;

      expect(feature.value, isNull);
      expect(feature.options.single.isDefault, isFalse);
    });

    test(
      'returns only ACP model ids because Cursor CLI ids cannot select ACP models',
      () {
        final catalog = deriveAcpProviderCatalog(
          provider: 'acp',
          sessionState: const {
            'sessionId': 'session-1',
            'models': {
              'currentModelId':
                  'gpt-5.4[context=272k,reasoning=medium,fast=false]',
              'availableModels': [
                {
                  'modelId':
                      'gpt-5.4[context=272k,reasoning=medium,fast=false]',
                  'name': 'gpt-5.4',
                  'description': null,
                },
              ],
            },
            'configOptions': <Map<String, Object?>>[],
          },
        );

        expect(catalog.models, hasLength(1));
        final model = catalog.models.single;
        expect(model.provider, 'acp');
        expect(model.id, 'gpt-5.4[context=272k,reasoning=medium,fast=false]');
        expect(model.label, 'gpt-5.4');
        expect(model.description, isNull);
        expect(model.isDefault, isTrue);
        expect(model.thinkingOptions, isNull);
        expect(model.defaultThinkingOptionId, isNull);
        expect(catalog.modes, isEmpty);
      },
    );

    test(
      'does not fall back to cursor-agent models when ACP reports zero models',
      () {
        final catalog = deriveAcpProviderCatalog(
          provider: 'acp',
          sessionState: const {
            'sessionId': 'session-1',
            'models': null,
            'configOptions': <Map<String, Object?>>[],
          },
        );

        expect(catalog.models, isEmpty);
        expect(catalog.modes, isEmpty);
      },
    );

    test('keeps modern Cursor models as plain ACP ids', () {
      final catalog = deriveAcpProviderCatalog(
        provider: 'acp',
        sessionState: {
          'sessionId': 'session-1',
          'models': const {
            'currentModelId': 'composer-2.5',
            'availableModels': [
              {
                'modelId': 'composer-2.5',
                'name': 'Composer 2.5',
                'description': null,
              },
            ],
          },
          'configOptions': [fastConfigOption('false')],
        },
      );

      expect(catalog.models.single.id, 'composer-2.5');
      expect(catalog.models.single.label, 'Composer 2.5');
      expect(catalog.models.single.isDefault, isTrue);
      // The `fast` option carries no category, so it must not be mistaken for
      // a mode, model or thinking-level selector.
      expect(catalog.modes, isEmpty);
      expect(catalog.currentThinkingOptionId, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // provider-runner.ts
  // -------------------------------------------------------------------------
  group('runProviderTurn', () {
    test('buffers events emitted before startTurn returns', () async {
      late final FakeTurnRunner runner;
      runner = FakeTurnRunner(
        'turn-1',
        'session-1',
        onStart: () {
          runner.emit(
            ProviderTurnTimelineEvent(
              item: assistant('hello'),
              turnId: 'turn-1',
            ),
          );
          runner.emit(
            const ProviderTurnCompletedEvent(
              usage: AgentUsage(inputTokens: 1),
              turnId: 'turn-1',
            ),
          );
        },
      );

      final result = await runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: runner.getSessionId,
      );

      expect(result.sessionId, 'session-1');
      expect(result.finalText, 'hello');
      expect(result.usage?.inputTokens, 1);
      expect(result.timeline.map((item) => item.kind).toList(), [
        'assistant_message',
      ]);
      expect(runner.unsubscribeCount, 1);
    });

    test(
      'ignores events from other turns after the turn id is known',
      () async {
        final runner = FakeTurnRunner('turn-1', 'session-1');
        final resultFuture = runProviderTurn(
          startTurn: runner.startTurn,
          subscribe: runner.subscribe,
          getSessionId: runner.getSessionId,
        );
        await pumpEventQueue();

        runner.emit(
          ProviderTurnTimelineEvent(
            item: assistant('wrong'),
            turnId: 'other-turn',
          ),
        );
        runner.emit(
          ProviderTurnTimelineEvent(item: assistant('right'), turnId: 'turn-1'),
        );
        runner.emit(const ProviderTurnCompletedEvent(turnId: 'turn-1'));

        final result = await resultFuture;
        expect(result.finalText, 'right');
        expect(
          result.timeline.map((item) => (item as AssistantMessageItem).text),
          ['right'],
        );
        expect(result.usage, isNull);
      },
    );

    test('accepts events that carry no turn id at all', () async {
      // Upstream's `getAgentStreamEventTurnId` returns undefined for arms
      // without a `turnId` property, so those events are never turn-filtered.
      final runner = FakeTurnRunner('turn-1', 'session-1');
      final resultFuture = runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: runner.getSessionId,
      );
      await pumpEventQueue();

      runner.emit(ProviderTurnTimelineEvent(item: assistant('untagged')));
      runner.emit(
        ProviderTurnTimelineEvent(item: assistant('empty'), turnId: ''),
      );
      runner.emit(const ProviderTurnCompletedEvent(turnId: 'turn-1'));

      final result = await resultFuture;
      expect(result.timeline, hasLength(2));
      expect(result.finalText, 'empty');
    });

    test(
      'disables turn filtering when the provider returns an empty turn id',
      () async {
        // `if (turnId && ...)` is a truthiness test upstream, so "" turns the
        // filter off entirely — and also leaves the pre-start buffer armed, so
        // only events replayed from it are ever reduced.
        late final FakeTurnRunner runner;
        runner = FakeTurnRunner(
          '',
          'session-1',
          onStart: () {
            runner.emit(
              ProviderTurnTimelineEvent(
                item: assistant('foreign'),
                turnId: 'other-turn',
              ),
            );
            runner.emit(const ProviderTurnCompletedEvent(turnId: 'other-turn'));
          },
        );

        final result = await runProviderTurn(
          startTurn: runner.startTurn,
          subscribe: runner.subscribe,
          getSessionId: runner.getSessionId,
        );

        expect(result.finalText, 'foreign');
      },
    );

    test('rejects when the turn fails', () async {
      final runner = FakeTurnRunner('turn-1', 'session-1');
      final resultFuture = runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: runner.getSessionId,
      );
      await pumpEventQueue();

      runner.emit(
        const ProviderTurnFailedEvent(
          error: 'provider failed',
          turnId: 'turn-1',
        ),
      );

      await expectLater(
        resultFuture,
        throwsA(
          isA<ProviderTurnFailure>().having(
            (failure) => failure.message,
            'message',
            'provider failed',
          ),
        ),
      );
      expect(runner.unsubscribeCount, 1);
      expect(runner.sessionIdCount, 0);
    });

    test('resolves with what arrived when the turn is canceled', () async {
      final runner = FakeTurnRunner('turn-1', 'session-1');
      final resultFuture = runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: runner.getSessionId,
      );
      await pumpEventQueue();

      runner.emit(
        ProviderTurnTimelineEvent(item: assistant('partial'), turnId: 'turn-1'),
      );
      runner.emit(
        const ProviderTurnCanceledEvent(reason: 'user', turnId: 'turn-1'),
      );

      final result = await resultFuture;
      expect(result.finalText, 'partial');
      expect(result.timeline, hasLength(1));
    });

    test('ignores everything that arrives after the turn settles', () async {
      final runner = FakeTurnRunner('turn-1', 'session-1');
      final resultFuture = runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: runner.getSessionId,
      );
      await pumpEventQueue();

      runner.emit(
        const ProviderTurnCompletedEvent(
          usage: AgentUsage(outputTokens: 7),
          turnId: 'turn-1',
        ),
      );
      runner.emit(
        ProviderTurnTimelineEvent(item: assistant('late'), turnId: 'turn-1'),
      );
      runner.emit(
        const ProviderTurnFailedEvent(error: 'late failure', turnId: 'turn-1'),
      );

      final result = await resultFuture;
      expect(result.finalText, '');
      expect(result.timeline, isEmpty);
      expect(result.usage?.outputTokens, 7);
    });

    test('stops replaying buffered events once one settles the turn', () async {
      late final FakeTurnRunner runner;
      runner = FakeTurnRunner(
        'turn-1',
        'session-1',
        onStart: () {
          runner.emit(
            ProviderTurnTimelineEvent(
              item: assistant('kept'),
              turnId: 'turn-1',
            ),
          );
          runner.emit(const ProviderTurnCompletedEvent(turnId: 'turn-1'));
          runner.emit(
            ProviderTurnTimelineEvent(
              item: assistant('dropped'),
              turnId: 'turn-1',
            ),
          );
        },
      );

      final result = await runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: runner.getSessionId,
      );

      expect(result.finalText, 'kept');
      expect(result.timeline, hasLength(1));
    });

    test('passes ignored event kinds through without reducing them', () async {
      final runner = FakeTurnRunner('turn-1', 'session-1');
      final resultFuture = runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: runner.getSessionId,
      );
      await pumpEventQueue();

      runner.emit(
        const ProviderTurnIgnoredEvent(type: 'turn_started', turnId: 'turn-1'),
      );
      runner.emit(
        const ProviderTurnIgnoredEvent(type: 'usage_updated', turnId: 'turn-1'),
      );
      runner.emit(const ProviderTurnCompletedEvent(turnId: 'turn-1'));

      final result = await resultFuture;
      expect(result.timeline, isEmpty);
      expect(result.finalText, '');
    });

    test('unsubscribes and propagates when startTurn throws', () async {
      final runner = FakeTurnRunner('turn-1', 'session-1')
        ..startThrows = StateError('spawn failed');

      await expectLater(
        runProviderTurn(
          startTurn: runner.startTurn,
          subscribe: runner.subscribe,
          getSessionId: runner.getSessionId,
        ),
        throwsA(isA<StateError>()),
      );
      expect(runner.subscribeCount, 1);
      expect(runner.unsubscribeCount, 1);
      expect(runner.sessionIdCount, 0);
    });

    test('subscribes before starting the turn', () async {
      var subscribedBeforeStart = false;
      late final FakeTurnRunner runner;
      runner = FakeTurnRunner(
        'turn-1',
        'session-1',
        onStart: () {
          subscribedBeforeStart = runner.subscribeCount == 1;
          runner.emit(const ProviderTurnCompletedEvent(turnId: 'turn-1'));
        },
      );

      await runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: runner.getSessionId,
      );

      expect(subscribedBeforeStart, isTrue);
    });

    test('awaits an asynchronous session id', () async {
      final runner = FakeTurnRunner('turn-1', 'session-async');
      final resultFuture = runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: () async => runner.getSessionId(),
      );
      await pumpEventQueue();
      runner.emit(const ProviderTurnCompletedEvent(turnId: 'turn-1'));

      expect((await resultFuture).sessionId, 'session-async');
    });

    test('returns an unmodifiable timeline', () async {
      final runner = FakeTurnRunner('turn-1', 'session-1');
      final resultFuture = runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: runner.getSessionId,
      );
      await pumpEventQueue();
      runner.emit(
        ProviderTurnTimelineEvent(item: assistant('a'), turnId: 'turn-1'),
      );
      runner.emit(const ProviderTurnCompletedEvent(turnId: 'turn-1'));

      final result = await resultFuture;
      expect(() => result.timeline.add(assistant('b')), throwsUnsupportedError);
    });

    test('supports growing assistant message reducers', () async {
      final runner = FakeTurnRunner('turn-1', 'session-1');
      final resultFuture = runProviderTurn(
        startTurn: runner.startTurn,
        subscribe: runner.subscribe,
        getSessionId: runner.getSessionId,
        reduceFinalText: appendOrReplaceGrowingAssistantMessage,
      );
      await pumpEventQueue();

      runner.emit(
        ProviderTurnTimelineEvent(item: assistant('hello'), turnId: 'turn-1'),
      );
      runner.emit(
        ProviderTurnTimelineEvent(
          item: assistant('hello world'),
          turnId: 'turn-1',
        ),
      );
      runner.emit(
        ProviderTurnTimelineEvent(item: assistant('!'), turnId: 'turn-1'),
      );
      runner.emit(const ProviderTurnCompletedEvent(turnId: 'turn-1'));

      expect((await resultFuture).finalText, 'hello world!');
    });

    test('reports its own name in toString', () {
      expect(
        const ProviderTurnFailure('boom').toString(),
        'ProviderTurnFailure: boom',
      );
    });
  });

  group('final text reducers', () {
    test('replace keeps the current text for non-assistant items', () {
      expect(
        replaceFinalTextWithAssistantMessage(
          current: 'kept',
          item: const ReasoningItem(id: 'r', text: 'thinking', complete: true),
        ),
        'kept',
      );
      expect(
        replaceFinalTextWithAssistantMessage(
          current: 'kept',
          item: assistant('replaced'),
        ),
        'replaced',
      );
    });

    test('append keeps the current text for non-assistant items', () {
      expect(
        appendOrReplaceGrowingAssistantMessage(
          current: 'kept',
          item: const UserMessageItem(id: 'u', text: 'hi'),
        ),
        'kept',
      );
    });

    test('append seeds from empty and then grows or concatenates', () {
      expect(
        appendOrReplaceGrowingAssistantMessage(
          current: '',
          item: assistant('first'),
        ),
        'first',
      );
      expect(
        appendOrReplaceGrowingAssistantMessage(
          current: 'first',
          item: assistant('first and more'),
        ),
        'first and more',
      );
      expect(
        appendOrReplaceGrowingAssistantMessage(
          current: 'first',
          item: assistant('restarted'),
        ),
        'firstrestarted',
      );
    });

    test('append treats an identical snapshot as a no-op', () {
      expect(
        appendOrReplaceGrowingAssistantMessage(
          current: 'same',
          item: assistant('same'),
        ),
        'same',
      );
    });
  });
}

String _identityPath(String path) => path;

String _decomposingPath(String path) =>
    path.replaceAll('\u00e9', 'e\u0301').replaceAll('\u00c9', 'E\u0301');

Future<String> _asyncCanonical(String path) async => '/canonical/repo';
