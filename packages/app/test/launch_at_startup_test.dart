import 'package:coding_agent_app/core/desktop/launch_at_startup.dart';
import 'package:coding_agent_app/core/desktop/launch_at_startup_platform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _RecordingPlatform platform;

  setUp(() {
    platform = _RecordingPlatform();
    launchAtStartup.debugOverridePlatform(platform);
  });

  tearDown(launchAtStartup.debugResetPlatform);

  test('facade preserves setup and delegates lifecycle state', () async {
    launchAtStartup.setup(
      appName: 'Coding Agent',
      appPath: r'C:\Coding Agent\coding_agent.exe',
      packageName: 'dev.tinyrack.coding_agent',
      args: const ['--hidden'],
    );
    expect(platform.appName, 'Coding Agent');
    expect(platform.appPath, r'C:\Coding Agent\coding_agent.exe');
    expect(platform.packageName, 'dev.tinyrack.coding_agent');
    expect(platform.args, ['--hidden']);

    expect(await launchAtStartup.isEnabled(), isFalse);
    expect(await launchAtStartup.enable(), isTrue);
    expect(await launchAtStartup.isEnabled(), isTrue);
    expect(await launchAtStartup.disable(), isTrue);
    expect(await launchAtStartup.isEnabled(), isFalse);
  });
}

final class _RecordingPlatform implements LaunchAtStartupPlatform {
  String? appName;
  String? appPath;
  String? packageName;
  List<String>? args;
  bool enabled = false;

  @override
  void setup({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {
    this.appName = appName;
    this.appPath = appPath;
    this.packageName = packageName;
    this.args = List.of(args);
  }

  @override
  Future<bool> disable() async {
    enabled = false;
    return true;
  }

  @override
  Future<bool> enable() async {
    enabled = true;
    return true;
  }

  @override
  Future<bool> isEnabled() async => enabled;
}
