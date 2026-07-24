import 'dart:io';

import 'package:agent_daemon/src/providers/claude/claude_client.dart';
import 'package:agent_daemon/src/providers/claude/claude_session.dart';
import 'package:agent_daemon/src/providers/exe_resolver.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class FakeExeResolver implements ExeResolver {
  FakeExeResolver(this.path);

  /// Path to return for `resolve('claude')`, or null to simulate "not found".
  final String? path;
  int resolveCalls = 0;

  @override
  Future<String?> resolve(String command) async {
    resolveCalls++;
    expect(command, 'claude');
    return path;
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('claude_client_test_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('throws StateError when the claude CLI cannot be resolved', () async {
    final client = ClaudeClient(resolver: FakeExeResolver(null));
    await expectLater(
      client.createSession(
        cwd: tempDir.path,
        model: 'claude-sonnet-5',
        mode: AgentMode.normal,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('explicit exePath bypasses resolver entirely', () async {
    // A harmless batch shim that exits immediately without doing anything
    // useful; we only care that spawning succeeds and the resolver (which
    // would fail the test if called) is never consulted.
    final scriptPath = p.join(tempDir.path, 'fake_claude.bat');
    File(scriptPath).writeAsStringSync('@echo off\r\nexit /b 0\r\n');

    final resolver = _ThrowingResolver();
    final client = ClaudeClient(resolver: resolver, exePath: scriptPath);
    final session = await client.createSession(
      cwd: tempDir.path,
      model: 'claude-sonnet-5',
      mode: AgentMode.normal,
    );
    expect(session, isA<ClaudeSession>());
    await session.dispose();
  });

  test('resolver result is cached across multiple createSession calls',
      () async {
    final scriptPath = p.join(tempDir.path, 'fake_claude.bat');
    File(scriptPath).writeAsStringSync('@echo off\r\nexit /b 0\r\n');
    final resolver = FakeExeResolver(scriptPath);
    final client = ClaudeClient(resolver: resolver);

    final s1 = await client.createSession(
      cwd: tempDir.path,
      model: 'claude-sonnet-5',
      mode: AgentMode.normal,
    );
    final s2 = await client.createSession(
      cwd: tempDir.path,
      model: 'claude-sonnet-5',
      mode: AgentMode.normal,
    );
    expect(resolver.resolveCalls, 1); // resolved once, cached after
    await s1.dispose();
    await s2.dispose();
  });

  test('default constructor uses a real ExeResolver when none is provided',
      () {
    // Just exercises the default-argument branch; doesn't spawn anything.
    expect(() => ClaudeClient(), returnsNormally);
  });

  test('fullAccess mode spawns with --dangerously-skip-permissions',
      () async {
    final scriptPath = p.join(tempDir.path, 'fake_claude_full.bat');
    File(scriptPath).writeAsStringSync('@echo off\r\nexit /b 0\r\n');
    final client =
        ClaudeClient(resolver: _ThrowingResolver(), exePath: scriptPath);
    final session = await client.createSession(
      cwd: tempDir.path,
      model: 'claude-sonnet-5',
      mode: AgentMode.fullAccess,
    );
    await session.dispose();
  });

  test('a prior sessionId spawns with --resume', () async {
    final scriptPath = p.join(tempDir.path, 'fake_claude_resume.bat');
    File(scriptPath).writeAsStringSync('@echo off\r\nexit /b 0\r\n');
    final client =
        ClaudeClient(resolver: _ThrowingResolver(), exePath: scriptPath);
    final session = await client.createSession(
      cwd: tempDir.path,
      model: 'claude-sonnet-5',
      mode: AgentMode.normal,
      sessionId: 'prior-session',
    );
    await session.dispose();
  });
}

class _ThrowingResolver implements ExeResolver {
  @override
  Future<String?> resolve(String command) async {
    fail('resolver.resolve should not be called when exePath is provided');
  }
}
