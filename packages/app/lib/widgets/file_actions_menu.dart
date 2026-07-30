import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

final class FileActionsMenu extends StatefulWidget {
  const FileActionsMenu({
    super.key,
    required this.path,
    required this.fileExists,
    required this.testIdPrefix,
    this.onOpenFile,
    this.onCopyPath,
    this.onDownload,
    this.onAddToChat,
  });

  final String path;
  final bool fileExists;
  final String testIdPrefix;
  final ValueChanged<String>? onOpenFile;
  final ValueChanged<String>? onCopyPath;
  final ValueChanged<String>? onDownload;
  final ValueChanged<String>? onAddToChat;

  @override
  State<FileActionsMenu> createState() => FileActionsMenuState();
}

final class FileActionsMenuState extends State<FileActionsMenu> {
  final _controller = FlyoutController();

  bool get _hasActions =>
      widget.onCopyPath != null ||
      (widget.fileExists &&
          (widget.onOpenFile != null ||
              widget.onDownload != null ||
              widget.onAddToChat != null));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> show() async {
    if (!_hasActions || !_controller.isAttached || _controller.isOpen) return;
    await _controller.showFlyout<void>(
      placementMode: FlyoutPlacementMode.bottomRight,
      builder: (context) => MenuFlyout(
        constraints: const BoxConstraints.tightFor(width: 220),
        items: [
          if (widget.fileExists && widget.onOpenFile != null)
            MenuFlyoutItem(
              key: ValueKey('${widget.testIdPrefix}-open-file'),
              leading: const Icon(FluentIcons.open_file, size: 14),
              text: const Text('Open file'),
              onPressed: () => widget.onOpenFile!(widget.path),
            ),
          if (widget.onCopyPath != null)
            MenuFlyoutItem(
              key: ValueKey('${widget.testIdPrefix}-copy-path'),
              leading: const Icon(FluentIcons.copy, size: 14),
              text: const Text('Copy path'),
              onPressed: () => widget.onCopyPath!(widget.path),
            ),
          if (widget.fileExists && widget.onDownload != null)
            MenuFlyoutItem(
              key: ValueKey('${widget.testIdPrefix}-download'),
              leading: const Icon(FluentIcons.download, size: 14),
              text: const Text('Download'),
              onPressed: () => widget.onDownload!(widget.path),
            ),
          if (widget.fileExists && widget.onAddToChat != null)
            MenuFlyoutItem(
              key: ValueKey('${widget.testIdPrefix}-add-to-chat'),
              leading: const Icon(FluentIcons.chat, size: 14),
              text: const Text('Add to chat…'),
              onPressed: () => widget.onAddToChat!(widget.path),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasActions) return const SizedBox.shrink();
    return FlyoutTarget(
      controller: _controller,
      child: Tooltip(
        message: 'More actions',
        child: IconButton(
          key: ValueKey('${widget.testIdPrefix}-actions'),
          icon: const Icon(FluentIcons.more_vertical, size: 14),
          onPressed: () => unawaited(show()),
        ),
      ),
    );
  }
}
