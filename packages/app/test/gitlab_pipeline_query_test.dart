import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/gitlab_pipeline_query.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('timeline keys include nullable PR identity', () {
    const pending = PrPaneTimelineQueryKey(
      serverId: 'host-a',
      cwd: '/repo',
      prNumber: null,
    );
    const ready = PrPaneTimelineQueryKey(
      serverId: 'host-a',
      cwd: '/repo',
      prNumber: 42,
    );

    expect(
      pending,
      const PrPaneTimelineQueryKey(
        serverId: 'host-a',
        cwd: '/repo',
        prNumber: null,
      ),
    );
    expect(pending, isNot(ready));
  });

  group('GitlabPipelineQueryKey', () {
    test('uses server, cwd, pipeline, and change request identity', () {
      const key = GitlabPipelineQueryKey(
        serverId: 'host-a',
        cwd: '/repo',
        pipelineId: 306,
        changeRequestNumber: 42,
      );

      expect(
        key,
        const GitlabPipelineQueryKey(
          serverId: 'host-a',
          cwd: '/repo',
          pipelineId: 306,
          changeRequestNumber: 42,
        ),
      );
      expect({
        key,
        const GitlabPipelineQueryKey(
          serverId: 'host-b',
          cwd: '/repo',
          pipelineId: 306,
          changeRequestNumber: 42,
        ),
        const GitlabPipelineQueryKey(
          serverId: 'host-a',
          cwd: '/other',
          pipelineId: 306,
          changeRequestNumber: 42,
        ),
        const GitlabPipelineQueryKey(
          serverId: 'host-a',
          cwd: '/repo',
          pipelineId: 307,
          changeRequestNumber: 42,
        ),
        const GitlabPipelineQueryKey(
          serverId: 'host-a',
          cwd: '/repo',
          pipelineId: 306,
          changeRequestNumber: 43,
        ),
      }, hasLength(5));
    });
  });

  group('GitlabPipelineQueryCache', () {
    late DateTime now;
    late GitlabPipelineQueryCache cache;
    const key = GitlabPipelineQueryKey(
      serverId: 'host-a',
      cwd: '/repo',
      pipelineId: 306,
      changeRequestNumber: 42,
    );

    setUp(() {
      now = DateTime.utc(2026, 7, 29, 12);
      cache = GitlabPipelineQueryCache(now: () => now);
    });

    test('keeps a finished result fresh for exactly 24 hours', () {
      expect(cache.shouldFetch(key, live: false), isTrue);
      cache.record(key, _pipeline(306));
      expect(cache.shouldFetch(key, live: false), isFalse);

      now = now.add(
        gitlabFinishedPipelineStaleTime - const Duration(microseconds: 1),
      );
      expect(cache.shouldFetch(key, live: false), isFalse);

      now = now.add(const Duration(microseconds: 1));
      expect(cache.shouldFetch(key, live: false), isTrue);
    });

    test('retains successful null data and always refreshes live data', () {
      cache.record(key, null);
      final snapshot = cache.snapshot(key);

      expect(snapshot, isNotNull);
      expect(snapshot!.pipeline, isNull);
      expect(cache.shouldFetch(key, live: false), isFalse);
      expect(cache.shouldFetch(key, live: true), isTrue);
    });

    test('invalidates only the matching host and cwd', () {
      const otherHost = GitlabPipelineQueryKey(
        serverId: 'host-b',
        cwd: '/repo',
        pipelineId: 306,
        changeRequestNumber: 42,
      );
      const otherCwd = GitlabPipelineQueryKey(
        serverId: 'host-a',
        cwd: '/other',
        pipelineId: 306,
        changeRequestNumber: 42,
      );
      cache
        ..record(key, _pipeline(306))
        ..record(otherHost, _pipeline(306))
        ..record(otherCwd, _pipeline(306))
        ..invalidate(serverId: 'host-a', cwd: '/repo');

      expect(cache.snapshot(key), isNull);
      expect(cache.snapshot(otherHost), isNotNull);
      expect(cache.snapshot(otherCwd), isNotNull);
    });

    test('deduplicates concurrent requests and records their result', () async {
      final gate = Completer<CheckoutPipeline?>();
      var calls = 0;
      Future<CheckoutPipeline?> load() {
        calls += 1;
        return gate.future;
      }

      final first = cache.fetch(key, load);
      final second = cache.fetch(key, load);
      expect(calls, 1);

      gate.complete(_pipeline(306));
      expect((await first)?.id, 306);
      expect((await second)?.id, 306);
      expect(cache.snapshot(key)?.pipeline?.id, 306);
    });

    test('invalidation supersedes an in-flight result', () async {
      final oldGate = Completer<CheckoutPipeline?>();
      final newGate = Completer<CheckoutPipeline?>();

      final oldRequest = cache.fetch(key, () => oldGate.future);
      cache.invalidate(serverId: 'host-a', cwd: '/repo');
      final newRequest = cache.fetch(key, () => newGate.future);

      newGate.complete(_pipeline(307));
      expect((await newRequest)?.id, 307);
      oldGate.complete(_pipeline(306));
      expect((await oldRequest)?.id, 306);
      expect(cache.snapshot(key)?.pipeline?.id, 307);
    });
  });
}

CheckoutPipeline _pipeline(int id) => CheckoutPipeline(
  id: id,
  status: 'success',
  rawStatus: 'success',
  url: null,
  ref: null,
  sha: null,
  stages: const [],
);
