import 'package:fluent_ui/fluent_ui.dart';
import 'package:go_router/go_router.dart';

import '../core/desktop/desktop_shell.dart';
import '../core/theme.dart';

class SettingsShell extends StatelessWidget {
  const SettingsShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: FluentTheme.of(context).scaffoldBackgroundColor,
      child: Row(
        children: [
          const SizedBox(width: 220, child: _SettingsSidebar()),
          const Divider(direction: Axis.vertical),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _SettingsSidebar extends StatelessWidget {
  const _SettingsSidebar();

  @override
  Widget build(BuildContext context) {
    final currentSection =
        GoRouterState.of(context).pathParameters['section'] ?? 'general';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        _SettingsHeaderRow(
          icon: FluentIcons.back,
          label: 'Back to Workspace',
          onTap: () => context.go('/'),
        ),
        const Divider(),
        Expanded(
          child: ListView(
            children: [
              const _SettingsSectionLabel('App'),
              _SettingsNavItem(
                icon: FluentIcons.settings,
                label: 'General',
                section: 'general',
                active: currentSection == 'general',
              ),
              _SettingsNavItem(
                icon: FluentIcons.cloud,
                label: 'Providers',
                section: 'providers',
                active: currentSection == 'providers',
              ),
              if (isDesktopShell)
                _SettingsNavItem(
                  icon: FluentIcons.system,
                  label: 'Desktop',
                  section: 'desktop',
                  active: currentSection == 'desktop',
                ),
              const _SettingsSectionLabel('Data'),
              _SettingsNavItem(
                icon: FluentIcons.reset,
                label: 'Reset',
                section: 'reset',
                active: currentSection == 'reset',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsHeaderRow extends StatelessWidget {
  const _SettingsHeaderRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: HoverButton(
        onPressed: onTap,
        builder: (context, states) {
          final hovering = states.contains(WidgetState.hovered);
          return Container(
            color: hovering
                ? context.tokens.surfaceContainerHighest
                : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SettingsNavItem extends StatelessWidget {
  const _SettingsNavItem({
    required this.icon,
    required this.label,
    required this.section,
    required this.active,
  });

  final IconData icon;
  final String label;
  final String section;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final accent = FluentTheme.of(context).accentColor.normal;
    return SizedBox(
      width: double.infinity,
      child: HoverButton(
        onPressed: () => context.go('/settings/$section'),
        builder: (context, states) {
          final hovering = states.contains(WidgetState.hovered);
          return Container(
            color: (active || hovering)
                ? context.tokens.surfaceContainerHighest
                : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 16,
                  margin: const EdgeInsets.only(right: 9),
                  decoration: BoxDecoration(
                    color: active ? accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Icon(icon, size: 16, color: active ? accent : null),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: active ? accent : null),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SettingsSectionLabel extends StatelessWidget {
  const _SettingsSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text(
        text,
        style: context.textStyles.bodySmall?.copyWith(
          color: context.tokens.onSurfaceVariant,
        ),
      ),
    );
  }
}
