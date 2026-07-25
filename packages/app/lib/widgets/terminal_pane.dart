import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../core/theme.dart';
import '../state/terminal_providers.dart';

/// Embedded terminal for one tab of one worktree: fills the pane, dark
/// background, and forwards keystrokes to the daemon PTY while focused.
class TerminalPane extends ConsumerStatefulWidget {
  const TerminalPane(
      {super.key, required this.worktreePath, required this.tabId});

  final String worktreePath;
  final String tabId;

  @override
  ConsumerState<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends ConsumerState<TerminalPane> {
  final _focusNode = FocusNode(debugLabel: 'TerminalPane');

  TerminalSessionKey get _key =>
      (worktreePath: widget.worktreePath, tabId: widget.tabId);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(terminalSessionProvider(_key));

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
          child: ColoredBox(
            color: const Color(0xFF1E1E1E),
            child: GestureDetector(
              onTap: _focusNode.requestFocus,
              child: TerminalView(
                session.terminal,
                key: ValueKey(session.terminal),
                focusNode: _focusNode,
                autofocus: true,
                backgroundOpacity: 0,
                padding: const EdgeInsets.all(4),
                textStyle: const TerminalStyle(fontSize: 13),
              ),
            ),
          ),
        ),
      ],
    );
  }
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
