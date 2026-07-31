// Port of the frozen Paseo 0.2.0 suites `server/agent/agent-archive.test.ts`,
// `server/agent/agent-timeline-content.test.ts`,
// `server/agent/provider-history-timestamps.test.ts` and the capability-
// dispatch half of `server/agent/rewind/rewind.test.ts`.
import 'package:agent_daemon/src/agent/paseo_agent_rules.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

// --- archive fixtures ------------------------------------------------------

/// Upstream's `BASE_RECORD`, expressed as this daemon's persisted agent value.
const baseRecord = AgentSummary(
  agentId: 'agent-1',
  title: 'Port the archive rule',
  cwd: '/workspace/project',
  provider: 'codex',
  model: 'gpt-5',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1735689600000,
  updatedAt: '2025-01-02T00:00:00.000Z',
);

DateTime Function() fixedClock(DateTime instant) =>
    () => instant;

// --- timeline content fixtures ---------------------------------------------

const max = agentToolCallContentMaxLength;

ToolCallItem shellCall({
  ToolCallStatus status = ToolCallStatus.success,
  String? output,
  String? errorMessage,
}) => ToolCallItem(
  id: 'call-1',
  toolName: 'bash',
  status: status,
  detail: ShellDetail(
    command: 'pnpm test',
    cwd: '/workspace/project',
    output: output,
    exitCode: 1,
  ),
  errorMessage: errorMessage,
  metadata: const {'origin': 'provider'},
);

// --- rewind fixtures -------------------------------------------------------

typedef RecordedRewind = ({RewindMode mode, String messageId});

/// Minimal [AgentSession] that satisfies the interface without doing anything;
/// rewind dispatch never touches the prompt/interrupt surface.
class InertSession implements AgentSession {
  final List<RecordedRewind> recorded = [];

  @override
  Stream<ProviderEvent> get events => Stream<ProviderEvent>.empty();

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() async {}
}

/// Advertises flags but wires up none of the `revert*` entry points — upstream's
/// "capability flag set, optional method missing" adapter bug.
class FlagsOnlySession extends InertSession implements RewindAwareAgentSession {
  FlagsOnlySession(this.rewindCapabilities);

  @override
  final RewindCapabilities rewindCapabilities;
}

/// Implements all three entry points; the flags decide what is reachable.
class FullRewindSession extends InertSession
    implements
        ConversationRewindingAgentSession,
        FileRewindingAgentSession,
        CombinedRewindingAgentSession {
  FullRewindSession(this.rewindCapabilities);

  @override
  final RewindCapabilities rewindCapabilities;

  @override
  Future<void> revertConversation({required String messageId}) async {
    recorded.add((mode: RewindMode.conversation, messageId: messageId));
  }

  @override
  Future<void> revertFiles({required String messageId}) async {
    recorded.add((mode: RewindMode.files, messageId: messageId));
  }

  @override
  Future<void> revertBoth({required String messageId}) async {
    recorded.add((mode: RewindMode.both, messageId: messageId));
  }
}

/// Advertises every flag but only implements the conversation entry point.
class ConversationOnlySession extends InertSession
    implements ConversationRewindingAgentSession {
  @override
  final RewindCapabilities rewindCapabilities = const RewindCapabilities(
    supportsRewindConversation: true,
    supportsRewindFiles: true,
    supportsRewindBoth: true,
  );

  @override
  Future<void> revertConversation({required String messageId}) async {
    recorded.add((mode: RewindMode.conversation, messageId: messageId));
  }
}

class ThrowingRewindSession extends InertSession
    implements FileRewindingAgentSession {
  @override
  final RewindCapabilities rewindCapabilities = const RewindCapabilities(
    supportsRewindFiles: true,
  );

  @override
  Future<void> revertFiles({required String messageId}) async {
    throw StateError('provider still owns the working tree');
  }
}

void main() {
  group('buildArchivedAgentSummary', () {
    final clock = fixedClock(DateTime.utc(2026, 6, 1, 12));

    test('archives without changing terminal statuses', () {
      for (final status in [
        AgentRunState.idle,
        AgentRunState.error,
        AgentRunState.closed,
      ]) {
        final archived = buildArchivedAgentSummary(
          baseRecord.copyWith(runState: status),
          now: clock,
          archivedAt: '2025-01-03T00:00:00.000Z',
        );

        expect(archived.runState, status);
        expect(archived.archivedAt, '2025-01-03T00:00:00.000Z');
        expect(archived.updatedAt, baseRecord.updatedAt);
      }
    });

    test('archives busy agents as idle', () {
      for (final status in [
        AgentRunState.initializing,
        AgentRunState.running,
      ]) {
        final archived = buildArchivedAgentSummary(
          baseRecord.copyWith(runState: status),
          now: clock,
          archivedAt: '2025-01-03T00:00:00.000Z',
        );

        expect(archived.runState, AgentRunState.idle);
      }
    });

    test('archives the daemon-only awaitingPermission state as idle', () {
      // Upstream's status union has no awaitingPermission; collapsing it
      // alongside the other busy states keeps a reloaded archived agent from
      // waiting on a permission prompt that archival already tore down.
      final archived = buildArchivedAgentSummary(
        baseRecord.copyWith(runState: AgentRunState.awaitingPermission),
        now: clock,
        archivedAt: '2025-01-03T00:00:00.000Z',
      );

      expect(archived.runState, AgentRunState.idle);
    });

    test('clears persisted attention when archiving', () {
      final archived = buildArchivedAgentSummary(
        baseRecord.copyWith(
          requiresAttention: true,
          attentionReason: AgentAttentionReason.finished,
          attentionTimestamp: '2025-01-02T12:00:00.000Z',
        ),
        now: clock,
        archivedAt: '2025-01-03T00:00:00.000Z',
      );

      expect(archived.requiresAttention, isFalse);
      expect(archived.attentionReason, isNull);
      expect(archived.attentionTimestamp, isNull);
    });

    test('can stamp updatedAt to the archive timestamp', () {
      final archived = buildArchivedAgentSummary(
        baseRecord,
        now: clock,
        archivedAt: '2025-01-03T00:00:00.000Z',
        updatedAt: '2025-01-03T00:00:00.000Z',
      );

      expect(archived.updatedAt, '2025-01-03T00:00:00.000Z');
      expect(archived.archivedAt, '2025-01-03T00:00:00.000Z');
    });

    test('falls back to the injected clock for archivedAt', () {
      final archived = buildArchivedAgentSummary(baseRecord, now: clock);

      expect(archived.archivedAt, '2026-06-01T12:00:00.000Z');
      // updatedAt is not advanced: archiving is filing, not activity.
      expect(archived.updatedAt, baseRecord.updatedAt);
    });

    test('normalizes a local-time clock reading to UTC', () {
      final local = DateTime.utc(2026, 6, 1, 12).toLocal();
      final archived = buildArchivedAgentSummary(
        baseRecord,
        now: fixedClock(local),
      );

      expect(archived.archivedAt, '2026-06-01T12:00:00.000Z');
    });

    test('does not consult the clock when archivedAt is supplied', () {
      var calls = 0;
      final archived = buildArchivedAgentSummary(
        baseRecord,
        now: () {
          calls += 1;
          return DateTime.utc(2026);
        },
        archivedAt: '2025-01-03T00:00:00.000Z',
      );

      expect(calls, 0);
      expect(archived.archivedAt, '2025-01-03T00:00:00.000Z');
    });

    test('re-archiving overwrites the previous archive stamp', () {
      final once = buildArchivedAgentSummary(
        baseRecord,
        now: clock,
        archivedAt: '2025-01-03T00:00:00.000Z',
      );
      final twice = buildArchivedAgentSummary(
        once,
        now: clock,
        archivedAt: '2025-02-03T00:00:00.000Z',
      );

      expect(twice.archivedAt, '2025-02-03T00:00:00.000Z');
    });

    test('preserves every field the archive rule does not own', () {
      final record = baseRecord.copyWith(
        title: 'Port the archive rule',
        sessionId: 'session-9',
        workspaceId: 'workspace-3',
        labels: const {'kind': 'port'},
        lastError: 'boom',
        lastUserMessageAt: '2025-01-02T00:00:00.000Z',
        currentModeId: 'plan',
        thinkingOptionId: 'high',
      );

      final archived = buildArchivedAgentSummary(
        record,
        now: clock,
        archivedAt: '2025-01-03T00:00:00.000Z',
      );

      expect(archived.agentId, 'agent-1');
      expect(archived.title, 'Port the archive rule');
      expect(archived.cwd, '/workspace/project');
      expect(archived.provider, 'codex');
      expect(archived.model, 'gpt-5');
      expect(archived.createdAtMs, baseRecord.createdAtMs);
      expect(archived.sessionId, 'session-9');
      expect(archived.workspaceId, 'workspace-3');
      expect(archived.labels, {'kind': 'port'});
      expect(archived.lastError, 'boom');
      expect(archived.lastUserMessageAt, '2025-01-02T00:00:00.000Z');
      expect(archived.currentModeId, 'plan');
      expect(archived.thinkingOptionId, 'high');
    });

    test('archivedRunState maps every run state', () {
      expect(archivedRunState(AgentRunState.running), AgentRunState.idle);
      expect(archivedRunState(AgentRunState.initializing), AgentRunState.idle);
      expect(
        archivedRunState(AgentRunState.awaitingPermission),
        AgentRunState.idle,
      );
      expect(archivedRunState(AgentRunState.idle), AgentRunState.idle);
      expect(archivedRunState(AgentRunState.error), AgentRunState.error);
      expect(archivedRunState(AgentRunState.closed), AgentRunState.closed);
    });
  });

  group('limitAgentTimelineItemContent', () {
    test('limits terminal input to the tool-call content budget', () {
      final oversizedInput = 'x' * (max + 1);

      final item =
          limitAgentTimelineItemContent(
                ToolCallItem(
                  id: 'terminal-session-4242',
                  toolName: 'terminal',
                  status: ToolCallStatus.success,
                  detail: PlainTextDetail(
                    text: oversizedInput,
                    icon: 'square_terminal',
                  ),
                ),
              )
              as ToolCallItem;

      expect(item.id, 'terminal-session-4242');
      expect(item.toolName, 'terminal');
      expect(item.status, ToolCallStatus.success);
      expect(item.errorMessage, isNull);
      final detail = item.detail as PlainTextDetail;
      expect(detail.text, 'x' * max);
      expect(detail.icon, 'square_terminal');
      expect(detail.label, isNull);
    });

    test('leaves content that exactly fills the budget alone', () {
      final exact = ToolCallItem(
        id: 'call-1',
        toolName: 'terminal',
        status: ToolCallStatus.success,
        detail: PlainTextDetail(text: 'x' * max),
      );

      expect(identical(limitAgentTimelineItemContent(exact), exact), isTrue);
    });

    test('limits shell output regardless of status', () {
      for (final status in ToolCallStatus.values) {
        final item =
            limitAgentTimelineItemContent(
                  shellCall(status: status, output: 'o' * (max + 10)),
                )
                as ToolCallItem;

        final detail = item.detail as ShellDetail;
        expect(detail.output, hasLength(max));
        expect(detail.command, 'pnpm test');
        expect(detail.cwd, '/workspace/project');
        expect(detail.exitCode, 1);
      }
    });

    test('limits the error text of a failed shell call', () {
      final item =
          limitAgentTimelineItemContent(
                shellCall(
                  status: ToolCallStatus.error,
                  errorMessage: 'e' * (max + 1),
                ),
              )
              as ToolCallItem;

      expect(item.errorMessage, hasLength(max));
    });

    test('limits error text and output together on one failed shell', () {
      final item =
          limitAgentTimelineItemContent(
                shellCall(
                  status: ToolCallStatus.error,
                  output: 'o' * (max + 1),
                  errorMessage: 'e' * (max + 1),
                ),
              )
              as ToolCallItem;

      expect(item.errorMessage, hasLength(max));
      expect((item.detail as ShellDetail).output, hasLength(max));
    });

    test('leaves the error text of a non-failed shell call alone', () {
      final item =
          limitAgentTimelineItemContent(
                shellCall(
                  status: ToolCallStatus.success,
                  errorMessage: 'e' * (max + 1),
                ),
              )
              as ToolCallItem;

      expect(item.errorMessage, hasLength(max + 1));
    });

    test('leaves the error text of a failed non-shell call alone', () {
      final item =
          limitAgentTimelineItemContent(
                ToolCallItem(
                  id: 'call-1',
                  toolName: 'read',
                  status: ToolCallStatus.error,
                  detail: const ReadDetail(path: '/tmp/a.txt'),
                  errorMessage: 'e' * (max + 1),
                ),
              )
              as ToolCallItem;

      expect(item.errorMessage, hasLength(max + 1));
    });

    test('tolerates absent text and output', () {
      final plain = ToolCallItem(
        id: 'call-1',
        toolName: 'terminal',
        status: ToolCallStatus.success,
        detail: const PlainTextDetail(label: 'terminal'),
      );
      final shell = shellCall();

      expect(identical(limitAgentTimelineItemContent(plain), plain), isTrue);
      expect(identical(limitAgentTimelineItemContent(shell), shell), isTrue);
    });

    test('preserves metadata across a truncating copy', () {
      final item =
          limitAgentTimelineItemContent(shellCall(output: 'o' * (max + 1)))
              as ToolCallItem;

      expect(item.metadata, {'origin': 'provider'});
    });

    test('returns non tool-call items identically', () {
      final assistant = AssistantMessageItem(
        id: 'a1',
        text: 'x' * (max + 1),
        complete: true,
      );
      final error = ErrorItem(id: 'e1', message: 'x' * (max + 1));
      // A permission item carries a detail too, but upstream only budgets
      // tool-call items, so an oversized permission preview passes through.
      final permission = PermissionItem(
        id: 'p1',
        permissionId: 'perm-1',
        toolName: 'bash',
        status: PermissionStatus.pending,
        detail: PlainTextDetail(text: 'x' * (max + 1)),
      );

      expect(
        identical(limitAgentTimelineItemContent(assistant), assistant),
        isTrue,
      );
      expect(identical(limitAgentTimelineItemContent(error), error), isTrue);
      expect(
        identical(limitAgentTimelineItemContent(permission), permission),
        isTrue,
      );
    });

    test('truncates by UTF-16 code unit, exactly as String.slice does', () {
      // 65535 ASCII characters plus one astral character = 65537 code units,
      // so the cut lands between the surrogates.
      final input = '${'x' * (max - 1)}\u{1F600}';
      expect(input.length, max + 1);

      final item =
          limitAgentTimelineItemContent(
                ToolCallItem(
                  id: 'call-1',
                  toolName: 'terminal',
                  status: ToolCallStatus.success,
                  detail: PlainTextDetail(text: input),
                ),
              )
              as ToolCallItem;

      final text = (item.detail as PlainTextDetail).text!;
      expect(text, hasLength(max));
      expect(text.codeUnitAt(max - 1), 0xD83D);
    });
  });

  group('normalizeProviderReplayTimestamp', () {
    test('preserves valid string timestamps after trimming', () {
      expect(
        normalizeProviderReplayTimestamp(' 2026-05-01T10:00:00.000Z '),
        '2026-05-01T10:00:00.000Z',
      );
    });

    test('converts numeric second and millisecond timestamps to ISO', () {
      expect(
        normalizeProviderReplayTimestamp(1778762475),
        '2026-05-14T12:41:15.000Z',
      );
      expect(
        normalizeProviderReplayTimestamp(1778762475873),
        '2026-05-14T12:41:15.873Z',
      );
    });

    test('returns null for missing or invalid timestamps', () {
      expect(normalizeProviderReplayTimestamp(null), isNull);
      expect(normalizeProviderReplayTimestamp('not a timestamp'), isNull);
      expect(normalizeProviderReplayTimestamp(double.nan), isNull);
      expect(normalizeProviderReplayTimestamp(double.infinity), isNull);
      expect(normalizeProviderReplayTimestamp(double.negativeInfinity), isNull);
    });

    test('treats blank strings as absent', () {
      expect(normalizeProviderReplayTimestamp(''), isNull);
      expect(normalizeProviderReplayTimestamp('   '), isNull);
      expect(normalizeProviderReplayTimestamp('\t\n '), isNull);
    });

    test('accepts zero rather than treating it as falsy', () {
      // JavaScript's `typeof` guard lets 0 through where a truthiness check
      // would have dropped it.
      expect(normalizeProviderReplayTimestamp(0), '1970-01-01T00:00:00.000Z');
      expect(normalizeProviderReplayTimestamp(0.0), '1970-01-01T00:00:00.000Z');
    });

    test('switches units strictly above one trillion', () {
      // Exactly 1e12 is still read as seconds, which lands in the year 33658.
      expect(
        normalizeProviderReplayTimestamp(1000000000000),
        '+033658-09-27T01:46:40.000Z',
      );
      expect(
        normalizeProviderReplayTimestamp(1000000000001),
        '2001-09-09T01:46:40.001Z',
      );
    });

    test('renders pre-epoch timestamps', () {
      expect(
        normalizeProviderReplayTimestamp(-1000),
        '1969-12-31T23:43:20.000Z',
      );
    });

    test('truncates fractional milliseconds toward zero', () {
      expect(normalizeProviderReplayTimestamp(1.5), '1970-01-01T00:00:01.500Z');
      expect(
        normalizeProviderReplayTimestamp(1778762475.5),
        '2026-05-14T12:41:15.500Z',
      );
      expect(
        normalizeProviderReplayTimestamp(0.0005),
        '1970-01-01T00:00:00.000Z',
      );
    });

    test('rejects instants outside the representable range', () {
      expect(
        normalizeProviderReplayTimestamp(8640000000000000),
        '+275760-09-13T00:00:00.000Z',
      );
      expect(normalizeProviderReplayTimestamp(8640000000000001), isNull);
      // Negative values always take the seconds branch, so this overflows.
      expect(normalizeProviderReplayTimestamp(-8640000000000000), isNull);
      expect(normalizeProviderReplayTimestamp(1000000000000000000), isNull);
    });

    test('rejects non-string, non-number inputs', () {
      expect(normalizeProviderReplayTimestamp(true), isNull);
      expect(normalizeProviderReplayTimestamp(false), isNull);
      expect(
        normalizeProviderReplayTimestamp(const <String, Object?>{}),
        isNull,
      );
      expect(normalizeProviderReplayTimestamp(const <Object?>[]), isNull);
      expect(normalizeProviderReplayTimestamp(Object()), isNull);
    });

    test('rejects a bare digit run that Dart would misread as a year', () {
      // `DateTime.tryParse("1778762475")` yields the year 177878 in basic
      // format; JavaScript's `Date.parse` rejects it, and so must this.
      expect(normalizeProviderReplayTimestamp('1778762475'), isNull);
      expect(normalizeProviderReplayTimestamp('20120227'), isNull);
    });

    test('rejects out-of-range date components instead of rolling over', () {
      // `DateTime.tryParse` would roll month 13 into the next year.
      expect(normalizeProviderReplayTimestamp('2026-13-01T00:00:00Z'), isNull);
      expect(normalizeProviderReplayTimestamp('2026-00-01'), isNull);
      expect(normalizeProviderReplayTimestamp('2026-05-32'), isNull);
      expect(normalizeProviderReplayTimestamp('2026-05-00'), isNull);
      expect(normalizeProviderReplayTimestamp('2026-05-01T25:00:00Z'), isNull);
      expect(normalizeProviderReplayTimestamp('2026-05-01T10:60:00Z'), isNull);
      expect(normalizeProviderReplayTimestamp('2026-05-01T10:00:60Z'), isNull);
    });

    test('accepts every shortened form of the date time string format', () {
      for (final value in [
        '2026',
        '2026-05',
        '2026-05-01',
        '2026-05-01T10:00',
        '2026-05-01T10:00:00',
        '2026-05-01T10:00:00.000',
        '2026-05-01T10:00:00.000Z',
        '2026-05-01T10:00:00+02:00',
        '2026-05-01T10:00:00-07:00',
        '2026-05-01T24:00:00Z',
        '+033658-09-27T01:46:40.000Z',
        '-000001-01-01T00:00:00Z',
        // Day 30 of February is range-valid and rolls over, as upstream does.
        '2026-02-30',
      ]) {
        expect(
          normalizeProviderReplayTimestamp(value),
          value,
          reason: 'expected $value to survive validation verbatim',
        );
      }
    });

    test('rejects engine-specific formats the spec does not define', () {
      // DEVIATION: V8 accepts these; the ECMAScript Date Time String Format
      // does not, and this port validates against the spec.
      expect(
        normalizeProviderReplayTimestamp('Mon, 14 May 2026 12:41:15 GMT'),
        isNull,
      );
      expect(normalizeProviderReplayTimestamp('May 14, 2026'), isNull);
      expect(normalizeProviderReplayTimestamp('2026-05-01 10:00:00'), isNull);
      expect(normalizeProviderReplayTimestamp('2026-05-01t10:00:00z'), isNull);
    });
  });

  group('invokeRewindCapability', () {
    RewindCapabilities all() => const RewindCapabilities(
      supportsRewindConversation: true,
      supportsRewindFiles: true,
      supportsRewindBoth: true,
    );

    test('dispatches each mode to exactly one entry point', () async {
      for (final mode in RewindMode.values) {
        final session = FullRewindSession(all());

        await invokeRewindCapability(
          session,
          messageId: 'message-1',
          mode: mode,
        );

        expect(session.recorded, [(mode: mode, messageId: 'message-1')]);
      }
    });

    test('forwards the message id verbatim', () async {
      final session = FullRewindSession(all());

      await invokeRewindCapability(
        session,
        messageId: ' message with spaces ',
        mode: RewindMode.files,
      );

      expect(session.recorded.single.messageId, ' message with spaces ');
    });

    test('rejects a mode whose capability flag is unset', () async {
      final session = FullRewindSession(
        const RewindCapabilities(supportsRewindConversation: true),
      );

      await expectLater(
        invokeRewindCapability(
          session,
          messageId: 'message-1',
          mode: RewindMode.files,
        ),
        throwsA(
          isA<RewindCapabilityError>().having(
            (error) => error.message,
            'message',
            'Provider does not support rewinding files',
          ),
        ),
      );
      expect(session.recorded, isEmpty);
    });

    test('rejects a mode whose entry point was never wired up', () async {
      final session = FlagsOnlySession(all());

      for (final mode in RewindMode.values) {
        await expectLater(
          invokeRewindCapability(session, messageId: 'message-1', mode: mode),
          throwsA(isA<RewindCapabilityError>()),
        );
      }
      expect(session.recorded, isEmpty);
    });

    test('rejects every mode on a session that advertises nothing', () async {
      final session = InertSession();

      for (final mode in RewindMode.values) {
        await expectLater(
          invokeRewindCapability(session, messageId: 'message-1', mode: mode),
          throwsA(
            isA<RewindCapabilityError>().having(
              (error) => error.mode,
              'mode',
              mode,
            ),
          ),
        );
      }
    });

    test('serves only the modes a partial session implements', () async {
      final session = ConversationOnlySession();

      await invokeRewindCapability(
        session,
        messageId: 'message-1',
        mode: RewindMode.conversation,
      );
      expect(session.recorded, [
        (mode: RewindMode.conversation, messageId: 'message-1'),
      ]);

      for (final mode in [RewindMode.files, RewindMode.both]) {
        await expectLater(
          invokeRewindCapability(session, messageId: 'message-1', mode: mode),
          throwsA(isA<RewindCapabilityError>()),
        );
      }
      expect(session.recorded, hasLength(1));
    });

    test('propagates a provider-side rewind failure unchanged', () async {
      final session = ThrowingRewindSession();

      await expectLater(
        invokeRewindCapability(
          session,
          messageId: 'message-1',
          mode: RewindMode.files,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('spells the capability error the way upstream does', () {
      expect(
        const RewindCapabilityError(RewindMode.conversation).message,
        'Provider does not support rewinding conversation',
      );
      expect(
        const RewindCapabilityError(RewindMode.files).message,
        'Provider does not support rewinding files',
      );
      expect(
        const RewindCapabilityError(RewindMode.both).message,
        'Provider does not support rewinding both',
      );
      expect(
        const RewindCapabilityError(RewindMode.both).toString(),
        'RewindCapabilityError: Provider does not support rewinding both',
      );
      expect(RewindCapabilityError.name, 'RewindCapabilityError');
    });

    test('rewind modes keep their upstream wire spelling', () {
      expect(RewindMode.values.map((mode) => mode.name), [
        'conversation',
        'files',
        'both',
      ]);
    });

    test('unset rewind capabilities default to unsupported', () {
      const capabilities = RewindCapabilities.none;

      expect(capabilities.supportsRewindConversation, isFalse);
      expect(capabilities.supportsRewindFiles, isFalse);
      expect(capabilities.supportsRewindBoth, isFalse);
    });
  });
}
