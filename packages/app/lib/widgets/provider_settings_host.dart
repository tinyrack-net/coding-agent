import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/provider_settings_provider.dart';
import 'provider_settings_sheet.dart';

class ProviderSettingsHost extends ConsumerStatefulWidget {
  const ProviderSettingsHost({super.key});

  @override
  ConsumerState<ProviderSettingsHost> createState() =>
      _ProviderSettingsHostState();
}

class _ProviderSettingsHostState extends ConsumerState<ProviderSettingsHost> {
  ProviderSettingsTarget? _presenting;
  var _scheduled = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(providerSettingsProvider);
    final target = state.target;
    if (state.visible &&
        target != null &&
        target.serverId.isNotEmpty &&
        target.provider.isNotEmpty &&
        _presenting == null &&
        !_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (mounted) unawaited(_present(target));
      });
    }
    return const SizedBox.shrink();
  }

  Future<void> _present(ProviderSettingsTarget target) async {
    if (_presenting != null || !mounted) return;
    final current = ref.read(providerSettingsProvider);
    if (!current.visible || current.target != target) return;
    _presenting = target;
    await showProviderSettingsSheet(
      context: context,
      serverId: target.serverId,
      provider: target.provider,
    );
    if (!mounted) return;
    _presenting = null;
    final latest = ref.read(providerSettingsProvider);
    if (latest.visible && latest.target == target) {
      ref.read(providerSettingsProvider.notifier).close();
    } else if (latest.visible && latest.target != null) {
      setState(() {});
    }
  }
}
