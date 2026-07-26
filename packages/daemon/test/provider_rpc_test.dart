/// Tests `registerProviderHandlers` through [RpcRouter.dispatch].
///
/// Dispatching directly (rather than over a real WebSocket, as
/// `workspace_rpc_test.dart` does) keeps these fast and free of the real-socket
/// timing flake, since nothing here needs the transport — only the payload
/// contract, error codes, and response shapes.
library;

import 'dart:io';

import 'package:agent_daemon/src/providers/native/credential_store.dart';
import 'package:agent_daemon/src/providers/native/llm_backend.dart';
import 'package:agent_daemon/src/providers/native/provider_config_store.dart';
import 'package:agent_daemon/src/providers/provider_registry.dart';
import 'package:agent_daemon/src/providers/provider_rpc.dart';
import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

/// Stands in for the [Connection] that [RpcRouter.dispatch] requires.
///
/// The provider handlers never touch it, and building a real one would open a
/// socket whose failed connect surfaces *after* the test completes — which the
/// test runner reports as a failure ("this test failed after it had already
/// completed"). Throwing here makes any accidental use obvious instead.
class UnusedConnection implements Connection {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
        'provider RPC handlers must not touch the connection '
        '(${invocation.memberName})',
      );
}

class StubBackend implements LlmBackend {
  bool credentialOk = true;

  @override
  Stream<LlmStreamEvent> chat({
    required List<LlmMessage> messages,
    required List<LlmToolSchema> tools,
    required String model,
    required String apiKey,
  }) =>
      const Stream.empty();

  @override
  Future<bool> testCredential(String apiKey) async => credentialOk;

  @override
  Future<List<ProviderModel>> fetchModels(String apiKey) async =>
      const [ProviderModel(id: 'fetched', displayName: 'Fetched')];
}

void main() {
  late Directory tempDir;
  late CredentialStore credentials;
  late ProviderRegistry registry;
  late RpcRouter router;
  late Connection connection;
  late StubBackend backend;
  var nextRequestId = 0;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('provider_rpc_test_');
    credentials = CredentialStore(dataDir: tempDir.path);
    backend = StubBackend();
    registry = ProviderRegistry(
      credentials: credentials,
      configs: ProviderConfigStore(dataDir: tempDir.path),
      backendFactory: (_) => backend,
    );
    router = RpcRouter();
    registerProviderHandlers(router, registry: registry);
    connection = UnusedConnection();
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<RpcResponse> call(String type, [Map<String, Object?>? payload]) =>
      router.dispatch(
        connection,
        RpcRequest(
          type: type,
          requestId: 'r${nextRequestId++}',
          payload: payload ?? const {},
        ),
      );

  Map<String, Object?> claudeConfig({String id = ''}) => ProviderConfig(
        id: id,
        displayName: 'Claude',
        kind: ProviderKind.anthropic,
        baseUrl: 'https://api.anthropic.com/v1',
      ).toJson();

  group('provider.upsert', () {
    test('creates a provider and returns the assigned id', () async {
      final response = await call(MessageTypes.providerUpsertRequest, {
        'config': claudeConfig(),
        'apiKey': 'sk-ant-1',
      });

      expect(response.error, isNull);
      final stored =
          ProviderUpsertResponse.fromJson(response.payload).config;
      expect(stored.id, isNotEmpty);
      expect(stored.displayName, 'Claude');
      expect(stored.kind, ProviderKind.anthropic);
      expect(await credentials.get(stored.id), 'sk-ant-1');
    });

    test('updates in place when an id is supplied', () async {
      final created = ProviderUpsertResponse.fromJson(
        (await call(MessageTypes.providerUpsertRequest, {
          'config': claudeConfig(),
        }))
            .payload,
      ).config;

      final response = await call(MessageTypes.providerUpsertRequest, {
        'config': created.copyWith(displayName: 'Renamed').toJson(),
      });
      final stored =
          ProviderUpsertResponse.fromJson(response.payload).config;
      expect(stored.id, created.id);
      expect(stored.displayName, 'Renamed');

      final list = await registry.list();
      expect(list, hasLength(1));
    });

    test('trims the display name', () async {
      final response = await call(MessageTypes.providerUpsertRequest, {
        'config': {...claudeConfig(), 'displayName': '  Claude  '},
      });
      expect(
        ProviderUpsertResponse.fromJson(response.payload).config.displayName,
        'Claude',
      );
    });

    test('rejects a missing config', () async {
      final response = await call(MessageTypes.providerUpsertRequest);
      expect(response.error?.code, RpcErrorCodes.invalidPayload);
      expect(response.error?.message, contains('config is required'));
    });

    test('rejects a blank display name', () async {
      final response = await call(MessageTypes.providerUpsertRequest, {
        'config': {...claudeConfig(), 'displayName': '   '},
      });
      expect(response.error?.code, RpcErrorCodes.invalidPayload);
      expect(response.error?.message, contains('displayName is required'));
    });

    // Caught at the boundary, not as an opaque mid-stream HTTP failure.
    test('rejects non-http, relative, and host-less base URLs', () async {
      for (final bad in [
        'not-a-url',
        'ftp://example.com/v1',
        '/v1',
        'https://',
        '',
      ]) {
        final response = await call(MessageTypes.providerUpsertRequest, {
          'config': {...claudeConfig(), 'baseUrl': bad},
        });
        expect(
          response.error?.code,
          RpcErrorCodes.invalidPayload,
          reason: 'should reject "$bad"',
        );
        expect(response.error?.message, contains('absolute http(s) URL'));
      }
    });

    test('rejects a trailing slash, which would double up in the path', () async {
      final response = await call(MessageTypes.providerUpsertRequest, {
        'config': {
          ...claudeConfig(),
          'baseUrl': 'https://api.anthropic.com/v1/',
        },
      });
      expect(response.error?.code, RpcErrorCodes.invalidPayload);
      expect(response.error?.message, contains('must not end with a slash'));
    });

    test('accepts plain http (for local gateways)', () async {
      final response = await call(MessageTypes.providerUpsertRequest, {
        'config': {...claudeConfig(), 'baseUrl': 'http://localhost:8080/v1'},
      });
      expect(response.error, isNull);
    });
  });

  group('provider.list', () {
    test('is empty before anything is configured', () async {
      final response = await call(MessageTypes.providerListRequest);
      expect(
        ProviderListResponse.fromJson(response.payload).providers,
        isEmpty,
      );
    });

    test('reports configured state and the fetched model list', () async {
      await call(MessageTypes.providerUpsertRequest, {
        'config': claudeConfig(),
        'apiKey': 'sk-ant-1',
      });

      final response = await call(MessageTypes.providerListRequest);
      final info =
          ProviderListResponse.fromJson(response.payload).providers.single;
      expect(info.configured, isTrue);
      expect(info.kind, ProviderKind.anthropic);
      expect(info.baseUrl, 'https://api.anthropic.com/v1');
      expect(info.models.single.id, 'fetched');
    });
  });

  group('provider.delete', () {
    test('removes the provider and its key', () async {
      final created = ProviderUpsertResponse.fromJson(
        (await call(MessageTypes.providerUpsertRequest, {
          'config': claudeConfig(),
          'apiKey': 'sk-ant-1',
        }))
            .payload,
      ).config;

      final response = await call(MessageTypes.providerDeleteRequest, {
        'providerId': created.id,
      });
      expect(response.error, isNull);
      expect(await registry.list(), isEmpty);
      expect(await credentials.get(created.id), isNull);
    });

    test('404s on an unknown id', () async {
      final response = await call(MessageTypes.providerDeleteRequest, {
        'providerId': 'nope',
      });
      expect(response.error?.code, RpcErrorCodes.notFound);
      expect(response.error?.message, contains('nope'));
    });

    test('rejects a missing providerId', () async {
      final response = await call(MessageTypes.providerDeleteRequest);
      expect(response.error?.code, RpcErrorCodes.invalidPayload);
    });
  });

  group('provider.credential.*', () {
    Future<String> seed() async => ProviderUpsertResponse.fromJson(
          (await call(MessageTypes.providerUpsertRequest, {
            'config': claudeConfig(),
          }))
              .payload,
        ).config.id;

    test('set then clear round-trips the stored key', () async {
      final id = await seed();

      expect(
        (await call(MessageTypes.providerCredentialSetRequest, {
          'providerId': id,
          'apiKey': 'sk-1',
        }))
            .error,
        isNull,
      );
      expect(await credentials.get(id), 'sk-1');

      expect(
        (await call(MessageTypes.providerCredentialClearRequest, {
          'providerId': id,
        }))
            .error,
        isNull,
      );
      expect(await credentials.get(id), isNull);
    });

    test('set requires both providerId and apiKey', () async {
      final id = await seed();
      expect(
        (await call(MessageTypes.providerCredentialSetRequest, {
          'apiKey': 'sk-1',
        }))
            .error
            ?.code,
        RpcErrorCodes.invalidPayload,
      );
      expect(
        (await call(MessageTypes.providerCredentialSetRequest, {
          'providerId': id,
        }))
            .error
            ?.code,
        RpcErrorCodes.invalidPayload,
      );
    });

    test('set and clear 404 on an unknown id', () async {
      for (final type in [
        MessageTypes.providerCredentialSetRequest,
        MessageTypes.providerCredentialClearRequest,
      ]) {
        final response = await call(type, {
          'providerId': 'nope',
          'apiKey': 'sk-1',
        });
        expect(response.error?.code, RpcErrorCodes.notFound, reason: type);
      }
    });

    test('test reports ok using the stored key', () async {
      final id = await seed();
      await call(MessageTypes.providerCredentialSetRequest, {
        'providerId': id,
        'apiKey': 'sk-1',
      });

      final response = await call(MessageTypes.providerCredentialTestRequest, {
        'providerId': id,
      });
      final result = ProviderCredentialTestResult.fromJson(response.payload);
      expect(result.ok, isTrue);
      expect(result.error, isNull);
    });

    test('test reports a rejection reason', () async {
      final id = await seed();
      backend.credentialOk = false;

      final response = await call(MessageTypes.providerCredentialTestRequest, {
        'providerId': id,
        'apiKey': 'sk-bad',
      });
      final result = ProviderCredentialTestResult.fromJson(response.payload);
      expect(result.ok, isFalse);
      expect(result.error, 'API key rejected by provider');
    });

    test('test reports no-key rather than calling the provider', () async {
      final id = await seed();
      final response = await call(MessageTypes.providerCredentialTestRequest, {
        'providerId': id,
      });
      final result = ProviderCredentialTestResult.fromJson(response.payload);
      expect(result.ok, isFalse);
      expect(result.error, 'no API key given');
    });

    test('test 404s on an unknown id', () async {
      final response = await call(MessageTypes.providerCredentialTestRequest, {
        'providerId': 'nope',
      });
      expect(response.error?.code, RpcErrorCodes.notFound);
    });
  });
}
