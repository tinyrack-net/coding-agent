import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import '../server/daemon_config.dart';
import '../server/pairing_offer.dart';
import 'cli_client_id.dart';

const pairingDaemonRpcTimeout = Duration(milliseconds: 1500);
final _ansiPattern = RegExp('${String.fromCharCode(0x1b)}\\[[0-9;]*m');

typedef PairingOfferFetcher =
    Future<DaemonGetPairingOfferResponse?> Function(DaemonRuntimeConfig config);

final class PairCommandOptions {
  const PairCommandOptions({this.home, this.json = false});
  final String? home;
  final bool json;
}

Future<int> runPairCommand({
  required PairCommandOptions options,
  Map<String, String>? environment,
  PairingOfferFetcher fetchOffer = fetchRunningDaemonPairingOffer,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
  int? terminalColumns,
}) async {
  final env = environment ?? Platform.environment;
  final config = loadDaemonRuntimeConfig(home: options.home, environment: env);
  LocalPairingOffer pairing;
  final running = await fetchOffer(config);
  if (running != null) {
    pairing = LocalPairingOffer(
      relayEnabled: running.relayEnabled,
      url: running.url.isEmpty ? null : running.url,
      qr: running.qr,
    );
  } else {
    pairing = await generateLocalPairingOffer(
      tinyrackHome: config.home,
      relayEnabled: config.relay.enabled,
      relayEndpoint: config.relay.endpoint,
      relayPublicEndpoint: config.relay.publicEndpoint,
      relayUseTls: config.relay.useTls,
      relayPublicUseTls: config.relay.publicUseTls,
      appBaseUrl: config.appBaseUrl,
      includeQr: true,
      environment: env,
    );
  }

  if (!pairing.relayEnabled || pairing.url == null) {
    (writeError ?? stderr.write)(
      'Relay pairing is disabled for this daemon config.\n'
      'Enable relay and run this command again.\n',
    );
    return 1;
  }
  if (options.json) {
    (writeOutput ?? stdout.write)(
      '${const JsonEncoder.withIndent('  ').convert({'relayEnabled': pairing.relayEnabled, 'url': pairing.url, 'qr': pairing.qr})}\n',
    );
    return 0;
  }
  (writeOutput ?? stdout.write)(
    formatPairingInstructions(
      url: pairing.url!,
      qr: pairing.qr,
      columns: terminalColumns,
    ),
  );
  return 0;
}

Future<DaemonGetPairingOfferResponse?> fetchRunningDaemonPairingOffer(
  DaemonRuntimeConfig config,
) async {
  final host = switch (config.host) {
    '0.0.0.0' || '::' => '127.0.0.1',
    final value => value,
  };
  WebSocket? socket;
  StreamIterator<dynamic>? frames;
  try {
    final password = Platform.environment['TINYRACK_PASSWORD']?.trim();
    socket = await WebSocket.connect(
      Uri(scheme: 'ws', host: host, port: config.port, path: '/ws').toString(),
      protocols: password == null || password.isEmpty
          ? null
          : ['tinyrack.bearer.$password'],
      compression: CompressionOptions.compressionOff,
    ).timeout(pairingDaemonRpcTimeout);
    frames = StreamIterator<dynamic>(socket);
    final clientId = await getOrCreateCliClientId(home: config.home);
    socket.add(
      jsonEncode(
        WebSocketHello(
          clientId: clientId,
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await _nextMatching(
      frames,
      (message) => message['status'] == 'server_info',
    );
    final requestId = 'pair_${DateTime.now().microsecondsSinceEpoch}';
    socket.add(
      jsonEncode({
        'type': 'session',
        'message': DaemonGetPairingOfferRequest(requestId: requestId).toJson(),
      }),
    );
    final envelope = await _nextMatching(
      frames,
      (message) =>
          message['type'] == 'session' &&
          (message['message'] as Map?)?['type'] ==
              DaemonGetPairingOfferResponse.type,
    );
    final response = DaemonGetPairingOfferResponse.fromJson(
      (envelope['message'] as Map).cast<String, Object?>(),
    );
    return response.requestId == requestId ? response : null;
  } on Object {
    return null;
  } finally {
    await frames?.cancel();
    await socket?.close();
  }
}

Future<Map<String, Object?>> _nextMatching(
  StreamIterator<dynamic> frames,
  bool Function(Map<String, Object?> message) predicate,
) async {
  final deadline = DateTime.now().add(pairingDaemonRpcTimeout);
  while (DateTime.now().isBefore(deadline)) {
    final remaining = deadline.difference(DateTime.now());
    if (!await frames.moveNext().timeout(remaining)) {
      throw StateError('Daemon closed while fetching pairing offer');
    }
    final frame = frames.current;
    if (frame is! String) continue;
    final decoded = jsonDecode(frame);
    if (decoded is Map<String, Object?> && predicate(decoded)) return decoded;
  }
  throw TimeoutException('Daemon pairing offer request timed out');
}

String formatPairingInstructions({
  required String url,
  required String? qr,
  required int? columns,
}) {
  final display = _formatQr(qr, columns);
  return '\nScan to pair:\n$display\n\nPairing link:\n$url\n';
}

String _formatQr(String? qr, int? columns) {
  if (qr == null) {
    return 'QR code is unavailable. Use the pairing link below.';
  }
  if (columns == null) {
    return 'QR code not shown because terminal width could not be detected.';
  }
  final width = qr
      .replaceAll(_ansiPattern, '')
      .split('\n')
      .map((line) => line.length)
      .fold(0, (largest, width) => width > largest ? width : largest);
  if (columns <= width) {
    return 'QR code not shown. Resize the terminal to at least '
        '${width + 1} columns, then run this command again.';
  }
  return qr;
}
