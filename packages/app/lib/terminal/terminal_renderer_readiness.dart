final class TerminalRendererReadyChange {
  const TerminalRendererReadyChange({
    required this.streamKey,
    required this.isReady,
  });

  final String streamKey;
  final bool isReady;
}

String? applyTerminalRendererReadyChange(
  String? currentReadyStreamKey,
  TerminalRendererReadyChange change,
) {
  if (change.isReady) return change.streamKey;
  return currentReadyStreamKey == change.streamKey
      ? null
      : currentReadyStreamKey;
}

bool shouldReplayTerminalSnapshotForRenderer({
  required TerminalRendererReadyChange change,
  required String terminalStreamKey,
}) => change.isReady && change.streamKey == terminalStreamKey;

bool shouldShowTerminalLoadingOverlay({
  required bool isWorkspaceFocused,
  required bool hasStreamError,
  required bool isAttaching,
  required String? rendererReadyStreamKey,
  required String terminalStreamKey,
}) =>
    isWorkspaceFocused &&
    !hasStreamError &&
    (isAttaching || rendererReadyStreamKey != terminalStreamKey);
