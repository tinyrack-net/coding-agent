import 'package:flutter/material.dart';

enum SettingsSection {
  connection(icon: Icons.dns_outlined, label: 'Connection'),
  providers(icon: Icons.smart_toy_outlined, label: 'AI Providers'),
  desktop(icon: Icons.desktop_windows_outlined, label: 'Desktop'),
  data(icon: Icons.storage_outlined, label: 'Data');

  const SettingsSection({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// Independent sidebar for the Settings page, listing its sections. This is
/// separate from the main app's agent-list sidebar in `home_shell.dart`.
class SettingsSidebar extends StatelessWidget {
  const SettingsSidebar({
    super.key,
    required this.sections,
    required this.selected,
    required this.onSelect,
  });

  final List<SettingsSection> sections;
  final SettingsSection selected;
  final ValueChanged<SettingsSection> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text('Settings', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final section in sections)
                ListTile(
                  dense: true,
                  selected: section == selected,
                  leading: Icon(section.icon, size: 20),
                  title: Text(section.label),
                  onTap: () => onSelect(section),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
