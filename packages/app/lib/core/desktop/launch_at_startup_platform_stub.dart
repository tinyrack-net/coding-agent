import 'launch_at_startup_platform.dart';

LaunchAtStartupPlatform createPlatform() => _UnsupportedLaunchAtStartup();

final class _UnsupportedLaunchAtStartup implements LaunchAtStartupPlatform {
  @override
  void setup({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {}

  @override
  Future<bool> disable() async => false;

  @override
  Future<bool> enable() async => false;

  @override
  Future<bool> isEnabled() async => false;
}
