// Ports of the upstream test suites for Paseo's session-facing decision rules:
// sidebar-workspace-title, synced-loader-state, daemon-reconnect, and
// session-resume-revalidation.
import 'package:coding_agent_app/core/paseo_session_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveSidebarWorkspacePrimaryLabel', () {
    test('uses the workspace name in title mode', () {
      expect(
        resolveSidebarWorkspacePrimaryLabel(
          workspaceName: 'Investigate search',
          workspaceCurrentBranch: 'fix/search',
          workspaceTitleSource: WorkspaceTitleSource.title,
        ),
        'Investigate search',
      );
    });

    test('uses the branch name in branch mode', () {
      expect(
        resolveSidebarWorkspacePrimaryLabel(
          workspaceName: 'Investigate search',
          workspaceCurrentBranch: 'fix/search',
          workspaceTitleSource: WorkspaceTitleSource.branch,
        ),
        'fix/search',
      );
    });

    test(
      'falls back to the workspace name in branch mode without a branch',
      () {
        expect(
          resolveSidebarWorkspacePrimaryLabel(
            workspaceName: 'Local folder',
            workspaceCurrentBranch: null,
            workspaceTitleSource: WorkspaceTitleSource.branch,
          ),
          'Local folder',
        );
      },
    );

    test('ignores a missing branch entirely in title mode', () {
      expect(
        resolveSidebarWorkspacePrimaryLabel(
          workspaceName: 'Local folder',
          workspaceCurrentBranch: null,
          workspaceTitleSource: WorkspaceTitleSource.title,
        ),
        'Local folder',
      );
    });

    test('keeps an empty branch rather than falling back', () {
      // Upstream coalesces on nullish only, so "" is a present branch.
      expect(
        resolveSidebarWorkspacePrimaryLabel(
          workspaceName: 'Local folder',
          workspaceCurrentBranch: '',
          workspaceTitleSource: WorkspaceTitleSource.branch,
        ),
        '',
      );
    });
  });

  group('synced loader state', () {
    test('advances through six wall-clock-aligned steps every 950 '
        'milliseconds', () {
      const sampleTimes = [
        0,
        158,
        159,
        316,
        317,
        474,
        475,
        633,
        634,
        791,
        792,
        949,
        950,
      ];

      final steps = sampleTimes.map(getSyncedLoaderStep).toList();

      expect(steps, [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 0]);
    });

    test('preserves the six visible snake states', () {
      final states = [
        for (var step = 0; step < 6; step += 1)
          [
            for (var dot = 0; dot < 6; dot += 1)
              getSyncedLoaderDotOpacity(step, dot),
          ],
      ];

      expect(states, [
        [1, 0, 0.78, 0, 0.56, 0.34],
        [0.78, 1, 0.56, 0, 0.34, 0],
        [0.56, 0.78, 0.34, 1, 0, 0],
        [0.34, 0.56, 0, 0.78, 0, 1],
        [0, 0.34, 0, 0.56, 1, 0.78],
        [0, 0, 1, 0.34, 0.78, 0.56],
      ]);
    });

    test('repeats the same step on every later cycle', () {
      expect(getSyncedLoaderStep(950 * 4 + 317), getSyncedLoaderStep(317));
      // A real epoch-millis reading is 217ms into its cycle, hence step 1.
      expect(getSyncedLoaderStep(1772000000317), getSyncedLoaderStep(217));
      expect(getSyncedLoaderStep(1772000000317), 1);
    });

    test('mirrors JavaScript remainder semantics before the epoch', () {
      // Dart's `%` would wrap to a positive step here; upstream's `%` does not,
      // and the resulting out-of-range step reads as transparent.
      expect(getSyncedLoaderStep(-1), -1);
      expect(getSyncedLoaderDotOpacity(getSyncedLoaderStep(-1), 0), 0);
    });

    test('exposes six dots', () {
      expect(syncedLoaderDotCount, 6);
    });

    test('treats out-of-range steps and dots as fully transparent', () {
      expect(getSyncedLoaderDotOpacity(6, 0), 0);
      expect(getSyncedLoaderDotOpacity(-1, 0), 0);
      expect(getSyncedLoaderDotOpacity(0, 6), 0);
      expect(getSyncedLoaderDotOpacity(0, -1), 0);
    });
  });

  group('daemon update reconnect detection', () {
    const start = DaemonConnectionMarker(
      clientGeneration: 4,
      lastOnlineAt: '2026-07-16T10:00:00.000Z',
    );

    test('accepts a reconnect performed by the existing daemon client', () {
      expect(
        hasDaemonReconnectedAfter(
          snapshot: const DaemonConnectionSnapshot(
            connectionStatus: DaemonConnectionStatus.online,
            clientGeneration: 4,
            lastOnlineAt: '2026-07-16T10:00:05.000Z',
          ),
          start: start,
        ),
        isTrue,
      );
    });

    test('does not accept the original connection before the daemon '
        'restarts', () {
      expect(
        hasDaemonReconnectedAfter(
          snapshot: const DaemonConnectionSnapshot(
            connectionStatus: DaemonConnectionStatus.online,
            clientGeneration: 4,
            lastOnlineAt: '2026-07-16T10:00:00.000Z',
          ),
          start: start,
        ),
        isFalse,
      );
    });

    test('accepts a bumped client generation at the same timestamp', () {
      expect(
        hasDaemonReconnectedAfter(
          snapshot: const DaemonConnectionSnapshot(
            connectionStatus: DaemonConnectionStatus.online,
            clientGeneration: 5,
            lastOnlineAt: '2026-07-16T10:00:00.000Z',
          ),
          start: start,
        ),
        isTrue,
      );
    });

    test('accepts any online connection when there is no start marker', () {
      expect(
        hasDaemonReconnectedAfter(
          snapshot: const DaemonConnectionSnapshot(
            connectionStatus: DaemonConnectionStatus.online,
            clientGeneration: 4,
            lastOnlineAt: '2026-07-16T10:00:00.000Z',
          ),
          start: null,
        ),
        isTrue,
      );
    });

    test('rejects every status short of online', () {
      for (final status in DaemonConnectionStatus.values) {
        if (status == DaemonConnectionStatus.online) continue;
        expect(
          hasDaemonReconnectedAfter(
            snapshot: DaemonConnectionSnapshot(
              connectionStatus: status,
              clientGeneration: 9,
              lastOnlineAt: '2026-07-16T11:00:00.000Z',
            ),
            start: start,
          ),
          isFalse,
          reason: '$status must not read as a reconnect',
        );
      }
    });

    test('rejects a missing snapshot', () {
      expect(hasDaemonReconnectedAfter(snapshot: null, start: start), isFalse);
      expect(hasDaemonReconnectedAfter(snapshot: null, start: null), isFalse);
    });

    test('treats a first-ever online timestamp as a reconnect', () {
      expect(
        hasDaemonReconnectedAfter(
          snapshot: const DaemonConnectionSnapshot(
            connectionStatus: DaemonConnectionStatus.online,
            clientGeneration: 4,
            lastOnlineAt: '2026-07-16T10:00:00.000Z',
          ),
          start: const DaemonConnectionMarker(
            clientGeneration: 4,
            lastOnlineAt: null,
          ),
        ),
        isTrue,
      );
    });
  });

  group('session resume revalidation', () {
    test('refreshes both directories and timeline history after a stale '
        'resume', () async {
      final calls = <String>[];

      final revalidated = await revalidateSessionAfterResume(
        awayMs: sessionStaleAfterMs,
        serverId: 'server',
        bumpHistorySyncGeneration: (serverId) => calls.add('history:$serverId'),
        refreshDirectories: () async => calls.add('directories'),
      );

      expect(revalidated, isTrue);
      expect(calls, ['history:server', 'directories']);
    });

    test('does nothing after a brief background interval', () async {
      final calls = <String>[];

      final revalidated = await revalidateSessionAfterResume(
        awayMs: sessionStaleAfterMs - 1,
        serverId: 'server',
        bumpHistorySyncGeneration: (_) => calls.add('history'),
        refreshDirectories: () async => calls.add('directories'),
      );

      expect(revalidated, isFalse);
      expect(calls, isEmpty);
    });

    test('defers stale resume revalidation while the host is '
        'disconnected', () async {
      final calls = <String>[];

      final revalidated = await revalidateSessionAfterResume(
        awayMs: sessionStaleAfterMs,
        serverId: 'server',
        bumpHistorySyncGeneration: (serverId) => calls.add('history:$serverId'),
        refreshDirectories: () async {
          calls.add('directories');
          throw StateError('Host server is not connected');
        },
      );

      expect(revalidated, isFalse);
      expect(calls, ['history:server', 'directories']);
    });

    test('revalidates well past the threshold too', () async {
      final calls = <String>[];

      final revalidated = await revalidateSessionAfterResume(
        awayMs: sessionStaleAfterMs * 10,
        serverId: 'other-server',
        bumpHistorySyncGeneration: (serverId) => calls.add('history:$serverId'),
        refreshDirectories: () async => calls.add('directories'),
      );

      expect(revalidated, isTrue);
      expect(calls, ['history:other-server', 'directories']);
    });

    test('reports failure when the history bump itself throws', () async {
      final calls = <String>[];

      final revalidated = await revalidateSessionAfterResume(
        awayMs: sessionStaleAfterMs,
        serverId: 'server',
        bumpHistorySyncGeneration: (_) => throw StateError('no such server'),
        refreshDirectories: () async => calls.add('directories'),
      );

      expect(revalidated, isFalse);
      // Directories are never refreshed once the bump fails.
      expect(calls, isEmpty);
    });

    test('stays put a millisecond under the threshold and acts exactly '
        'on it', () async {
      var refreshes = 0;

      Future<bool> resumeAfter(num awayMs) => revalidateSessionAfterResume(
        awayMs: awayMs,
        serverId: 'server',
        bumpHistorySyncGeneration: (_) {},
        refreshDirectories: () async => refreshes += 1,
      );

      expect(await resumeAfter(59999), isFalse);
      expect(refreshes, 0);
      expect(await resumeAfter(60000), isTrue);
      expect(refreshes, 1);
    });
  });
}
