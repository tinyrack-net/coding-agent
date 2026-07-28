import 'launch_at_startup_platform.dart';
import 'launch_at_startup_platform_stub.dart'
    if (dart.library.io) 'launch_at_startup_platform_io.dart'
    as implementation;

final class LaunchAtStartup {
  LaunchAtStartup._() : _platform = implementation.createPlatform();

  static final LaunchAtStartup instance = LaunchAtStartup._();

  LaunchAtStartupPlatform _platform;

  void setup({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {
    _platform.setup(
      appName: appName,
      appPath: appPath,
      packageName: packageName,
      args: args,
    );
  }

  Future<bool> enable() => _platform.enable();

  Future<bool> disable() => _platform.disable();

  Future<bool> isEnabled() => _platform.isEnabled();

  void debugOverridePlatform(LaunchAtStartupPlatform platform) {
    _platform = platform;
  }

  void debugResetPlatform() {
    _platform = implementation.createPlatform();
  }
}

final launchAtStartup = LaunchAtStartup.instance;
