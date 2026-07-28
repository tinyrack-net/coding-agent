import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import '../core/theme.dart';
import '../state/daemon_providers.dart';
import '../workspace/file_editor_model.dart';
import '../workspace/workspace_file_open.dart';
import 'fluent/segmented_control.dart';

typedef _FilePreviewKey = ({
  String cwd,
  WorkspaceFileLocation location,
  int revision,
});

final class WorkspaceFilePreview {
  const WorkspaceFilePreview({
    required this.path,
    required this.kind,
    required this.size,
    required this.mimeType,
    required this.modifiedAt,
    required this.revision,
    this.content,
  });

  final String path;
  final String kind;
  final int size;
  final String mimeType;
  final String modifiedAt;
  final String? revision;
  final String? content;
}

final _filePreviewProvider =
    FutureProvider.family<WorkspaceFilePreview, _FilePreviewKey>((
      ref,
      key,
    ) async {
      const uuid = Uuid();
      final paths = resolveWorkspaceFilePaths(
        path: key.location.path,
        workspaceRoot: key.cwd,
      );
      final requestPath = paths?.relativePath ?? key.location.path;
      final response = await ref
          .watch(daemonClientProvider)
          .requestSessionMessage({
            'type': 'file_explorer_request',
            'cwd': key.cwd,
            'path': requestPath,
            'mode': 'file',
            'acceptBinary': false,
            'requestId': uuid.v4(),
          });
      final payload = Map<String, Object?>.from(response['payload'] as Map);
      final error = payload['error'];
      if (error != null) throw StateError('$error');
      final file = Map<String, Object?>.from(payload['file'] as Map);
      return WorkspaceFilePreview(
        path: file['path'] as String,
        kind: file['kind'] as String,
        size: (file['size'] as num).toInt(),
        mimeType: file['mimeType'] as String,
        modifiedAt: file['modifiedAt'] as String,
        revision: file['revision'] as String?,
        content: file['content'] as String?,
      );
    });

class WorkspaceFilePane extends ConsumerStatefulWidget {
  const WorkspaceFilePane({
    super.key,
    required this.cwd,
    required this.location,
    this.navigationRevision = 0,
    this.onClose,
    this.onModifiedChanged,
  });

  final String cwd;
  final WorkspaceFileLocation location;
  final int navigationRevision;
  final VoidCallback? onClose;
  final ValueChanged<bool>? onModifiedChanged;

  @override
  ConsumerState<WorkspaceFilePane> createState() => _WorkspaceFilePaneState();
}

class _WorkspaceFilePaneState extends ConsumerState<WorkspaceFilePane> {
  @override
  Widget build(BuildContext context) {
    final key = (
      cwd: widget.cwd,
      location: widget.location,
      revision: widget.navigationRevision,
    );
    final preview = ref.watch(_filePreviewProvider(key));
    return ColoredBox(
      key: const ValueKey('workspace-file-pane'),
      color: FluentTheme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          _FilePaneBar(
            location: widget.location,
            preview: preview.value,
            onClose: widget.onClose,
            onRefresh: () => ref.invalidate(_filePreviewProvider(key)),
          ),
          Expanded(
            child: preview.when(
              loading: () => const Center(child: ProgressRing()),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Failed to load file\n$error',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.tokens.error),
                  ),
                ),
              ),
              data: (file) => _buildPreview(context, key, file),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(
    BuildContext context,
    _FilePreviewKey key,
    WorkspaceFilePreview file,
  ) {
    if (file.kind == 'text') {
      final client = ref.watch(daemonClientProvider);
      if (client.serverInfo?.features['workspaceFileEditing'] == true &&
          file.size <= 1024 * 1024) {
        return _EditableFileBody(
          key: ValueKey('${key.cwd}:${file.path}'),
          client: client,
          cwd: key.cwd,
          location: key.location,
          file: file,
          navigationRevision: key.revision,
          onModifiedChanged: widget.onModifiedChanged,
        );
      }
      return _ReadOnlyTextPreview(
        location: key.location,
        content: file.content ?? '',
        navigationRevision: key.revision,
      );
    }
    if (file.kind == 'image' && file.content != null) {
      Uint8List bytes;
      try {
        bytes = base64Decode(file.content!);
      } on FormatException {
        return const Center(child: Text('Image preview unavailable'));
      }
      return InteractiveViewer(
        minScale: .25,
        maxScale: 8,
        child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Binary preview unavailable'),
          const SizedBox(height: 8),
          Text(
            _formatBytes(file.size),
            style: TextStyle(color: context.tokens.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

enum _MarkdownMode { preview, source }

class _ReadOnlyTextPreview extends StatefulWidget {
  const _ReadOnlyTextPreview({
    required this.location,
    required this.content,
    required this.navigationRevision,
  });

  final WorkspaceFileLocation location;
  final String content;
  final int navigationRevision;

  @override
  State<_ReadOnlyTextPreview> createState() => _ReadOnlyTextPreviewState();
}

class _ReadOnlyTextPreviewState extends State<_ReadOnlyTextPreview> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToLine();
  }

  @override
  void didUpdateWidget(covariant _ReadOnlyTextPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationRevision != widget.navigationRevision) {
      _scrollToLine();
    }
  }

  void _scrollToLine() {
    final line = widget.location.lineStart;
    if (line == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) return;
      _controller.jumpTo(
        ((line - 1) * 20.0).clamp(0, _controller.position.maxScrollExtent),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.content.split('\n');
    final start = widget.location.lineStart;
    final end = widget.location.lineEnd ?? start;
    final gutterWidth = (lines.length.toString().length * 8 + 24).toDouble();
    return SingleChildScrollView(
      controller: _controller,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < lines.length; index++)
                Container(
                  constraints: const BoxConstraints(minHeight: 20),
                  color:
                      start != null &&
                          index + 1 >= start &&
                          index + 1 <= (end ?? start)
                      ? const Color(0x334EA1FF)
                      : Colors.transparent,
                  child: Row(
                    children: [
                      SizedBox(
                        width: gutterWidth,
                        child: Text(
                          '${index + 1}',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: context.tokens.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        lines[index].isEmpty ? ' ' : lines[index],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 20 / 13,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditableFileBody extends StatefulWidget {
  const _EditableFileBody({
    super.key,
    required this.client,
    required this.cwd,
    required this.location,
    required this.file,
    required this.navigationRevision,
    this.onModifiedChanged,
  });

  final DaemonClient client;
  final String cwd;
  final WorkspaceFileLocation location;
  final WorkspaceFilePreview file;
  final int navigationRevision;
  final ValueChanged<bool>? onModifiedChanged;

  @override
  State<_EditableFileBody> createState() => _EditableFileBodyState();
}

class _EditableFileBodyState extends State<_EditableFileBody> {
  late final TextEditingController _controller;
  late final FileEditorModel _model;
  FileSubscription? _subscription;
  _MarkdownMode _mode = _MarkdownMode.source;
  bool _lastReportedModified = false;

  bool get _isMarkdown {
    final path = widget.location.path.toLowerCase();
    return path.endsWith('.md') ||
        path.endsWith('.markdown') ||
        path.endsWith('.mdx');
  }

  @override
  void initState() {
    super.initState();
    if (_isMarkdown && widget.location.lineStart == null) {
      _mode = _MarkdownMode.preview;
    }
    final raw = widget.file.content ?? '';
    final hasBom = raw.startsWith('\uFEFF');
    final content = hasBom ? raw.substring(1) : raw;
    _controller = TextEditingController(text: content);
    final session = _DaemonFileEditorSession(
      client: widget.client,
      cwd: widget.cwd,
      path: widget.file.path,
    );
    _model = FileEditorModel(
      file: FileEditorFile(
        content: content,
        hasBom: hasBom,
        version: ReadyFileVersion(
          cwd: widget.cwd,
          path: widget.file.path,
          size: widget.file.size,
          modifiedAt: widget.file.modifiedAt,
          revision: widget.file.revision,
        ),
      ),
      session: session,
    )..addListener(_onModelChanged);
    _selectRequestedLine();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant _EditableFileBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationRevision != widget.navigationRevision) {
      _selectRequestedLine();
    }
  }

  void _selectRequestedLine() {
    final requested = widget.location.lineStart;
    if (requested == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lines = _controller.text.split('\n');
      final line = requested.clamp(1, lines.length);
      var offset = 0;
      for (var index = 1; index < line; index++) {
        offset += lines[index - 1].length + 1;
      }
      _controller.selection = TextSelection.collapsed(offset: offset);
    });
  }

  Future<void> _subscribe() async {
    try {
      final subscription = await widget.client.subscribeFile(
        cwd: widget.cwd,
        path: widget.file.path,
        onUpdate: _model.receiveFileVersion,
      );
      if (!mounted) {
        await subscription.unsubscribe();
        return;
      }
      _subscription = subscription;
      _model.receiveFileVersion(subscription.initial);
    } catch (_) {
      // Reading/editing remains available when the daemon lacks live updates.
    }
  }

  void _onModelChanged() {
    if (!mounted) return;
    final content = _model.snapshot.content;
    if (_controller.text != content) {
      final selection = _controller.selection;
      _controller.value = TextEditingValue(
        text: content,
        selection: TextSelection.collapsed(
          offset: selection.baseOffset.clamp(0, content.length),
        ),
      );
    }
    final modified = _model.snapshot.modified;
    if (modified != _lastReportedModified) {
      _lastReportedModified = modified;
      widget.onModifiedChanged?.call(modified);
    }
    setState(() {});
  }

  @override
  void dispose() {
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.unsubscribe());
    _model
      ..removeListener(_onModelChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Reload file?'),
        content: const Text(
          'Your changes will be discarded and the file will be reloaded from disk.',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reload'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _model.reload();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _model.snapshot;
    return Column(
      children: [
        _FileEditorBar(
          snapshot: snapshot,
          markdownMode: _isMarkdown ? _mode : null,
          onMarkdownModeChanged: _isMarkdown
              ? (mode) => setState(() => _mode = mode)
              : null,
          onOverwrite: snapshot.observedVersion is ReadyFileVersion
              ? _model.overwrite
              : null,
          onReload: snapshot.observedVersion is ReadyFileVersion
              ? _reload
              : null,
        ),
        Expanded(
          child: _mode == _MarkdownMode.preview && _isMarkdown
              ? Markdown(
                  data: snapshot.content,
                  selectable: true,
                  padding: const EdgeInsets.all(16),
                )
              : TextBox(
                  key: const ValueKey('workspace-file-editor'),
                  controller: _controller,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 20 / 13,
                  ),
                  padding: const EdgeInsets.all(16),
                  onChanged: _model.edit,
                ),
        ),
      ],
    );
  }
}

class _DaemonFileEditorSession implements FileEditorSession {
  const _DaemonFileEditorSession({
    required this.client,
    required this.cwd,
    required this.path,
  });

  final DaemonClient client;
  final String cwd;
  final String path;

  @override
  Future<FileEditorFile> read() async {
    final response = await client.requestSessionMessage({
      'type': 'file_explorer_request',
      'cwd': cwd,
      'path': path,
      'mode': 'file',
      'acceptBinary': false,
      'requestId': const Uuid().v4(),
    });
    final payload = Map<String, Object?>.from(response['payload'] as Map);
    final error = payload['error'];
    if (error != null) throw StateError('$error');
    final file = Map<String, Object?>.from(payload['file'] as Map);
    if (file['kind'] != 'text' || file['content'] is! String) {
      throw StateError('File is no longer text.');
    }
    final raw = file['content']! as String;
    final hasBom = raw.startsWith('\uFEFF');
    return FileEditorFile(
      content: hasBom ? raw.substring(1) : raw,
      hasBom: hasBom,
      version: ReadyFileVersion(
        cwd: cwd,
        path: file['path']! as String,
        size: (file['size']! as num).toInt(),
        modifiedAt: file['modifiedAt']! as String,
        revision: file['revision'] as String?,
      ),
    );
  }

  @override
  Future<FileWriteResult> write({
    required String content,
    required String expectedModifiedAt,
    String? expectedRevision,
  }) => client.writeFile(
    cwd: cwd,
    path: path,
    content: content,
    expectedModifiedAt: expectedModifiedAt,
    expectedRevision: expectedRevision,
  );
}

class _FileEditorBar extends StatelessWidget {
  const _FileEditorBar({
    required this.snapshot,
    this.markdownMode,
    this.onMarkdownModeChanged,
    this.onOverwrite,
    this.onReload,
  });

  final FileEditorSnapshot snapshot;
  final _MarkdownMode? markdownMode;
  final ValueChanged<_MarkdownMode>? onMarkdownModeChanged;
  final Future<void> Function()? onOverwrite;
  final Future<void> Function()? onReload;

  @override
  Widget build(BuildContext context) {
    final version = snapshot.observedVersion;
    final size = version is ReadyFileVersion ? version.size : 0;
    return Container(
      decoration: BoxDecoration(
        color: FluentTheme.of(context).cardColor,
        border: Border(
          bottom: BorderSide(color: context.tokens.outlineVariant),
        ),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(
                    _formatBytes(size),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.tokens.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${snapshot.content.split('\n').length} lines',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.tokens.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  _EditorStatus(status: snapshot.status),
                  if (markdownMode != null &&
                      onMarkdownModeChanged != null) ...[
                    const SizedBox(width: 12),
                    SegmentedControl<_MarkdownMode>(
                      segments: const [
                        (_MarkdownMode.preview, 'Preview'),
                        (_MarkdownMode.source, 'Source'),
                      ],
                      selected: markdownMode!,
                      onChanged: onMarkdownModeChanged!,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (snapshot.status == FileEditorStatus.conflict)
            InfoBar(
              key: const ValueKey('file-conflict-alert'),
              severity: InfoBarSeverity.warning,
              title: Text(
                version is ReadyFileVersion
                    ? 'File changed on disk'
                    : 'File unavailable',
              ),
              content: const Text(
                'Reload the file or overwrite the version on disk.',
              ),
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Button(
                    onPressed: onOverwrite == null
                        ? null
                        : () => unawaited(onOverwrite!()),
                    child: const Text('Overwrite'),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    onPressed: onReload == null
                        ? null
                        : () => unawaited(onReload!()),
                    child: const Text('Reload'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _EditorStatus extends StatelessWidget {
  const _EditorStatus({required this.status});
  final FileEditorStatus status;

  @override
  Widget build(BuildContext context) => switch (status) {
    FileEditorStatus.dirty => const Text(
      '●',
      semanticsLabel: 'Unsaved changes',
    ),
    FileEditorStatus.saving => const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 12, height: 12, child: ProgressRing(strokeWidth: 2)),
        SizedBox(width: 6),
        Text('Saving'),
      ],
    ),
    FileEditorStatus.error => Text(
      'Save failed',
      style: TextStyle(color: context.tokens.error),
    ),
    FileEditorStatus.conflict => Text(
      'Changed on disk',
      style: TextStyle(color: context.tokens.error),
    ),
    _ => const SizedBox.shrink(),
  };
}

class _FilePaneBar extends StatelessWidget {
  const _FilePaneBar({
    required this.location,
    required this.preview,
    required this.onRefresh,
    this.onClose,
  });

  final WorkspaceFileLocation location;
  final WorkspaceFilePreview? preview;
  final VoidCallback onRefresh;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final filename = location.path
        .replaceAll(r'\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .lastOrNull;
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.tokens.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          const Icon(FluentIcons.page, size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: location.path,
              child: Text(
                filename ?? location.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          if (preview != null)
            Text(
              _formatBytes(preview!.size),
              style: TextStyle(
                fontSize: 10,
                color: context.tokens.onSurfaceVariant,
              ),
            ),
          IconButton(
            icon: const Icon(FluentIcons.refresh, size: 14),
            onPressed: onRefresh,
          ),
          if (onClose != null)
            IconButton(
              icon: const Icon(FluentIcons.chrome_close, size: 14),
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
