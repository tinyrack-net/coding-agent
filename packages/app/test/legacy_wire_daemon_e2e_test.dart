import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the frozen, pre-namespaced Paseo messages through the same
/// [DaemonClient] used by Flutter.  The existing client unit tests use an
/// in-memory WebSocket peer; this suite proves that the envelopes, Git side
/// effects, HTTP download token, and lifecycle responses survive a real
/// daemon connection.
void main() {
  test(
    'Flutter client crosses real daemon for legacy checkout and download',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'tinyrack-legacy-wire-checkout-e2e-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      await _git(temp.path, ['init', '-b', 'main']);
      await _git(temp.path, ['config', 'user.email', 'test@example.com']);
      await _git(temp.path, ['config', 'user.name', 'Tinyrack Test']);
      File(
        '${temp.path}${Platform.pathSeparator}tracked.txt',
      ).writeAsStringSync('initial\n');
      await _git(temp.path, ['add', '--all']);
      await _git(temp.path, ['commit', '-m', 'Initial']);
      await _git(temp.path, ['branch', 'feature/legacy']);
      File(
        '${temp.path}${Platform.pathSeparator}tracked.txt',
      ).writeAsStringSync('changed\n');
      File(
        '${temp.path}${Platform.pathSeparator}untracked.txt',
      ).writeAsStringSync('untracked\n');

      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        log: (_) {},
      );
      addTearDown(handle.stop);
      final client = DaemonClient(
        uri: Uri.parse('ws://127.0.0.1:${handle.server.port}'),
      );
      addTearDown(client.dispose);
      await client.connect();

      final validation = await client.validateBranch(
        cwd: temp.path,
        branchName: 'feature/legacy',
        requestId: 'legacy-validate',
      );
      expect(validation.exists, isTrue);
      expect(validation.resolvedRef, 'feature/legacy');
      expect(validation.isRemote, isFalse);

      final suggestions = await client.getBranchSuggestions(
        cwd: temp.path,
        query: 'legacy',
        limit: 10,
        requestId: 'legacy-suggest',
      );
      expect(suggestions.branches, contains('feature/legacy'));

      final saved = await client.stashSave(
        temp.path,
        branch: 'feature/legacy',
        requestId: 'legacy-stash-save',
      );
      expect(saved.success, isTrue);
      expect(
        File('${temp.path}${Platform.pathSeparator}untracked.txt').existsSync(),
        isFalse,
      );

      final listed = await client.stashList(
        temp.path,
        paseoOnly: true,
        requestId: 'legacy-stash-list',
      );
      expect(listed.error, isNull);
      expect(listed.entries, isNotEmpty);
      expect(listed.entries.first.branch, 'feature/legacy');
      expect(listed.entries.first.isPaseo, isTrue);

      final popped = await client.stashPop(
        temp.path,
        listed.entries.first.index,
        requestId: 'legacy-stash-pop',
      );
      expect(popped.success, isTrue);
      expect(
        File('${temp.path}${Platform.pathSeparator}untracked.txt').existsSync(),
        isTrue,
      );

      // Paseo invokes its metadata generator for a blank message.  The Dart
      // compatibility service uses its deterministic fallback until the
      // provider-backed generator is wired, so this must still commit.
      final committed = await client.checkoutCommit(
        temp.path,
        message: ' ',
        requestId: 'legacy-commit',
      );
      expect(committed.success, isTrue);
      final log = await _git(temp.path, ['log', '-1', '--format=%s']);
      expect(log.stdout.trim(), 'Update files');

      final downloadable = File(
        '${temp.path}${Platform.pathSeparator}download.txt',
      )..writeAsStringSync('download body');
      final token = await client.requestFileDownloadToken(
        cwd: temp.path,
        path: 'download.txt',
        requestId: 'legacy-download',
      );
      expect(token.error, isNull);
      expect(token.fileName, downloadable.uri.pathSegments.last);
      expect(token.size, 13);
      final http = HttpClient();
      addTearDown(http.close);
      final request = await http.getUrl(
        Uri.parse(
          'http://127.0.0.1:${handle.server.port}/api/files/download'
          '?token=${Uri.encodeQueryComponent(token.token!)}',
        ),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(await utf8.decodeStream(response), 'download body');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'Flutter client receives real lifecycle status and resume errors',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'tinyrack-legacy-wire-lifecycle-e2e-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        log: (_) {},
      );
      addTearDown(handle.stop);
      final client = DaemonClient(
        uri: Uri.parse('ws://127.0.0.1:${handle.server.port}'),
      );
      addTearDown(client.dispose);
      await client.connect();

      await expectLater(
        client.resumeAgent(requestId: 'legacy-resume-missing'),
        throwsA(
          isA<DaemonRpcException>().having(
            (error) => error.error.code,
            'code',
            'agent_resume_failed',
          ),
        ),
      );

      final response = await client.restartServer(
        reason: 'legacy lifecycle e2e',
        requestId: 'legacy-restart',
      );
      expect(response.clientId, isNotEmpty);
      expect(response.reason, 'legacy lifecycle e2e');
      await _eventually(
        () => client.currentState == DaemonConnectionState.disconnected,
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'Flutter client resumes an archived provider session over real daemon',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'tinyrack-legacy-wire-resume-e2e-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        agentClients: {'test': _ResumeAgentClient()},
        log: (_) {},
      );
      addTearDown(handle.stop);
      final client = DaemonClient(
        uri: Uri.parse('ws://127.0.0.1:${handle.server.port}'),
      );
      addTearDown(client.dispose);
      await client.connect();

      final imported = await client.importProviderSession(
        providerId: 'test',
        providerHandleId: 'resume-session',
        cwd: temp.path,
      );
      final agentId = imported.agentId;
      expect(agentId, isNotNull);
      await client.request(MessageTypes.agentArchiveRequest, {
        'agentId': agentId,
      });

      final resumed = await client.resumeAgent(
        handle: const AgentPersistenceHandle(
          provider: 'test',
          sessionId: 'resume-session',
        ),
        requestId: 'legacy-resume-success',
      );
      expect(resumed.agentId, agentId);
      expect(resumed.agent.sessionId, 'resume-session');
      expect(resumed.timelineSize, isNotNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'Flutter client receives shutdown_requested status over real daemon',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'tinyrack-legacy-wire-shutdown-e2e-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        log: (_) {},
      );
      addTearDown(handle.stop);
      final client = DaemonClient(
        uri: Uri.parse('ws://127.0.0.1:${handle.server.port}'),
      );
      addTearDown(client.dispose);
      await client.connect();

      final response = await client.shutdownServer(
        requestId: 'legacy-shutdown',
      );
      expect(response.clientId, isNotEmpty);
      await _eventually(
        () => client.currentState == DaemonConnectionState.disconnected,
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<ProcessResult> _git(String cwd, List<String> args) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: cwd,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'git ${args.join(' ')} failed (${result.exitCode}): ${result.stderr}',
    );
  }
  return result;
}

Future<void> _eventually(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

final class _ResumeAgentClient implements AgentClient, ImportableAgentClient {
  @override
  Future<List<ImportableProviderSession>> listImportableSessions([
    ListImportableSessionsOptions? options,
  ]) async => [
    ImportableProviderSession(
      providerHandleId: 'resume-session',
      cwd: options?.cwd ?? Directory.current.path,
      title: 'Resume fixture',
      firstPromptPreview: 'Resume fixture',
      lastPromptPreview: 'Resume fixture',
      lastActivityAt: DateTime.utc(2026, 7, 31),
    ),
  ];

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async => _ResumeAgentSession(
    restoredHistory: sessionId == null
        ? null
        : const [UserMessageItem(id: 'resume-fixture', text: 'Restored')],
  );
}

final class _ResumeAgentSession
    implements AgentSession, HistoryRestoringAgentSession {
  _ResumeAgentSession({this.restoredHistory});

  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  final List<TimelineItem>? restoredHistory;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> dispose() => _events.close();

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> prompt(String text) async {}
}
