import 'package:coding_agent_app/terminal/terminal_renderer_readiness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const stream1 = 'scope:terminal-1';
  const stream2 = 'scope:terminal-2';

  test('preserves the attach loader even after the renderer is ready', () {
    expect(
      shouldShowTerminalLoadingOverlay(
        isWorkspaceFocused: true,
        hasStreamError: false,
        isAttaching: true,
        rendererReadyStreamKey: stream1,
        terminalStreamKey: stream1,
      ),
      isTrue,
    );
  });

  test('keeps the loader visible until the current renderer is ready', () {
    expect(
      shouldShowTerminalLoadingOverlay(
        isWorkspaceFocused: true,
        hasStreamError: false,
        isAttaching: false,
        rendererReadyStreamKey: null,
        terminalStreamKey: stream1,
      ),
      isTrue,
    );
  });

  test('hides only after attach and current-renderer readiness complete', () {
    expect(
      shouldShowTerminalLoadingOverlay(
        isWorkspaceFocused: true,
        hasStreamError: false,
        isAttaching: false,
        rendererReadyStreamKey: stream1,
        terminalStreamKey: stream1,
      ),
      isFalse,
    );
  });

  test('does not cover stream errors or unfocused workspaces', () {
    expect(
      shouldShowTerminalLoadingOverlay(
        isWorkspaceFocused: true,
        hasStreamError: true,
        isAttaching: true,
        rendererReadyStreamKey: null,
        terminalStreamKey: stream1,
      ),
      isFalse,
    );
    expect(
      shouldShowTerminalLoadingOverlay(
        isWorkspaceFocused: false,
        hasStreamError: false,
        isAttaching: true,
        rendererReadyStreamKey: null,
        terminalStreamKey: stream1,
      ),
      isFalse,
    );
  });

  test('ignores stale unready events from an old renderer', () {
    expect(
      applyTerminalRendererReadyChange(
        stream2,
        const TerminalRendererReadyChange(streamKey: stream1, isReady: false),
      ),
      stream2,
    );
  });

  test('clears readiness when the current renderer unmounts', () {
    expect(
      applyTerminalRendererReadyChange(
        stream1,
        const TerminalRendererReadyChange(streamKey: stream1, isReady: false),
      ),
      isNull,
    );
  });

  test('ready events replace old readiness with the current renderer', () {
    expect(
      applyTerminalRendererReadyChange(
        stream1,
        const TerminalRendererReadyChange(streamKey: stream2, isReady: true),
      ),
      stream2,
    );
  });

  test('replays snapshots only for ready events from current renderer', () {
    expect(
      shouldReplayTerminalSnapshotForRenderer(
        change: const TerminalRendererReadyChange(
          streamKey: stream1,
          isReady: true,
        ),
        terminalStreamKey: stream1,
      ),
      isTrue,
    );
    expect(
      shouldReplayTerminalSnapshotForRenderer(
        change: const TerminalRendererReadyChange(
          streamKey: stream1,
          isReady: false,
        ),
        terminalStreamKey: stream1,
      ),
      isFalse,
    );
    expect(
      shouldReplayTerminalSnapshotForRenderer(
        change: const TerminalRendererReadyChange(
          streamKey: stream1,
          isReady: true,
        ),
        terminalStreamKey: stream2,
      ),
      isFalse,
    );
  });
}
