import 'package:coding_agent_app/terminal/terminal_pane_focus_claim.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const key = 'workspace:terminal';

  test('waits until client and renderer are ready', () {
    expect(
      canRequestTerminalPaneFocusClaim(
        isWorkspaceFocused: true,
        isAppActivelyVisible: true,
        isClientReady: false,
        isConnected: true,
        isRendererReady: true,
      ),
      isFalse,
    );
    expect(
      canRequestTerminalPaneFocusClaim(
        isWorkspaceFocused: true,
        isAppActivelyVisible: true,
        isClientReady: true,
        isConnected: true,
        isRendererReady: false,
      ),
      isFalse,
    );
    expect(
      canRequestTerminalPaneFocusClaim(
        isWorkspaceFocused: true,
        isAppActivelyVisible: true,
        isClientReady: true,
        isConnected: true,
        isRendererReady: true,
      ),
      isTrue,
    );
  });

  test('does not claim while disconnected', () {
    expect(
      canRequestTerminalPaneFocusClaim(
        isWorkspaceFocused: true,
        isAppActivelyVisible: true,
        isClientReady: true,
        isConnected: false,
        isRendererReady: true,
      ),
      isFalse,
    );
  });

  test('claims once after a successful request', () {
    final requested = reconcileTerminalPaneFocusClaim(
      state: TerminalPaneFocusClaimState.empty,
      key: key,
      canRequest: true,
    );
    expect(requested.shouldRequest, isTrue);
    expect(requested.state.requestedKey, key);

    final settled = settleTerminalPaneFocusClaim(
      state: requested.state,
      key: key,
      sent: true,
    );
    expect(settled.claimedKey, key);
    expect(settled.requestedKey, isNull);

    final repeated = reconcileTerminalPaneFocusClaim(
      state: settled,
      key: key,
      canRequest: true,
    );
    expect(repeated.shouldRequest, isFalse);
  });

  test('defers the request until readiness becomes true', () {
    final deferred = reconcileTerminalPaneFocusClaim(
      state: TerminalPaneFocusClaimState.empty,
      key: key,
      canRequest: false,
    );
    expect(deferred.shouldRequest, isFalse);

    final ready = reconcileTerminalPaneFocusClaim(
      state: deferred.state,
      key: key,
      canRequest: true,
    );
    expect(ready.shouldRequest, isTrue);
  });

  test('clears a pending request when readiness disappears and retries', () {
    final requested = reconcileTerminalPaneFocusClaim(
      state: TerminalPaneFocusClaimState.empty,
      key: key,
      canRequest: true,
    );
    final interrupted = reconcileTerminalPaneFocusClaim(
      state: requested.state,
      key: key,
      canRequest: false,
    );
    expect(interrupted.state.requestedKey, isNull);

    final retried = reconcileTerminalPaneFocusClaim(
      state: interrupted.state,
      key: key,
      canRequest: true,
    );
    expect(retried.shouldRequest, isTrue);
  });

  test('retries a dropped request', () {
    final requested = reconcileTerminalPaneFocusClaim(
      state: TerminalPaneFocusClaimState.empty,
      key: key,
      canRequest: true,
    );
    final dropped = settleTerminalPaneFocusClaim(
      state: requested.state,
      key: key,
      sent: false,
    );
    expect(dropped.claimedKey, isNull);
    expect(dropped.requestedKey, isNull);

    final retried = reconcileTerminalPaneFocusClaim(
      state: dropped,
      key: key,
      canRequest: true,
    );
    expect(retried.shouldRequest, isTrue);
  });

  test('blur and terminal changes rearm the claim', () {
    final claimed = settleTerminalPaneFocusClaim(
      state: reconcileTerminalPaneFocusClaim(
        state: TerminalPaneFocusClaimState.empty,
        key: key,
        canRequest: true,
      ).state,
      key: key,
      sent: true,
    );
    final blurred = reconcileTerminalPaneFocusClaim(
      state: claimed,
      key: null,
      canRequest: false,
    );
    expect(blurred.state.claimedKey, isNull);

    final refocused = reconcileTerminalPaneFocusClaim(
      state: blurred.state,
      key: key,
      canRequest: true,
    );
    expect(refocused.shouldRequest, isTrue);

    final changed = reconcileTerminalPaneFocusClaim(
      state: claimed,
      key: 'workspace:other-terminal',
      canRequest: true,
    );
    expect(changed.shouldRequest, isTrue);
  });
}
