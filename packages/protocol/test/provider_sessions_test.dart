import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'recent provider session descriptor preserves required nullable keys',
    () {
      final descriptor = RecentProviderSessionDescriptor.fromJson(const {
        'providerId': 'codex',
        'providerLabel': 'Codex',
        'providerHandleId': 'thread-1',
        'cwd': r'C:\repo',
        'title': null,
        'firstPromptPreview': 'first',
        'lastPromptPreview': null,
        'lastActivityAt': '2026-07-28T01:02:03.000Z',
      });

      expect(descriptor.providerHandleId, 'thread-1');
      expect(descriptor.toJson()['title'], isNull);
      expect(
        () => RecentProviderSessionDescriptor.fromJson(const {
          'providerId': 'codex',
          'providerLabel': 'Codex',
          'providerHandleId': 'thread-1',
          'cwd': r'C:\repo',
          'firstPromptPreview': null,
          'lastPromptPreview': null,
          'lastActivityAt': '2026-07-28T01:02:03.000Z',
        }),
        throwsFormatException,
      );
    },
  );

  test('fetch recent sessions request matches the frozen wire contract', () {
    final request = FetchRecentProviderSessionsRequest.fromJson(const {
      'type': 'fetch_recent_provider_sessions_request',
      'requestId': 'request-1',
      'cwd': '/repo',
      'providers': ['claude', 'codex'],
      'since': '2026-07-01T00:00:00Z',
      'limit': 200,
    });

    expect(request.providers, ['claude', 'codex']);
    expect(request.toJson()['limit'], 200);
    for (final limit in [0, 201, 1.5]) {
      expect(
        () => FetchRecentProviderSessionsRequest.fromJson({
          'type': FetchRecentProviderSessionsRequest.type,
          'requestId': 'request-1',
          'limit': limit,
        }),
        throwsFormatException,
      );
    }
  });

  test('fetch recent sessions response validates count and round-trips', () {
    const response = FetchRecentProviderSessionsResponse(
      requestId: 'request-1',
      entries: [
        RecentProviderSessionDescriptor(
          providerId: 'claude',
          providerLabel: 'Claude Code',
          providerHandleId: 'session-1',
          cwd: '/repo',
          title: 'Fix it',
          firstPromptPreview: 'Fix it',
          lastPromptPreview: 'Done',
          lastActivityAt: '2026-07-28T01:02:03.000Z',
        ),
      ],
      filteredAlreadyImportedCount: 2,
    );

    final decoded = FetchRecentProviderSessionsResponse.fromJson(
      response.toJson(),
    );
    expect(decoded.requestId, 'request-1');
    expect(decoded.entries.single.providerId, 'claude');
    expect(decoded.filteredAlreadyImportedCount, 2);
    expect(
      () => FetchRecentProviderSessionsResponse.fromJson(const {
        'type': FetchRecentProviderSessionsResponse.type,
        'payload': {
          'requestId': 'request-1',
          'entries': [],
          'filteredAlreadyImportedCount': -1,
        },
      }),
      throwsFormatException,
    );
  });

  test('import request accepts new and legacy provider handles', () {
    final current = ImportAgentRequest.fromJson(const {
      'type': 'import_agent_request',
      'requestId': 'new',
      'providerId': 'codex',
      'providerHandleId': 'thread-1',
      'cwd': '/repo',
      'workspaceId': 'workspace-1',
      'labels': {'parent': 'agent-1'},
    });
    expect(current.normalizedProvider, 'codex');
    expect(current.normalizedProviderHandleId, 'thread-1');
    expect(current.toJson()['providerId'], 'codex');

    final legacy = ImportAgentRequest.fromJson(const {
      'type': 'import_agent_request',
      'requestId': 'legacy',
      'provider': 'claude',
      'sessionId': 'session-1',
    });
    expect(legacy.normalizedProvider, 'claude');
    expect(legacy.normalizedProviderHandleId, 'session-1');
  });

  test('import status validates success and failure payloads', () {
    final success = ImportAgentStatusResponse.fromJson(const {
      'type': 'status',
      'payload': {
        'status': 'agent_resumed',
        'requestId': 'request-1',
        'agentId': 'agent-1',
        'timelineSize': 2,
        'agent': {
          'id': 'agent-1',
          'provider': 'codex',
          'cwd': '/repo',
          'model': null,
          'thinkingOptionId': null,
          'effectiveThinkingOptionId': null,
          'createdAt': '2026-07-28T00:00:00.000Z',
          'updatedAt': '2026-07-28T00:00:00.000Z',
          'lastUserMessageAt': null,
          'status': 'idle',
          'capabilities': <String, Object?>{},
          'currentModeId': 'normal',
          'availableModes': <Object?>[],
          'pendingPermissions': <Object?>[],
          'persistence': {'provider': 'codex', 'sessionId': 'thread-1'},
          'runtimeInfo': {
            'provider': 'codex',
            'sessionId': 'thread-1',
            'model': null,
            'thinkingOptionId': null,
            'modeId': 'normal',
          },
          'title': null,
          'labels': <String, String>{},
          'requiresAttention': false,
          'attentionReason': null,
          'attentionTimestamp': null,
          'archivedAt': null,
          'providerUnavailable': false,
        },
      },
    });
    expect(success.succeeded, isTrue);
    expect(success.agent?.sessionId, 'thread-1');
    expect(success.timelineSize, 2);

    final failure = ImportAgentStatusResponse.fromJson(const {
      'type': 'status',
      'payload': {
        'status': 'agent_create_failed',
        'requestId': 'request-2',
        'error': 'boom',
      },
    });
    expect(failure.succeeded, isFalse);
    expect(failure.error, 'boom');

    for (final payload in [
      {'status': 'agent_resumed', 'requestId': 'missing-agent'},
      {'status': 'agent_create_failed', 'requestId': 'missing-error'},
      {'status': 'agent_resumed', 'requestId': 'negative', 'timelineSize': -1},
    ]) {
      expect(
        () => ImportAgentStatusResponse.fromJson({
          'type': 'status',
          'payload': payload,
        }),
        throwsFormatException,
      );
    }
  });
}
