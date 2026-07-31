import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/desktop/desktop_shell.dart';
import '../core/host_routes.dart';
import '../core/theme.dart';
import '../state/daemon_lifecycle_provider.dart';
import '../state/daemon_providers.dart';
import '../state/host_registry_provider.dart';

class SettingsShell extends StatelessWidget {
  const SettingsShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Paseo keeps the compact settings root as a full-screen list. Desktop
    // uses the split sidebar shell and redirects /settings to /general.
    if (!isDesktopShell && GoRouterState.of(context).uri.path == '/settings') {
      return child;
    }
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

/// Compatibility landing route for the old `/settings/daemon` deep link.
/// Paseo waits for host/bootstrap state before choosing the managed host view.
class SettingsDaemonRedirectScreen extends ConsumerStatefulWidget {
  const SettingsDaemonRedirectScreen({super.key});

  @override
  ConsumerState<SettingsDaemonRedirectScreen> createState() =>
      _SettingsDaemonRedirectScreenState();
}

class _SettingsDaemonRedirectScreenState
    extends ConsumerState<SettingsDaemonRedirectScreen> {
  String? _scheduledTarget;

  void _redirect(String target) {
    if (_scheduledTarget == target) return;
    _scheduledTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.replace(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(hostRegistryProvider);
    final lifecycle = ref.watch(daemonLifecycleProvider);
    final desktopServerId = ref.watch(desktopManagedDaemonServerIdProvider);

    if (!registry.loaded || lifecycle.isLoading) {
      return const Center(
        child: ProgressRing(key: ValueKey('settings-bootstrap-loading')),
      );
    }

    final target =
        desktopServerId != null &&
            registry.hosts.any((host) => host.serverId == desktopServerId)
        ? buildSettingsHostSectionRoute(desktopServerId, HostSectionSlug.host)
        : buildSettingsRoute();
    _redirect(target);
    return const Center(
      child: ProgressRing(key: ValueKey('settings-bootstrap-redirecting')),
    );
  }
}

class _SettingsSidebar extends StatelessWidget {
  const _SettingsSidebar();

  @override
  Widget build(BuildContext context) {
    final serverId = GoRouterState.of(context).pathParameters['serverId'];
    if (serverId != null) {
      return _HostSettingsSidebar(serverId: serverId);
    }
    final currentSection =
        GoRouterState.of(context).pathParameters.containsKey('projectKey')
        ? 'projects'
        : GoRouterState.of(context).pathParameters['section'] ?? 'general';

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
                icon: FluentIcons.color,
                label: 'Appearance',
                section: 'appearance',
                active: currentSection == 'appearance',
              ),
              _SettingsNavItem(
                icon: FluentIcons.code,
                label: 'Editor',
                section: 'editor',
                active: currentSection == 'editor',
              ),
              _SettingsNavItem(
                icon: FluentIcons.keyboard_classic,
                label: 'Keyboard shortcuts',
                // Keep the legacy segment for embedded/test routers; the
                // application router canonicalizes it to /shortcuts.
                section: 'keyboard',
                active:
                    currentSection == 'keyboard' ||
                    currentSection == 'shortcuts',
              ),
              _SettingsNavItem(
                icon: FluentIcons.puzzle,
                label: 'Integrations',
                section: 'integrations',
                active: currentSection == 'integrations',
              ),
              _SettingsNavItem(
                icon: FluentIcons.permissions,
                label: 'Permissions',
                section: 'permissions',
                active: currentSection == 'permissions',
              ),
              _SettingsNavItem(
                icon: FluentIcons.diagnostic,
                label: 'Diagnostics',
                section: 'diagnostics',
                active: currentSection == 'diagnostics',
              ),
              _SettingsNavItem(
                icon: FluentIcons.info,
                label: 'About',
                section: 'about',
                active: currentSection == 'about',
              ),
              _SettingsNavItem(
                icon: FluentIcons.fabric_folder,
                label: 'Projects',
                section: 'projects',
                active: currentSection == 'projects',
              ),
              const _SettingsSectionLabel('Host'),
              _SettingsNavItem(
                icon: FluentIcons.settings,
                label: 'Connections',
                section: 'general',
                active: currentSection == 'general',
              ),
              _SettingsNavItem(
                icon: FluentIcons.robot,
                label: 'Agents',
                section: 'agents',
                active: currentSection == 'agents',
              ),
              _SettingsNavItem(
                icon: FluentIcons.branch_fork2,
                label: 'Workspaces',
                section: 'workspaces',
                active: currentSection == 'workspaces',
              ),
              _SettingsNavItem(
                icon: FluentIcons.command_prompt,
                label: 'Terminals',
                section: 'terminals',
                active: currentSection == 'terminals',
              ),
              _SettingsNavItem(
                icon: FluentIcons.analytics_view,
                label: 'Usage',
                section: 'usage',
                active: currentSection == 'usage',
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

class _HostSettingsSidebar extends ConsumerWidget {
  const _HostSettingsSidebar({required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(hostRegistryProvider);
    final currentSection =
        GoRouterState.of(context).pathParameters['hostSection'] ??
        'connections';
    final host = registry.hosts
        .where((candidate) => candidate.serverId == serverId)
        .firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        _SettingsHeaderRow(
          icon: FluentIcons.back,
          label: 'Back to Workspace',
          onTap: () => context.go('/h/${Uri.encodeComponent(serverId)}'),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 4),
          child: Text(
            host?.label ?? serverId,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final entry in const [
                (FluentIcons.link, 'Connections', 'connections'),
                (FluentIcons.robot, 'Agents', 'agents'),
                (FluentIcons.branch_fork2, 'Workspaces', 'workspaces'),
                (FluentIcons.cloud, 'Providers', 'providers'),
                (FluentIcons.command_prompt, 'Terminals', 'terminals'),
                (FluentIcons.settings, 'Host', 'host'),
              ])
                _SettingsNavItem(
                  icon: entry.$1,
                  label: entry.$2,
                  section: entry.$3,
                  active: currentSection == entry.$3,
                  route:
                      '/settings/hosts/${Uri.encodeComponent(serverId)}/${entry.$3}',
                ),
              const _SettingsSectionLabel('Hosts'),
              for (final candidate in registry.hosts)
                _SettingsNavItem(
                  icon: FluentIcons.server,
                  label: candidate.label,
                  section: 'connections',
                  active: candidate.serverId == serverId,
                  route:
                      '/settings/hosts/${Uri.encodeComponent(candidate.serverId)}/connections',
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
      child: Semantics(
        button: true,
        label: label,
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
    this.route,
  });

  final IconData icon;
  final String label;
  final String section;
  final bool active;
  final String? route;

  @override
  Widget build(BuildContext context) {
    final accent = FluentTheme.of(context).accentColor.normal;
    return SizedBox(
      width: double.infinity,
      child: Semantics(
        button: true,
        selected: active,
        label: label,
        child: HoverButton(
          onPressed: () => context.go(route ?? '/settings/$section'),
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
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
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
