import 'package:go_router/go_router.dart';

import '../screens/home_shell.dart';
import '../screens/new_workspace_screen.dart';
import '../screens/projects_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/settings_shell.dart';
import '../screens/status_screen.dart';

GoRouter buildAppRouter() {
  return GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) => HomeShell(child: child),
        routes: [
          GoRoute(path: '/', builder: (context, state) => const HomeChatPane()),
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
        ],
      ),
    ],
  );
}
