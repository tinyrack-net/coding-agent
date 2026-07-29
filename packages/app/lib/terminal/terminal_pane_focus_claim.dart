class TerminalPaneFocusClaimState {
  const TerminalPaneFocusClaimState({
    required this.claimedKey,
    required this.requestedKey,
  });

  static const empty = TerminalPaneFocusClaimState(
    claimedKey: null,
    requestedKey: null,
  );

  final String? claimedKey;
  final String? requestedKey;
}

class TerminalPaneFocusClaimStep {
  const TerminalPaneFocusClaimStep({
    required this.state,
    required this.shouldRequest,
  });

  final TerminalPaneFocusClaimState state;
  final bool shouldRequest;
}

bool canRequestTerminalPaneFocusClaim({
  required bool isWorkspaceFocused,
  required bool isAppActivelyVisible,
  required bool isClientReady,
  required bool isConnected,
  required bool isRendererReady,
}) =>
    isWorkspaceFocused &&
    isAppActivelyVisible &&
    isClientReady &&
    isConnected &&
    isRendererReady;

TerminalPaneFocusClaimStep reconcileTerminalPaneFocusClaim({
  required TerminalPaneFocusClaimState state,
  required String? key,
  required bool canRequest,
}) {
  if (key == null) {
    return const TerminalPaneFocusClaimStep(
      state: TerminalPaneFocusClaimState.empty,
      shouldRequest: false,
    );
  }
  if (state.claimedKey == key) {
    return TerminalPaneFocusClaimStep(
      state: TerminalPaneFocusClaimState(claimedKey: key, requestedKey: null),
      shouldRequest: false,
    );
  }
  if (!canRequest) {
    return TerminalPaneFocusClaimStep(
      state: TerminalPaneFocusClaimState(
        claimedKey: state.claimedKey,
        requestedKey: null,
      ),
      shouldRequest: false,
    );
  }
  if (state.requestedKey == key) {
    return TerminalPaneFocusClaimStep(state: state, shouldRequest: false);
  }
  return TerminalPaneFocusClaimStep(
    state: TerminalPaneFocusClaimState(
      claimedKey: state.claimedKey,
      requestedKey: key,
    ),
    shouldRequest: true,
  );
}

TerminalPaneFocusClaimState settleTerminalPaneFocusClaim({
  required TerminalPaneFocusClaimState state,
  required String key,
  required bool sent,
}) {
  if (state.requestedKey != key) return state;
  return TerminalPaneFocusClaimState(
    claimedKey: sent ? key : state.claimedKey,
    requestedKey: null,
  );
}
