/// RPC handlers for provider configuration and credentials.
///
/// Extracted from `daemon_server.dart` (following `workspace_rpc.dart` and
/// `terminal_rpc.dart`) so the wire contract — payload validation, error
/// codes, response shapes — is testable without standing up a real server.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../server/rpc_router.dart';
import 'provider_registry.dart';

/// Wires `provider.*` request types into [router].
void registerProviderHandlers(
  RpcRouter router, {
  required ProviderRegistry registry,
}) {
  router.on(MessageTypes.providerListRequest, (_, __) async {
    final providers = await registry.list();
    return ProviderListResponse(providers: providers).toJson();
  });

  router.on(MessageTypes.providerUpsertRequest, (_, payload) async {
    final raw = (payload['config'] as Map?)?.cast<String, Object?>();
    if (raw == null) {
      throw RpcException(RpcErrorCodes.invalidPayload, 'config is required');
    }
    final config = ProviderConfig.fromJson(raw);
    if (config.displayName.trim().isEmpty) {
      throw RpcException(
        RpcErrorCodes.invalidPayload,
        'displayName is required',
      );
    }
    requireHttpUrl(config.baseUrl);
    final stored = await _mapUnknownProvider(
      () => registry.upsert(
        config.copyWith(displayName: config.displayName.trim()),
        apiKey: payload['apiKey'] as String?,
      ),
    );
    return ProviderUpsertResponse(config: stored).toJson();
  });

  router.on(MessageTypes.providerDeleteRequest, (_, payload) async {
    final providerId = requireString(payload, 'providerId');
    await _mapUnknownProvider(() => registry.delete(providerId));
    return const <String, Object?>{};
  });

  router.on(MessageTypes.providerCredentialSetRequest, (_, payload) async {
    final providerId = requireString(payload, 'providerId');
    final apiKey = requireString(payload, 'apiKey');
    await _mapUnknownProvider(() => registry.setKey(providerId, apiKey));
    return const <String, Object?>{};
  });

  router.on(MessageTypes.providerCredentialClearRequest, (_, payload) async {
    final providerId = requireString(payload, 'providerId');
    await _mapUnknownProvider(() => registry.clearKey(providerId));
    return const <String, Object?>{};
  });

  router.on(MessageTypes.providerCredentialTestRequest, (_, payload) async {
    final providerId = requireString(payload, 'providerId');
    final result = await _mapUnknownProvider(
      () => registry.testKey(providerId, apiKey: payload['apiKey'] as String?),
    );
    return result.toJson();
  });
}

/// Rejects a bad base URL at the boundary rather than letting it surface much
/// later as an opaque mid-stream HTTP failure.
void requireHttpUrl(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw RpcException(
      RpcErrorCodes.invalidPayload,
      'baseUrl must be an absolute http(s) URL',
    );
  }
  if (raw.endsWith('/')) {
    throw RpcException(
      RpcErrorCodes.invalidPayload,
      'baseUrl must not end with a slash',
    );
  }
}

String requireString(Map<String, Object?> payload, String key) {
  final value = payload[key] as String?;
  if (value == null || value.isEmpty) {
    throw RpcException(RpcErrorCodes.invalidPayload, '$key is required');
  }
  return value;
}

Future<T> _mapUnknownProvider<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on UnknownProviderException catch (e) {
    throw RpcException(RpcErrorCodes.notFound, '$e');
  }
}
