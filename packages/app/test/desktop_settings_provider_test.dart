import 'package:coding_agent_app/state/desktop_settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// NOTE: this test host is Windows, so `isDesktopShell` (a real
// `Platform.isWindows` check, not overridable) is true. The notifier's
// platform-plugin calls (launch_at_startup, tray) then hit unregistered
// method channels and throw `MissingPluginException`, which the notifier
// deliberately swallows — see the try/catch blocks in
// lib/state/desktop_settings_provider.dart. That lets us exercise the real
// notifier logic end-to-end without faking the plugin.

ProviderContainer makeContainer() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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
      'platform plugin is unavailable', () async {
    final container = makeContainer();
    container.read(desktopSettingsProvider); // trigger build()
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await container
        .read(desktopSettingsProvider.notifier)
        .setAutoStartAtLogin(true);

    expect(container.read(desktopSettingsProvider).autoStartAtLogin, isTrue);

    await container
        .read(desktopSettingsProvider.notifier)
        .setAutoStartAtLogin(false);

    expect(container.read(desktopSettingsProvider).autoStartAtLogin, isFalse);
  });

  test('setKeepRunningAfterQuit() updates state and persists to prefs',
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
  });

  test('a fresh notifier loads the persisted keepRunningAfterQuit value',
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
  });

  test('reset() restores defaults and clears the persisted keepRunning key',
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
    expect(
      container.read(desktopSettingsProvider).autoStartAtLogin,
      isFalse,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('desktop.keepRunningAfterQuit'), isFalse);
  });
}
