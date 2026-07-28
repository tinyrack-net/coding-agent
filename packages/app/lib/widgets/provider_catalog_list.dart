import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

import '../providers/acp_provider_catalog.dart';
import 'provider_icon.dart';

typedef InstallAcpProvider =
    FutureOr<void> Function(AcpProviderCatalogEntry entry);
typedef OpenAcpProviderInstructions =
    FutureOr<void> Function(AcpProviderCatalogEntry entry);

class ProviderCatalogList extends StatefulWidget {
  const ProviderCatalogList({
    super.key,
    required this.entries,
    required this.installedProviderIds,
    required this.installingProviderId,
    required this.onInstall,
    required this.onOpenInstallInstructions,
  });

  final List<AcpProviderCatalogEntry> entries;
  final Set<String> installedProviderIds;
  final String? installingProviderId;
  final InstallAcpProvider onInstall;
  final OpenAcpProviderInstructions onOpenInstallInstructions;

  @override
  State<ProviderCatalogList> createState() => _ProviderCatalogListState();
}

class _ProviderCatalogListState extends State<ProviderCatalogList> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearchChanged);
  }

  void _onSearchChanged() => setState(() {});

  @override
  void dispose() {
    _search
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final available = [
      for (final entry in widget.entries)
        if (!widget.installedProviderIds.contains(entry.id) &&
            acpProviderMatchesSearch(entry, _search.text))
          entry,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: 'Search providers',
          textField: true,
          child: TextBox(
            key: const ValueKey('provider-catalog-search'),
            controller: _search,
            placeholder: 'Search providers',
          ),
        ),
        const SizedBox(height: 12),
        if (available.isEmpty)
          const Card(
            child: SizedBox(
              height: 72,
              child: Center(child: Text('No providers found')),
            ),
          )
        else
          Card(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var index = 0; index < available.length; index++) ...[
                  if (index > 0) const Divider(),
                  _ProviderCatalogRow(
                    entry: available[index],
                    installing:
                        widget.installingProviderId == available[index].id,
                    onInstall: widget.onInstall,
                    onOpenInstallInstructions: widget.onOpenInstallInstructions,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ProviderCatalogRow extends StatelessWidget {
  const _ProviderCatalogRow({
    required this.entry,
    required this.installing,
    required this.onInstall,
    required this.onOpenInstallInstructions,
  });

  final AcpProviderCatalogEntry entry;
  final bool installing;
  final InstallAcpProvider onInstall;
  final OpenAcpProviderInstructions onOpenInstallInstructions;

  @override
  Widget build(BuildContext context) {
    final foreground = FluentTheme.of(context).typography.body?.color;
    return Padding(
      key: ValueKey('provider-catalog-row-${entry.id}'),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: FluentTheme.of(
                context,
              ).resources.cardStrokeColorDefaultSolid,
              borderRadius: BorderRadius.circular(6),
            ),
            child: entry.iconName == null
                ? Icon(FluentIcons.package, size: 20, color: foreground)
                : ProviderIcon(
                    provider: entry.id,
                    size: 24,
                    color: foreground ?? Colors.white,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      entry.version,
                      style: FluentTheme.of(context).typography.caption,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entry.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: FluentTheme.of(context).typography.caption,
                ),
                HyperlinkButton(
                  key: ValueKey('provider-install-link-${entry.id}'),
                  onPressed: () => onOpenInstallInstructions(entry),
                  style: const ButtonStyle(
                    padding: WidgetStatePropertyAll(EdgeInsets.zero),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Install instructions'),
                      SizedBox(width: 4),
                      Icon(FluentIcons.open_in_new_window, size: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 92,
            child: Button(
              key: ValueKey('install-provider-${entry.id}'),
              onPressed: installing ? null : () => onInstall(entry),
              child: Text(installing ? 'Adding' : 'Add'),
            ),
          ),
        ],
      ),
    );
  }
}
