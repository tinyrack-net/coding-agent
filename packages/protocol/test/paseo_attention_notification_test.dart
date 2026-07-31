import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

/// Every expectation below was captured by executing the frozen Paseo 0.2.0
/// module (`packages/protocol/dist/agent-attention-notification.js`) under Node,
/// so these are recorded ground truth rather than re-derived behaviour.
void main() {
  String finishedBody(String? message) =>
      buildAgentAttentionNotificationPayload(
        reason: AgentAttentionReason.finished,
        serverId: 's',
        workspaceId: 'w',
        agentId: 'a',
        assistantMessage: message,
      ).body;

  String permissionBody(NotificationPermissionRequest? request) =>
      buildAgentAttentionNotificationPayload(
        reason: AgentAttentionReason.permission,
        serverId: 's',
        workspaceId: 'w',
        agentId: 'a',
        permissionRequest: request,
      ).body;

  group('buildAgentAttentionNotificationPayload', () {
    test('carries the workspace needed to open a cold agent destination', () {
      final payload = buildAgentAttentionNotificationPayload(
        reason: AgentAttentionReason.finished,
        serverId: 'srv-1',
        workspaceId: 'workspace-1',
        agentId: 'agent-1',
      );

      expect(payload.data.toJson(), {
        'serverId': 'srv-1',
        'workspaceId': 'workspace-1',
        'agentId': 'agent-1',
        'reason': 'finished',
      });
    });

    test('builds finished notifications from markdown assistant text', () {
      final payload = buildAgentAttentionNotificationPayload(
        reason: AgentAttentionReason.finished,
        serverId: 'srv-1',
        workspaceId: 'workspace-1',
        agentId: 'agent-1',
        assistantMessage:
            '**Done**. Updated `README.md` and [link](https://example.com).',
      );

      expect(payload.title, 'Agent finished');
      expect(payload.body, 'Done. Updated README.md and link.');
      expect(payload.data.reason, AgentAttentionReason.finished);
    });

    test('builds permission notifications from request details', () {
      final payload = buildAgentAttentionNotificationPayload(
        reason: AgentAttentionReason.permission,
        serverId: 'srv-2',
        workspaceId: 'workspace-2',
        agentId: 'agent-2',
        permissionRequest: const NotificationPermissionRequest(
          id: 'perm-1',
          provider: 'claude',
          name: 'exec',
          kind: NotificationPermissionKind.tool,
          title: '**Approve command**',
          description: 'Run `git push`',
        ),
      );

      expect(payload.title, 'Agent needs permission');
      expect(payload.body, 'Approve command - Run git push');
      expect(payload.data.toJson(), {
        'serverId': 'srv-2',
        'workspaceId': 'workspace-2',
        'agentId': 'agent-2',
        'reason': 'permission',
      });
    });

    test('uses error-specific defaults when reason is error', () {
      final payload = buildAgentAttentionNotificationPayload(
        reason: AgentAttentionReason.error,
        serverId: 'srv-3',
        workspaceId: 'workspace-3',
        agentId: 'agent-3',
      );

      expect(payload.title, 'Agent needs attention');
      expect(payload.body, 'Encountered an error.');
    });

    test('ignores the assistant message when the reason is error', () {
      expect(
        buildAgentAttentionNotificationPayload(
          reason: AgentAttentionReason.error,
          serverId: 's',
          workspaceId: 'w',
          agentId: 'a',
          assistantMessage: 'ignored',
        ).body,
        'Encountered an error.',
      );
    });

    test('ignores a permission request when the reason is finished', () {
      expect(
        buildAgentAttentionNotificationPayload(
          reason: AgentAttentionReason.finished,
          serverId: 's',
          workspaceId: 'w',
          agentId: 'a',
          permissionRequest: const NotificationPermissionRequest(
            id: 'p',
            provider: 'claude',
            name: 'exec',
            kind: NotificationPermissionKind.tool,
            title: 'Approve',
          ),
        ).body,
        'Finished working.',
      );
    });

    test('falls back when no permission request is supplied', () {
      expect(permissionBody(null), 'Permission requested.');
    });
  });

  group('markdown preview stripping', () {
    test('flattens block structure while keeping fenced code content', () {
      expect(
        finishedBody(
          '# Heading\n\n> quoted line\n- bullet one\n1. numbered\n\n---\n\n'
          '```ts\nconst a = 1;\n```\n~~~\nfenced\n~~~\n',
        ),
        'Heading quoted line bullet one numbered const a = 1; fenced',
      );
    });

    test('unwraps images, strikethrough and emphasis markers', () {
      expect(
        finishedBody(
          '![alt text](https://img.example/a.png) and ~~struck~~ and '
          '__bold__ and _em_ and *star*',
        ),
        'alt text and struck and bold and em and star',
      );
    });

    test('unwraps angle-bracketed autolinks', () {
      expect(
        finishedBody('Visit <https://example.com/docs> now'),
        'Visit https://example.com/docs now',
      );
    });

    test('leaves links with bracketed label text untouched', () {
      expect(
        finishedBody('[nested [inner] text](https://x.com)'),
        '[nested [inner] text](https://x.com)',
      );
    });

    test('accepts backslash-escaped parentheses inside link targets', () {
      expect(finishedBody(r'[esc](https://x.com/\(paren\))'), 'esc');
      expect(finishedBody(r'![img](a\)b) tail'), 'img tail');
    });

    test('strips list prefixes before thematic breaks', () {
      // Order-sensitive: the list rule consumes the leading "- " first, leaving
      // only two repetitions, so the thematic-break rule no longer matches.
      expect(finishedBody('- - -'), '- -');
      expect(finishedBody('***'), 'Finished working.');
    });

    test('only strips one to six leading hashes', () {
      expect(finishedBody('  ####### seven hashes'), '####### seven hashes');
    });

    test('normalizes CRLF and unicode whitespace', () {
      expect(finishedBody('line1\r\nline2'), 'line1 line2');
      // ECMA-262 `\s` covers NBSP, EM SPACE and U+FEFF, and so does Dart's
      // RegExp, so the frozen normalizer and this port agree on all three.
      const nbsp = 0x00a0;
      const emSpace = 0x2003;
      const bom = 0xfeff;
      final exotic = String.fromCharCodes([
        nbsp,
        emSpace,
        0x73,
        0x70,
        0x61,
        0x63,
        0x65,
        0x64,
        nbsp,
        0x6f,
        0x75,
        0x74,
        emSpace,
      ]);
      expect(finishedBody(exotic), 'spaced out');
      expect(
        finishedBody(String.fromCharCodes([bom, 0x62, 0x6f, 0x6d, bom])),
        'bom',
      );
    });

    test('falls back when the message is absent or whitespace only', () {
      expect(finishedBody(null), 'Finished working.');
      expect(finishedBody(''), 'Finished working.');
      expect(finishedBody('   \n\t  \n '), 'Finished working.');
    });
  });

  group('preview truncation', () {
    test('leaves text at or under 220 code units untouched', () {
      expect(finishedBody('b' * 219), 'b' * 219);
      expect(finishedBody('c' * 220), 'c' * 220);
    });

    test('truncates to 217 code units plus an ellipsis', () {
      final body = finishedBody('d' * 221);
      expect(body, '${'d' * 217}...');
      expect(body.length, 220);
    });

    test('trims trailing whitespace before appending the ellipsis', () {
      final body = finishedBody('word ' * 60);
      expect(body.length, 220);
      expect(body.endsWith('word wo...'), isTrue);
    });

    test('cuts on UTF-16 boundaries exactly like String.prototype.slice', () {
      // Deliberate parity with the frozen implementation: the cut lands inside a
      // surrogate pair and leaves a lone high surrogate behind.
      final body = finishedBody('\u{1F389} emoji ' * 40);
      expect(body.length, 220);
      expect(body.codeUnitAt(216), 0xd83c);
      expect(body.endsWith('...'), isTrue);
    });
  });

  group('permission detail precedence', () {
    NotificationPermissionRequest request({
      String name = 'n',
      NotificationPermissionKind kind = NotificationPermissionKind.tool,
      String? title,
      String? description,
      Map<String, Object?>? input,
      Map<String, Object?>? metadata,
    }) => NotificationPermissionRequest(
      id: '1',
      provider: 'p',
      name: name,
      kind: kind,
      title: title,
      description: description,
      input: input,
      metadata: metadata,
    );

    test('drops a description identical to the trimmed title', () {
      expect(
        permissionBody(request(title: '  T  ', description: '  T  ')),
        'T',
      );
    });

    test('joins a distinct title and description with a dash', () {
      expect(permissionBody(request(title: 'T', description: 'D')), 'T - D');
    });

    test('uses the description alone when no title exists', () {
      expect(permissionBody(request(description: 'only desc')), 'only desc');
    });

    test('treats whitespace-only title and description as absent', () {
      expect(permissionBody(request(title: '   ', description: '   ')), 'n');
    });

    test('falls back to a JSON preview of the tool input', () {
      expect(
        permissionBody(
          request(input: {'cmd': 'ls -la', 'n': 1, 'b': true, 'z': null}),
        ),
        '{"cmd":"ls -la","n":1,"b":true,"z":null}',
      );
    });

    test('an empty input map still wins over metadata', () {
      // JS truthiness is on the object, not its size, so `{}` short-circuits.
      expect(
        permissionBody(request(input: const {}, metadata: const {'m': 1})),
        '{}',
      );
    });

    test('falls back to a JSON preview of metadata', () {
      expect(
        permissionBody(
          request(
            metadata: const {
              'm': [1, 'x'],
            },
          ),
        ),
        '{"m":[1,"x"]}',
      );
    });

    test('falls back to the trimmed tool name', () {
      expect(
        permissionBody(
          request(
            name: '  spaced name  ',
            kind: NotificationPermissionKind.plan,
          ),
        ),
        'spaced name',
      );
    });

    test('falls back to the prompt kind when the name is blank', () {
      expect(
        permissionBody(
          request(name: '', kind: NotificationPermissionKind.question),
        ),
        'question',
      );
      expect(
        permissionBody(
          request(name: '   ', kind: NotificationPermissionKind.mode),
        ),
        'mode',
      );
    });

    test('strips markdown from the resolved detail', () {
      expect(
        permissionBody(
          request(
            kind: NotificationPermissionKind.other,
            title: '`code` **bold**',
          ),
        ),
        'code bold',
      );
    });
  });

  group('findLatestAssistantMessageFromTimeline', () {
    AssistantMessageItem assistant(String id, String text) =>
        AssistantMessageItem(id: id, text: text, complete: true);

    test('joins the latest contiguous assistant chunks', () {
      expect(
        findLatestAssistantMessageFromTimeline([
          const UserMessageItem(id: '1', text: 'start'),
          assistant('2', 'Part '),
          assistant('3', 'one'),
          const ReasoningItem(id: '4', text: 'thinking...', complete: true),
          assistant('5', 'Done '),
          assistant('6', 'now'),
        ]),
        'Done now',
      );
    });

    test('returns null for an empty timeline', () {
      expect(findLatestAssistantMessageFromTimeline(const []), isNull);
    });

    test('returns null when no assistant item exists', () {
      expect(
        findLatestAssistantMessageFromTimeline([
          const UserMessageItem(id: '1', text: 'x'),
        ]),
        isNull,
      );
    });

    test('skips trailing non-assistant items before collecting', () {
      expect(
        findLatestAssistantMessageFromTimeline([
          assistant('1', 'A'),
          const ErrorItem(id: '2', message: 'boom'),
        ]),
        'A',
      );
    });

    test('stops at the first non-assistant item after a chunk', () {
      expect(
        findLatestAssistantMessageFromTimeline([
          assistant('1', 'X'),
          const ReasoningItem(id: '2', text: 'r', complete: true),
          const ReasoningItem(id: '3', text: 'r2', complete: true),
          assistant('4', 'Y'),
        ]),
        'Y',
      );
    });

    test('returns an empty string for an empty assistant chunk', () {
      expect(findLatestAssistantMessageFromTimeline([assistant('1', '')]), '');
    });
  });

  group('findLatestPermissionRequest', () {
    test('returns the most recently inserted request', () {
      final pending = <String, NotificationPermissionRequest>{
        'first': const NotificationPermissionRequest(
          id: 'first',
          provider: 'claude',
          name: 'a',
          kind: NotificationPermissionKind.tool,
        ),
        'second': const NotificationPermissionRequest(
          id: 'second',
          provider: 'claude',
          name: 'b',
          kind: NotificationPermissionKind.tool,
        ),
      };

      expect(findLatestPermissionRequest(pending)?.id, 'second');
    });

    test('returns null when nothing is pending', () {
      expect(findLatestPermissionRequest(const {}), isNull);
    });
  });

  group('wire round trips', () {
    test('payload encodes byte-for-byte like the frozen builder', () {
      final payload = buildAgentAttentionNotificationPayload(
        reason: AgentAttentionReason.finished,
        serverId: 's',
        workspaceId: 'w',
        agentId: 'a',
      );

      expect(
        jsonEncode(payload.toJson()),
        '{"title":"Agent finished","body":"Finished working.",'
        '"data":{"serverId":"s","workspaceId":"w","agentId":"a",'
        '"reason":"finished"}}',
      );
    });

    test('omits workspaceId exactly like JSON.stringify omits undefined', () {
      const data = AgentAttentionNotificationData(
        serverId: 's',
        agentId: 'a',
        reason: AgentAttentionReason.finished,
      );

      expect(
        jsonEncode(data.toJson()),
        '{"serverId":"s","agentId":"a","reason":"finished"}',
      );
      expect(
        AgentAttentionNotificationData.fromJson(data.toJson()).toJson(),
        data.toJson(),
      );
    });

    test('payload survives a decode/encode round trip', () {
      for (final reason in AgentAttentionReason.values) {
        final json = {
          'title': 'T',
          'body': 'B',
          'data': {
            'serverId': 's',
            'workspaceId': 'w',
            'agentId': 'a',
            'reason': reason.name,
          },
        };

        final decoded = AgentAttentionNotificationPayload.fromJson(json);
        expect(decoded.data.reason, reason);
        expect(jsonEncode(decoded.toJson()), jsonEncode(json));
      }
    });

    test('notification data preserves unknown passthrough keys', () {
      final json = <String, Object?>{
        'serverId': 's',
        'workspaceId': 'w',
        'agentId': 'a',
        'reason': 'permission',
        'sound': 'default',
        'badge': 3,
      };

      final decoded = AgentAttentionNotificationData.fromJson(json);
      expect(decoded.extra, {'sound': 'default', 'badge': 3});
      expect(jsonEncode(decoded.toJson()), jsonEncode(json));
    });

    test('permission request survives a decode/encode round trip', () {
      for (final kind in NotificationPermissionKind.values) {
        final json = <String, Object?>{
          'id': 'perm-1',
          'provider': 'claude',
          'name': 'exec',
          'kind': kind.name,
          'title': 'Approve',
          'description': 'Run it',
          'input': {'cmd': 'ls'},
          'metadata': {'origin': 'hook'},
        };

        final decoded = NotificationPermissionRequest.fromJson(json);
        expect(decoded.kind, kind);
        expect(jsonEncode(decoded.toJson()), jsonEncode(json));
      }
    });

    test('permission request omits absent optional fields', () {
      const request = NotificationPermissionRequest(
        id: 'p',
        provider: 'claude',
        name: 'exec',
        kind: NotificationPermissionKind.tool,
      );

      expect(
        jsonEncode(request.toJson()),
        '{"id":"p","provider":"claude","name":"exec","kind":"tool"}',
      );
    });

    test('rejects malformed wire payloads', () {
      expect(
        () => AgentAttentionNotificationData.fromJson(const {
          'serverId': 's',
          'agentId': 'a',
          'reason': 'nope',
        }),
        throwsFormatException,
      );
      expect(
        () => AgentAttentionNotificationData.fromJson(const {
          'serverId': 's',
          'agentId': 'a',
        }),
        throwsFormatException,
      );
      expect(
        () => AgentAttentionNotificationPayload.fromJson(const {
          'title': 'T',
          'body': 'B',
        }),
        throwsFormatException,
      );
      expect(
        () => NotificationPermissionRequest.fromJson(const {
          'id': 'p',
          'provider': 'claude',
          'name': 'exec',
          'kind': 'unknown',
        }),
        throwsFormatException,
      );
    });
  });
}
