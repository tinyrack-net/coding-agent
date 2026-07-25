import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/desktop_settings_provider.dart';

/// Tray-residency toggles; only rendered when `isDesktopShell`.
class DesktopSection extends ConsumerWidget {
  const DesktopSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktop = ref.watch(desktopSettingsProvider);
    final notifier = ref.read(desktopSettingsProvider.notifier);
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Start at login'),
          subtitle: const Text('Launch hidden in the tray when you sign in'),
          value: desktop.autoStartAtLogin,
          onChanged: (value) => notifier.setAutoStartAtLogin(value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep daemon running after quit'),
          subtitle: const Text(
            'When off, quitting the app also stops the local daemon',
          ),
          value: desktop.keepRunningAfterQuit,
          onChanged: (value) => notifier.setKeepRunningAfterQuit(value),
        ),
      ],
    );
  }
}
