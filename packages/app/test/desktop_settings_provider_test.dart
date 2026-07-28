import 'package:coding_agent_app/core/desktop/launch_at_startup.dart';
import 'package:coding_agent_app/core/desktop/launch_at_startup_platform.dart';
import 'package:coding_agent_app/state/desktop_settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer makeContainer() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  late _FakeLaunchAtStartup platform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platform = _FakeLaunchAtStartup();
    launchAtStartup.debugOverridePlatform(platform);
  });

  tearDown(launchAtStartup.debugResetPlatform);

  test('build() returns defaults synchronously', () async {
    final container = makeContainer();
    final state = container.read(desktopSettingsProvider);
    expect(state.autoStartAtLogin, isFalse);
    expect(state.keepRunningAfterQuit, isTrue);
    // Let the fire-and-forget `_load()` microtask settle before the
    // container is torn down, so its (swallowed) plugin failure doesn't
    // race the next test's container disposal.
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test('DesktopSettings.copyWith keeps unspecified fields', () {
    const settings = DesktopSettings(
      autoStartAtLogin: true,
      keepRunningAfterQuit: false,
    );
    final copy = settings.copyWith();
    expect(copy.autoStartAtLogin, isTrue);
    expect(copy.keepRunningAfterQuit, isFalse);

    final flipped = settings.copyWith(autoStartAtLogin: false);
    expect(flipped.autoStartAtLogin, isFalse);
    expect(flipped.keepRunningAfterQuit, isFalse);
  });

  test('setAutoStartAtLogin() reflects the requested value even when the '
      'platform adapter is available', () async {
    final container = makeContainer();
    container.read(desktopSettingsProvider); // trigger build()
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await container
        .read(desktopSettingsProvider.notifier)
        .setAutoStartAtLogin(true);

    expect(container.read(desktopSettingsProvider).autoStartAtLogin, isTrue);
    expect(platform.enableCount, 1);

    await container
        .read(desktopSettingsProvider.notifier)
        .setAutoStartAtLogin(false);

    expect(container.read(desktopSettingsProvider).autoStartAtLogin, isFalse);
    expect(platform.disableCount, 1);
  });

  test(
    'setKeepRunningAfterQuit() updates state and persists to prefs',
    () async {
      final container = makeContainer();

      await container
          .read(desktopSettingsProvider.notifier)
          .setKeepRunningAfterQuit(false);

      expect(
        container.read(desktopSettingsProvider).keepRunningAfterQuit,
        isFalse,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('desktop.keepRunningAfterQuit'), isFalse);
    },
  );

  test(
    'a fresh notifier loads the persisted keepRunningAfterQuit value',
    () async {
      SharedPreferences.setMockInitialValues({
        'desktop.keepRunningAfterQuit': false,
      });
      final container = makeContainer();
      container.read(desktopSettingsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        container.read(desktopSettingsProvider).keepRunningAfterQuit,
        isFalse,
      );
    },
  );

  test(
    'reset() restores defaults and clears the persisted keepRunning key',
    () async {
      SharedPreferences.setMockInitialValues({
        'desktop.keepRunningAfterQuit': false,
      });
      final container = makeContainer();
      container.read(desktopSettingsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Sanity: persisted false loaded into state.
      expect(
        container.read(desktopSettingsProvider).keepRunningAfterQuit,
        isFalse,
      );

      await container.read(desktopSettingsProvider.notifier).reset();

      // Defaults restored.
      expect(
        container.read(desktopSettingsProvider).keepRunningAfterQuit,
        isTrue,
      );
      expect(container.read(desktopSettingsProvider).autoStartAtLogin, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('desktop.keepRunningAfterQuit'), isFalse);
    },
  );
}

final class _FakeLaunchAtStartup implements LaunchAtStartupPlatform {
  bool enabled = false;
  int enableCount = 0;
  int disableCount = 0;

  @override
  void setup({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {}

  @override
  Future<bool> disable() async {
    disableCount++;
    enabled = false;
    return true;
  }

  @override
  Future<bool> enable() async {
    enableCount++;
    enabled = true;
    return true;
  }

  @override
  Future<bool> isEnabled() async => enabled;
}
