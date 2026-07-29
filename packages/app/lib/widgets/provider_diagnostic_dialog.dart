import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../core/daemon_client.dart';
import 'adaptive_modal_sheet.dart';
import 'fluent/toast.dart';

Future<void> showProviderDiagnosticDialog({
  required BuildContext context,
  required DaemonClient client,
  required String provider,
}) => showAdaptiveModalSheet<void>(
  context: context,
  builder: (context) =>
      ProviderDiagnosticDialog(client: client, provider: provider),
);

class ProviderDiagnosticDialog extends StatefulWidget {
  const ProviderDiagnosticDialog({
    super.key,
    required this.client,
    required this.provider,
  });

  final DaemonClient client;
  final String provider;

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
    if (!_loading) setState(() => _loading = true);
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
      if (mounted) AppToast.show(context, 'Diagnostic copied.');
    } on Object {
      if (mounted) {
        AppToast.show(
          context,
          'Failed to copy diagnostic',
          severity: InfoBarSeverity.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AdaptiveModalSheet(
    key: const Key('provider-diagnostic-dialog'),
    title: 'Diagnostic',
    onClose: () => Navigator.of(context).pop(),
    compactInitialHeightFactor: .5,
    compactMaxHeightFactor: .85,
    sizeContentToCurrentSnapPoint: true,
    contentScrollable: false,
    headerActions: [
      Tooltip(
        message: 'Copy diagnostic',
        child: IconButton(
          key: const Key('copy-provider-diagnostic'),
          icon: const Icon(FluentIcons.copy, size: 16),
          onPressed: _diagnostic?.isNotEmpty == true ? _copy : null,
        ),
      ),
      Tooltip(
        message: _loading ? 'Refreshing diagnostic' : 'Refresh diagnostic',
        child: IconButton(
          key: const Key('refresh-provider-diagnostic'),
          onPressed: _loading ? null : _fetch,
          icon: _loading
              ? const SizedBox.square(
                  dimension: 16,
                  child: ProgressRing(strokeWidth: 2),
                )
              : const Icon(FluentIcons.refresh, size: 16),
        ),
      ),
    ],
    content: SizedBox(height: 480, child: _body(context)),
  );

  Widget _body(BuildContext context) {
    final diagnostic = _diagnostic;
    if (_loading && diagnostic == null) {
      return const Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProgressRing(),
            SizedBox(width: 8),
            Text('Running diagnostic...'),
          ],
        ),
      );
    }
    if (diagnostic == null || diagnostic.isEmpty) {
      return Center(
        child: Text(
          'No diagnostic available',
          style: TextStyle(
            color: FluentTheme.of(context).resources.textFillColorSecondary,
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: FluentTheme.of(context).resources.cardBackgroundFillColorDefault,
        border: Border.all(
          color: FluentTheme.of(context).resources.cardStrokeColorDefault,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                diagnostic,
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
    );
  }
}
