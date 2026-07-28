import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import '../core/theme.dart';
import '../state/daemon_providers.dart';
import '../state/terminal_providers.dart';
import '../terminal/terminal_file_drop.dart';
import '../terminal/terminal_local_link_provider.dart';
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
  });

  final String worktreePath;
  final String tabId;
  final String? workspaceId;
  final void Function(WorkspaceFileOpenRequest request)? onOpenWorkspaceFile;

  @override
  ConsumerState<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends ConsumerState<TerminalPane> {
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

  TerminalSessionKey get _key => (
    worktreePath: widget.worktreePath,
    tabId: widget.tabId,
    workspaceId: widget.workspaceId,
  );

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final handled = ref
        .read(terminalSessionProvider(_key).notifier)
        .sendModifiedEnter(
          ctrl: keyboard.isControlPressed,
          shift: keyboard.isShiftPressed,
          alt: keyboard.isAltPressed,
          meta: keyboard.isMetaPressed,
        );
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _hoverRequest++;
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
    if (!identical(_renderedTerminal, session.terminal)) {
      _renderedTerminal = session.terminal;
      _terminalViewKey = GlobalKey<TerminalViewState>();
      _linkTerminal = null;
      _linkProvider = null;
      _hoveredLink = null;
      _hoverUnderlineRects = const [];
    }

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
              color: const Color(0xFF1E1E1E),
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
                        autofocus: true,
                        backgroundOpacity: 0,
                        padding: const EdgeInsets.all(4),
                        textStyle: const TerminalStyle(fontSize: 13),
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
      ],
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
