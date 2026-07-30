import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app_router.dart';
import 'core/desktop/agent_deep_link_source_platform.dart';
import 'core/desktop/agent_hot_route_startup.dart';
import 'core/desktop/desktop_shell.dart';
import 'core/desktop/notification_service.dart';
import 'core/desktop/title_bar.dart';
import 'core/host_routes.dart';
import 'core/theme.dart';
import 'hosts/host_chooser.dart';
import 'state/appearance_provider.dart';
import 'state/agents_provider.dart';
import 'state/daemon_providers.dart';
import 'state/providers_snapshot_lifecycle_provider.dart';
import 'state/timeline_provider.dart';
import 'state/workspace_catalog_provider.dart';
import 'widgets/app_command_center_host.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initDesktopShell(args);
  await NotificationService.init();
  final initialLocation = args
      .map(routeFromCodingAgentDeepLink)
      .whereType<String>()
      .firstOrNull;
  final router = buildAppRouter(initialLocation: initialLocation ?? '/');
  runApp(
    bindAgentHotRoutes(
      router: router,
      source: createPlatformAgentDeepLinkSource(),
      child: ProviderScope(child: CodingAgentApp(router: router)),
    ),
  );
}

class CodingAgentApp extends ConsumerWidget {
  const CodingAgentApp({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(appearanceProvider);
    // Paseo maintains one runtime/session per registered host, regardless of
    // which host route is currently active.
    ref.watch(hostRuntimeClientsProvider);
    ref.watch(agentDirectoryReplicaLifecycleProvider);
    ref.watch(timelineReplicaLifecycleProvider);
    ref.watch(workspaceCatalogReplicaLifecycleProvider);
    ref.watch(providersSnapshotReplicaLifecycleProvider);
    return FluentApp.router(
      title: 'Coding Agent',
      theme: buildAppTheme(theme, Brightness.light),
      darkTheme: buildAppTheme(theme, Brightness.dark),
      themeMode: theme == AppThemeName.auto
          ? ThemeMode.system
          : theme == AppThemeName.light
          ? ThemeMode.light
          : ThemeMode.dark,
      routerConfig: router,
      builder: (context, child) => HostChooserHost(
        child: AppCommandCenterHost(
          router: router,
          child: AppTitleBar(child: child!),
        ),
      ),
    );
  }
}
