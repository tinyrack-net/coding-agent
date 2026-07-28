import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../command_center/command_center.dart';
import 'provider_icon.dart';
import 'shortcut_badge.dart';

class CommandCenterDialog extends StatefulWidget {
  const CommandCenterDialog({
    super.key,
    required this.sectionsBuilder,
    required this.isMac,
    required this.onClose,
    this.toggleShortcutOverride,
  });

  final List<CommandCenterResultSection> Function(String query) sectionsBuilder;
  final bool isMac;
  final VoidCallback onClose;
  final String? toggleShortcutOverride;

  @override
  State<CommandCenterDialog> createState() => _CommandCenterDialogState();
}

class _CommandCenterDialogState extends State<CommandCenterDialog> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  var _query = '';
  String? _activeId;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  List<CommandCenterResultSection> get _sections =>
      widget.sectionsBuilder(_query);

  List<CommandCenterResult> get _results =>
      _sections.expand((section) => section.results).toList();

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _activeId = moveActiveResultId(_activeId, _results, next: true);
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _activeId = moveActiveResultId(_activeId, _results, next: false);
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      final selected = _results
          .where((result) => result.id == _activeId)
          .firstOrNull;
      if (selected != null) _select(selected);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        (event.logicalKey == LogicalKeyboardKey.keyK &&
            ((widget.isMac && HardwareKeyboard.instance.isMetaPressed) ||
                (!widget.isMac &&
                    HardwareKeyboard.instance.isControlPressed)))) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _select(CommandCenterResult result) {
    widget.onClose();
    unawaited(Future.sync(result.run));
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    final results = _results;
    _activeId = preserveActiveResultId(_activeId, results);
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
      content: Column(
        children: [
          Focus(
            onKeyEvent: _onKeyEvent,
            child: TextBox(
              key: const ValueKey('command-center-search'),
              controller: _searchController,
              focusNode: _searchFocusNode,
              autofocus: true,
              placeholder: 'Search workspaces, agents, and actions',
              prefix: const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(FluentIcons.search, size: 16),
              ),
              suffix: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: widget.toggleShortcutOverride == null
                    ? ShortcutBadge(
                        keys: const ['mod', 'K'],
                        isMac: widget.isMac,
                      )
                    : ShortcutValueBadge(value: widget.toggleShortcutOverride!),
              ),
              onChanged: (value) => setState(() {
                _query = value;
                _activeId = preserveActiveResultId(_activeId, _results);
              }),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: results.isEmpty
                ? const Center(child: Text('No results'))
                : ListView(
                    children: [
                      for (final section in sections) ...[
                        if (section.title != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                            child: Text(
                              section.title!,
                              style: FluentTheme.of(context).typography.caption,
                            ),
                          ),
                        for (final result in section.results)
                          _CommandCenterRow(
                            result: result,
                            active: result.id == _activeId,
                            isMac: widget.isMac,
                            onPressed: () => _select(result),
                            onHover: () =>
                                setState(() => _activeId = result.id),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _CommandCenterRow extends StatelessWidget {
  const _CommandCenterRow({
    required this.result,
    required this.active,
    required this.isMac,
    required this.onPressed,
    required this.onHover,
  });

  final CommandCenterResult result;
  final bool active;
  final bool isMac;
  final VoidCallback onPressed;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final subtitle = switch (result) {
      CommandCenterWorkspaceResult(:final subtitle) => subtitle,
      CommandCenterAgentResult(:final subtitle) => subtitle,
      CommandCenterContributionResult(:final contribution) =>
        switch (contribution.presentation) {
          CommandCenterActionPresentation(:final subtitle) => subtitle,
          CommandCenterChoicePresentation(:final path) =>
            path.length > 1
                ? path.sublist(0, path.length - 1).join(' › ')
                : null,
        },
    };
    final contribution = result is CommandCenterContributionResult
        ? (result as CommandCenterContributionResult).contribution
        : null;
    final selected = switch (contribution?.presentation) {
      CommandCenterChoicePresentation(:final selected) => selected,
      _ => false,
    };
    final providerIcon = switch (contribution?.presentation) {
      CommandCenterChoicePresentation(:final providerIcon) => providerIcon,
      _ => null,
    };
    final shortcutKeys = switch (contribution?.presentation) {
      CommandCenterActionPresentation(:final shortcutKeys) => shortcutKeys,
      _ => const <List<String>>[],
    };
    return MouseRegion(
      onEnter: (_) => onHover(),
      child: Button(
        key: ValueKey('command-center-result-${result.id}'),
        onPressed: onPressed,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (active || states.contains(WidgetState.hovered)) {
              return FluentTheme.of(context).resources.subtleFillColorSecondary;
            }
            return Colors.transparent;
          }),
        ),
        child: Row(
          children: [
            if (providerIcon != null)
              ProviderIcon(
                key: ValueKey('command-center-provider-icon-$providerIcon'),
                provider: providerIcon,
                size: 16,
                color: FluentTheme.of(context).resources.textFillColorSecondary,
              )
            else
              Icon(
                result is CommandCenterAgentResult
                    ? FluentIcons.robot
                    : result is CommandCenterWorkspaceResult
                    ? FluentIcons.folder_horizontal
                    : FluentIcons.command_prompt,
                size: 16,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: FluentTheme.of(
                          context,
                        ).resources.textFillColorSecondary,
                      ),
                    ),
                ],
              ),
            ),
            for (final keys in shortcutKeys)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ShortcutBadge(keys: keys, isMac: isMac),
              ),
            if (selected)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(FluentIcons.check_mark, size: 16),
              ),
          ],
        ),
      ),
    );
  }
}
