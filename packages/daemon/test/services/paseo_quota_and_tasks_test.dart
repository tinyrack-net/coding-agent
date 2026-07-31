import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/services/paseo_quota_and_tasks.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ProviderUsageService (quota-fetcher/service.ts)', () {
    test(
      'returns registered providers and windows as normalized usage',
      () async {
        final service = ProviderUsageService(
          now: () => DateTime.utc(2026, 6, 19),
          fetchers: [
            _StaticFetcher(
              const ProviderUsage(
                providerId: 'glm',
                displayName: 'GLM coding plan',
                status: ProviderUsageStatus.available,
                planLabel: 'GLM coding plan',
                windows: [
                  ProviderUsageWindow(
                    id: 'biweekly',
                    label: 'Biweekly',
                    usedPct: 23,
                    remainingPct: 77,
                    resetsAt: '2026-07-03T00:00:00.000Z',
                  ),
                ],
              ),
            ),
          ],
        );

        final result = await service.listUsage();

        expect(result.fetchedAt, '2026-06-19T00:00:00.000Z');
        expect(result.providers.map((provider) => provider.toJson()), [
          {
            'providerId': 'glm',
            'displayName': 'GLM coding plan',
            'status': 'available',
            'planLabel': 'GLM coding plan',
            'windows': [
              {
                'id': 'biweekly',
                'label': 'Biweekly',
                'usedPct': 23,
                'remainingPct': 77,
                'resetsAt': '2026-07-03T00:00:00.000Z',
              },
            ],
          },
        ]);
      },
    );

    test('caches usage until forced to refresh', () async {
      var now = DateTime.utc(2026, 6, 19);
      var calls = 0;
      final service = ProviderUsageService(
        now: () => now,
        cacheTtl: const Duration(seconds: 60),
        fetchers: [
          _CountingFetcher(() {
            calls += 1;
            return ProviderUsage(
              providerId: 'claude',
              displayName: 'Claude',
              status: ProviderUsageStatus.available,
              planLabel: 'Max 20x',
              windows: [
                ProviderUsageWindow(
                  id: 'session',
                  label: 'Session',
                  usedPct: calls.toDouble(),
                ),
              ],
            );
          }),
        ],
      );

      final first = await service.listUsage();
      now = now.add(const Duration(seconds: 30));
      final cached = await service.listUsage();
      final refreshed = await service.listUsage(forceRefresh: true);

      expect(calls, 2);
      expect(identical(cached, first), isTrue);
      expect(refreshed.providers.first.windows.first.usedPct, 2);
    });

    test('refetches once the cache ttl has elapsed', () async {
      var now = DateTime.utc(2026, 6, 19);
      var calls = 0;
      final service = ProviderUsageService(
        now: () => now,
        cacheTtl: const Duration(seconds: 60),
        fetchers: [
          _CountingFetcher(() {
            calls += 1;
            return _usage('claude');
          }),
        ],
      );

      await service.listUsage();
      now = now.add(const Duration(seconds: 59, milliseconds: 999));
      await service.listUsage();
      expect(calls, 1, reason: 'still inside the ttl window');

      // The upstream comparison is strictly `<`, so exactly-ttl is a miss.
      now = now.add(const Duration(milliseconds: 1));
      await service.listUsage();
      expect(calls, 2);
    });

    test('deduplicates concurrent cache misses', () async {
      final gate = Completer<ProviderUsage>();
      var calls = 0;
      final service = ProviderUsageService(
        now: () => DateTime.utc(2026, 6, 19),
        fetchers: [
          _CountingFetcher(() {
            calls += 1;
            return gate.future;
          }),
        ],
      );

      final first = service.listUsage();
      final second = service.listUsage();
      expect(calls, 1);

      gate.complete(
        const ProviderUsage(
          providerId: 'claude',
          displayName: 'Claude',
          status: ProviderUsageStatus.available,
          planLabel: 'Max 20x',
          windows: [
            ProviderUsageWindow(id: 'session', label: 'Session', usedPct: 12),
          ],
        ),
      );

      expect(identical(await first, await second), isTrue);
      expect(calls, 1);
    });

    test('forceRefresh still joins an already in-flight fetch', () async {
      final gate = Completer<ProviderUsage>();
      var calls = 0;
      final service = ProviderUsageService(
        now: () => DateTime.utc(2026, 6, 19),
        fetchers: [
          _CountingFetcher(() {
            calls += 1;
            return gate.future;
          }),
        ],
      );

      final first = service.listUsage();
      final forced = service.listUsage(forceRefresh: true);
      gate.complete(_usage('claude'));

      expect(identical(await first, await forced), isTrue);
      expect(calls, 1);
    });

    test(
      'isolates one provider error without dropping other providers',
      () async {
        final service = ProviderUsageService(
          now: () => DateTime.utc(2026, 6, 19),
          fetchers: [
            _CountingFetcher(
              () => Future<ProviderUsage>.error(
                _MessageError('Claude auth expired'),
              ),
            ),
            _StaticFetcher(
              const ProviderUsage(
                providerId: 'codex',
                displayName: 'Codex',
                status: ProviderUsageStatus.available,
                planLabel: 'Pro 20x',
                windows: [
                  ProviderUsageWindow(
                    id: 'weekly',
                    label: 'Weekly',
                    usedPct: 29,
                  ),
                ],
              ),
            ),
          ],
        );

        final result = await service.listUsage();

        expect(result.fetchedAt, '2026-06-19T00:00:00.000Z');
        expect(result.providers.map((provider) => provider.providerId), [
          'claude',
          'codex',
        ]);

        final failed = result.providers.first;
        expect(failed.status, ProviderUsageStatus.error);
        expect(failed.planLabel, isNull);
        expect(failed.windows, isEmpty);
        expect(failed.balances, isEmpty);
        expect(failed.details, isEmpty);
        expect(failed.error, 'Claude auth expired');

        expect(result.providers.last.windows.single.usedPct, 29);
      },
    );

    test(
      'shipped service stringifies Dart errors instead of taking .message',
      () async {
        // Documented deviation: upstream uses `reason.message` for Error values,
        // while the already-ported service interpolates the whole object. The
        // upstream rule lives in providerFetchErrorMessage; wiring it into the
        // shipped service would mean editing a file outside this cluster.
        final service = ProviderUsageService(
          now: () => DateTime.utc(2026, 6, 19),
          fetchers: [
            _CountingFetcher(
              () => Future<ProviderUsage>.error(
                StateError('credentials missing'),
              ),
            ),
          ],
        );

        final result = await service.listUsage();
        expect(result.providers.single.error, 'Bad state: credentials missing');
        expect(
          providerFetchErrorMessage(StateError('credentials missing')),
          'Bad state: credentials missing',
        );
        expect(providerFetchErrorMessage(Exception('boom')), 'boom');
        expect(providerFetchErrorMessage('plain string'), 'plain string');
      },
    );

    test('an empty fetcher list still reports a fetch timestamp', () async {
      final service = ProviderUsageService(
        now: () => DateTime.utc(2026, 6, 19),
      );
      final result = await service.listUsage();
      expect(result.providers, isEmpty);
      expect(result.fetchedAt, '2026-06-19T00:00:00.000Z');
    });
  });

  group('unavailableProviderUsage (quota-fetcher/usage.ts)', () {
    test('is unavailable with no error and error when one is present', () {
      final unavailable = unavailableProviderUsage(
        providerId: 'kimi',
        displayName: 'Kimi',
      );
      expect(unavailable.status, ProviderUsageStatus.unavailable);
      expect(unavailable.error, isNull);
      expect(unavailable.planLabel, isNull);
      expect(unavailable.windows, isEmpty);
      expect(unavailable.balances, isEmpty);
      expect(unavailable.details, isEmpty);

      final failed = unavailableProviderUsage(
        providerId: 'kimi',
        displayName: 'Kimi',
        error: 'no credentials',
      );
      expect(failed.status, ProviderUsageStatus.error);
      expect(failed.error, 'no credentials');
    });

    test(
      'an empty error string is falsy upstream, so status stays unavailable',
      () {
        final usage = unavailableProviderUsage(
          providerId: 'zai',
          displayName: 'Z.ai',
          error: '',
        );
        expect(usage.status, ProviderUsageStatus.unavailable);
        expect(usage.error, '');
      },
    );
  });

  group('windowFromUsedPct (quota-fetcher/usage.ts)', () {
    test('derives the remaining percentage', () {
      final window = windowFromUsedPct(
        id: 'weekly',
        label: 'Weekly',
        utilizationPct: 23,
        resetsAt: '2026-07-03T00:00:00.000Z',
      );
      expect(window.id, 'weekly');
      expect(window.label, 'Weekly');
      expect(window.usedPct, 23);
      expect(window.remainingPct, 77);
      expect(window.resetsAt, '2026-07-03T00:00:00.000Z');
      expect(window.tone, isNull);
    });

    test('clamps the remainder at zero when over quota', () {
      expect(
        windowFromUsedPct(
          id: 'weekly',
          label: 'Weekly',
          utilizationPct: 150,
        ).remainingPct,
        0,
      );
    });

    test('leaves both percentages unknown when utilization is unknown', () {
      final window = windowFromUsedPct(
        id: 'weekly',
        label: 'Weekly',
        utilizationPct: null,
      );
      expect(window.usedPct, isNull);
      expect(window.remainingPct, isNull);
      expect(window.resetsAt, isNull);
    });

    test('attaches a tone only when one is supplied', () {
      expect(
        windowFromUsedPct(
          id: 'w',
          label: 'W',
          utilizationPct: 95,
          tone: providerUsageToneFromUsedPct(95),
        ).tone,
        ProviderUsageTone.danger,
      );
      // "default" is truthy in JS, so it is still attached.
      expect(
        windowFromUsedPct(
          id: 'w',
          label: 'W',
          utilizationPct: null,
          tone: ProviderUsageTone.defaultTone,
        ).tone,
        ProviderUsageTone.defaultTone,
      );
    });

    test('a NaN utilization propagates rather than being nulled', () {
      final window = windowFromUsedPct(
        id: 'w',
        label: 'W',
        utilizationPct: double.nan,
      );
      expect(window.usedPct?.isNaN, isTrue);
      expect(window.remainingPct?.isNaN, isTrue);
    });
  });

  group('toIsoStringOrNull (quota-fetcher/usage.ts)', () {
    test('renders a valid epoch as an ISO instant', () {
      expect(toIsoStringOrNull(1780272000000), '2026-06-01T00:00:00.000Z');
      expect(toIsoStringOrNull(0), '1970-01-01T00:00:00.000Z');
      expect(toIsoStringOrNull(-1000), '1969-12-31T23:59:59.000Z');
    });

    test('is null for values that would make an Invalid Date', () {
      expect(toIsoStringOrNull(double.nan), isNull);
      expect(toIsoStringOrNull(double.infinity), isNull);
      expect(toIsoStringOrNull(double.negativeInfinity), isNull);
      expect(toIsoStringOrNull(8640000000000001), isNull);
      expect(toIsoStringOrNull(-8640000000000001), isNull);
    });

    test('accepts the exact ECMAScript time-value boundary', () {
      expect(toIsoStringOrNull(8640000000000000), isNotNull);
    });
  });

  group('API value coercion (quota-fetcher/usage.ts zod schemas)', () {
    test('coerceApiNumber accepts the shapes provider APIs actually send', () {
      expect(coerceApiNumber(42), 42);
      expect(coerceApiNumber(42.5), 42.5);
      expect(coerceApiNumber('42'), 42);
      expect(coerceApiNumber('  7.5  '), 7.5);
      expect(coerceApiNumber('1e3'), 1000);
      expect(coerceApiNumber('0x1f'), 31);
      expect(coerceApiNumber('0b101'), 5);
      expect(coerceApiNumber('0o17'), 15);
      expect(coerceApiNumber('.5'), 0.5);
    });

    test('coerceApiNumber reproduces JavaScript ToNumber for non-numbers', () {
      expect(coerceApiNumber(null), 0);
      expect(coerceApiNumber(''), 0);
      expect(coerceApiNumber('   '), 0);
      expect(coerceApiNumber(true), 1);
      expect(coerceApiNumber(false), 0);
      expect(coerceApiNumber(<Object?>[]), 0);
      expect(coerceApiNumber(<Object?>['5']), 5);
    });

    test('coerceApiNumber rejects anything not finite', () {
      expect(() => coerceApiNumber('abc'), throwsFormatException);
      expect(() => coerceApiNumber('12px'), throwsFormatException);
      expect(() => coerceApiNumber('Infinity'), throwsFormatException);
      expect(() => coerceApiNumber(double.infinity), throwsFormatException);
      expect(() => coerceApiNumber(double.nan), throwsFormatException);
      expect(() => coerceApiNumber(<Object?>[1, 2]), throwsFormatException);
      expect(() => coerceApiNumber(<String, Object?>{}), throwsFormatException);
    });

    test('coerceApiNullableNumber keeps null and coerces everything else', () {
      expect(coerceApiNullableNumber(null), isNull);
      expect(coerceApiNullableNumber('3'), 3);
      expect(coerceApiNullableNumber(''), 0);
      expect(() => coerceApiNullableNumber('nope'), throwsFormatException);
    });

    test('coerceApiOptionalString stringifies the JavaScript way', () {
      expect(coerceApiOptionalString(null), isNull);
      expect(coerceApiOptionalString('already'), 'already');
      expect(coerceApiOptionalString(42), '42');
      expect(coerceApiOptionalString(42.0), '42');
      expect(coerceApiOptionalString(42.5), '42.5');
      expect(coerceApiOptionalString(-0.0), '0');
      expect(coerceApiOptionalString(true), 'true');
      expect(coerceApiOptionalString(false), 'false');
      expect(coerceApiOptionalString(double.nan), 'NaN');
      expect(coerceApiOptionalString(double.infinity), 'Infinity');
      expect(coerceApiOptionalString(1e20), '100000000000000000000');
    });
  });

  group('fetchProviderApi (quota-fetcher/usage.ts)', () {
    test('forwards the request verbatim and returns the response', () async {
      String? seenMethod;
      Uri? seenUri;
      Map<String, String>? seenHeaders;
      Object? seenBody;

      final response = await fetchProviderApi(
        (method, uri, {headers, body}) async {
          seenMethod = method;
          seenUri = uri;
          seenHeaders = headers;
          seenBody = body;
          return http.Response('{"ok":true}', 200);
        },
        Uri.parse('https://api.example.com/usage'),
        method: 'POST',
        headers: const {'authorization': 'Bearer t'},
        body: '{"q":1}',
      );

      expect(seenMethod, 'POST');
      expect(seenUri.toString(), 'https://api.example.com/usage');
      expect(seenHeaders, {'authorization': 'Bearer t'});
      expect(seenBody, '{"q":1}');
      expect(response.statusCode, 200);
      expect(response.body, '{"ok":true}');
    });

    test('defaults to a 15 second deadline', () {
      expect(providerApiTimeout, const Duration(seconds: 15));

      fakeAsync((async) {
        Object? failure;
        unawaited(
          fetchProviderApi(
            (method, uri, {headers, body}) => Completer<http.Response>().future,
            Uri.parse('https://api.example.com/usage'),
          ).then<void>((_) {}, onError: (Object error) => failure = error),
        );

        async.elapse(const Duration(seconds: 14, milliseconds: 999));
        expect(failure, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(failure, isA<TimeoutException>());
      });
    });

    test('honours a caller-supplied deadline', () async {
      await expectLater(
        fetchProviderApi(
          (method, uri, {headers, body}) => Completer<http.Response>().future,
          Uri.parse('https://api.example.com/usage'),
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('PushTokenStore (server/push/token-store.ts)', () {
    test('adds, trims, deduplicates, and ignores blank tokens', () {
      final storage = _MemoryTokenStorage();
      final store = PushTokenStore(storage);

      store.addToken('  ExponentPushToken[a]  ');
      store.addToken('ExponentPushToken[a]');
      store.addToken('   ');
      store.addToken('');
      store.addToken('ExponentPushToken[b]');

      expect(store.getAllTokens(), [
        'ExponentPushToken[a]',
        'ExponentPushToken[b]',
      ]);
      expect(
        storage.writes.length,
        2,
        reason: 'duplicates and blanks must not rewrite the file',
      );
    });

    test('persists a two-space indented document with a trailing newline', () {
      final storage = _MemoryTokenStorage();
      PushTokenStore(storage).addToken('ExponentPushToken[a]');

      expect(
        storage.writes.single,
        '{\n  "tokens": [\n    "ExponentPushToken[a]"\n  ]\n}\n',
      );
    });

    test('removes tokens, ignoring blanks and unknown values', () {
      final storage = _MemoryTokenStorage(
        contents: jsonEncode({
          'tokens': ['a', 'b'],
        }),
      );
      final store = PushTokenStore(storage);

      store.removeToken('  ');
      store.removeToken('missing');
      expect(storage.writes, isEmpty);

      store.removeToken('  a  ');
      expect(store.getAllTokens(), ['b']);
      expect(storage.writes.length, 1);
    });

    test('loads persisted tokens, tightening permissions before reading', () {
      final storage = _MemoryTokenStorage(
        contents: jsonEncode({
          'tokens': ['  a  ', 'b', '   ', '', 7, null, true],
        }),
      );
      final store = PushTokenStore(storage);

      expect(store.getAllTokens(), ['a', 'b']);
      expect(storage.calls, ['exists', 'ensurePrivate', 'read']);
    });

    test('an absent file loads as empty without reading', () {
      final storage = _MemoryTokenStorage();
      final store = PushTokenStore(storage);

      expect(store.getAllTokens(), isEmpty);
      expect(storage.calls, ['exists']);
    });

    test('a document without a tokens array degrades to empty', () {
      for (final document in <String>[
        '{}',
        '{"tokens":"nope"}',
        '[1,2]',
        '5',
      ]) {
        final logs = <String>[];
        final store = PushTokenStore(
          _MemoryTokenStorage(contents: document),
          logger: (level, message, {error}) => logs.add('$level:$message'),
        );
        expect(store.getAllTokens(), isEmpty, reason: document);
        expect(logs, [
          'PushTokenLogLevel.info:Loaded push tokens',
        ], reason: '$document is a successful parse, not a failure');
      }
    });

    test('a corrupt or null document warns and leaves the store empty', () {
      for (final document in <String>['not json', 'null']) {
        final logs = <String>[];
        final store = PushTokenStore(
          _MemoryTokenStorage(contents: document),
          logger: (level, message, {error}) => logs.add('$level:$message'),
        );
        expect(store.getAllTokens(), isEmpty, reason: document);
        expect(logs, [
          'PushTokenLogLevel.warn:Failed to load push tokens',
        ], reason: document);
      }
    });

    test('a read failure warns instead of taking the daemon down', () {
      final logs = <String>[];
      final store = PushTokenStore(
        _MemoryTokenStorage(
          contents: '{}',
          readError: const FileSystemException('denied'),
        ),
        logger: (level, message, {error}) => logs.add('$level:$message'),
      );

      expect(store.getAllTokens(), isEmpty);
      expect(logs, ['PushTokenLogLevel.warn:Failed to load push tokens']);
    });

    test('a persist failure warns but keeps the token in memory', () {
      final logs = <String>[];
      final store = PushTokenStore(
        _MemoryTokenStorage(writeError: const FileSystemException('read-only')),
        logger: (level, message, {error}) => logs.add('$level:$message'),
      );

      store.addToken('ExponentPushToken[a]');

      expect(store.getAllTokens(), ['ExponentPushToken[a]']);
      expect(logs, [
        'PushTokenLogLevel.warn:Failed to persist push tokens',
        'PushTokenLogLevel.debug:Added token',
      ]);
    });

    test('FilePushTokenStorage round-trips through a real file', () async {
      final dir = await Directory.systemTemp.createTemp('paseo-push-tokens-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'push-tokens.json'));

      PushTokenStore(
        FilePushTokenStorage(file),
      ).addToken('ExponentPushToken[test]');

      expect(file.existsSync(), isTrue);
      expect(jsonDecode(file.readAsStringSync()), {
        'tokens': ['ExponentPushToken[test]'],
      });

      final reloaded = PushTokenStore(FilePushTokenStorage(file));
      expect(reloaded.getAllTokens(), ['ExponentPushToken[test]']);
    });
  });

  group('computeExecutionOrder (tasks/execution-order.ts)', () {
    late _MemoryTaskStore store;

    setUp(() => store = _MemoryTaskStore());

    test('returns an empty timeline for an empty store', () async {
      final result = await computeExecutionOrder(store);
      expect(result.timeline, isEmpty);
      expect(result.orderMap, isEmpty);
      expect(result.blocked, isEmpty);
    });

    test('orders by priority, lower number first', () async {
      store
        ..add(_task('a', priority: 2, created: '2024-01-01'))
        ..add(_task('b', priority: 0, created: '2024-01-02'))
        ..add(_task('c', priority: 1, created: '2024-01-03'));

      final result = await computeExecutionOrder(store);
      expect(_ids(result), ['b', 'c', 'a']);
      expect(result.orderMap, {'b': 0, 'c': 1, 'a': 2});
    });

    test('orders unprioritized tasks after prioritized ones', () async {
      store
        ..add(_task('a', created: '2024-01-01'))
        ..add(_task('b', priority: 1, created: '2024-01-02'))
        ..add(_task('c', created: '2024-01-03'));

      expect(_ids(await computeExecutionOrder(store)), ['b', 'a', 'c']);
    });

    test('respects dependencies', () async {
      store
        ..add(_task('a', created: '2024-01-01'))
        ..add(_task('b', created: '2024-01-02'))
        ..add(_task('c', deps: ['b'], created: '2024-01-03'));

      expect(_ids(await computeExecutionOrder(store)), ['a', 'b', 'c']);
    });

    test('executes children before their parent', () async {
      store
        ..add(_task('b', created: '2024-01-01'))
        ..add(_task('b1', parentId: 'b', created: '2024-01-02'))
        ..add(_task('b2', parentId: 'b', created: '2024-01-03'));

      expect(_ids(await computeExecutionOrder(store, 'b')), ['b1', 'b2', 'b']);
    });

    test('handles a complex epic with phases and dependencies', () async {
      store
        ..add(_task('epic', created: '2024-01-01'))
        ..add(
          _task('phase1', parentId: 'epic', priority: 0, created: '2024-01-02'),
        )
        ..add(_task('p1-task1', parentId: 'phase1', created: '2024-01-03'))
        ..add(
          _task(
            'p1-task2',
            parentId: 'phase1',
            deps: ['p1-task1'],
            created: '2024-01-04',
          ),
        )
        ..add(
          _task(
            'phase2',
            parentId: 'epic',
            deps: ['phase1'],
            created: '2024-01-05',
          ),
        )
        ..add(_task('p2-task1', parentId: 'phase2', created: '2024-01-06'))
        ..add(_task('p2-task2', parentId: 'phase2', created: '2024-01-07'))
        ..add(
          _task(
            'cleanup',
            parentId: 'epic',
            deps: ['phase2'],
            created: '2024-01-08',
          ),
        );

      expect(_ids(await computeExecutionOrder(store, 'epic')), [
        'p1-task1',
        'p1-task2',
        'phase1',
        'p2-task1',
        'p2-task2',
        'phase2',
        'cleanup',
        'epic',
      ]);
    });

    test('lets priority override creation order within a parent', () async {
      store
        ..add(_task('parent', created: '2024-01-01'))
        ..add(_task('child-a', parentId: 'parent', created: '2024-01-02'))
        ..add(
          _task(
            'child-b',
            parentId: 'parent',
            priority: 0,
            created: '2024-01-03',
          ),
        )
        ..add(
          _task(
            'child-c',
            parentId: 'parent',
            priority: 1,
            created: '2024-01-04',
          ),
        );

      expect(_ids(await computeExecutionOrder(store, 'parent')), [
        'child-b',
        'child-c',
        'child-a',
        'parent',
      ]);
    });

    test('places done tasks first in historical order', () async {
      store
        ..add(
          _task('done-later', status: TaskStatus.done, created: '2024-01-03'),
        )
        ..add(
          _task('done-first', status: TaskStatus.done, created: '2024-01-01'),
        )
        ..add(_task('pending', created: '2024-01-02'));

      expect(_ids(await computeExecutionOrder(store)), [
        'done-first',
        'done-later',
        'pending',
      ]);
    });

    test('marks tasks with unresolvable deps as blocked', () async {
      store
        ..add(_task('a', created: '2024-01-01'))
        ..add(_task('b', deps: ['external-dep'], created: '2024-01-02'));

      final result = await computeExecutionOrder(store);
      expect(_ids(result), ['a']);
      expect(result.blocked, {'b'});
    });

    test('detects circular dependencies as blocked', () async {
      store
        ..add(_task('a', deps: ['b'], created: '2024-01-01'))
        ..add(_task('b', deps: ['a'], created: '2024-01-02'));

      final result = await computeExecutionOrder(store);
      expect(result.timeline, isEmpty);
      expect(result.blocked, {'a', 'b'});
    });

    test('treats in_progress tasks the same as open', () async {
      store
        ..add(_task('a', status: TaskStatus.inProgress, created: '2024-01-01'))
        ..add(_task('b', status: TaskStatus.open, created: '2024-01-02'));

      expect(_ids(await computeExecutionOrder(store)), ['a', 'b']);
    });

    test('draft and failed tasks are neither scheduled nor blocked', () async {
      store
        ..add(_task('d', status: TaskStatus.draft, created: '2024-01-01'))
        ..add(_task('f', status: TaskStatus.failed, created: '2024-01-02'))
        ..add(_task('o', created: '2024-01-03'));

      final result = await computeExecutionOrder(store);
      expect(_ids(result), ['o']);
      expect(result.blocked, isEmpty);
    });

    test('a dependency on a failed task blocks forever', () async {
      store
        ..add(_task('f', status: TaskStatus.failed, created: '2024-01-01'))
        ..add(_task('b', deps: ['f'], created: '2024-01-02'));

      final result = await computeExecutionOrder(store);
      expect(result.timeline, isEmpty);
      expect(result.blocked, {'b'});
    });

    test('a parent whose child is already done can run immediately', () async {
      store
        ..add(_task('parent', created: '2024-01-01'))
        ..add(
          _task(
            'child',
            parentId: 'parent',
            status: TaskStatus.done,
            created: '2024-01-02',
          ),
        );

      expect(_ids(await computeExecutionOrder(store, 'parent')), [
        'child',
        'parent',
      ]);
    });

    test('children outside the scope do not hold their parent back', () async {
      // The store only reports direct children, so the grandchild is a child of
      // an in-scope task while never becoming a candidate itself.
      final shallow = _MemoryTaskStore(directChildrenOnly: true)
        ..add(_task('root', created: '2024-01-01'))
        ..add(_task('child', parentId: 'root', created: '2024-01-02'))
        ..add(_task('grandchild', parentId: 'child', created: '2024-01-03'));

      final result = await computeExecutionOrder(shallow, 'root');
      expect(_ids(result), ['child', 'root']);
      expect(result.blocked, isEmpty);
    });

    test('an empty scope id behaves like no scope at all', () async {
      store
        ..add(_task('a', created: '2024-01-01'))
        ..add(_task('b', parentId: 'a', created: '2024-01-02'));

      expect(_ids(await computeExecutionOrder(store, '')), ['b', 'a']);
    });

    test('an unknown scope id yields only descendants', () async {
      store.add(_task('a', created: '2024-01-01'));

      final result = await computeExecutionOrder(store, 'ghost');
      expect(result.timeline, isEmpty);
      expect(result.blocked, isEmpty);
    });

    test(
      'ties keep insertion order beyond Dart\'s stable-sort threshold',
      () async {
        // Dart's List.sort is only stable for short lists; upstream relies on the
        // ES2019 stability guarantee, so equal keys must preserve input order.
        final ids = [
          for (var i = 0; i < 40; i++) 'task-${i.toString().padLeft(2, '0')}',
        ];
        for (final id in ids) {
          store.add(_task(id, priority: 1, created: '2024-01-01'));
        }

        expect(_ids(await computeExecutionOrder(store)), ids);
      },
    );
  });

  group('buildSortedChildrenMap (tasks/execution-order.ts)', () {
    test('sorts children by execution order', () {
      final tasks = [
        _task('parent'),
        _task('child-a', parentId: 'parent'),
        _task('child-b', parentId: 'parent'),
        _task('child-c', parentId: 'parent'),
      ];
      final orderMap = {'child-c': 0, 'child-a': 1, 'child-b': 2, 'parent': 3};

      final children = buildSortedChildrenMap(tasks, orderMap)['parent']!;
      expect(children.map((task) => task.id), [
        'child-c',
        'child-a',
        'child-b',
      ]);
    });

    test('puts tasks missing from the order map at the end', () {
      final tasks = [
        _task('parent'),
        _task('child-a', parentId: 'parent'),
        _task('child-b', parentId: 'parent'),
      ];

      final children = buildSortedChildrenMap(tasks, {'child-b': 0})['parent']!;
      expect(children.map((task) => task.id), ['child-b', 'child-a']);
    });

    test('keeps the relative order of two unordered children', () {
      final tasks = [
        _task('parent'),
        _task('child-a', parentId: 'parent'),
        _task('child-b', parentId: 'parent'),
        _task('child-c', parentId: 'parent'),
      ];

      final children = buildSortedChildrenMap(tasks, {'child-c': 0})['parent']!;
      expect(children.map((task) => task.id), [
        'child-c',
        'child-a',
        'child-b',
      ]);
    });

    test('roots and empty-string parents are not children of anything', () {
      final tasks = [_task('root'), _task('orphan', parentId: '')];
      expect(buildSortedChildrenMap(tasks, const {}), isEmpty);
    });
  });

  group('task graph helpers (tasks/task-graph.ts)', () {
    test('sortByPriorityThenCreated ranks priority above creation time', () {
      final prioritized = _task('a', priority: 5, created: '2024-02-01');
      final unprioritized = _task('b', created: '2024-01-01');
      expect(sortByPriorityThenCreated(prioritized, unprioritized), -1);
      expect(sortByPriorityThenCreated(unprioritized, prioritized), 1);

      expect(
        sortByPriorityThenCreated(
          _task('a', priority: 1),
          _task('b', priority: 3),
        ),
        lessThan(0),
      );
      expect(
        sortByPriorityThenCreated(
          _task('a', priority: 1, created: '2024-02-01'),
          _task('b', priority: 1, created: '2024-01-01'),
        ),
        greaterThan(0),
      );
      expect(
        sortByPriorityThenCreated(
          _task('a', created: '2024-01-01'),
          _task('b', created: '2024-01-01'),
        ),
        0,
      );
    });

    test('buildTaskMap indexes by id with later duplicates winning', () {
      final map = buildTaskMap([
        _task('a', title: 'first'),
        _task('a', title: 'second'),
      ]);
      expect(map.keys, ['a']);
      expect(map['a']!.title, 'second');
    });

    test(
      'loadScopedTaskGraph collects candidates, children, and done ids',
      () async {
        final store = _MemoryTaskStore()
          ..add(_task('root', created: '2024-01-01'))
          ..add(
            _task(
              'child',
              parentId: 'root',
              status: TaskStatus.done,
              created: '2024-01-02',
            ),
          )
          ..add(_task('outside', created: '2024-01-03'));

        final scoped = await loadScopedTaskGraph(store, 'root');
        expect(scoped.allTasks.length, 3);
        expect(scoped.candidateIds, {'root', 'child'});
        expect(scoped.doneTaskIds, {'child'});
        expect(scoped.childrenMap['root']!.map((task) => task.id), ['child']);

        final unscoped = await loadScopedTaskGraph(store);
        expect(unscoped.candidateIds, {'root', 'child', 'outside'});
      },
    );

    test('getTasksById drops ids the graph does not know', () async {
      final store = _MemoryTaskStore()..add(_task('a'));
      final graph = await loadScopedTaskGraph(store);
      expect(getTasksById(graph, ['a', 'ghost']).map((task) => task.id), ['a']);
    });

    test(
      'isTaskExecutableInOrder needs deps and in-scope children complete',
      () async {
        final store = _MemoryTaskStore()
          ..add(_task('dep', created: '2024-01-01'))
          ..add(_task('parent', deps: ['dep'], created: '2024-01-02'))
          ..add(_task('child', parentId: 'parent', created: '2024-01-03'));
        final graph = await loadScopedTaskGraph(store);

        expect(isTaskExecutableInOrder(graph, 'parent', <String>{}), isFalse);
        expect(isTaskExecutableInOrder(graph, 'parent', {'dep'}), isFalse);
        expect(
          isTaskExecutableInOrder(graph, 'parent', {'dep', 'child'}),
          isTrue,
        );
        expect(isTaskExecutableInOrder(graph, 'ghost', <String>{}), isFalse);
      },
    );
  });

  group('TaskStatus', () {
    test('round-trips its wire values', () {
      expect(TaskStatus.inProgress.wireValue, 'in_progress');
      expect(TaskStatus.fromWire('in_progress'), TaskStatus.inProgress);
      expect(TaskStatus.fromWire('draft'), TaskStatus.draft);
      expect(() => TaskStatus.fromWire('nope'), throwsFormatException);
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

ProviderUsage _usage(String id) => ProviderUsage(
  providerId: id,
  displayName: id,
  status: ProviderUsageStatus.available,
  planLabel: null,
  windows: const [],
);

final class _StaticFetcher implements ProviderUsageFetcher {
  _StaticFetcher(this.usage);

  final ProviderUsage usage;

  @override
  String get providerId => usage.providerId;

  @override
  String get displayName => usage.displayName;

  @override
  Future<ProviderUsage> fetchUsage() async => usage;
}

final class _CountingFetcher implements ProviderUsageFetcher {
  _CountingFetcher(this.body);

  final FutureOr<ProviderUsage> Function() body;

  @override
  String get providerId => 'claude';

  @override
  String get displayName => 'Claude';

  @override
  Future<ProviderUsage> fetchUsage() async => body();
}

/// Stands in for a JavaScript `Error`, whose `.message` is what upstream reads.
final class _MessageError implements Exception {
  const _MessageError(this.message);

  final String message;

  @override
  String toString() => message;
}

final class _MemoryTokenStorage implements PushTokenStorage {
  _MemoryTokenStorage({this.contents, this.readError, this.writeError});

  String? contents;
  final Object? readError;
  final Object? writeError;
  final List<String> calls = [];
  final List<String> writes = [];

  @override
  bool exists() {
    calls.add('exists');
    return contents != null;
  }

  @override
  void ensurePrivate() => calls.add('ensurePrivate');

  @override
  String read() {
    calls.add('read');
    if (readError != null) throw readError!;
    return contents!;
  }

  @override
  void write(String value) {
    calls.add('write');
    if (writeError != null) throw writeError!;
    writes.add(value);
    contents = value;
  }
}

final class _MemoryTaskStore implements TaskGraphStore {
  _MemoryTaskStore({this.directChildrenOnly = false});

  /// When set, [getDescendants] reports only direct children, which exercises
  /// the out-of-scope child branch of `isTaskExecutableInOrder`.
  final bool directChildrenOnly;
  final Map<String, Task> _tasks = {};

  void add(Task task) => _tasks[task.id] = task;

  @override
  Future<List<Task>> list() async => _tasks.values.toList(growable: false);

  @override
  Future<Task?> get(String id) async => _tasks[id];

  @override
  Future<List<Task>> getDescendants(String id) async {
    final result = <Task>[];
    void traverse(String parentId) {
      for (final task in _tasks.values) {
        if (task.parentId == parentId) {
          result.add(task);
          if (!directChildrenOnly) traverse(task.id);
        }
      }
    }

    traverse(id);
    return result;
  }
}

Task _task(
  String id, {
  String? title,
  TaskStatus status = TaskStatus.open,
  String? parentId,
  List<String> deps = const [],
  int? priority,
  String created = '2024-01-01',
}) => Task(
  id: id,
  title: title ?? id,
  status: status,
  parentId: parentId,
  deps: deps,
  priority: priority,
  created: created,
);

List<String> _ids(ExecutionOrderResult result) =>
    result.timeline.map((task) => task.id).toList(growable: false);
