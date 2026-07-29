import 'dart:io';

import 'desktop_launch.dart';

typedef ProjectDesktopLauncher = Future<void> Function(String projectPath);

Future<int> runOpenProjectInvocation({
  required String projectPath,
  ProjectDesktopLauncher openDesktop = launchDesktopWithProject,
  void Function(String value)? writeError,
}) async {
  try {
    await openDesktop(projectPath);
    return 0;
  } on Object catch (error) {
    (writeError ?? stderr.write)('${_message(error)}\n');
    return 1;
  }
}

String _message(Object error) => switch (error) {
  StateError(message: final message) => message,
  FileSystemException(message: final message) => message,
  _ => '$error',
};
