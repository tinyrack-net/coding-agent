import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/cli_version.dart';
import 'package:test/test.dart';

void main() {
  test('resolves and trims the frozen CLI package version', () {
    expect(resolveCliVersion(), '0.2.0');
    expect(resolveCliVersion(' 1.2.3-beta.1 '), '1.2.3-beta.1');
  });

  test('rejects missing and invalid package metadata versions', () {
    for (final value in [null, '', '   ', 2, true]) {
      expect(
        () => resolveCliVersion(value),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Unable to resolve coding-agent CLI version from package metadata.',
          ),
        ),
      );
    }
  });

  test('matches the agent_daemon package metadata', () async {
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:agent_daemon/agent_daemon.dart'),
    );
    final packageRoot = File.fromUri(library!).parent.parent;
    final pubspec = await File(
      '${packageRoot.path}${Platform.pathSeparator}pubspec.yaml',
    ).readAsString();
    final match = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull);
    expect(match!.group(1), resolveCliVersion());
  });
}
