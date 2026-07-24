import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';

/// Color/icon/letter mapping for a diff file status.
(Color, IconData, String) diffStatusStyle(DiffFileStatus status) =>
    switch (status) {
      DiffFileStatus.added => (Colors.green, Icons.add_circle_outline, 'A'),
      DiffFileStatus.modified => (Colors.amber, Icons.edit_outlined, 'M'),
      DiffFileStatus.deleted => (Colors.red, Icons.remove_circle_outline, 'D'),
      DiffFileStatus.renamed => (
        Colors.purple,
        Icons.drive_file_move_outlined,
        'R',
      ),
    };

/// Structured diff review: file list + unified per-file view.
///
/// Wide layouts show a file list on the left and the selected file's hunks on
/// the right; narrow layouts fall back to collapsible per-file sections.
class DiffView extends StatefulWidget {
  const DiffView({super.key, required this.diff});

  final DiffResponse diff;

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  int _selectedIndex = 0;

  @override
  void didUpdateWidget(covariant DiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedIndex >= widget.diff.files.length) {
      _selectedIndex = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = widget.diff.files;
    if (files.isEmpty) return const _NoChanges();

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          // Narrow: collapsible section per file.
          return ListView(
            children: [
              for (final file in files)
                ExpansionTile(
                  key: PageStorageKey('diff-${file.path}'),
                  dense: true,
                  title: _FileRowLabel(file: file),
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  children: [_FileDiffBody(file: file)],
                ),
            ],
          );
        }
        final selected = files[_selectedIndex.clamp(0, files.length - 1)];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 280,
              child: ListView.builder(
                itemCount: files.length,
                itemBuilder: (context, index) => _FileListTile(
                  file: files[index],
                  selected: index == _selectedIndex,
                  onTap: () => setState(() => _selectedIndex = index),
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: ListView(
                key: ValueKey('diff-body-${selected.path}'),
                children: [_FileDiffBody(file: selected)],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NoChanges extends StatelessWidget {
  const _NoChanges();

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, size: 48, color: outline),
          const SizedBox(height: 12),
          Text('No changes', style: TextStyle(color: outline)),
          const SizedBox(height: 4),
          Text(
            'The working tree is clean.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: outline),
          ),
        ],
      ),
    );
  }
}

class _FileListTile extends StatelessWidget {
  const _FileListTile({
    required this.file,
    required this.selected,
    required this.onTap,
  });

  final DiffFile file;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      selected: selected,
      onTap: onTap,
      title: _FileRowLabel(file: file),
    );
  }
}

/// Status icon + path + add/del counts; shared by both layouts.
class _FileRowLabel extends StatelessWidget {
  const _FileRowLabel({required this.file});

  final DiffFile file;

  @override
  Widget build(BuildContext context) {
    final (color, icon, _) = diffStatusStyle(file.status);
    final small = Theme.of(context).textTheme.bodySmall;
    final path = file.status == DiffFileStatus.renamed && file.oldPath != null
        ? '${file.oldPath} → ${file.path}'
        : file.path;
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        const SizedBox(width: 8),
        Text('+${file.additions}', style: small?.copyWith(color: Colors.green)),
        const SizedBox(width: 4),
        Text('-${file.deletions}', style: small?.copyWith(color: Colors.red)),
      ],
    );
  }
}

/// Unified diff for a single file: hunk headers + numbered, tinted lines.
class _FileDiffBody extends StatelessWidget {
  const _FileDiffBody({required this.file});

  final DiffFile file;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    if (file.binary) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.insert_drive_file_outlined, size: 18, color: outline),
            const SizedBox(width: 8),
            Text('Binary file', style: TextStyle(color: outline)),
          ],
        ),
      );
    }
    if (file.hunks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text('No textual changes', style: TextStyle(color: outline)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final hunk in file.hunks) ...[
          _HunkHeader(header: hunk.header),
          for (final line in hunk.lines) _DiffLineRow(line: line),
        ],
      ],
    );
  }
}

class _HunkHeader extends StatelessWidget {
  const _HunkHeader({required this.header});

  final String header;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        header,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  const _DiffLineRow({required this.line});

  final DiffLine line;

  static const _monoStyle = TextStyle(fontFamily: 'monospace', fontSize: 12.5);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    final dark = theme.brightness == Brightness.dark;
    final (background, marker, textColor) = switch (line.type) {
      DiffLineType.add => (
        Colors.green.withValues(alpha: 0.12),
        '+',
        dark ? Colors.green.shade300 : Colors.green.shade800,
      ),
      DiffLineType.del => (
        Colors.red.withValues(alpha: 0.12),
        '-',
        dark ? Colors.red.shade300 : Colors.red.shade800,
      ),
      DiffLineType.context => (null, ' ', null),
    };
    final numberStyle = _monoStyle.copyWith(color: outline);
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Text(
              line.oldLineNo?.toString() ?? '',
              textAlign: TextAlign.right,
              style: numberStyle,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              line.newLineNo?.toString() ?? '',
              textAlign: TextAlign.right,
              style: numberStyle,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 12,
            child: Text(marker, style: _monoStyle.copyWith(color: textColor)),
          ),
          Expanded(
            child: Text(
              line.text,
              style: _monoStyle.copyWith(color: textColor),
            ),
          ),
        ],
      ),
    );
  }
}
