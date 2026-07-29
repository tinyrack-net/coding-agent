import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../core/daemon_client.dart';
import 'fluent/toast.dart';

Future<void> showProviderDiagnosticDialog({
  required BuildContext context,
  required DaemonClient client,
  required String provider,
  required String label,
}) => showDialog<void>(
  context: context,
  builder: (context) => ProviderDiagnosticDialog(
    client: client,
    provider: provider,
    label: label,
  ),
);

class ProviderDiagnosticDialog extends StatefulWidget {
  const ProviderDiagnosticDialog({
    super.key,
    required this.client,
    required this.provider,
    required this.label,
  });

  final DaemonClient client;
  final String provider;
  final String label;

  @override
  State<ProviderDiagnosticDialog> createState() =>
      _ProviderDiagnosticDialogState();
}

class _ProviderDiagnosticDialogState extends State<ProviderDiagnosticDialog> {
  String? _diagnostic;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    try {
      final response = await widget.client.getProviderDiagnostic(
        widget.provider,
      );
      if (!mounted) return;
      setState(() => _diagnostic = response.diagnostic);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _diagnostic = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy() async {
    final diagnostic = _diagnostic;
    if (diagnostic == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: diagnostic));
      if (mounted) AppToast.show(context, 'Provider diagnostic copied.');
    } on Object {
      if (mounted) {
        AppToast.show(
          context,
          'Failed to copy provider diagnostic.',
          severity: InfoBarSeverity.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ContentDialog(
    key: const Key('provider-diagnostic-dialog'),
    constraints: const BoxConstraints(maxWidth: 640),
    title: Text('${widget.label} diagnostic'),
    content: SizedBox(
      height: 360,
      child: _loading && _diagnostic == null
          ? const Center(child: ProgressRing())
          : DecoratedBox(
              decoration: BoxDecoration(
                color: FluentTheme.of(
                  context,
                ).resources.cardBackgroundFillColorDefault,
                border: Border.all(
                  color: FluentTheme.of(
                    context,
                  ).resources.cardStrokeColorDefault,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        _diagnostic ?? '',
                        key: const Key('provider-diagnostic-text'),
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                  if (_loading)
                    const Positioned(
                      top: 10,
                      right: 10,
                      child: SizedBox.square(
                        dimension: 16,
                        child: ProgressRing(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
            ),
    ),
    actions: [
      Tooltip(
        message: 'Copy diagnostic',
        child: IconButton(
          key: const Key('copy-provider-diagnostic'),
          icon: const Icon(FluentIcons.copy, size: 16),
          onPressed: _diagnostic == null ? null : _copy,
        ),
      ),
      Button(
        key: const Key('refresh-provider-diagnostic'),
        onPressed: _loading ? null : _fetch,
        child: Text(_loading ? 'Refreshing…' : 'Refresh'),
      ),
      FilledButton(
        key: const Key('close-provider-diagnostic'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}
