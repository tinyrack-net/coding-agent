import 'package:agent_daemon/src/cli/open_command.dart';
import 'package:test/test.dart';

void main() {
  test('opens the resolved project path', () async {
    String? opened;
    expect(
      await runOpenProjectInvocation(
        projectPath: r'C:\repo',
        openDesktop: (path) async => opened = path,
      ),
      0,
    );
    expect(opened, r'C:\repo');
  });

  test('prints stable desktop launch failures', () async {
    var error = '';
    expect(
      await runOpenProjectInvocation(
        projectPath: r'C:\repo',
        openDesktop: (_) async => throw StateError('desktop missing'),
        writeError: (value) => error += value,
      ),
      1,
    );
    expect(error, 'desktop missing\n');
  });
}
