import 'package:agent_protocol/agent_protocol.dart';

import 'daemon_config.dart';
import 'daemon_identity.dart';
import 'pairing_qr.dart';

typedef PairingQrRenderer = Future<String> Function(String url);

final class LocalPairingOffer {
  const LocalPairingOffer({
    required this.relayEnabled,
    required this.url,
    required this.qr,
  });

  final bool relayEnabled;
  final String? url;
  final String? qr;
}

Future<LocalPairingOffer> generateLocalPairingOffer({
  required String tinyrackHome,
  bool relayEnabled = true,
  String relayEndpoint = defaultTinyrackRelayEndpoint,
  String? relayPublicEndpoint,
  bool? relayUseTls,
  bool? relayPublicUseTls,
  String appBaseUrl = defaultTinyrackAppBaseUrl,
  bool includeQr = true,
  PairingQrRenderer renderQr = _defaultPairingQrRenderer,
  Map<String, String>? environment,
  DaemonLog? log,
}) async {
  if (!relayEnabled) {
    return const LocalPairingOffer(relayEnabled: false, url: null, qr: null);
  }

  final publicEndpoint = relayPublicEndpoint ?? relayEndpoint;
  final useTls = relayUseTls ?? relayEndpoint == defaultTinyrackRelayEndpoint;
  final publicUseTls = relayPublicUseTls ?? useTls;
  final serverId = getOrCreateServerId(
    tinyrackHome,
    environment: environment,
    log: log,
  );
  final daemonKeyPair = loadOrCreateDaemonKeyPair(tinyrackHome, log: log);
  final offer = ConnectionOffer(
    serverId: serverId,
    daemonPublicKeyB64: daemonKeyPair.publicKeyB64,
    relay: ConnectionOfferRelay(endpoint: publicEndpoint, useTls: publicUseTls),
  );
  final url = encodeConnectionOfferToFragmentUrl(offer, appBaseUrl);
  String? qr;
  if (includeQr) {
    try {
      qr = await renderQr(url);
    } on Object catch (error) {
      log?.call('failed to render pairing QR: $error');
    }
  }
  return LocalPairingOffer(relayEnabled: true, url: url, qr: qr);
}

Future<String> _defaultPairingQrRenderer(String url) async =>
    renderPairingQr(url);
