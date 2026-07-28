abstract interface class LaunchAtStartupPlatform {
  void setup({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  });

  Future<bool> enable();

  Future<bool> disable();

  Future<bool> isEnabled();
}
