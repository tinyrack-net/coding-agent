import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/hub_cloud_device_authorization.dart';
import 'package:agent_daemon/src/cli/hub_device_authorization.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  group('Cloud device authorization', () {
    test(
      'starts through the exact endpoint and accepts loopback URLs',
      () async {
        Map<String, Object?>? requestBody;
        late final String origin;
        final server = await _startServer((request) async {
          requestBody =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, Object?>;
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(_authorizationJson(origin: origin)));
          await request.response.close();
        });
        addTearDown(() => server.close(force: true));
        origin = 'http://127.0.0.1:${server.port}';
        final client = HubCloudDeviceAuthorizationClient();
        addTearDown(client.close);

        final result = await client.start(origin, 'Studio Windows');

        expect(requestBody, {'displayName': 'Studio Windows'});
        expect(result.verificationUri.toString(), '$origin/activate');
        expect(
          result.verificationUriComplete.toString(),
          '$origin/activate?code=ABCD-EFGH-JKLMN',
        );
        expect(result.interval, 5);
      },
    );

    test('validates Hub origins and Cloud response boundaries', () async {
      for (final url in const [
        'ftp://hub.example.test',
        'https://user@hub.example.test',
        'https://hub.example.test?query=1',
        'https://hub.example.test#fragment',
      ]) {
        expect(
          () => hubDeviceAuthorizationEndpoint(url, '/api/test'),
          throwsA(
            isA<HubDeviceAuthorizationException>().having(
              (error) => error.message,
              'message',
              'Hub URL must be an HTTP or HTTPS origin without credentials '
                  'or a query',
            ),
          ),
        );
      }
      expect(
        hubDeviceAuthorizationEndpoint(
          'https://hub.example.test/base/',
          '/api/device-authorizations/',
        ).toString(),
        'https://hub.example.test/base/api/device-authorizations/',
      );
      expect(
        () => HubDeviceAuthorization.fromJson({
          ..._authorizationJson(origin: 'https://hub.example.test'),
          'verificationUriComplete': 'file:///tmp/activate',
        }),
        throwsFormatException,
      );
      expect(
        () => HubDeviceAuthorization.fromJson({
          ..._authorizationJson(origin: 'https://hub.example.test'),
          'interval': 4,
        }),
        throwsFormatException,
      );
    });

    test('start timeout covers a response body that never completes', () async {
      final stalled = Completer<void>();
      final server = await _startServer((request) async {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..bufferOutput = false
          ..write('{"deviceCode":"device-code-with-more-than-thirty-two');
        await request.response.flush();
        await stalled.future;
      });
      addTearDown(() {
        stalled.complete();
        return server.close(force: true);
      });
      final client = HubCloudDeviceAuthorizationClient(
        startTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(client.close);

      await expectLater(
        client.start('http://127.0.0.1:${server.port}', 'Studio Windows'),
        throwsA(
          isA<HubDeviceAuthorizationException>().having(
            (error) => error.message,
            'message',
            'Cloud registration start timed out',
          ),
        ),
      );
    });

    test('poll retries transient HTTP and transport failures', () async {
      for (final status in [408, 425, 429, 500, 503]) {
        final client = HubCloudDeviceAuthorizationClient(
          client: _RequestClient((_) async => http.Response('', status)),
        );
        expect(
          await client.poll(
            'https://hub.example.test',
            'device-code-with-more-than-thirty-two-characters',
            const Duration(seconds: 1),
          ),
          isA<HubDeviceAuthorizationRetryLater>(),
        );
      }
      final transportFailure = HubCloudDeviceAuthorizationClient(
        client: _RequestClient((_) async => throw const SocketException('no')),
      );
      expect(
        await transportFailure.poll(
          'https://hub.example.test',
          'device-code-with-more-than-thirty-two-characters',
          const Duration(seconds: 1),
        ),
        isA<HubDeviceAuthorizationRetryLater>(),
      );
    });

    test('poll validates completed response status and schema', () async {
      final malformed = HubCloudDeviceAuthorizationClient(
        client: _RequestClient((_) async => http.Response('not-json', 200)),
      );
      await expectLater(
        malformed.poll(
          'https://hub.example.test',
          'device-code-with-more-than-thirty-two-characters',
          const Duration(seconds: 1),
        ),
        throwsFormatException,
      );

      final invalid = HubCloudDeviceAuthorizationClient(
        client: _RequestClient(
          (_) async => http.Response('{"status":"pending"}', 200),
        ),
      );
      await expectLater(
        invalid.poll(
          'https://hub.example.test',
          'device-code-with-more-than-thirty-two-characters',
          const Duration(seconds: 1),
        ),
        throwsFormatException,
      );

      final rejected = HubCloudDeviceAuthorizationClient(
        client: _RequestClient((_) async => http.Response('', 401)),
      );
      await expectLater(
        rejected.poll(
          'https://hub.example.test',
          'device-code-with-more-than-thirty-two-characters',
          const Duration(seconds: 1),
        ),
        throwsA(
          isA<HubDeviceAuthorizationException>().having(
            (error) => error.message,
            'message',
            'Cloud registration poll failed (401)',
          ),
        ),
      );
    });

    test('parses every frozen poll outcome', () {
      expect(
        HubDeviceAuthorizationPoll.fromJson({
          'status': 'pending',
          'interval': 5,
        }),
        isA<HubDeviceAuthorizationPending>(),
      );
      expect(
        HubDeviceAuthorizationPoll.fromJson({
          'status': 'slow_down',
          'interval': 10,
        }),
        isA<HubDeviceAuthorizationSlowDown>(),
      );
      expect(
        HubDeviceAuthorizationPoll.fromJson({
          'status': 'approved',
          'interval': 5,
          'enrollmentToken':
              'approved-enrollment-token-with-thirty-two-characters',
        }),
        isA<HubDeviceAuthorizationApproved>(),
      );
      expect(
        HubDeviceAuthorizationPoll.fromJson({
          'status': 'denied',
          'interval': 5,
        }),
        isA<HubDeviceAuthorizationDenied>(),
      );
      expect(
        HubDeviceAuthorizationPoll.fromJson({
          'status': 'expired',
          'interval': 5,
        }),
        isA<HubDeviceAuthorizationExpired>(),
      );
      expect(
        HubDeviceAuthorizationPoll.fromJson({
          'status': 'enrolled',
          'interval': 5,
        }),
        isA<HubDeviceAuthorizationEnrolled>(),
      );
      expect(
        HubDeviceAuthorizationPoll.fromJson({'status': 'retry_later'}),
        isA<HubDeviceAuthorizationRetryLater>(),
      );
    });
  });

  group('device authorization workflow', () {
    test('uses platform-native browser launch commands', () async {
      final launches = <(String, List<String>)>[];
      Future<void> launch(String command, List<String> arguments) async {
        launches.add((command, arguments));
      }

      await HubSystemBrowser(
        operatingSystem: 'windows',
        launch: launch,
      ).open('https://hub.example.test/activate?code=ABC');
      await HubSystemBrowser(
        operatingSystem: 'macos',
        launch: launch,
      ).open('https://hub.example.test/activate');
      await HubSystemBrowser(
        operatingSystem: 'linux',
        launch: launch,
      ).open('https://hub.example.test/activate');

      expect(launches.map((launch) => launch.$1), [
        'rundll32.exe',
        'open',
        'xdg-open',
      ]);
      expect(launches.map((launch) => launch.$2), [
        [
          'url.dll,FileProtocolHandler',
          'https://hub.example.test/activate?code=ABC',
        ],
        ['https://hub.example.test/activate'],
        ['https://hub.example.test/activate'],
      ]);
    });

    test('opens, follows Cloud cadence, and returns approval', () async {
      final cloud = _FakeCloud([
        const HubDeviceAuthorizationPending(interval: 5),
        const HubDeviceAuthorizationSlowDown(interval: 10),
        const HubDeviceAuthorizationApproved(
          interval: 10,
          enrollmentToken:
              'approved-enrollment-token-with-thirty-two-characters',
        ),
      ]);
      final journey = _AuthorizationJourney(cloud);

      expect(
        await journey.workflow.authorize(
          'https://hub.example.test',
          'Studio Windows',
        ),
        'approved-enrollment-token-with-thirty-two-characters',
      );
      expect(journey.waiter.waited, [5000, 5000, 10000]);
      expect(cloud.polls.map((poll) => poll.timeout.inMilliseconds), [
        595000,
        590000,
        580000,
      ]);
      expect(journey.browser.opened, [
        'https://hub.example.test/activate?code=ABCD-EFGH-JKLMN',
      ]);
      expect(journey.reporter.reported, [
        'https://hub.example.test/activate ABCD-EFGH-JKLMN',
      ]);
    });

    test('retries only within the fixed authorization expiry', () async {
      final cloud = _FakeCloud(const [
        HubDeviceAuthorizationRetryLater(),
        HubDeviceAuthorizationRetryLater(),
      ], expiresAt: DateTime.parse('2026-07-18T12:00:11.000Z'));
      final journey = _AuthorizationJourney(cloud);

      await expectLater(
        journey.workflow.authorize(
          'https://hub.example.test',
          'Studio Windows',
        ),
        throwsA(
          isA<HubDeviceAuthorizationException>().having(
            (error) => error.message,
            'message',
            'Daemon registration expired',
          ),
        ),
      );
      expect(journey.waiter.waited, [5000, 5000, 1000]);
      expect(cloud.polls.map((poll) => poll.timeout.inMilliseconds), [
        6000,
        1000,
      ]);
    });

    test('maps denied, expired, and enrolled terminal outcomes', () async {
      for (final entry in <(HubDeviceAuthorizationPoll, String)>[
        (
          const HubDeviceAuthorizationDenied(interval: 5),
          'Daemon registration was denied',
        ),
        (
          const HubDeviceAuthorizationExpired(interval: 5),
          'Daemon registration expired',
        ),
        (
          const HubDeviceAuthorizationEnrolled(interval: 5),
          'Daemon registration was already used',
        ),
      ]) {
        final journey = _AuthorizationJourney(_FakeCloud([entry.$1]));
        await expectLater(
          journey.workflow.authorize(
            'https://hub.example.test',
            'Studio Windows',
          ),
          throwsA(
            isA<HubDeviceAuthorizationException>().having(
              (error) => error.message,
              'message',
              entry.$2,
            ),
          ),
        );
      }
    });

    test('browser launch failure does not cancel authorization', () async {
      final cloud = _FakeCloud([
        const HubDeviceAuthorizationApproved(
          interval: 5,
          enrollmentToken:
              'approved-enrollment-token-with-thirty-two-characters',
        ),
      ]);
      final waiter = _FakeWaiter();
      final workflow = HubDeviceAuthorizationWorkflow(
        cloud: cloud,
        waiter: waiter,
        browser: _ThrowingBrowser(),
        reporter: _FakeReporter(),
      );

      expect(
        await workflow.authorize('https://hub.example.test', 'Studio Windows'),
        contains('approved-enrollment-token'),
      );
    });
  });
}

Future<HttpServer> _startServer(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return server;
}

Map<String, Object?> _authorizationJson({required String origin}) => {
  'deviceCode': 'device-code-with-more-than-thirty-two-characters',
  'userCode': 'ABCD-EFGH-JKLMN',
  'verificationUri': '$origin/activate',
  'verificationUriComplete': '$origin/activate?code=ABCD-EFGH-JKLMN',
  'expiresAt': '2026-07-18T12:10:00.000Z',
  'interval': 5,
};

final class _RequestClient extends http.BaseClient {
  _RequestClient(this.sendRequest);

  final Future<http.Response> Function(http.BaseRequest request) sendRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await sendRequest(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

final class _PollCall {
  const _PollCall(this.timeout);
  final Duration timeout;
}

final class _FakeCloud implements HubCloudDeviceAuthorization {
  _FakeCloud(this.outcomes, {DateTime? expiresAt})
    : expiresAt = expiresAt ?? DateTime.parse('2026-07-18T12:10:00.000Z');

  final List<HubDeviceAuthorizationPoll> outcomes;
  final DateTime expiresAt;
  final polls = <_PollCall>[];

  @override
  Future<HubDeviceAuthorizationPoll> poll(
    String hubUrl,
    String deviceCode,
    Duration timeout,
  ) async {
    polls.add(_PollCall(timeout));
    return outcomes[polls.length - 1];
  }

  @override
  Future<HubDeviceAuthorization> start(
    String hubUrl,
    String displayName,
  ) async => HubDeviceAuthorization(
    deviceCode: 'device-code-with-more-than-thirty-two-characters',
    userCode: 'ABCD-EFGH-JKLMN',
    verificationUri: Uri.parse('https://hub.example.test/activate'),
    verificationUriComplete: Uri.parse(
      'https://hub.example.test/activate?code=ABCD-EFGH-JKLMN',
    ),
    expiresAt: expiresAt,
    interval: 5,
  );
}

final class _FakeWaiter implements HubAuthorizationWaiter {
  var now = DateTime.parse('2026-07-18T12:00:00.000Z').millisecondsSinceEpoch;
  final waited = <int>[];

  @override
  int nowMilliseconds() => now;

  @override
  Future<void> wait(Duration duration) async {
    waited.add(duration.inMilliseconds);
    now += duration.inMilliseconds;
  }
}

final class _FakeBrowser implements HubBrowserOpener {
  final opened = <String>[];

  @override
  Future<void> open(String url) async {
    opened.add(url);
  }
}

final class _ThrowingBrowser implements HubBrowserOpener {
  @override
  Future<void> open(String url) async => throw StateError('no browser');
}

final class _FakeReporter implements HubAuthorizationReporter {
  final reported = <String>[];

  @override
  void instructions(String verificationUri, String userCode) {
    reported.add('$verificationUri $userCode');
  }
}

final class _AuthorizationJourney {
  _AuthorizationJourney(this.cloud)
    : waiter = _FakeWaiter(),
      browser = _FakeBrowser(),
      reporter = _FakeReporter() {
    workflow = HubDeviceAuthorizationWorkflow(
      cloud: cloud,
      waiter: waiter,
      browser: browser,
      reporter: reporter,
    );
  }

  final _FakeCloud cloud;
  final _FakeWaiter waiter;
  final _FakeBrowser browser;
  final _FakeReporter reporter;
  late final HubDeviceAuthorizationWorkflow workflow;
}
