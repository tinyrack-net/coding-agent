// Ports of the upstream Vitest suites for five frozen Paseo 0.2.0 modules:
// utils/assistant-image-metadata, utils/test-daemon-connection,
// types/agent-activity, stores/session-store-hooks/selectors and
// dictation/dictation-stream-sender.
//
// Every upstream case is reproduced. Three groups needed re-expression rather
// than transcription, each noted at its group:
//
// * The selectors suite drives a live zustand store and asserts *reference
//   stability* through `useStoreWithEqualityFn`. That store has no Dart port,
//   so `_TrackedSelector` below reproduces the hook's contract — hold the last
//   published value, republish only when the equality function rejects the
//   candidate — over explicit snapshots. The assertions are unchanged; only the
//   thing producing successive states is.
// * The dictation burst case counts V8 microtask turns via a two-`await` tick.
//   Dart's async scheduling does not agree turn-for-turn, so the flush
//   scheduler is injected and driven by hand, which pins the invariant the
//   upstream case exists for (no unbounded synchronous replay) more tightly
//   than a turn count could.
// * The relay URL case expects the WHATWG `URL` serialisation, which drops the
//   default `wss:` port. Dart's `Uri` keeps it; the assertion is adjusted and
//   the deviation is called out at the case.
//
// Cases the upstream suites leave unpinned — LRU eviction in both image caches,
// the `Object.is` primitive-by-value rule, the numeric/base collation
// approximation, the probe timeout, and every `restartStream`/`cancel`
// transition — are pinned here so the deviations documented in the library are
// visible rather than assumed.
import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/paseo_more_utils.dart'
    show AssistantMessageHeightEstimateCache;
import 'package:coding_agent_app/core/paseo_session_selectors.dart';
import 'package:coding_agent_app/core/paseo_app_misc.dart'
    show WorkspaceStructureHostPlacement, WorkspaceStructureProject;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('assistant image metadata', () {
    late AssistantImageMetadataCache cache;

    setUp(() {
      cache = AssistantImageMetadataCache();
    });

    test('extracts markdown image sources', () {
      expect(
        cache.extractImageSources(
          'Before\n\n![local](/tmp/paseo.png)\n\n'
          '![remote](https://example.com/test.png "Remote")',
        ),
        ['/tmp/paseo.png', 'https://example.com/test.png'],
      );
    });

    test('reuses cached metadata across canonical and raw source keys', () {
      cache.setMetadata(
        source: '/tmp/paseo-codex-screenshot.png',
        workspaceRoot: '/workspaces/paseo',
        serverId: 'server-1',
        width: 1200,
        height: 800,
      );

      expect(
        cache.getMetadata(source: '/tmp/paseo-codex-screenshot.png'),
        const AssistantImageMetadata(
          width: 1200,
          height: 800,
          aspectRatio: 1.5,
        ),
      );
    });

    test('maps missing metadata to the image loading state', () {
      expect(
        getAssistantImageLoadStateFromMetadata(null),
        const AssistantImageLoading(),
      );
    });

    test('maps cached metadata to the image ready state', () {
      expect(
        getAssistantImageLoadStateFromMetadata(
          const AssistantImageMetadata(
            width: 900,
            height: 1600,
            aspectRatio: 9 / 16,
          ),
        ),
        const AssistantImageReady(aspectRatio: 9 / 16),
      );
    });

    test('estimates assistant message height from cached image metadata', () {
      cache.setMetadata(
        source: 'https://example.com/landscape.png',
        width: 1200,
        height: 800,
      );

      expect(
        cache.estimateMessageHeightFromCache(
          'Here is the screenshot\n\n'
          '![Screenshot](https://example.com/landscape.png)',
        ),
        greaterThan(assistantMessageMinHeight),
      );
    });

    test('estimates image-only data-image markdown without caching the full '
        'payload as text', () {
      final source = 'data:image/png;base64,${'a' * 512}';
      cache.setMetadata(source: source, width: 1200, height: 800);

      final imageOnlyHeight = cache.estimateMessageHeightFromCache(
        '![Screenshot]($source)',
      );
      final mixedHeight = cache.estimateMessageHeightFromCache(
        'Text\n\n![Screenshot]($source)',
      );

      expect(imageOnlyHeight, greaterThan(assistantMessageMinHeight));
      expect(mixedHeight, greaterThan(imageOnlyHeight ?? 0));
      // The exact arithmetic, so the base-height split is pinned rather than
      // merely ordered: 812 / 1.5 rounds to 541, plus one 24px gap.
      expect(
        imageOnlyHeight,
        assistantMessageImageOnlyBaseHeight + 541 + assistantImageBlockGap,
      );
      expect(
        mixedHeight,
        assistantMessageBaseHeight + 541 + assistantImageBlockGap,
      );
    });

    test('never caches a parse of markdown that carries a data image', () {
      final source = 'data:image/png;base64,${'a' * 512}';

      cache.extractImageSources('![Screenshot]($source)');
      expect(cache.parseLength, 0);

      cache.extractImageSources('![Screenshot](/tmp/a.png)');
      expect(cache.parseLength, 1);
    });

    test('serves a repeated parse from the cache', () {
      const markdown = 'Text\n\n![a](/tmp/a.png)';
      final first = cache.extractImageSources(markdown);
      final second = cache.extractImageSources(markdown);

      expect(second, ['/tmp/a.png']);
      // The cached parse hands back the very same list, which is what makes the
      // cache worth having for a re-render.
      expect(identical(first, second), isTrue);
    });

    test('estimating never populates the parse cache', () {
      cache.setMetadata(source: '/tmp/a.png', width: 100, height: 100);

      expect(
        cache.estimateMessageHeightFromCache('![a](/tmp/a.png)'),
        isNotNull,
      );
      expect(cache.parseLength, 0);
    });

    test('normalizes angle-bracketed and titled image targets', () {
      expect(cache.extractImageSources('![a](< /tmp/spaced.png >)'), [
        '/tmp/spaced.png',
      ]);
      expect(cache.extractImageSources("![a](/tmp/a.png 'Title')"), [
        '/tmp/a.png',
      ]);
      // An empty angle-bracketed target yields nothing rather than an empty
      // source that would later resolve to null anyway.
      expect(cache.extractImageSources('![a](<>)'), isEmpty);
    });

    test('ignores markdown with no images', () {
      expect(cache.extractImageSources('plain text'), isEmpty);
      expect(cache.estimateMessageHeightFromCache('plain text'), isNull);
    });

    test('returns null when no referenced image has been measured', () {
      expect(
        cache.estimateMessageHeightFromCache('![a](/tmp/unmeasured.png)'),
        isNull,
      );
    });

    test('floors a very wide image at the minimum block height', () {
      cache.setMetadata(source: '/tmp/wide.png', width: 10000, height: 100);

      // 812 / 100 rounds to 8, which the 160 block floor lifts. The message
      // floor does not bind here: 40 + 160 + 24 already clears 220.
      expect(
        cache.estimateMessageHeightFromCache('![a](/tmp/wide.png)'),
        assistantMessageImageOnlyBaseHeight +
            assistantImageMinHeight +
            assistantImageBlockGap,
      );
      expect(
        cache.estimateMessageHeightFromCache('![a](/tmp/wide.png)'),
        greaterThan(assistantMessageMinHeight),
      );
    });

    test('rejects unusable measurements', () {
      expect(
        cache.setMetadata(source: '/tmp/a.png', width: 0, height: 100),
        isNull,
      );
      expect(
        cache.setMetadata(source: '/tmp/a.png', width: 100, height: -1),
        isNull,
      );
      expect(
        cache.setMetadata(
          source: '/tmp/a.png',
          width: double.infinity,
          height: 100,
        ),
        isNull,
      );
      expect(
        cache.setMetadata(source: '/tmp/a.png', width: 100, height: double.nan),
        isNull,
      );
      expect(cache.getMetadata(source: '/tmp/a.png'), isNull);
      expect(cache.metadataLength, 0);
    });

    test('files nothing under a blank source', () {
      expect(
        cache.setMetadata(source: '   ', width: 100, height: 100),
        isNotNull,
      );
      expect(cache.metadataLength, 0);
      expect(cache.getMetadata(source: '   '), isNull);
    });

    test('keys a file image by server so two hosts do not collide', () {
      cache.setMetadata(
        source: '/repo/shot.png',
        workspaceRoot: '/repo',
        serverId: 'server-a',
        width: 400,
        height: 200,
      );

      // Same path, different host: the resolution key differs, and the shared
      // alias key is what still resolves it.
      expect(
        cache
            .getMetadata(
              source: '/repo/shot.png',
              workspaceRoot: '/repo',
              serverId: 'server-b',
            )
            ?.aspectRatio,
        2.0,
      );
      // Two keys were written: the host-scoped one and the alias.
      expect(cache.metadataLength, 2);
    });

    test('files a measurement under both its resolution and alias keys', () {
      cache.setMetadata(
        source: 'https://example.com/a.png',
        width: 100,
        height: 100,
      );

      // Two keys per source is what makes the alias lookup work, and it is what
      // the eviction arithmetic below is counted in.
      expect(cache.metadataLength, 2);
    });

    test('evicts the least recently used measurement past the limit', () {
      // Two keys per source, so half the limit plus one source overflows it.
      for (
        var index = 0;
        index <= assistantImageMetadataCacheLimit ~/ 2;
        index++
      ) {
        cache.setMetadata(
          source: 'https://example.com/$index.png',
          width: 100,
          height: 100,
        );
      }

      expect(cache.metadataLength, assistantImageMetadataCacheLimit);
      expect(cache.getMetadata(source: 'https://example.com/0.png'), isNull);
      expect(cache.getMetadata(source: 'https://example.com/1.png'), isNotNull);
    });

    test('a read refreshes recency so a live image is not evicted', () {
      cache.setMetadata(
        source: 'https://example.com/keep.png',
        width: 100,
        height: 100,
      );
      // Fill to exactly the limit: `keep` plus (limit / 2 - 1) more sources.
      for (
        var index = 0;
        index < assistantImageMetadataCacheLimit ~/ 2 - 1;
        index++
      ) {
        cache.setMetadata(
          source: 'https://example.com/$index.png',
          width: 100,
          height: 100,
        );
      }
      expect(cache.metadataLength, assistantImageMetadataCacheLimit);

      // The read moves `keep`'s resolution key to the most-recent end; its
      // alias key stays where it was and is the first thing to go.
      expect(
        cache.getMetadata(source: 'https://example.com/keep.png'),
        isNotNull,
      );
      cache.setMetadata(
        source: 'https://example.com/overflow-a.png',
        width: 100,
        height: 100,
      );
      cache.setMetadata(
        source: 'https://example.com/overflow-b.png',
        width: 100,
        height: 100,
      );

      expect(
        cache.getMetadata(source: 'https://example.com/keep.png'),
        isNotNull,
      );
      expect(cache.getMetadata(source: 'https://example.com/0.png'), isNull);
    });

    test('evicts the least recently used parse past the limit', () {
      for (var index = 0; index <= assistantImageParseCacheLimit; index++) {
        cache.extractImageSources('![a](/tmp/$index.png)');
      }

      expect(cache.parseLength, assistantImageParseCacheLimit);
    });

    test('clear drops both caches', () {
      cache
        ..setMetadata(source: '/tmp/a.png', width: 10, height: 10)
        ..extractImageSources('![a](/tmp/a.png)');
      expect(cache.metadataLength, greaterThan(0));
      expect(cache.parseLength, greaterThan(0));

      cache.clear();

      expect(cache.metadataLength, 0);
      expect(cache.parseLength, 0);
    });

    // The reuse contract this port exists to satisfy: `paseo_more_utils.dart`
    // declares `AssistantImageHeightEstimator` as `int? Function(String)` and
    // takes it as `imageFallback` precisely because this module was unported.
    test('satisfies the AssistantMessageHeightEstimateCache fallback seam', () {
      cache.setMetadata(
        source: 'https://example.com/landscape.png',
        width: 1200,
        height: 800,
      );

      final heightCache = AssistantMessageHeightEstimateCache(
        imageFallback: cache.estimateMessageHeightFromCache,
      );

      // No markdown block was ever measured, so the block path yields null and
      // upstream's `markdownEstimate ?? imageEstimate` falls through to here.
      expect(
        heightCache.estimateFromCache(
          '![Screenshot](https://example.com/landscape.png)',
        ),
        cache.estimateMessageHeightFromCache(
          '![Screenshot](https://example.com/landscape.png)',
        ),
      );
    });
  });

  group('test-daemon-connection connectToDaemon', () {
    late _FakeDaemonProbe probe;

    setUp(() {
      probe = _FakeDaemonProbe();
    });

    test('reuses the app clientId for direct connections', () async {
      final first = await connectToDaemon(
        const DirectTcpHostConnection(
          id: 'direct:lan:6767',
          endpoint: 'lan:6767',
        ),
        deps: probe.deps,
      );
      await first.client.close();

      final second = await connectToDaemon(
        const DirectTcpHostConnection(
          id: 'direct:lan:6767',
          endpoint: 'lan:6767',
        ),
        deps: probe.deps,
      );
      await second.client.close();

      final configs = probe.createdConfigs();
      expect(configs[0].clientId, 'cid_shared_probe_test');
      expect(configs[1].clientId, 'cid_shared_probe_test');
      expect(probe.clientIdsRequested, 2);
    });

    test('encodes the local socket target into the client config', () async {
      final result = await connectToDaemon(
        const DirectSocketHostConnection(
          id: 'socket:/tmp/paseo.sock',
          path: '/tmp/paseo.sock',
        ),
        deps: probe.deps,
      );
      await result.client.close();

      expect(
        probe.createdConfigs()[0].url,
        'paseo+local://socket?path=%2Ftmp%2Fpaseo.sock',
      );
    });

    test('encodes the local pipe target into the client config', () async {
      final result = await connectToDaemon(
        const DirectPipeHostConnection(
          id: r'pipe:\\.\pipe\paseo',
          path: r'\\.\pipe\paseo',
        ),
        deps: probe.deps,
      );
      await result.client.close();

      expect(
        probe.createdConfigs()[0].url,
        r'paseo+local://pipe?path=%5C%5C.%5Cpipe%5Cpaseo',
      );
    });

    test(
      'passes direct TCP connection passwords into the client config',
      () async {
        final result = await connectToDaemon(
          const DirectTcpHostConnection(
            id: 'direct:lan:6767',
            endpoint: 'lan:6767',
            password: 'shared-secret',
          ),
          deps: probe.deps,
        );
        await result.client.close();

        expect(probe.createdConfigs()[0].password, 'shared-secret');
      },
    );

    test('uses relay TLS from the stored connection', () async {
      final tlsResult = await connectToDaemon(
        const RelayHostConnection(
          id: 'relay:wss:[::1]:443',
          relayEndpoint: '[::1]:443',
          useTls: true,
          daemonPublicKeyB64: 'pubkey',
        ),
        serverId: 'srv_probe_test',
        deps: probe.deps,
      );
      await tlsResult.client.close();

      final plainResult = await connectToDaemon(
        const RelayHostConnection(
          id: 'relay:relay.paseo.sh:443',
          relayEndpoint: 'relay.paseo.sh:443',
          useTls: false,
          daemonPublicKeyB64: 'pubkey',
        ),
        serverId: 'srv_probe_test',
        deps: probe.deps,
      );
      await plainResult.client.close();

      // Deviation, documented on `buildDaemonProbeClientConfig`: upstream's
      // WHATWG `URL` drops the default `wss:` port and asserts
      // `wss://[::1]/ws?`; Dart's `Uri` (inside the reused protocol helper)
      // keeps it.
      expect(probe.createdConfigs()[0].url, startsWith('wss://[::1]:443/ws?'));
      expect(
        probe.createdConfigs()[1].url,
        startsWith('ws://relay.paseo.sh:443/ws?'),
      );
      expect(
        probe.createdConfigs()[0].e2ee,
        const DaemonClientE2eeConfig(
          enabled: true,
          daemonPublicKeyB64: 'pubkey',
        ),
      );
    });

    test('falls back to the hosted-relay TLS heuristic when unset', () async {
      final result = await connectToDaemon(
        const RelayHostConnection(
          id: 'relay:relay.paseo.sh:443',
          relayEndpoint: 'relay.paseo.sh:443',
          daemonPublicKeyB64: 'pubkey',
        ),
        serverId: 'srv_probe_test',
        deps: probe.deps,
      );
      await result.client.close();

      expect(probe.createdConfigs()[0].url, startsWith('wss://'));
    });

    test('surfaces auth rejection as an incorrect password', () async {
      probe.failNextConnection(
        Exception('Transport closed (code 4001)'),
        'Transport closed (code 4001)',
      );

      await expectLater(
        connectToDaemon(
          const DirectTcpHostConnection(
            id: 'direct:lan:6767',
            endpoint: 'lan:6767',
            password: 'wrong-secret',
          ),
          deps: probe.deps,
        ),
        throwsA(
          isA<DaemonConnectionTestException>().having(
            (error) => error.message,
            'message',
            'Incorrect password',
          ),
        ),
      );
    });

    test(
      'keeps generic transport failures generic when a password was supplied',
      () async {
        probe.failNextConnection(
          Exception('Transport error'),
          'Transport error',
        );

        await expectLater(
          connectToDaemon(
            const DirectTcpHostConnection(
              id: 'direct:lan:6767',
              endpoint: 'lan:6767',
              password: 'shared-secret',
            ),
            deps: probe.deps,
          ),
          throwsA(
            isA<DaemonConnectionTestException>().having(
              (error) => error.message,
              'message',
              'Transport error',
            ),
          ),
        );
      },
    );

    test('closes the client on every failure path', () async {
      probe.failNextConnection(Exception('Transport error'), null);

      await expectLater(
        connectToDaemon(
          const DirectTcpHostConnection(
            id: 'direct:lan:6767',
            endpoint: 'lan:6767',
          ),
          deps: probe.deps,
        ),
        throwsA(isA<DaemonConnectionTestException>()),
      );

      expect(probe.closedClients, hasLength(1));
    });

    test('rejects a socket that never announced itself', () async {
      probe.nextServerInfo = null;

      await expectLater(
        connectToDaemon(
          const DirectTcpHostConnection(
            id: 'direct:lan:6767',
            endpoint: 'lan:6767',
          ),
          deps: probe.deps,
        ),
        throwsA(
          isA<DaemonConnectionTestException>().having(
            (error) => error.message,
            'message',
            'Missing server info message',
          ),
        ),
      );
      expect(probe.closedClients, hasLength(1));
    });

    test('times out and closes the client', () async {
      probe.hangNextConnection = true;
      void Function() fireTimeout = () {};

      final probeFuture = connectToDaemon(
        const DirectTcpHostConnection(
          id: 'direct:lan:6767',
          endpoint: 'lan:6767',
        ),
        deps: probe.deps,
        scheduleTimeout: (duration, callback) {
          expect(duration, const Duration(seconds: 6));
          fireTimeout = callback;
          return () {};
        },
      );
      final expectation = expectLater(
        probeFuture,
        throwsA(
          isA<DaemonConnectionTestException>().having(
            (error) => error.message,
            'message',
            'Connection timed out',
          ),
        ),
      );

      // `connectToDaemon` awaits the client id before it ever schedules the
      // timeout, so the scheduler is not installed until the next turn.
      await _tick();
      // The probe is now suspended on `connect()`; firing the injected
      // scheduler is what a real six-second timer would do.
      fireTimeout();

      await expectation;
      expect(probe.closedClients, hasLength(1));
    });

    test('a relay probe waits longer than a direct one', () {
      expect(
        resolveDaemonProbeTimeout(
          const RelayHostConnection(
            id: 'relay:r:443',
            relayEndpoint: 'r:443',
            daemonPublicKeyB64: 'k',
          ),
        ),
        const Duration(seconds: 10),
      );
      expect(
        resolveDaemonProbeTimeout(
          const DirectTcpHostConnection(id: 'direct:lan:1', endpoint: 'lan:1'),
        ),
        const Duration(seconds: 6),
      );
      expect(
        resolveDaemonProbeTimeout(
          const DirectTcpHostConnection(id: 'direct:lan:1', endpoint: 'lan:1'),
          timeout: const Duration(seconds: 2),
        ),
        const Duration(seconds: 2),
      );
      // Upstream's `if (options?.timeoutMs)` is truthy, so an explicit zero
      // falls through to the default rather than timing out instantly.
      expect(
        resolveDaemonProbeTimeout(
          const DirectTcpHostConnection(id: 'direct:lan:1', endpoint: 'lan:1'),
          timeout: Duration.zero,
        ),
        const Duration(seconds: 6),
      );
    });

    test('refuses to probe a relay without a serverId', () async {
      await expectLater(
        connectToDaemon(
          const RelayHostConnection(
            id: 'relay:r:443',
            relayEndpoint: 'r:443',
            daemonPublicKeyB64: 'k',
          ),
          deps: probe.deps,
        ),
        throwsA(
          isA<DaemonConnectionTestException>().having(
            (error) => error.message,
            'message',
            'serverId is required to probe a relay connection',
          ),
        ),
      );
    });

    test(
      'attaches the local transport factory only to local connections',
      () async {
        probe.localTransportFactory = 'factory';

        final socket = await connectToDaemon(
          const DirectSocketHostConnection(id: 'socket:/s', path: '/s'),
          deps: probe.deps,
        );
        await socket.client.close();

        final tcp = await connectToDaemon(
          const DirectTcpHostConnection(id: 'direct:lan:1', endpoint: 'lan:1'),
          deps: probe.deps,
        );
        await tcp.client.close();

        expect(probe.createdConfigs()[0].transportFactory, 'factory');
        expect(probe.createdConfigs()[1].transportFactory, isNull);
      },
    );

    test(
      'carries the app version, capabilities and probe-safe defaults',
      () async {
        probe.appVersion = '1.2.3';

        final result = await connectToDaemon(
          const DirectTcpHostConnection(id: 'direct:lan:1', endpoint: 'lan:1'),
          capabilities: const {'dictation': true},
          deps: probe.deps,
        );
        await result.client.close();

        final config = probe.createdConfigs()[0];
        expect(config.appVersion, '1.2.3');
        expect(config.capabilities, const {'dictation': true});
        expect(config.clientType, DaemonClientType.mobile);
        expect(config.suppressSendErrors, isTrue);
        expect(config.reconnect.enabled, isFalse);
        expect(config.e2ee, isNull);
        // The redaction is what makes a config safe to log.
        expect(config.toString(), isNot(contains('shared-secret')));
      },
    );

    test('drops an empty stored password rather than sending it', () async {
      final result = await connectToDaemon(
        const DirectTcpHostConnection(
          id: 'direct:lan:1',
          endpoint: 'lan:1',
          password: '',
        ),
        deps: probe.deps,
      );
      await result.client.close();

      expect(probe.createdConfigs()[0].password, isNull);
    });

    test('prefers the more specific of two failure signals', () {
      expect(
        pickBestProbeFailureReason('Transport closed', 'certificate expired'),
        'certificate expired',
      );
      expect(
        pickBestProbeFailureReason('Transport closed', 'Transport error'),
        'Transport closed',
      );
      expect(
        pickBestProbeFailureReason('Transport error', 'Unable to connect'),
        'Transport error',
      );
      expect(pickBestProbeFailureReason(null, 'boom'), 'boom');
      expect(pickBestProbeFailureReason('boom', null), 'boom');
      expect(pickBestProbeFailureReason(null, null), 'Unable to connect');
    });

    test('never blames credentials when none were supplied', () {
      const passwordless = DaemonProbeClientConfig(
        url: 'ws://lan:1/ws',
        clientId: 'cid',
        clientType: DaemonClientType.mobile,
        suppressSendErrors: true,
        reconnect: DaemonClientReconnectConfig(enabled: false),
      );
      expect(
        isIncorrectDaemonPasswordFailure(
          config: passwordless,
          reason: '401 unauthorized',
          lastError: null,
        ),
        isFalse,
      );

      const withPassword = DaemonProbeClientConfig(
        url: 'ws://lan:1/ws',
        clientId: 'cid',
        clientType: DaemonClientType.mobile,
        suppressSendErrors: true,
        reconnect: DaemonClientReconnectConfig(enabled: false),
        password: 'secret',
      );
      for (final detail in ['401', '4001', 'Unauthorized', 'code 1006']) {
        expect(
          isIncorrectDaemonPasswordFailure(
            config: withPassword,
            reason: detail,
            lastError: null,
          ),
          isTrue,
          reason: detail,
        );
      }
      expect(
        isIncorrectDaemonPasswordFailure(
          config: withPassword,
          reason: 'dns failure',
          lastError: null,
        ),
        isFalse,
      );
    });
  });

  group('groupActivities', () {
    test('groups text chunks and merges tool call updates at the first tool '
        'position', () {
      final activities = <AgentActivity>[
        AgentActivity(
          timestamp: _timestamp(1),
          update: const AgentMessageChunk(text: 'Hel'),
        ),
        AgentActivity(
          timestamp: _timestamp(2),
          update: const AgentMessageChunk(text: 'lo'),
        ),
        AgentActivity(
          timestamp: _timestamp(3),
          update: const ToolCall(
            toolCallId: 'tool_1',
            title: 'Read file',
            status: AcpToolCallStatus.inProgress,
            toolKind: ToolKind.read,
            input: {'path': 'README.md'},
          ),
        ),
        AgentActivity(
          timestamp: _timestamp(4),
          update: const AgentThoughtChunk(text: 'Checking context'),
        ),
        AgentActivity(
          timestamp: _timestamp(5),
          update: const ToolCallUpdate(
            toolCallId: 'tool_1',
            status: AcpToolCallStatus.completed,
            output: {'ok': true},
          ),
        ),
      ];

      expect(groupActivities(activities), [
        GroupedTextMessage(
          messageType: TextMessageType.agent,
          text: 'Hello',
          startTimestamp: _timestamp(1),
          endTimestamp: _timestamp(2),
        ),
        MergedToolCall(
          toolCallId: 'tool_1',
          title: 'Read file',
          status: AcpToolCallStatus.completed,
          toolKind: ToolKind.read,
          input: const {'path': 'README.md'},
          output: const {'ok': true},
          content: null,
          locations: null,
          startTimestamp: _timestamp(3),
          endTimestamp: _timestamp(5),
        ),
        GroupedTextMessage(
          messageType: TextMessageType.thought,
          text: 'Checking context',
          startTimestamp: _timestamp(4),
          endTimestamp: _timestamp(4),
        ),
      ]);
    });

    test('creates a merged tool call when an update arrives before the initial '
        'call', () {
      final activities = <AgentActivity>[
        AgentActivity(
          timestamp: _timestamp(1),
          update: const ToolCallUpdate(
            toolCallId: 'tool_2',
            title: 'Shell',
            status: AcpToolCallStatus.completed,
            toolKind: ToolKind.execute,
            output: {'exitCode': 0},
          ),
        ),
      ];

      expect(groupActivities(activities), [
        MergedToolCall(
          toolCallId: 'tool_2',
          title: 'Shell',
          status: AcpToolCallStatus.completed,
          toolKind: ToolKind.execute,
          input: null,
          output: const {'exitCode': 0},
          content: null,
          locations: null,
          startTimestamp: _timestamp(1),
          endTimestamp: _timestamp(1),
        ),
      ]);
    });

    test('splits a text run when the author changes', () {
      final grouped = groupActivities([
        AgentActivity(
          timestamp: _timestamp(1),
          update: const UserMessageChunk(text: 'hi'),
        ),
        AgentActivity(
          timestamp: _timestamp(2),
          update: const AgentMessageChunk(text: 'hello'),
        ),
        AgentActivity(
          timestamp: _timestamp(3),
          update: const UserMessageChunk(text: 'again'),
        ),
      ]);

      expect(
        grouped
            .whereType<GroupedTextMessage>()
            .map((message) => (message.messageType, message.text))
            .toList(),
        [
          (TextMessageType.user, 'hi'),
          (TextMessageType.agent, 'hello'),
          (TextMessageType.user, 'again'),
        ],
      );
    });

    test('passes non-text, non-tool updates through in order', () {
      final plan = AgentActivity(
        timestamp: _timestamp(2),
        update: const Plan(
          entries: [
            PlanEntry(
              content: 'Ship it',
              status: PlanEntryStatus.pending,
              priority: PlanEntryPriority.high,
            ),
          ],
        ),
      );
      final mode = AgentActivity(
        timestamp: _timestamp(3),
        update: const CurrentModeUpdate(currentModeId: 'plan'),
      );
      final commands = AgentActivity(
        timestamp: _timestamp(4),
        update: const AvailableCommandsUpdate(
          availableCommands: [
            AvailableCommand(name: 'test', description: 'run tests'),
          ],
        ),
      );

      final grouped = groupActivities([
        AgentActivity(
          timestamp: _timestamp(1),
          update: const AgentMessageChunk(text: 'x'),
        ),
        plan,
        mode,
        commands,
      ]);

      expect(grouped[0], isA<GroupedTextMessage>());
      expect(identical(grouped[1], plan), isTrue);
      expect(identical(grouped[2], mode), isTrue);
      expect(identical(grouped[3], commands), isTrue);
    });

    test('merges input and output key-wise but replaces content', () {
      final grouped = groupActivities([
        AgentActivity(
          timestamp: _timestamp(1),
          update: const ToolCall(
            toolCallId: 't',
            title: 'Edit',
            input: {'path': 'a.dart'},
            output: {'lines': 1},
            content: ['first'],
            locations: ['a'],
          ),
        ),
        AgentActivity(
          timestamp: _timestamp(2),
          update: const ToolCallUpdate(
            toolCallId: 't',
            input: {'mode': 'append'},
            output: {'lines': 2, 'ok': true},
            content: ['second'],
            locations: ['b'],
          ),
        ),
      ]);

      final merged = grouped.single as MergedToolCall;
      expect(merged.input, {'path': 'a.dart', 'mode': 'append'});
      expect(merged.output, {'lines': 2, 'ok': true});
      expect(merged.content, ['second']);
      expect(merged.locations, ['b']);
      // No status was ever sent, so the accumulator's seed survives.
      expect(merged.status, AcpToolCallStatus.pending);
    });

    test('an empty title never clears an existing one, but an empty map does '
        'overwrite', () {
      final grouped = groupActivities([
        AgentActivity(
          timestamp: _timestamp(1),
          update: const ToolCall(
            toolCallId: 't',
            title: 'Read file',
            input: {'path': 'a'},
          ),
        ),
        AgentActivity(
          timestamp: _timestamp(2),
          // JS truthiness: `""` is falsy so the title is kept, while `{}` is
          // truthy so the empty content list replaces nothing-yet.
          update: const ToolCallUpdate(toolCallId: 't', title: '', content: []),
        ),
      ]);

      final merged = grouped.single as MergedToolCall;
      expect(merged.title, 'Read file');
      expect(merged.content, isEmpty);
    });

    test('a patch-first tool call with a blank title gets the placeholder', () {
      final grouped = groupActivities([
        AgentActivity(
          timestamp: _timestamp(1),
          update: const ToolCallUpdate(toolCallId: 't', title: ''),
        ),
      ]);

      expect((grouped.single as MergedToolCall).title, 'Tool Call');
    });

    test('a late initial call fills in the title and keeps the first slot', () {
      final grouped = groupActivities([
        AgentActivity(
          timestamp: _timestamp(1),
          update: const ToolCallUpdate(
            toolCallId: 't',
            status: AcpToolCallStatus.inProgress,
          ),
        ),
        AgentActivity(
          timestamp: _timestamp(2),
          update: const AgentMessageChunk(text: 'thinking'),
        ),
        AgentActivity(
          timestamp: _timestamp(3),
          update: const ToolCall(
            toolCallId: 't',
            title: 'Search',
            toolKind: ToolKind.search,
            locations: ['x'],
          ),
        ),
      ]);

      final merged = grouped.first as MergedToolCall;
      expect(merged.title, 'Search');
      expect(merged.toolKind, ToolKind.search);
      expect(merged.locations, ['x']);
      // Still in progress: the late initial call carried no status.
      expect(merged.status, AcpToolCallStatus.inProgress);
      expect(merged.startTimestamp, _timestamp(1));
      expect(merged.endTimestamp, _timestamp(3));
      expect(grouped[1], isA<GroupedTextMessage>());
    });

    test('returns nothing for an empty log', () {
      expect(groupActivities(const []), isEmpty);
    });
  });

  group('workspace replica authority', () {
    test('keeps a cached workspace addressable without publishing it as an '
        'authoritative directory', () {
      final cachedWorkspace = _createWorkspace(id: 'cached-workspace');
      final cached = _snapshot({
        _serverId: _session([cachedWorkspace], hasHydratedWorkspaces: false),
      });

      final cachedServerIds = selectHydratedWorkspaceServerIds(cached, const [
        _serverId,
      ]);

      expect(
        identical(
          selectWorkspace(cached, _serverId, cachedWorkspace.id),
          cachedWorkspace,
        ),
        isTrue,
      );
      expect(
        selectWorkspaceStructureProjects(cached, cachedServerIds),
        isEmpty,
      );

      final authoritativeWorkspace = _createWorkspace(
        id: 'authoritative-workspace',
        projectId: 'authoritative-project',
      );
      final hydrated = _snapshot({
        _serverId: _session([
          authoritativeWorkspace,
        ], hasHydratedWorkspaces: true),
      });
      final hydratedServerIds = selectHydratedWorkspaceServerIds(
        hydrated,
        const [_serverId],
      );

      expect(
        selectWorkspaceStructureProjects(
          hydrated,
          hydratedServerIds,
        ).map((project) => project.workspaceKeys).toList(),
        [
          ['$_serverId:${authoritativeWorkspace.id}'],
        ],
      );
    });

    test('publishes each host to the workspace directory independently', () {
      const loadingServerId = 'loading-server';
      const hydratedServerId = 'hydrated-server';
      final loadingWorkspace = _createWorkspace(id: 'loading-workspace');
      final hydratedWorkspace = _createWorkspace(
        id: 'hydrated-workspace',
        projectId: 'hydrated-project',
      );
      final state = _snapshot({
        loadingServerId: _session([
          loadingWorkspace,
        ], hasHydratedWorkspaces: false),
        hydratedServerId: _session([
          hydratedWorkspace,
        ], hasHydratedWorkspaces: true),
      });

      final directoryServerIds = selectHydratedWorkspaceServerIds(state, const [
        loadingServerId,
        hydratedServerId,
      ]);
      final directoryProjects = selectWorkspaceStructureProjects(
        state,
        directoryServerIds,
      );

      expect(directoryServerIds, [hydratedServerId]);
      expect(
        directoryProjects.map((project) => project.workspaceKeys).toList(),
        [
          ['$hydratedServerId:${hydratedWorkspace.id}'],
        ],
      );
    });

    test('an absent hydration flag is not hydration', () {
      final state = _snapshot({
        _serverId: _session([_createWorkspace(id: 'w')]),
      });

      expect(selectHasHydratedWorkspaces(state, _serverId), isFalse);
      expect(selectHasHydratedWorkspaces(state, null), isFalse);
      expect(selectHasHydratedWorkspaces(state, 'unknown'), isFalse);
      expect(
        selectHydratedWorkspaceServerIds(state, const [_serverId]),
        isEmpty,
      );
    });
  });

  group('selectWorkspace', () {
    test(
      'resolves a descriptor when the route id matches workspace identity but '
      'not the map key',
      () {
        final workspace = _createWorkspace(id: 'workspace-a');
        final state = _snapshot({
          _serverId: SessionWorkspacesSnapshot(
            workspaces: {'map-key-a': workspace},
          ),
        });

        expect(
          identical(selectWorkspace(state, _serverId, workspace.id), workspace),
          isTrue,
        );
      },
    );

    test('keeps the descriptor reference for unrelated workspace updates', () {
      final workspaceA = _createWorkspace(id: 'workspace-a', name: 'A');
      final workspaceB = _createWorkspace(id: 'workspace-b', name: 'B');
      final tracked = _TrackedSelector<SessionsSnapshot, WorkspaceDescriptor?>(
        select: (state) => selectWorkspace(state, _serverId, workspaceA.id),
        equals: workspaceEqualityFns.identity,
        initial: _snapshot({
          _serverId: _session([workspaceA, workspaceB]),
        }),
      );
      final before = tracked.current;

      tracked.publish(
        _snapshot({
          _serverId: _session([
            workspaceA,
            _createWorkspace(
              id: 'workspace-b',
              name: 'B',
              status: WorkspaceStateBucket.running,
            ),
          ]),
        }),
      );
      expect(identical(tracked.current, before), isTrue);

      tracked.publish(
        _snapshot({
          _serverId: _session([
            _createWorkspace(
              id: 'workspace-a',
              name: 'A',
              status: WorkspaceStateBucket.attention,
            ),
            workspaceB,
          ]),
        }),
      );
      expect(identical(tracked.current, before), isFalse);
    });

    test('keeps the descriptor reference when the observed workspace is '
        're-filed unchanged', () {
      // Upstream drives this through the store's content-equal merge, which
      // preserves the descriptor instance. The selector's own half is that an
      // unchanged instance re-published under a fresh map is still identical.
      final workspace = _createWorkspace(id: 'workspace-a');
      final tracked = _TrackedSelector<SessionsSnapshot, WorkspaceDescriptor?>(
        select: (state) => selectWorkspace(state, _serverId, workspace.id),
        equals: workspaceEqualityFns.identity,
        initial: _snapshot({
          _serverId: _session([workspace]),
        }),
      );
      final before = tracked.current;

      tracked.publish(
        _snapshot({
          _serverId: _session([workspace]),
        }),
      );

      expect(identical(tracked.current, before), isTrue);
    });

    test('returns null for a blank or unknown address', () {
      final state = _snapshot({
        _serverId: _session([_createWorkspace(id: 'w')]),
      });

      expect(selectWorkspace(state, null, 'w'), isNull);
      expect(selectWorkspace(state, '', 'w'), isNull);
      expect(selectWorkspace(state, _serverId, null), isNull);
      expect(selectWorkspace(state, _serverId, ''), isNull);
      expect(selectWorkspace(state, 'other', 'w'), isNull);
      expect(selectWorkspaceExists(state, _serverId, 'w'), isTrue);
      expect(selectWorkspaceExists(state, _serverId, 'missing'), isFalse);
    });
  });

  group('selectWorkspaceDirectory', () {
    test('returns the workspace directory, never the opaque workspace id', () {
      final workspace = _createWorkspace(
        id: 'wks_3f9a2b1c',
        workspaceDirectory: '/Users/dev/project',
      );
      final state = _snapshot({
        _serverId: _session([workspace]),
      });

      final directory = selectWorkspaceDirectory(
        state,
        _serverId,
        'wks_3f9a2b1c',
      );

      expect(directory, '/Users/dev/project');
      expect(directory, isNot('wks_3f9a2b1c'));
    });

    test('returns null when the workspace is missing', () {
      final state = _snapshot({_serverId: _session(const [])});

      expect(selectWorkspaceDirectory(state, _serverId, 'missing-id'), isNull);
    });

    test('collapses a blank directory to null', () {
      final state = _snapshot({
        _serverId: _session([
          _createWorkspace(id: 'w', workspaceDirectory: ''),
        ]),
      });

      expect(selectWorkspaceDirectory(state, _serverId, 'w'), isNull);
    });
  });

  group('selectWorkspaceFields', () {
    test(
      'keeps deep-equal projection references until projected fields change',
      () {
        final workspace = _createWorkspace(id: 'workspace-a', name: 'A');
        Map<String, Object?> selectIdentity(WorkspaceDescriptor current) => {
          'identity': {'id': current.id, 'name': current.name},
        };

        final tracked =
            _TrackedSelector<SessionsSnapshot, Map<String, Object?>?>(
              select: (state) => selectWorkspaceFields(
                state,
                _serverId,
                workspace.id,
                selectIdentity,
              ),
              equals: workspaceEqualityFns.deep,
              initial: _snapshot({
                _serverId: _session([workspace]),
              }),
            );
        final before = tracked.current;

        tracked.publish(
          _snapshot({
            _serverId: _session([
              _createWorkspace(
                id: 'workspace-a',
                name: 'A',
                status: WorkspaceStateBucket.running,
              ),
            ]),
          }),
        );
        expect(identical(tracked.current, before), isTrue);

        tracked.publish(
          _snapshot({
            _serverId: _session([
              _createWorkspace(
                id: 'workspace-a',
                name: 'A renamed',
                status: WorkspaceStateBucket.running,
              ),
            ]),
          }),
        );
        expect(identical(tracked.current, before), isFalse);
      },
    );

    test('projects null when there is no workspace', () {
      final state = _snapshot({_serverId: _session(const [])});

      expect(
        selectWorkspaceFields(state, _serverId, 'missing', (w) => w.name),
        isNull,
      );
    });
  });

  group('workspace structure composition', () {
    test('keeps a project parent visible throughout the last workspace archive '
        'transition', () {
      final workspace = _createWorkspace(
        id: 'workspace-a',
        projectId: 'project-a',
        projectDisplayName: 'Project A',
        projectRootPath: '/repo/a',
        workspaceDirectory: '/repo/a',
      );
      const emptyProject = WorkspaceProjectDescriptor(
        projectId: 'project-a',
        projectDisplayName: 'Project A',
        projectRootPath: '/repo/a',
        projectKind: WorkspaceProjectKind.git,
      );

      // The two states either side of the archive: the workspace goes away and
      // the empty-project row takes over in the same transition.
      final emittedProjectKeys = [
        selectWorkspaceStructureProjects(
          _snapshot({
            _serverId: _session([workspace]),
          }),
          const [_serverId],
        ).map((project) => project.projectKey).toList(),
        selectWorkspaceStructureProjects(
          _snapshot({
            _serverId: SessionWorkspacesSnapshot(
              workspaces: const {},
              emptyProjects: const {'project-a': emptyProject},
            ),
          }),
          const [_serverId],
        ).map((project) => project.projectKey).toList(),
      ];

      expect(emittedProjectKeys, [
        ['project-a'],
        ['project-a'],
      ]);
    });

    test('changes for membership updates but not status-only updates', () {
      final workspaceA = _createWorkspace(id: 'workspace-a', name: 'A');
      final workspaceB = _createWorkspace(id: 'workspace-b', name: 'B');

      final tracked =
          _TrackedSelector<SessionsSnapshot, List<WorkspaceStructureProject>>(
            select: (state) =>
                selectWorkspaceStructureProjects(state, const [_serverId]),
            equals: workspaceEqualityFns.deep,
            initial: _snapshot({
              _serverId: _session([workspaceA]),
            }),
          );
      final before = tracked.current;

      tracked.publish(
        _snapshot({
          _serverId: _session([workspaceA, workspaceB]),
        }),
      );
      final afterAdd = tracked.current;
      expect(identical(afterAdd, before), isFalse);
      expect(afterAdd[0].workspaceKeys, [
        'test-server:workspace-a',
        'test-server:workspace-b',
      ]);

      tracked.publish(
        _snapshot({
          _serverId: _session([
            _createWorkspace(
              id: 'workspace-a',
              name: 'A',
              status: WorkspaceStateBucket.running,
            ),
            workspaceB,
          ]),
        }),
      );
      expect(identical(tracked.current, afterAdd), isTrue);
    });

    test('renders a project parent with zero active workspaces', () {
      final state = _snapshot({
        _serverId: const SessionWorkspacesSnapshot(
          workspaces: {},
          emptyProjects: {
            'empty-project': WorkspaceProjectDescriptor(
              projectId: 'empty-project',
              projectDisplayName: 'Empty Project',
              projectRootPath: '/repo/empty',
              projectKind: WorkspaceProjectKind.git,
            ),
          },
        ),
      });

      final projects = selectWorkspaceStructureProjects(state, const [
        _serverId,
      ]);
      expect(projects, hasLength(1));
      expect(projects.single.projectKey, 'empty-project');
      expect(projects.single.projectName, 'Empty Project');
      expect(projects.single.workspaceKeys, isEmpty);
      expect(projects.single.hosts.single.canCreateWorktree, isTrue);
    });

    test(
      'changes when a structure-relevant project identity field changes',
      () {
        final workspace = _createWorkspace(
          id: 'workspace-a',
          projectDisplayName: 'Project 1',
        );

        final tracked =
            _TrackedSelector<SessionsSnapshot, List<WorkspaceStructureProject>>(
              select: (state) =>
                  selectWorkspaceStructureProjects(state, const [_serverId]),
              equals: workspaceEqualityFns.deep,
              initial: _snapshot({
                _serverId: _session([workspace]),
              }),
            );
        final before = tracked.current;

        tracked.publish(
          _snapshot({
            _serverId: _session([
              _createWorkspace(
                id: 'workspace-a',
                projectDisplayName: 'Project Renamed',
              ),
            ]),
          }),
        );
        expect(identical(tracked.current, before), isFalse);
      },
    );

    test('changes the composed structure when persisted sidebar project order '
        'changes', () {
      final state = _snapshot({
        _serverId: _session([
          _createWorkspace(
            id: 'workspace-a',
            projectId: 'project-a',
            projectDisplayName: 'Project A',
          ),
          _createWorkspace(
            id: 'workspace-b',
            projectId: 'project-b',
            projectDisplayName: 'Project B',
          ),
        ]),
      });

      WorkspaceStructure snapshotStructure(SidebarOrderSnapshot sidebar) =>
          composeWorkspaceStructure(
            projects: selectWorkspaceStructureProjects(state, const [
              _serverId,
            ]),
            projectOrder: selectProjectOrder(sidebar),
            workspaceOrderByScope: selectWorkspaceOrderByScope(sidebar),
          );

      final before = snapshotStructure(const SidebarOrderSnapshot());
      final after = snapshotStructure(
        const SidebarOrderSnapshot(projectOrder: ['project-b', 'project-a']),
      );

      expect(after.projects.map((project) => project.projectKey).toList(), [
        'project-b',
        'project-a',
      ]);
      expect(after, isNot(before));
    });

    test(
      'reorders workspaces inside a project from the stored scope order',
      () {
        final state = _snapshot({
          _serverId: _session([
            _createWorkspace(id: 'workspace-a', name: 'A'),
            _createWorkspace(id: 'workspace-b', name: 'B'),
          ]),
        });

        final composed = composeWorkspaceStructure(
          projects: selectWorkspaceStructureProjects(state, const [_serverId]),
          projectOrder: const [],
          workspaceOrderByScope: const {
            'project-1': ['test-server:workspace-b', 'test-server:workspace-a'],
          },
        );

        expect(composed.projects.single.workspaceKeys, [
          'test-server:workspace-b',
          'test-server:workspace-a',
        ]);
      },
    );

    test('an empty project list composes to the shared empty structure', () {
      final composed = composeWorkspaceStructure(
        projects: const [],
        projectOrder: const ['a'],
        workspaceOrderByScope: const {},
      );

      expect(identical(composed, emptyWorkspaceStructure), isTrue);
      expect(composed.projects, isEmpty);
    });

    test('sorts projects and workspaces by numeric, case-insensitive name', () {
      final state = _snapshot({
        _serverId: _session([
          _createWorkspace(
            id: 'w10',
            name: 'branch-10',
            projectId: 'p',
            projectDisplayName: 'beta',
          ),
          _createWorkspace(
            id: 'w2',
            name: 'branch-2',
            projectId: 'p',
            projectDisplayName: 'beta',
          ),
          _createWorkspace(
            id: 'w1',
            name: 'Branch-1',
            projectId: 'p',
            projectDisplayName: 'beta',
          ),
          _createWorkspace(
            id: 'x',
            name: 'x',
            projectId: 'q',
            projectDisplayName: 'Alpha',
          ),
        ]),
      });

      final projects = selectWorkspaceStructureProjects(state, const [
        _serverId,
      ]);

      expect(projects.map((project) => project.projectName).toList(), [
        'Alpha',
        'beta',
      ]);
      expect(projects[1].workspaceKeys, [
        'test-server:w1',
        'test-server:w2',
        'test-server:w10',
      ]);
    });

    test('a workspace placement key wins over the flat projectId', () {
      final state = _snapshot({
        _serverId: _session([
          _createWorkspace(
            id: 'w',
            projectId: 'flat-project',
            project: const {'projectKey': 'placement-project'},
          ),
        ]),
      });

      expect(
        selectWorkspaceStructureProjects(state, const [
          _serverId,
        ]).single.projectKey,
        'placement-project',
      );
    });

    test('a custom project name wins over the display name', () {
      final state = _snapshot({
        _serverId: _session([
          _createWorkspace(
            id: 'w',
            projectDisplayName: 'Display',
            projectCustomName: 'Custom',
          ),
        ]),
      });

      expect(
        selectWorkspaceStructureProjects(state, const [
          _serverId,
        ]).single.projectName,
        'Custom',
      );
    });

    test('a blank project name falls back to the derived id name', () {
      final state = _snapshot({
        _serverId: _session([
          _createWorkspace(
            id: 'w',
            projectId: 'remote:github.com/acme/widgets',
            projectDisplayName: '',
          ),
        ]),
      });

      expect(
        selectWorkspaceStructureProjects(state, const [
          _serverId,
        ]).single.projectName,
        'acme/widgets',
      );
    });

    test('merges the same project across two hosts', () {
      final state = _snapshot({
        'server-a': _session([
          _createWorkspace(id: 'w1', projectRootPath: '/a'),
        ]),
        'server-b': _session([
          _createWorkspace(id: 'w2', projectRootPath: '/b'),
        ]),
      });

      final project = selectWorkspaceStructureProjects(state, const [
        'server-a',
        'server-b',
      ]).single;

      expect(project.hosts.map((host) => host.serverId).toList(), [
        'server-a',
        'server-b',
      ]);
      expect(project.workspaceKeys, ['server-a:w1', 'server-b:w2']);
      // The first host seen supplies the icon directory.
      expect(project.iconWorkingDir, '/a');
    });

    test('a non-git project cannot spawn worktrees', () {
      final state = _snapshot({
        _serverId: _session([
          _createWorkspace(
            id: 'w',
            projectKind: WorkspaceProjectKind.directory,
          ),
        ]),
      });

      expect(
        selectWorkspaceStructureProjects(state, const [
          _serverId,
        ]).single.hosts.single.canCreateWorktree,
        isFalse,
      );
    });

    test('skips hosts with nothing to contribute', () {
      final state = _snapshot({
        _serverId: const SessionWorkspacesSnapshot(workspaces: {}),
      });

      final projects = selectWorkspaceStructureProjects(state, const [
        _serverId,
        'unknown-server',
      ]);
      expect(identical(projects, emptyWorkspaceStructure.projects), isTrue);
    });
  });

  group('selectWorkspaceKeys', () {
    test('changes for reorder updates but not content-only updates', () {
      final workspaceA = _createWorkspace(id: 'workspace-a', name: 'A');
      final workspaceB = _createWorkspace(id: 'workspace-b', name: 'B');

      final tracked = _TrackedSelector<SessionsSnapshot, List<String>>(
        select: (state) => selectWorkspaceKeys(state, _serverId),
        equals: workspaceEqualityFns.deep,
        initial: _snapshot({
          _serverId: _session([workspaceA, workspaceB]),
        }),
      );
      final before = tracked.current;
      expect(before, ['workspace-a', 'workspace-b']);

      tracked.publish(
        _snapshot({
          _serverId: _session([workspaceB, workspaceA]),
        }),
      );
      final afterReorder = tracked.current;
      expect(identical(afterReorder, before), isFalse);
      expect(afterReorder, ['workspace-b', 'workspace-a']);

      tracked.publish(
        _snapshot({
          _serverId: _session([
            workspaceB,
            _createWorkspace(
              id: 'workspace-a',
              name: 'A',
              status: WorkspaceStateBucket.running,
            ),
          ]),
        }),
      );
      expect(identical(tracked.current, afterReorder), isTrue);
    });

    test('returns the shared empty list for an unaddressable host', () {
      final state = _snapshot({
        _serverId: _session([_createWorkspace(id: 'w')]),
      });

      expect(selectWorkspaceKeys(state, null), isEmpty);
      expect(selectWorkspaceKeys(state, ''), isEmpty);
      expect(selectWorkspaceKeys(state, 'unknown'), isEmpty);
      expect(
        identical(
          selectWorkspaceKeys(state, null),
          selectWorkspaceKeys(state, 'unknown'),
        ),
        isTrue,
      );
    });
  });

  group('selectRecommendedProjectPaths', () {
    test('updates when an existing workspace project root changes', () {
      final state = _snapshot({
        _serverId: _session([
          _createWorkspace(id: 'workspace-a', projectRootPath: '/repo/b'),
        ]),
      });

      expect(selectRecommendedProjectPaths(state, _serverId), ['/repo/b']);
    });

    test('keeps the path list reference under unrelated workspace updates', () {
      final workspace = _createWorkspace(
        id: 'workspace-a',
        projectRootPath: '/repo/a',
      );
      final tracked = _TrackedSelector<SessionsSnapshot, List<String>>(
        select: (state) => selectRecommendedProjectPaths(state, _serverId),
        equals: workspaceEqualityFns.deep,
        initial: _snapshot({
          _serverId: _session([workspace]),
        }),
      );
      final before = tracked.current;

      tracked.publish(
        _snapshot({
          _serverId: _session([
            _createWorkspace(
              id: 'workspace-a',
              projectRootPath: '/repo/a',
              status: WorkspaceStateBucket.running,
            ),
          ]),
        }),
      );
      expect(identical(tracked.current, before), isTrue);
    });

    test('drops blank roots and unaddressable hosts', () {
      final state = _snapshot({
        _serverId: _session([
          _createWorkspace(id: 'a', projectRootPath: ''),
          _createWorkspace(id: 'b', projectRootPath: '/repo'),
        ]),
      });

      expect(selectRecommendedProjectPaths(state, _serverId), ['/repo']);
      expect(selectRecommendedProjectPaths(state, null), isEmpty);
      expect(selectRecommendedProjectPaths(state, 'unknown'), isEmpty);
    });
  });

  group('selectHasWorkspaces', () {
    test('stays stable when workspace membership changes without flipping the '
        'boolean', () {
      final workspaceA = _createWorkspace(id: 'workspace-a');
      final workspaceB = _createWorkspace(id: 'workspace-b');

      final tracked = _TrackedSelector<SessionsSnapshot, bool>(
        select: (state) => selectHasWorkspaces(state, _serverId),
        equals: workspaceEqualityFns.identity,
        initial: _snapshot({
          _serverId: _session([workspaceA]),
        }),
      );
      final before = tracked.current;

      tracked.publish(
        _snapshot({
          _serverId: _session([workspaceA, workspaceB]),
        }),
      );
      expect(tracked.current, before);
      expect(tracked.publishedCount, 0);
    });

    test('is false for an empty or unaddressable host', () {
      final state = _snapshot({_serverId: _session(const [])});

      expect(selectHasWorkspaces(state, _serverId), isFalse);
      expect(selectHasWorkspaces(state, null), isFalse);
      expect(selectHasWorkspaces(state, ''), isFalse);
      expect(selectHasWorkspaces(state, 'unknown'), isFalse);
    });
  });

  group('selectWorkspaceStatusesForBadges', () {
    test('tracks status changes without changing for no-ops or unrelated '
        'descriptor updates', () {
      final workspaceA = _createWorkspace(
        id: 'workspace-a',
        status: WorkspaceStateBucket.done,
      );
      final workspaceB = _createWorkspace(
        id: 'workspace-b',
        status: WorkspaceStateBucket.attention,
      );

      final tracked =
          _TrackedSelector<SessionsSnapshot, List<DesktopBadgeWorkspaceStatus>>(
            select: selectWorkspaceStatusesForBadges,
            equals: workspaceEqualityFns.deep,
            initial: _snapshot({
              _serverId: _session([workspaceA, workspaceB]),
            }),
          );
      final before = tracked.current;
      expect(before, [
        DesktopBadgeWorkspaceStatus.done,
        DesktopBadgeWorkspaceStatus.attention,
      ]);

      tracked.publish(
        _snapshot({
          _serverId: _session([workspaceA, workspaceB]),
        }),
      );
      expect(identical(tracked.current, before), isTrue);

      tracked.publish(
        _snapshot({
          _serverId: _session([
            workspaceA,
            _createWorkspace(
              id: 'workspace-b',
              name: 'Renamed',
              status: WorkspaceStateBucket.attention,
            ),
          ]),
        }),
      );
      expect(identical(tracked.current, before), isTrue);

      tracked.publish(
        _snapshot({
          _serverId: _session([
            _createWorkspace(
              id: 'workspace-a',
              status: WorkspaceStateBucket.failed,
            ),
            workspaceB,
          ]),
        }),
      );
      expect(identical(tracked.current, before), isFalse);
      expect(tracked.current, [
        DesktopBadgeWorkspaceStatus.failed,
        DesktopBadgeWorkspaceStatus.attention,
      ]);
    });

    test('maps every wire status bucket onto a badge status', () {
      expect(
        WorkspaceStateBucket.values
            .map(desktopBadgeStatusFromWorkspaceState)
            .toSet(),
        DesktopBadgeWorkspaceStatus.values.toSet(),
      );
    });
  });

  group('selector plumbing', () {
    test('applyStoredOrdering leaves short or unordered inputs alone', () {
      final single = ['a'];
      expect(
        identical(
          applyStoredOrdering(
            items: single,
            storedOrder: const ['a'],
            getKey: (item) => item,
          ),
          single,
        ),
        isTrue,
      );

      final pair = ['a', 'b'];
      expect(
        identical(
          applyStoredOrdering(
            items: pair,
            storedOrder: const [],
            getKey: (item) => item,
          ),
          pair,
        ),
        isTrue,
      );
      // Every stored key is stale, so there is nothing to apply.
      expect(
        identical(
          applyStoredOrdering(
            items: pair,
            storedOrder: const ['gone'],
            getKey: (item) => item,
          ),
          pair,
        ),
        isTrue,
      );
    });

    test(
      'applyStoredOrdering prunes duplicates and keeps unlisted items put',
      () {
        expect(
          applyStoredOrdering(
            items: const ['a', 'b', 'c', 'd'],
            // `c` is listed twice and `zz` is unknown; `b` and `d` are not listed.
            storedOrder: const ['c', 'zz', 'c', 'a'],
            getKey: (item) => item,
          ),
          // The pruned order is `[c, a]`. Only the *slots* held by listed items
          // (`a` at 0 and `c` at 2) are rewritten, in pruned order; `b` and `d`
          // keep their positions untouched.
          ['c', 'b', 'a', 'd'],
        );
      },
    );

    test('selectProjectOrder hands back the shared empty list', () {
      expect(
        identical(
          selectProjectOrder(const SidebarOrderSnapshot()),
          selectWorkspaceKeys(const SessionsSnapshot(sessions: {}), null),
        ),
        isTrue,
      );
      expect(
        selectProjectOrder(const SidebarOrderSnapshot(projectOrder: ['a'])),
        ['a'],
      );
      expect(
        selectWorkspaceOrderByScope(
          const SidebarOrderSnapshot(
            workspaceOrderByProject: {
              'p': ['w'],
            },
          ),
        ),
        {
          'p': ['w'],
        },
      );
    });

    test(
      'jsObjectIs compares primitives by value and objects by reference',
      () {
        // Runtime-computed strings are `Object.is`-equal upstream but not
        // `identical` in Dart; the port compares them by value.
        expect(jsObjectIs('ab', 'a${'b'}'), isTrue);
        expect(jsObjectIs(true, true), isTrue);
        expect(jsObjectIs(1, 1), isTrue);
        expect(jsObjectIs(double.nan, double.nan), isTrue);
        expect(jsObjectIs(0.0, -0.0), isFalse);
        expect(jsObjectIs(null, null), isTrue);
        expect(jsObjectIs(null, 1), isFalse);
        expect(jsObjectIs(<int>[1], <int>[1]), isFalse);
      },
    );

    test('workspaceStructureDeepEquals walks lists, maps and structures', () {
      expect(workspaceStructureDeepEquals(const [1, 2], const [1, 2]), isTrue);
      expect(workspaceStructureDeepEquals(const [1, 2], const [2, 1]), isFalse);
      expect(workspaceStructureDeepEquals(const [1], const [1, 2]), isFalse);
      expect(
        workspaceStructureDeepEquals(const {'a': 1}, const {'a': 1}),
        isTrue,
      );
      expect(
        workspaceStructureDeepEquals(const {'a': 1}, const {'b': 1}),
        isFalse,
      );
      expect(
        workspaceStructureDeepEquals(const {'a': 1}, const {'a': 1, 'b': 2}),
        isFalse,
      );
      expect(workspaceStructureDeepEquals(null, const [1]), isFalse);
      expect(workspaceStructureDeepEquals(const [1], null), isFalse);

      // The explicit arm: `WorkspaceStructureProject` has no `==` of its own.
      final left = _structureProject(workspaceKeys: const ['a']);
      final right = _structureProject(workspaceKeys: const ['a']);
      expect(left == right, isFalse);
      expect(workspaceStructureDeepEquals(left, right), isTrue);
      expect(
        workspaceStructureDeepEquals(
          left,
          _structureProject(workspaceKeys: const ['b']),
        ),
        isFalse,
      );
      expect(
        WorkspaceStructure(projects: [left]) ==
            WorkspaceStructure(projects: [right]),
        isTrue,
      );
      expect(
        WorkspaceStructure(projects: [left]).hashCode,
        WorkspaceStructure(projects: [right]).hashCode,
      );
    });

    test('the numeric/base collation approximation and its ICU divergence', () {
      expect(compareWorkspaceStructureNamesNumericBase('a2', 'a10'), -1);
      expect(compareWorkspaceStructureNamesNumericBase('a10', 'a2'), 1);
      expect(compareWorkspaceStructureNamesNumericBase('a02', 'a2'), 0);
      expect(compareWorkspaceStructureNamesNumericBase('ABC', 'abc'), 0);
      expect(compareWorkspaceStructureNamesNumericBase('abc', 'abcd'), -1);
      expect(compareWorkspaceStructureNamesNumericBase('abcd', 'abc'), 1);
      expect(
        compareWorkspaceStructureNamesNumericBase('Project 1', 'Project A'),
        -1,
      );
      // Documented divergence: ICU sorts `é` next to `e`, code-unit order puts
      // it after every ASCII letter.
      expect(compareWorkspaceStructureNamesNumericBase('é', 'z'), 1);
    });
  });

  group('DictationStreamSender', () {
    test('enqueues segments and sends them after stream start', () async {
      final transport = _FakeDictationTransport();
      final ids = ['d1'];
      final sender = _sender(transport, () => _shift(ids));

      sender
        ..enqueueSegment('seg0')
        ..enqueueSegment('seg1');

      await _tick();

      expect(transport.starts, [('d1', _format)]);
      expect(transport.chunks, [
        ('d1', 0, 'seg0', _format),
        ('d1', 1, 'seg1', _format),
      ]);
    });

    test('restarts stream and resends from seq=0 on reconnect', () async {
      final transport = _FakeDictationTransport();
      final ids = ['d1', 'd2'];
      final sender = _sender(transport, () => _shift(ids));

      sender
        ..enqueueSegment('seg0')
        ..enqueueSegment('seg1');
      await _tick();

      await sender.restartStream('reconnect');

      expect(transport.starts.map((start) => start.$1).toList(), ['d1', 'd2']);
      expect(
        transport.chunks
            .where((chunk) => chunk.$1 == 'd2')
            .map((chunk) => (chunk.$2, chunk.$3))
            .toList(),
        [(0, 'seg0'), (1, 'seg1')],
      );
    });

    test(
      'finish flushes all queued segments and sends finish with finalSeq',
      () async {
        final transport = _FakeDictationTransport();
        final ids = ['d1'];
        final sender = _sender(transport, () => _shift(ids));

        sender
          ..enqueueSegment('seg0')
          ..enqueueSegment('seg1');

        final finalSeq = sender.getFinalSeq();
        final result = await sender.finish(finalSeq);

        expect(result.text, 'ok');
        expect(transport.chunks.map((chunk) => chunk.$2).toList(), [0, 1]);
        expect(transport.finishes, [('d1', 1)]);
      },
    );

    test('keeps segments while disconnected and sends them after restart when '
        'reconnected', () async {
      final transport = _FakeDictationTransport()..isConnected = false;
      final ids = ['d1'];
      final sender = _sender(transport, () => _shift(ids));

      sender
        ..enqueueSegment('seg0')
        ..enqueueSegment('seg1');

      expect(transport.starts, isEmpty);
      expect(transport.chunks, isEmpty);

      transport.isConnected = true;
      await sender.restartStream('reconnect');

      expect(transport.chunks.map((chunk) => chunk.$2).toList(), [0, 1]);
    });

    test(
      'does not replay long buffered native dictation in one synchronous burst',
      () async {
        final transport = _FakeDictationTransport()..isConnected = false;
        final scheduler = _ManualFlushScheduler();
        final sender = DictationStreamSender(
          initialTransport: transport,
          format: _format,
          createDictationId: () => 'd1',
          translate: _translate,
          scheduleFlushTurn: scheduler.schedule,
          // With the scheduler driven by hand there is no real turn to wait
          // for, so the drain yield is a no-op.
          awaitFlushTurn: () async {},
        );

        for (var seq = 0; seq < 480; seq += 1) {
          sender.enqueueSegment('native-frame-$seq');
        }

        transport.isConnected = true;
        final finish = sender.finish(sender.getFinalSeq());

        await _tick();

        // Upstream asserts `<= 128` after two V8 microtask turns. Dart's async
        // scheduling settles the start *and* `finish`'s own flush inside one
        // `Future.delayed(Duration.zero)`, which is two flush turns. The
        // invariant the case exists for — no unbounded synchronous replay —
        // holds either way, and is pinned here per turn rather than per tick.
        expect(transport.chunks, hasLength(2 * maxDictationChunksPerFlushTurn));
        expect(transport.chunks.length, lessThan(480));

        var previous = transport.chunks.length;
        while (scheduler.isNotEmpty) {
          await scheduler.runNext();
          expect(
            transport.chunks.length - previous,
            lessThanOrEqualTo(maxDictationChunksPerFlushTurn),
          );
          previous = transport.chunks.length;
        }

        expect(
          await finish,
          const DictationFinishResult(dictationId: 'd1', text: 'ok'),
        );
        expect(transport.finishes, [('d1', 479)]);
        expect(transport.chunks, hasLength(480));
      },
    );

    test('reports the sender buffer state', () {
      final transport = _FakeDictationTransport()..isConnected = false;
      final sender = _sender(transport, () => 'd1');

      expect(sender.hasSegments(), isFalse);
      expect(sender.getFinalSeq(), -1);
      expect(sender.getDictationId(), isNull);

      sender.enqueueSegment('seg0');

      expect(sender.hasSegments(), isTrue);
      expect(sender.getSegmentCount(), 1);
      expect(sender.getFinalSeq(), 0);
    });

    test(
      'clearAll drops the buffer while resetStreamForReplay keeps it',
      () async {
        final transport = _FakeDictationTransport();
        final ids = ['d1', 'd2'];
        final sender = _sender(transport, () => _shift(ids));

        sender.enqueueSegment('seg0');
        await _tick();
        expect(sender.getDictationId(), 'd1');

        sender.resetStreamForReplay();
        expect(sender.getDictationId(), isNull);
        expect(sender.getSegmentCount(), 1);

        await sender.restartStream('reconnect');
        expect(transport.chunks.map((chunk) => chunk.$1).toList(), [
          'd1',
          'd2',
        ]);

        sender.clearAll();
        expect(sender.getSegmentCount(), 0);
        expect(sender.getDictationId(), isNull);
      },
    );

    test(
      'cancel tells the daemon to discard the stream but keeps the audio',
      () async {
        final transport = _FakeDictationTransport();
        final sender = _sender(transport, () => 'd1');

        sender.enqueueSegment('seg0');
        await _tick();

        sender.cancel();

        expect(transport.cancels, ['d1']);
        expect(sender.getDictationId(), isNull);
        expect(sender.getSegmentCount(), 1);
      },
    );

    test('cancel while disconnected only resets local state', () {
      final transport = _FakeDictationTransport()..isConnected = false;
      final sender = _sender(transport, () => 'd1');

      sender
        ..enqueueSegment('seg0')
        ..cancel();

      expect(transport.cancels, isEmpty);
      expect(sender.getSegmentCount(), 1);
    });

    test(
      'finish reports an unavailable and a disconnected transport apart',
      () async {
        final unavailable = DictationStreamSender(
          initialTransport: null,
          format: _format,
          createDictationId: () => 'd1',
          translate: _translate,
        );
        await expectLater(
          unavailable.finish(0),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              't:common.errors.daemonClientUnavailable',
            ),
          ),
        );

        final transport = _FakeDictationTransport()..isConnected = false;
        final disconnected = _sender(transport, () => 'd1');
        await expectLater(
          disconnected.finish(0),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              't:common.errors.daemonClientDisconnected',
            ),
          ),
        );
      },
    );

    test('a failed start clears the stream and surfaces the error', () async {
      final transport = _FakeDictationTransport()
        ..nextStartError = StateError('daemon refused');
      final sender = _sender(transport, () => 'd1');

      await expectLater(
        sender.restartStream('finalize'),
        throwsA(isA<StateError>()),
      );
      expect(sender.getDictationId(), isNull);

      // The segments survive for a retry.
      sender.enqueueSegment('seg0');
      expect(sender.getSegmentCount(), 1);
    });

    test(
      'an enqueue-triggered start failure is reported, not swallowed',
      () async {
        final transport = _FakeDictationTransport()
          ..nextStartError = StateError('daemon refused');
        final errors = <Object>[];
        final sender = DictationStreamSender(
          initialTransport: transport,
          format: _format,
          createDictationId: () => 'd1',
          translate: _translate,
          onStartError: (error, _) => errors.add(error),
        );

        sender.enqueueSegment('seg0');
        await _tick();

        expect(errors, hasLength(1));
        expect(sender.getDictationId(), isNull);
      },
    );

    test('finish fails cleanly when the stream could not be started', () async {
      final transport = _FakeDictationTransport()
        ..nextStartError = StateError('daemon refused');
      final sender = _sender(transport, () => 'd1');

      await expectLater(sender.finish(0), throwsA(isA<StateError>()));
      expect(transport.finishes, isEmpty);
    });

    test('a superseded start never marks the newer stream ready', () async {
      final transport = _FakeDictationTransport()..holdNextStart = true;
      final ids = ['d1', 'd2'];
      final sender = _sender(transport, () => _shift(ids));

      sender.enqueueSegment('seg0');
      // `d1`'s start is parked; a reconnect supersedes it before it resolves.
      final superseded = sender.restartStream('reconnect');
      transport.releaseHeldStart();
      await superseded;

      expect(sender.getDictationId(), 'd2');
      expect(transport.chunks.map((chunk) => chunk.$1).toSet(), {'d2'});
    });

    test(
      'a drain interrupted by a disconnect fails instead of waiting',
      () async {
        final transport = _FakeDictationTransport();
        final scheduler = _ManualFlushScheduler();
        late final DictationStreamSender sender;
        var interrupted = false;
        sender = DictationStreamSender(
          initialTransport: transport,
          format: _format,
          createDictationId: () => 'd1',
          translate: _translate,
          scheduleFlushTurn: scheduler.schedule,
          // The turn yield is exactly where a reconnect can land in production:
          // the buffer just drained, then more audio arrives against a transport
          // that has since dropped.
          awaitFlushTurn: () async {
            if (interrupted) return;
            interrupted = true;
            transport.isConnected = false;
            sender.enqueueSegment('late-frame');
          },
        );

        for (var seq = 0; seq < 300; seq += 1) {
          sender.enqueueSegment('frame-$seq');
        }

        final finish = sender.finish(sender.getFinalSeq());
        final expectation = expectLater(
          finish,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Failed to flush dictation stream',
            ),
          ),
        );

        await _tick();
        // Drains the remainder, which resolves the waiter and hands control to
        // `awaitFlushTurn` above.
        await scheduler.runNext();

        await expectation;
        expect(transport.finishes, isEmpty);
      },
    );

    test('setTransport swaps the client used for the next start', () async {
      final first = _FakeDictationTransport()..isConnected = false;
      final second = _FakeDictationTransport();
      final sender = _sender(first, () => 'd1');

      sender
        ..enqueueSegment('seg0')
        ..setTransport(second);
      await sender.restartStream('reconnect');

      expect(first.chunks, isEmpty);
      expect(second.chunks.map((chunk) => chunk.$2).toList(), [0]);
    });

    test('flush is a no-op until the stream is ready', () {
      final transport = _FakeDictationTransport();
      final sender = _sender(transport, () => 'd1');

      sender.enqueueSegment('seg0');
      // The start has not resolved yet, so nothing may go out under an id the
      // daemon has not acknowledged.
      expect(sender.flush(), 0);
      expect(transport.chunks, isEmpty);
    });
  });
}

// ---------------------------------------------------------------------------
// shared fixtures
// ---------------------------------------------------------------------------

const String _serverId = 'test-server';
const String _format = 'audio/pcm;rate=16000;bits=16';

DateTime _timestamp(int seconds) => DateTime.parse(
  '2026-01-01T00:00:${seconds.toString().padLeft(2, '0')}.000Z',
);

/// Mirrors what `useStoreWithEqualityFn` does: hold onto the previous selection
/// and publish a new value only when the equality function rejects it. Lets the
/// ported cases assert reference stability without React or a store.
final class _TrackedSelector<S, T> {
  _TrackedSelector({
    required T Function(S state) select,
    required this.equals,
    required S initial,
  }) : _select = select,
       _current = select(initial);

  final T Function(S state) _select;
  final bool Function(Object? a, Object? b) equals;
  T _current;

  /// How many times a candidate was actually accepted — a re-render count.
  int publishedCount = 0;

  T get current => _current;

  void publish(S state) {
    final candidate = _select(state);
    if (!equals(candidate, _current)) {
      _current = candidate;
      publishedCount += 1;
    }
  }
}

SessionsSnapshot _snapshot(Map<String, SessionWorkspacesSnapshot> sessions) =>
    SessionsSnapshot(sessions: sessions);

SessionWorkspacesSnapshot _session(
  List<WorkspaceDescriptor> workspaces, {
  bool? hasHydratedWorkspaces,
  Map<String, WorkspaceProjectDescriptor>? emptyProjects,
}) => SessionWorkspacesSnapshot(
  hasHydratedWorkspaces: hasHydratedWorkspaces,
  workspaces: {for (final workspace in workspaces) workspace.id: workspace},
  emptyProjects: emptyProjects,
);

WorkspaceDescriptor _createWorkspace({
  required String id,
  String projectId = 'project-1',
  String projectDisplayName = 'Project 1',
  String? projectCustomName,
  String projectRootPath = '/repo',
  String workspaceDirectory = '/repo',
  WorkspaceProjectKind projectKind = WorkspaceProjectKind.git,
  WorkspaceKind workspaceKind = WorkspaceKind.localCheckout,
  String name = 'main',
  WorkspaceStateBucket status = WorkspaceStateBucket.done,
  Map<String, Object?>? project,
}) => WorkspaceDescriptor(
  id: id,
  projectId: projectId,
  projectDisplayName: projectDisplayName,
  projectCustomName: projectCustomName,
  projectRootPath: projectRootPath,
  workspaceDirectory: workspaceDirectory,
  projectKind: projectKind,
  workspaceKind: workspaceKind,
  name: name,
  status: status,
  activityAt: null,
  project: project,
);

WorkspaceStructureProject _structureProject({
  required List<String> workspaceKeys,
}) => WorkspaceStructureProject(
  projectKey: 'p',
  projectName: 'P',
  projectKind: WorkspaceProjectKind.git,
  iconWorkingDir: '/repo',
  hosts: const [
    WorkspaceStructureHostPlacement(
      serverId: _serverId,
      iconWorkingDir: '/repo',
      canCreateWorktree: true,
    ),
  ],
  workspaceKeys: workspaceKeys,
);

// ---------------------------------------------------------------------------
// daemon probe fake
// ---------------------------------------------------------------------------

final class _FakeDaemonClient implements DaemonProbeClient {
  _FakeDaemonClient(this._probe, this.config)
    : lastError = _probe.nextLastError;

  final _FakeDaemonProbe _probe;
  final DaemonProbeClientConfig config;

  @override
  final String? lastError;

  @override
  Future<void> connect() async {
    if (_probe.hangNextConnection) {
      // Never completes: the injected timeout scheduler is what ends the probe.
      return Completer<void>().future;
    }
    final error = _probe.nextConnectError;
    if (error != null) {
      throw error;
    }
  }

  @override
  DaemonProbeServerInfo? getLastServerInfoMessage() => _probe.nextServerInfo;

  @override
  Future<void> close() async {
    _probe.closedClients.add(this);
  }
}

final class _FakeDaemonProbe {
  final List<_FakeDaemonClient> createdClients = [];
  final List<_FakeDaemonClient> closedClients = [];
  int clientIdsRequested = 0;
  Object? nextConnectError;
  String? nextLastError;
  bool hangNextConnection = false;
  String? appVersion;
  Object? localTransportFactory;
  DaemonProbeServerInfo? nextServerInfo = const DaemonProbeServerInfo(
    serverId: 'srv_probe_test',
    hostname: 'probe-host',
  );

  late final DaemonConnectionDependencies<_FakeDaemonClient> deps =
      DaemonConnectionDependencies<_FakeDaemonClient>(
        getClientId: () async {
          clientIdsRequested += 1;
          return 'cid_shared_probe_test';
        },
        resolveAppVersion: () => appVersion,
        createLocalTransportFactory: () => localTransportFactory,
        buildLocalTransportUrl: (target) =>
            'paseo+local://${target.transportType.wireName}'
            '?path=${Uri.encodeQueryComponent(target.transportPath)}',
        createClient: (config) {
          final client = _FakeDaemonClient(this, config);
          createdClients.add(client);
          return client;
        },
      );

  void failNextConnection(Object error, String? lastError) {
    nextConnectError = error;
    nextLastError = lastError;
  }

  List<DaemonProbeClientConfig> createdConfigs() =>
      createdClients.map((client) => client.config).toList();
}

// ---------------------------------------------------------------------------
// dictation fakes
// ---------------------------------------------------------------------------

String _translate(String key) => 't:$key';

String _shift(List<String> ids) => ids.isEmpty ? 'dX' : ids.removeAt(0);

DictationStreamSender _sender(
  DictationStreamTransport transport,
  String Function() createDictationId,
) => DictationStreamSender(
  initialTransport: transport,
  format: _format,
  createDictationId: createDictationId,
  translate: _translate,
);

/// One event-loop turn, which drains the microtask queue and any zero-duration
/// timer the default flush scheduler posted.
Future<void> _tick() => Future<void>.delayed(Duration.zero);

final class _FakeDictationTransport implements DictationStreamTransport {
  @override
  bool isConnected = true;

  final List<(String, String)> starts = [];
  final List<(String, int, String, String)> chunks = [];
  final List<(String, int)> finishes = [];
  final List<String> cancels = [];

  Object? nextStartError;
  bool holdNextStart = false;
  Completer<void>? _heldStart;

  void releaseHeldStart() {
    _heldStart?.complete();
    _heldStart = null;
  }

  @override
  Future<void> startDictationStream(String dictationId, String format) async {
    starts.add((dictationId, format));
    if (holdNextStart) {
      holdNextStart = false;
      final held = Completer<void>();
      _heldStart = held;
      await held.future;
      return;
    }
    final error = nextStartError;
    if (error != null) {
      nextStartError = null;
      throw error;
    }
  }

  @override
  void sendDictationStreamChunk(
    String dictationId,
    int seq,
    String audio,
    String format,
  ) {
    chunks.add((dictationId, seq, audio, format));
  }

  @override
  Future<DictationFinishResult> finishDictationStream(
    String dictationId,
    int finalSeq,
  ) async {
    finishes.add((dictationId, finalSeq));
    return DictationFinishResult(dictationId: dictationId, text: 'ok');
  }

  @override
  void cancelDictationStream(String dictationId) {
    cancels.add(dictationId);
  }
}

/// A flush scheduler the test steps by hand, so the per-turn chunk cap is
/// observable instead of racing a real timer.
final class _ManualFlushScheduler {
  final List<void Function()> _pending = [];

  bool get isNotEmpty => _pending.isNotEmpty;

  DictationFlushHandle schedule(void Function() callback) {
    _pending.add(callback);
    return () => _pending.remove(callback);
  }

  Future<void> runNext() async {
    if (_pending.isEmpty) return;
    _pending.removeAt(0)();
    await _tick();
  }
}
