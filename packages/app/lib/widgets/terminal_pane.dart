import 'package:agent_protocol/agent_protocol.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import '../core/theme.dart';
import '../core/daemon_client.dart';
import '../core/desktop/desktop_shell.dart';
import '../state/daemon_providers.dart';
import '../state/terminal_providers.dart';
import '../terminal/terminal_file_drop.dart';
import '../terminal/terminal_flutter_keys.dart';
import '../terminal/terminal_keys.dart';
import '../terminal/terminal_local_link_provider.dart';
import '../terminal/terminal_platform.dart';
import '../terminal/terminal_pane_focus_claim.dart';
import '../terminal/terminal_renderer_readiness.dart';
import '../terminal/to_xterm_theme.dart';
import '../workspace/workspace_file_open.dart';
import '../keyboard/shortcut_engine.dart';
import '../keyboard/shortcut_focus_scope.dart';

/// Embedded terminal for one tab of one worktree: fills the pane, dark
/// background, and forwards keystrokes to the daemon PTY while focused.
class TerminalPane extends ConsumerStatefulWidget {
  const TerminalPane({
    super.key,
    required this.worktreePath,
    required this.tabId,
    this.onOpenWorkspaceFile,
    this.workspaceId,
    this.isWorkspaceFocused = true,
  });

  final String worktreePath;
  final String tabId;
  final String? workspaceId;
  final bool isWorkspaceFocused;
  final void Function(WorkspaceFileOpenRequest request)? onOpenWorkspaceFile;

  @override
  ConsumerState<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends ConsumerState<TerminalPane>
    with WidgetsBindingObserver {
  final _focusNode = FocusNode(debugLabel: 'TerminalPane');
  GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  final _surfaceKey = GlobalKey();
  Terminal? _renderedTerminal;
  bool _dropActive = false;
  Terminal? _linkTerminal;
  TerminalLocalFileLinkProvider? _linkProvider;
  TerminalLocalFileLink? _hoveredLink;
  List<Rect> _hoverUnderlineRects = const [];
  int _hoverRequest = 0;
  String? _rendererReadyStreamKey;
  String? _scheduledRendererStreamKey;
  late bool _isAppActivelyVisible;
  TerminalPaneFocusClaimState _focusClaim = TerminalPaneFocusClaimState.empty;
  String? _scheduledFocusClaimKey;
  TerminalSessionNotifier? _terminalNotifier;

  TerminalSessionKey get _key => (
    worktreePath: widget.worktreePath,
    tabId: widget.tabId,
    workspaceId: widget.workspaceId,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowFocusedNotifier.addListener(_onWindowFocusChanged);
    _isAppActivelyVisible = _computeAppVisibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _updateAppVisibility();
  }

  bool _computeAppVisibility() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final lifecycleVisible =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    final windowVisible = !isDesktopShell || windowFocusedNotifier.value;
    return lifecycleVisible && windowVisible;
  }

  void _onWindowFocusChanged() => _updateAppVisibility();

  void _updateAppVisibility() {
    final next = _computeAppVisibility();
    if (next == _isAppActivelyVisible || !mounted) return;
    setState(() => _isAppActivelyVisible = next);
  }

  void _reconcileFocusClaim({
    required TerminalSessionState session,
    required String terminalStreamKey,
  }) {
    final notifier = ref.read(terminalSessionProvider(_key).notifier);
    _terminalNotifier = notifier;
    final key = widget.isWorkspaceFocused && session.terminalId != null
        ? terminalStreamKey
        : null;
    final canRequest = canRequestTerminalPaneFocusClaim(
      isWorkspaceFocused: widget.isWorkspaceFocused,
      isAppActivelyVisible: _isAppActivelyVisible,
      isClientReady: session.status == TerminalSessionStatus.running,
      isConnected:
          ref.read(daemonClientProvider).currentState ==
          DaemonConnectionState.connected,
      isRendererReady: _rendererReadyStreamKey == terminalStreamKey,
    );
    final step = reconcileTerminalPaneFocusClaim(
      state: _focusClaim,
      key: key,
      canRequest: canRequest,
    );
    _focusClaim = step.state;
    notifier.setResizeClaimEnabled(key != null && canRequest);
    if (!step.shouldRequest || key == null || _scheduledFocusClaimKey == key) {
      return;
    }
    _scheduledFocusClaimKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scheduledFocusClaimKey != key) return;
      _scheduledFocusClaimKey = null;
      final current = ref.read(terminalSessionProvider(_key));
      final stillCurrent =
          widget.isWorkspaceFocused &&
          _isAppActivelyVisible &&
          current.status == TerminalSessionStatus.running &&
          current.terminalId != null &&
          '${widget.workspaceId ?? widget.worktreePath}:'
                  '${current.terminalId}' ==
              key &&
          _rendererReadyStreamKey == key &&
          ref.read(daemonClientProvider).currentState ==
              DaemonConnectionState.connected;
      final sent = stillCurrent
          ? ref.read(terminalSessionProvider(_key).notifier).claimCurrentSize()
          : false;
      _focusClaim = settleTerminalPaneFocusClaim(
        state: _focusClaim,
        key: key,
        sent: sent,
      );
      if (!sent && mounted) setState(() {});
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (isTerminalModifierLogicalKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    final key = terminalKeyFromFlutterEvent(event);
    if (key == null) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final pendingModifiers = ref
        .read(terminalSessionProvider(_key))
        .pendingModifiers;
    final notifier = ref.read(terminalSessionProvider(_key).notifier);
    if (!shouldInterceptDomTerminalKey(
      key: key,
      ctrlKey: keyboard.isControlPressed,
      shiftKey: keyboard.isShiftPressed,
      altKey: keyboard.isAltPressed,
      metaKey: keyboard.isMetaPressed,
      pendingModifiers: pendingModifiers,
      enhancedInputActive: notifier.enhancedInputActive,
      isAppleHandheld: currentPlatformIsAppleHandheld,
    )) {
      return KeyEventResult.ignored;
    }
    final modifiers = mergeTerminalModifiers(
      pendingModifiers: pendingModifiers,
      ctrlKey: keyboard.isControlPressed,
      shiftKey: keyboard.isShiftPressed,
      altKey: keyboard.isAltPressed,
      metaKey: keyboard.isMetaPressed,
    );
    final handled = notifier.sendKeyInput(
      TerminalKeyInput(
        key: normalizeTerminalTransportKey(key),
        ctrl: modifiers.ctrl,
        shift: modifiers.shift,
        alt: modifiers.alt,
        meta: modifiers.meta,
      ),
    );
    if (pendingModifiers.hasAny) notifier.clearPendingModifiers();
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool get _showVirtualKeyboard =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      currentPlatformIsAppleHandheld;

  void _toggleModifier(TerminalModifier modifier) {
    ref
        .read(terminalSessionProvider(_key).notifier)
        .togglePendingModifier(modifier);
    _focusNode.requestFocus();
  }

  void _sendVirtualKey(String key) {
    final session = ref.read(terminalSessionProvider(_key));
    final notifier = ref.read(terminalSessionProvider(_key).notifier);
    notifier.sendKeyInput(
      TerminalKeyInput(
        key: normalizeTerminalTransportKey(key),
        ctrl: session.pendingModifiers.ctrl,
        shift: session.pendingModifiers.shift,
        alt: session.pendingModifiers.alt,
      ),
    );
    notifier.clearPendingModifiers();
    _focusNode.requestFocus();
  }

  void _scheduleRendererReady(String streamKey) {
    if (_scheduledRendererStreamKey == streamKey) return;
    final previousStreamKey = _scheduledRendererStreamKey;
    if (previousStreamKey != null) {
      _rendererReadyStreamKey = applyTerminalRendererReadyChange(
        _rendererReadyStreamKey,
        TerminalRendererReadyChange(
          streamKey: previousStreamKey,
          isReady: false,
        ),
      );
    }
    _scheduledRendererStreamKey = streamKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scheduledRendererStreamKey != streamKey) return;
      final nextReadyStreamKey = applyTerminalRendererReadyChange(
        _rendererReadyStreamKey,
        TerminalRendererReadyChange(streamKey: streamKey, isReady: true),
      );
      if (nextReadyStreamKey == _rendererReadyStreamKey) return;
      setState(() => _rendererReadyStreamKey = nextReadyStreamKey);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    windowFocusedNotifier.removeListener(_onWindowFocusChanged);
    _terminalNotifier?.setResizeClaimEnabled(false);
    _hoverRequest++;
    _scheduledRendererStreamKey = null;
    _focusNode.dispose();
    super.dispose();
  }

  TerminalLocalFileLinkProvider _providerFor(Terminal terminal) {
    if (identical(_linkTerminal, terminal) && _linkProvider != null) {
      return _linkProvider!;
    }
    _linkTerminal = terminal;
    _hoveredLink = null;
    _hoverUnderlineRects = const [];
    return _linkProvider = TerminalLocalFileLinkProvider(
      terminal,
      resolveLink: _resolveLocalFileLink,
    );
  }

  Future<TerminalLocalFileLinkTarget?> _resolveLocalFileLink(
    TerminalLocalFileLinkSource source,
  ) async {
    try {
      const uuid = Uuid();
      final response = await ref
          .read(daemonClientProvider)
          .requestSessionMessage({
            'type': 'file_explorer_request',
            'cwd': widget.worktreePath,
            'path': source.path,
            'mode': 'file',
            'acceptBinary': false,
            'requestId': uuid.v4(),
          });
      final payload = Map<String, Object?>.from(response['payload'] as Map);
      if (payload['error'] != null || payload['file'] is! Map) return null;
      final file = Map<String, Object?>.from(payload['file'] as Map);
      final path = file['path'];
      if (path is! String || path.trim().isEmpty) return null;
      return TerminalLocalFileLinkTarget(
        path: path,
        lineStart: source.lineStart,
        lineEnd: source.lineEnd,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleHover(PointerHoverEvent event, Terminal terminal) async {
    final view = _terminalViewKey.currentState;
    if (view == null) return;
    final renderTerminal = view.renderTerminal;
    final local = renderTerminal.globalToLocal(event.position);
    final cell = renderTerminal.getCellOffset(local);
    final request = ++_hoverRequest;
    final link = await _providerFor(terminal).linkAtCell(x: cell.x, y: cell.y);
    if (!mounted || request != _hoverRequest) return;
    final rects = link == null ? const <Rect>[] : _linkRects(link);
    setState(() {
      _hoveredLink = link;
      _hoverUnderlineRects = rects;
    });
  }

  void _handleHoverExit(PointerExitEvent _) {
    _hoverRequest++;
    if (_hoveredLink == null && _hoverUnderlineRects.isEmpty) return;
    setState(() {
      _hoveredLink = null;
      _hoverUnderlineRects = const [];
    });
  }

  Future<void> _handleTapUp(
    TapUpDetails _,
    CellOffset cell,
    Terminal terminal,
  ) async {
    final link = await _providerFor(terminal).linkAtCell(x: cell.x, y: cell.y);
    if (!mounted || link == null) return;
    final keyboard = HardwareKeyboard.instance;
    final disposition = keyboard.isControlPressed || keyboard.isMetaPressed
        ? OpenFileDisposition.side
        : OpenFileDisposition.main;
    final location = normalizeWorkspaceFileLocation(
      WorkspaceFileLocation(
        path: link.target.path,
        lineStart: link.target.lineStart,
        lineEnd: link.target.lineEnd,
      ),
    );
    if (location == null) return;
    widget.onOpenWorkspaceFile?.call(
      WorkspaceFileOpenRequest(location: location, disposition: disposition),
    );
  }

  List<Rect> _linkRects(TerminalLocalFileLink link) {
    final view = _terminalViewKey.currentState;
    final surfaceContext = _surfaceKey.currentContext;
    if (view == null || surfaceContext == null) return const [];
    final renderTerminal = view.renderTerminal;
    final surface = surfaceContext.findRenderObject();
    if (surface is! RenderBox) return const [];
    final cellSize = renderTerminal.cellSize;
    final rects = <Rect>[];
    final firstRow = link.range.start.y - 1;
    final lastRow = link.range.end.y - 1;
    for (var row = firstRow; row <= lastRow; row++) {
      final startX = row == firstRow ? link.range.start.x - 1 : 0;
      final endX = row == lastRow ? link.range.end.x : _linkTerminal!.viewWidth;
      if (endX <= startX) continue;
      final startGlobal = renderTerminal.localToGlobal(
        renderTerminal.getOffset(CellOffset(startX, row)),
      );
      final start = surface.globalToLocal(startGlobal);
      rects.add(
        Rect.fromLTWH(
          start.dx,
          start.dy + cellSize.height - 1,
          (endX - startX) * cellSize.width,
          1,
        ),
      );
    }
    return rects;
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(terminalSessionProvider(_key));
    ref.watch(connectionStateProvider);
    final xtermTheme = toFlutterTerminalTheme(
      toXtermTheme(context.paseoTerminalPalette),
    );
    if (!identical(_renderedTerminal, session.terminal)) {
      _renderedTerminal = session.terminal;
      _terminalViewKey = GlobalKey<TerminalViewState>();
      _linkTerminal = null;
      _linkProvider = null;
      _hoveredLink = null;
      _hoverUnderlineRects = const [];
    }
    final terminalStreamKey =
        '${widget.workspaceId ?? widget.worktreePath}:'
        '${session.terminalId ?? 'pending:${widget.tabId}'}';
    _scheduleRendererReady(terminalStreamKey);
    _reconcileFocusClaim(
      session: session,
      terminalStreamKey: terminalStreamKey,
    );
    final showLoadingOverlay = shouldShowTerminalLoadingOverlay(
      isWorkspaceFocused: widget.isWorkspaceFocused,
      hasStreamError:
          session.status == TerminalSessionStatus.error ||
          session.status == TerminalSessionStatus.exited,
      isAttaching: session.status == TerminalSessionStatus.starting,
      rendererReadyStreamKey: _rendererReadyStreamKey,
      terminalStreamKey: terminalStreamKey,
    );

    return Column(
      children: [
        if (session.status == TerminalSessionStatus.exited)
          _Banner(
            icon: FluentIcons.stop,
            text: session.exitCode == null
                ? 'Terminal exited'
                : 'Terminal exited (code ${session.exitCode})',
            onRestart: () =>
                ref.read(terminalSessionProvider(_key).notifier).restart(),
          ),
        if (session.status == TerminalSessionStatus.error)
          _Banner(
            icon: FluentIcons.error_badge,
            text: 'Terminal failed: ${session.errorMessage ?? 'unknown error'}',
            onRestart: () =>
                ref.read(terminalSessionProvider(_key).notifier).restart(),
          ),
        Expanded(
          child: DropTarget(
            onDragEntered: (_) {
              if (!_dropActive) setState(() => _dropActive = true);
            },
            onDragExited: (_) {
              if (_dropActive) setState(() => _dropActive = false);
            },
            onDragDone: (details) {
              if (_dropActive) setState(() => _dropActive = false);
              if (kIsWeb) return;
              final paths = details.files
                  .map((file) => file.path)
                  .where((path) => path.isNotEmpty)
                  .toList(growable: false);
              if (paths.isEmpty) return;
              final platform = defaultTargetPlatform == TargetPlatform.windows
                  ? TerminalHostPlatform.windows
                  : TerminalHostPlatform.nonWindows;
              final input = prepareDroppedPathsForTerminal(paths, platform);
              if (ref
                  .read(terminalSessionProvider(_key).notifier)
                  .sendRawInput(input)) {
                _focusNode.requestFocus();
              }
            },
            child: ColoredBox(
              key: _surfaceKey,
              color: xtermTheme.background,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ShortcutFocusScope(
                    scope: KeyboardFocusScope.terminal,
                    child: MouseRegion(
                      cursor: _hoveredLink == null
                          ? SystemMouseCursors.text
                          : SystemMouseCursors.click,
                      onHover: (event) => _handleHover(event, session.terminal),
                      onExit: _handleHoverExit,
                      child: TerminalView(
                        session.terminal,
                        key: _terminalViewKey,
                        focusNode: _focusNode,
                        onKeyEvent: _handleKeyEvent,
                        onTapUp: (details, cell) =>
                            _handleTapUp(details, cell, session.terminal),
                        mouseCursor: _hoveredLink == null
                            ? SystemMouseCursors.text
                            : SystemMouseCursors.click,
                        autofocus: widget.isWorkspaceFocused,
                        backgroundOpacity: 0,
                        padding: const EdgeInsets.all(4),
                        textStyle: const TerminalStyle(fontSize: 13),
                        theme: xtermTheme,
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: CustomPaint(
                      key: const ValueKey('terminal-link-underline'),
                      painter: _TerminalLinkUnderlinePainter(
                        _hoverUnderlineRects,
                      ),
                    ),
                  ),
                  if (showLoadingOverlay)
                    const IgnorePointer(
                      child: ColoredBox(
                        key: ValueKey('terminal-attach-loading'),
                        color: Color(0x29000000),
                        child: Center(child: ProgressRing()),
                      ),
                    ),
                  IgnorePointer(
                    child: AnimatedOpacity(
                      key: const ValueKey('terminal-drop-overlay'),
                      opacity: _dropActive ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0x294EA1FF),
                          border: Border.all(color: const Color(0xB84EA1FF)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_showVirtualKeyboard)
          _TerminalVirtualKeyboard(
            modifiers: session.pendingModifiers,
            onToggleModifier: _toggleModifier,
            onSendKey: _sendVirtualKey,
          ),
      ],
    );
  }
}

class _TerminalVirtualKeyboard extends StatelessWidget {
  const _TerminalVirtualKeyboard({
    required this.modifiers,
    required this.onToggleModifier,
    required this.onSendKey,
  });

  final PendingTerminalModifiers modifiers;
  final ValueChanged<TerminalModifier> onToggleModifier;
  final ValueChanged<String> onSendKey;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.paseoPalette.surface0,
          border: Border(top: BorderSide(color: context.paseoPalette.border)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            key: const ValueKey('terminal-virtual-keyboard'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _TerminalKeyButton(
                    id: 'esc',
                    label: 'Esc',
                    onPressed: () => onSendKey('Escape'),
                  ),
                  _TerminalKeyButton(
                    id: 'tab',
                    label: 'Tab',
                    onPressed: () => onSendKey('Tab'),
                  ),
                  _TerminalKeyButton(
                    id: 'ctrl',
                    label: 'Ctrl',
                    active: modifiers.ctrl,
                    onPressed: () => onToggleModifier(TerminalModifier.ctrl),
                  ),
                  _TerminalKeyButton(
                    id: 'up',
                    label: '↑',
                    onPressed: () => onSendKey('ArrowUp'),
                  ),
                  _TerminalKeyButton(
                    id: 'shift',
                    label: 'Shift',
                    active: modifiers.shift,
                    onPressed: () => onToggleModifier(TerminalModifier.shift),
                  ),
                  _TerminalKeyButton(
                    id: 'backspace',
                    label: '⌫',
                    onPressed: () => onSendKey('Backspace'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _TerminalKeyButton(
                    id: 'alt',
                    label: 'Alt',
                    active: modifiers.alt,
                    onPressed: () => onToggleModifier(TerminalModifier.alt),
                  ),
                  _TerminalKeyButton(
                    id: 'space',
                    label: 'Space',
                    onPressed: () => onSendKey(' '),
                  ),
                  _TerminalKeyButton(
                    id: 'left',
                    label: '←',
                    onPressed: () => onSendKey('ArrowLeft'),
                  ),
                  _TerminalKeyButton(
                    id: 'down',
                    label: '↓',
                    onPressed: () => onSendKey('ArrowDown'),
                  ),
                  _TerminalKeyButton(
                    id: 'right',
                    label: '→',
                    onPressed: () => onSendKey('ArrowRight'),
                  ),
                  _TerminalKeyButton(
                    id: 'enter',
                    label: 'Enter',
                    onPressed: () => onSendKey('Enter'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TerminalKeyButton extends StatelessWidget {
  const _TerminalKeyButton({
    required this.id,
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  final String id;
  final String label;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: HoverButton(
          key: ValueKey('terminal-key-$id'),
          onPressed: onPressed,
          builder: (context, states) {
            final highlighted =
                active ||
                states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.pressed);
            return Container(
              height: 34,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: highlighted
                    ? context.paseoPalette.surface2
                    : context.paseoPalette.surface1,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: active
                      ? context.paseoPalette.accent
                      : context.paseoPalette.border,
                ),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: active
                      ? context.paseoPalette.foreground
                      : context.paseoPalette.foregroundMuted,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TerminalLinkUnderlinePainter extends CustomPainter {
  const _TerminalLinkUnderlinePainter(this.rects);

  final List<Rect> rects;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF4EA1FF)
      ..strokeWidth = 1;
    for (final rect in rects) {
      canvas.drawLine(rect.bottomLeft, rect.bottomRight, paint);
    }
  }

  @override
  bool shouldRepaint(_TerminalLinkUnderlinePainter oldDelegate) =>
      oldDelegate.rects != rects;
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.onRestart,
  });

  final IconData icon;
  final String text;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      color: tokens.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: tokens.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textStyles.bodySmall,
            ),
          ),
          Button(
            onPressed: onRestart,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.refresh, size: 16),
                SizedBox(width: 6),
                Text('Restart'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
