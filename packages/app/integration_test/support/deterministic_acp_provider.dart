import 'dart:convert';
import 'dart:io';

/// A tiny ACP process used by the Windows integration smoke.
///
/// It deliberately has no network or credential dependency: the real daemon
/// launches this process through its custom-provider configuration, probes its
/// catalog, creates a session, and receives one deterministic assistant turn.
Future<void> main() async {
  var sessionSequence = 0;
  final tracePath = Platform.environment['INTEGRATION_ACP_LOG'];

  void trace(String message) {
    final path = tracePath;
    if (path == null || path.isEmpty) return;
    try {
      File(path).writeAsStringSync(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  void send(Map<String, Object?> message) {
    stdout.writeln(jsonEncode(message));
  }

  Map<String, Object?> object(Object? value) =>
      (value as Map).cast<String, Object?>();

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final request = object(jsonDecode(line));
    final id = request['id'];
    final method = request['method'] as String?;
    final params = object(request['params'] ?? const <String, Object?>{});
    trace('$method id=$id params=${jsonEncode(params)}');

    void result(Map<String, Object?> value) {
      send({'jsonrpc': '2.0', 'id': id, 'result': value});
    }

    switch (method) {
      case 'initialize':
        result({
          'protocolVersion': 1,
          'agentCapabilities': {
            'sessionCapabilities': {'resume': true},
          },
        });
      case 'session/new':
        sessionSequence += 1;
        result({
          'sessionId': 'integration-session-$sessionSequence',
          'models': {
            'availableModels': [
              {'modelId': 'deterministic-model', 'name': 'Deterministic model'},
            ],
            'currentModelId': 'deterministic-model',
          },
          'modes': {
            'availableModes': [
              {'id': 'agent', 'name': 'Agent'},
            ],
            'currentModeId': 'agent',
          },
          'configOptions': const [],
        });
      case 'session/set_model':
      case 'session/set_mode':
      case 'session/set_config_option':
        result(const {});
      case 'session/prompt':
        final sessionId = params['sessionId'] as String;
        send({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': sessionId,
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'messageId': 'deterministic-assistant',
              'content': {
                'type': 'text',
                'text': 'Deterministic integration response.',
              },
            },
          },
        });
        result({'stopReason': 'end_turn'});
      case 'session/cancel':
        result(const {});
      default:
        if (id != null) {
          send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'Unsupported method: $method'},
          });
        }
    }
  }
}
