import 'package:flutter/material.dart';

import '../../core/desktop/desktop_shell.dart';
import 'sections/connection_section.dart';
import 'sections/data_section.dart';
import 'sections/desktop_section.dart';
import 'sections/providers_section.dart';
import 'settings_sidebar.dart';

/// Settings page: a fixed-width `SettingsSidebar` listing sections next to a
/// content pane that swaps based on the selected section. Independent of the
/// main app's agent-list sidebar in `home_shell.dart`.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsSection _selected = SettingsSection.connection;

  List<SettingsSection> get _sections => [
        SettingsSection.connection,
        SettingsSection.providers,
        if (isDesktopShell) SettingsSection.desktop,
        SettingsSection.data,
      ];

  void _select(SettingsSection section) {
    setState(() => _selected = section);
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    final selected = sections.contains(_selected)
        ? _selected
        : SettingsSection.connection;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Row(
        children: [
          SizedBox(
            width: 240,
            child: SettingsSidebar(
              sections: sections,
              selected: selected,
              onSelect: _select,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    switch (selected) {
                      SettingsSection.connection => const ConnectionSection(),
                      SettingsSection.providers => const ProvidersSection(),
                      SettingsSection.desktop => const DesktopSection(),
                      SettingsSection.data => const DataSection(),
                    },
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
