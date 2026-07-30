import 'package:go_router/go_router.dart';

import 'host_routes.dart';
import '../screens/home_shell.dart';
import '../screens/host_agent_route_screen.dart';
import '../screens/host_index_route_screen.dart';
import '../screens/host_open_project_route_screen.dart';
import '../screens/host_workspace_route_screen.dart';
import '../screens/host_settings_route_screen.dart';
import '../screens/new_workspace_screen.dart';
import '../screens/projects_screen.dart';
import '../screens/project_settings_screen.dart';
import '../screens/schedules_screen.dart';
import '../screens/sessions_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/settings_shell.dart';
import '../screens/status_screen.dart';
import '../state/last_workspace_route_selection.dart';

GoRouter buildAppRouter({String initialLocation = '/'}) {
  final deepLinkRoute = routeFromCodingAgentDeepLink(initialLocation);
  return GoRouter(
    initialLocation: deepLinkRoute ?? initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            HomeShell(routeLocation: state.uri.path, child: child),
        routes: [
          GoRoute(path: '/', builder: (context, state) => const HomeChatPane()),
          GoRoute(
            path: '/h/:serverId',
            builder: (context, state) => HostIndexRouteScreen(
              serverId: state.pathParameters['serverId']!,
            ),
          ),
          GoRoute(
            path: '/h/:serverId/agent/:agentId',
            builder: (context, state) => HostAgentRouteScreen(
              serverId: state.pathParameters['serverId']!,
              agentId: state.pathParameters['agentId']!,
            ),
          ),
          GoRoute(
            path: '/h/:serverId/open-project',
            builder: (context, state) => const HostOpenProjectRouteScreen(),
          ),
          GoRoute(
            path: '/h/:serverId/workspace/:workspaceId',
            builder: (context, state) {
              final workspaceId = decodeWorkspaceIdFromPathSegment(
                state.pathParameters['workspaceId']!,
              );
              if (workspaceId == null) {
                return const HomeChatPane();
              }
              final serverId = state.pathParameters['serverId']!;
              return LastWorkspaceRouteSelectionRecorder(
                serverId: serverId,
                workspaceId: workspaceId,
                child: HostWorkspaceRouteScreen(
                  serverId: serverId,
                  workspaceId: workspaceId,
                  openIntent: parseWorkspaceOpenIntent(
                    state.uri.queryParameters['open'],
                  ),
                  onOpenIntentConsumed:
                      state.uri.queryParameters.containsKey('open')
                      ? () => context.replace(
                          buildHostWorkspaceRoute(serverId, workspaceId),
                        )
                      : null,
                ),
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
            path: '/new',
            builder: (context, state) => NewWorkspaceScreen(
              initialProjectPath: state.uri.queryParameters['dir'],
            ),
          ),
          GoRoute(
            path: '/new-workspace',
            redirect: (context, state) => buildNewWorkspaceRoute(),
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
            path: '/settings/projects/:projectKey',
            builder: (context, state) => ProjectSettingsScreen(
              projectKey: state.pathParameters['projectKey']!,
            ),
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
