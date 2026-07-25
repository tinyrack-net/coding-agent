import 'package:fluent_ui/fluent_ui.dart';

/// A searchable (or plain-list) `ContentDialog`-based picker — shared by
/// every "choose X" flow in the app (project/isolation/base-ref pickers in
/// `NewWorkspaceScreen`) instead of each defining its own dialog.
class SearchPickerDialog<T> extends StatefulWidget {
  const SearchPickerDialog({
    required this.title,
    required this.items,
    required this.itemLabel,
    this.itemIcon,
    this.searchHint,
    this.emptyText = 'No matches.',
    this.searchable = true,
    this.footer,
    super.key,
  });

  final String title;
  final List<T> items;
  final String Function(T) itemLabel;
  final IconData Function(T)? itemIcon;
  final String? searchHint;
  final String emptyText;
  final bool searchable;
  final Widget Function(BuildContext context)? footer;

  @override
  State<SearchPickerDialog<T>> createState() => _SearchPickerDialogState<T>();
}

class _SearchPickerDialogState<T> extends State<SearchPickerDialog<T>> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? widget.items
        : widget.items
            .where((item) =>
                widget.itemLabel(item).toLowerCase().contains(_query.toLowerCase()))
            .toList();

    return ContentDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.searchable) ...[
              TextBox(
                controller: _searchController,
                autofocus: true,
                placeholder: widget.searchHint,
                prefix: const Padding(
                  padding: EdgeInsetsDirectional.only(start: 8),
                  child: Icon(FluentIcons.search),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 8),
            ],
            Flexible(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(widget.emptyText),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        return ListTile(
                          leading: widget.itemIcon == null
                              ? null
                              : Icon(widget.itemIcon!(item)),
                          title: Text(widget.itemLabel(item)),
                          onPressed: () => Navigator.of(context).pop(item),
                        );
                      },
                    ),
            ),
            if (widget.footer != null) ...[
              const Divider(),
              widget.footer!(context),
            ],
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// A tappable "badge" chip that opens a picker (project/isolation/base-ref)
/// — replaces the old Material `_PickerBadge` (Material+InkWell+Tooltip).
class PickerBadge extends StatelessWidget {
  const PickerBadge({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final badge = Button(
      onPressed: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 4),
            const Icon(FluentIcons.chevron_down, size: 10),
          ],
        ),
      ),
    );
    return tooltip == null ? badge : Tooltip(message: tooltip, child: badge);
  }
}
