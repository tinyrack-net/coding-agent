import 'package:go_router/go_router.dart';

import 'host_routes.dart';
import '../screens/home_shell.dart';
import '../screens/host_workspace_route_screen.dart';
import '../screens/host_settings_route_screen.dart';
import '../screens/new_workspace_screen.dart';
import '../screens/projects_screen.dart';
import '../screens/schedules_screen.dart';
import '../screens/sessions_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/settings_shell.dart';
import '../screens/status_screen.dart';

GoRouter buildAppRouter({String initialLocation = '/'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, child) => HomeShell(child: child),
        routes: [
          GoRoute(path: '/', builder: (context, state) => const HomeChatPane()),
          GoRoute(
            path: '/h/:serverId/workspace/:workspaceId',
            builder: (context, state) {
              final workspaceId = decodeWorkspaceIdFromPathSegment(
                state.pathParameters['workspaceId']!,
              );
              if (workspaceId == null) {
                return const HomeChatPane();
              }
              return HostWorkspaceRouteScreen(
                serverId: state.pathParameters['serverId']!,
                workspaceId: workspaceId,
                openIntent: parseWorkspaceOpenIntent(
                  state.uri.queryParameters['open'],
                ),
                onOpenIntentConsumed:
                    state.uri.queryParameters.containsKey('open')
                    ? () => context.replace(
                        buildHostWorkspaceRoute(
                          state.pathParameters['serverId']!,
                          workspaceId,
                        ),
                      )
                    : null,
              );
            },
          ),
          GoRoute(
            path: '/open-project',
            builder: (context, state) => const ProjectsScreen(),
          ),
          GoRoute(
            path: '/welcome',
            builder: (context, state) => const HomeChatPane(),
          ),
          GoRoute(
            path: '/new-workspace',
            builder: (context, state) => const NewWorkspaceScreen(),
          ),
          GoRoute(
            path: '/projects',
            builder: (context, state) => const ProjectsScreen(),
          ),
          GoRoute(
            path: '/status',
            builder: (context, state) => const StatusScreen(),
          ),
          GoRoute(
            path: '/schedules',
            builder: (context, state) => const SchedulesScreen(),
          ),
          GoRoute(
            path: '/sessions',
            builder: (context, state) => const SessionsScreen(),
          ),
        ],
      ),
      ShellRoute(
        builder: (context, state, child) => SettingsShell(child: child),
        routes: [
          GoRoute(
            path: '/settings',
            redirect: (context, state) => '/settings/general',
          ),
          GoRoute(
            path: '/settings/:section',
            builder: (context, state) {
              final section = state.pathParameters['section']!;
              return SettingsScreen(section: section);
            },
          ),
          GoRoute(
            path: '/settings/hosts/:serverId',
            redirect: (context, state) =>
                '/settings/hosts/${state.pathParameters['serverId']}/connections',
          ),
          GoRoute(
            path: '/settings/hosts/:serverId/:hostSection',
            builder: (context, state) => HostSettingsRouteScreen(
              serverId: state.pathParameters['serverId']!,
              section: state.pathParameters['hostSection']!,
            ),
          ),
        ],
      ),
    ],
  );
}
