import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_display.dart';
import '../../core/theme.dart';
import '../../state/daemon_providers.dart';
import '../../widgets/fluent/toast.dart';

/// Add/edit form for one provider. [draft] is either a preset-seeded config
/// with an empty id (create) or an existing provider's config (edit).
///
/// [ProviderConfig.kind] is fixed once created — switching dialect under a
/// live provider would silently change how every stored agent talks to it, so
/// delete-and-recreate is the supported path.
Future<void> showProviderFormDialog(
  BuildContext context,
  WidgetRef ref, {
  required ProviderConfig draft,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ProviderFormDialog(draft: draft, ref: ref),
    );

class _ProviderFormDialog extends StatefulWidget {
  const _ProviderFormDialog({required this.draft, required this.ref});

  final ProviderConfig draft;
  final WidgetRef ref;

  @override
  State<_ProviderFormDialog> createState() => _ProviderFormDialogState();
}

class _ProviderFormDialogState extends State<_ProviderFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _displayName;
  late final TextEditingController _baseUrl;
  late final TextEditingController _models;
  final _apiKey = TextEditingController();
  bool _saving = false;

  bool get _isEdit => widget.draft.id.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _displayName = TextEditingController(text: widget.draft.displayName);
    _baseUrl = TextEditingController(text: widget.draft.baseUrl);
    _models = TextEditingController(
      text: widget.draft.models.map((m) => m.id).join(', '),
    );
  }

  @override
  void dispose() {
    _displayName.dispose();
    _baseUrl.dispose();
    _models.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  String? _validateBaseUrl(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return 'Base URL is required';
    if (value.endsWith('/')) return 'Remove the trailing slash';
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return 'Must be an absolute http(s) URL';
    }
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);

    final modelIds = _models.text
        .split(',')
        .map((raw) => raw.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    final config = widget.draft.copyWith(
      displayName: _displayName.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      models: [
        for (final id in modelIds) ProviderModel(id: id, displayName: id),
      ],
    );

    try {
      await widget.ref.read(providerActionsProvider).upsert(
            config,
            apiKey: _apiKey.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      AppToast.show(
        context,
        _isEdit
            ? '${config.displayName} updated'
            : '${config.displayName} added',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.show(context, 'Failed to save provider: $e',
          severity: InfoBarSeverity.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: Text(_isEdit ? 'Edit provider' : 'Add provider'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InfoLabel(
                label: 'Name',
                child: TextFormBox(
                  controller: _displayName,
                  autofocus: true,
                  placeholder: 'e.g. Claude (work account)',
                  validator: (value) =>
                      (value?.trim().isEmpty ?? true) ? 'Name is required' : null,
                ),
              ),
              const SizedBox(height: 12),
              InfoLabel(
                label: 'Base URL',
                child: TextFormBox(
                  controller: _baseUrl,
                  placeholder: 'https://api.anthropic.com/v1',
                  validator: _validateBaseUrl,
                ),
              ),
              const SizedBox(height: 12),
              InfoLabel(
                label: 'API key',
                child: TextBox(
                  controller: _apiKey,
                  obscureText: true,
                  placeholder: _isEdit
                      ? 'Leave blank to keep the existing key'
                      : 'API key',
                ),
              ),
              const SizedBox(height: 12),
              InfoLabel(
                label: 'Models (optional)',
                child: TextBox(
                  controller: _models,
                  placeholder: 'comma-separated ids',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Used as a fallback when the provider\'s model list can\'t be '
                'fetched.',
                style: context.textStyles.bodySmall
                    ?.copyWith(color: context.tokens.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              // Fixed after create: switching dialect would change how every
              // stored agent talks to this provider.
              Row(
                children: [
                  Text('API dialect', style: context.textStyles.bodySmall),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      providerKindLabel(widget.draft.kind),
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                      style: context.textStyles.bodySmall
                          ?.copyWith(color: context.tokens.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        Button(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: ProgressRing(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
