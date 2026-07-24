import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/agents_provider.dart';

/// Prompt input: Enter sends, Shift+Enter inserts a newline. The send button
/// turns into a stop (interrupt) button while the agent is busy.
class Composer extends ConsumerStatefulWidget {
  const Composer({super.key, required this.agentId});

  final String agentId;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    try {
      await ref.read(agentActionsProvider).prompt(widget.agentId, text);
    } catch (e) {
      if (!mounted) return;
      _controller.text = text;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send prompt: $e')),
      );
    }
  }

  Future<void> _interrupt() async {
    try {
      await ref.read(agentActionsProvider).interrupt(widget.agentId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to interrupt: $e')),
      );
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift) return KeyEventResult.ignored; // let TextField insert newline
    _send();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final runState = ref.watch(
      agentSummaryProvider(widget.agentId).select((a) => a?.runState),
    );
    final busy = runState == AgentRunState.running ||
        runState == AgentRunState.awaitingPermission;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: _onKeyEvent,
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  minLines: 1,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: 'Message the agent… (Enter to send)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            busy
                ? IconButton.filledTonal(
                    tooltip: 'Stop',
                    onPressed: _interrupt,
                    icon: const Icon(Icons.stop),
                  )
                : IconButton.filled(
                    tooltip: 'Send',
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
          ],
        ),
      ),
    );
  }
}
