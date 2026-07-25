import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app_router.dart';
import 'core/desktop/desktop_shell.dart';
import 'core/desktop/notification_service.dart';
import 'core/desktop/title_bar.dart';
import 'core/theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initDesktopShell(args);
  await NotificationService.init();
  runApp(ProviderScope(child: CodingAgentApp(router: buildAppRouter())));
}

class CodingAgentApp extends StatelessWidget {
  const CodingAgentApp({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) {
    return FluentApp.router(
      title: 'Coding Agent',
      theme: buildAppTheme(),
      themeMode: ThemeMode.dark,
      routerConfig: router,
      builder: (context, child) => AppTitleBar(child: child!),
    );
  }
}
