import 'package:coding_agent_app/state/connection_settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer makeContainer() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('ConnectionSettings.uri builds a ws:// uri from host/port', () {
    const settings = ConnectionSettings(host: '192.168.1.5', port: 1234);
    expect(settings.uri, Uri.parse('ws://192.168.1.5:1234'));
  });

  test('ConnectionSettings equality is by value', () {
    const a = ConnectionSettings(host: 'h', port: 1, token: 't');
    const b = ConnectionSettings(host: 'h', port: 1, token: 't');
    const c = ConnectionSettings(host: 'h', port: 2, token: 't');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == c, isFalse);
  });

  test('build() returns defaults synchronously, before prefs load', () async {
    SharedPreferences.setMockInitialValues({
      'daemon.host': '10.0.0.2',
      'daemon.port': 9999,
    });
    final container = makeContainer();

    final initial = container.read(connectionSettingsProvider);
    expect(initial, const ConnectionSettings());

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final loaded = container.read(connectionSettingsProvider);
    expect(loaded.host, '10.0.0.2');
    expect(loaded.port, 9999);
  });

  test('build() keeps defaults when no persisted keys exist', () async {
    SharedPreferences.setMockInitialValues({});
    final container = makeContainer();

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(connectionSettingsProvider), const ConnectionSettings());
  });

  test('loads a persisted empty token as null', () async {
    SharedPreferences.setMockInitialValues({
      'daemon.host': '127.0.0.1',
      'daemon.token': '',
    });
    final container = makeContainer();

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(connectionSettingsProvider).token, isNull);
  });

  test('save() updates state immediately and persists to prefs', () async {
    SharedPreferences.setMockInitialValues({});
    final container = makeContainer();
    await Future<void>.delayed(Duration.zero);

    await container.read(connectionSettingsProvider.notifier).save(
          host: '10.1.1.1',
          port: 7000,
          token: 'secret',
        );

    final state = container.read(connectionSettingsProvider);
    expect(state.host, '10.1.1.1');
    expect(state.port, 7000);
    expect(state.token, 'secret');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('daemon.host'), '10.1.1.1');
    expect(prefs.getInt('daemon.port'), 7000);
    expect(prefs.getString('daemon.token'), 'secret');
  });

  test('save() with an empty token clears the persisted token', () async {
    SharedPreferences.setMockInitialValues({'daemon.token': 'old'});
    final container = makeContainer();
    // Trigger build() and let its internal _load() fully settle before we
    // call save(), so the two async paths don't race over `state`.
    container.read(connectionSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await container.read(connectionSettingsProvider.notifier).save(
          host: '127.0.0.1',
          port: 6868,
          token: '',
        );

    expect(container.read(connectionSettingsProvider).token, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('daemon.token'), isFalse);
  });

  test('a fresh provider instance reads persisted values back', () async {
    SharedPreferences.setMockInitialValues({});
    final firstContainer = ProviderContainer();
    firstContainer.read(connectionSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await firstContainer.read(connectionSettingsProvider.notifier).save(
          host: 'saved-host',
          port: 4321,
        );
    firstContainer.dispose();

    final container = makeContainer();
    container.read(connectionSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final loaded = container.read(connectionSettingsProvider);
    expect(loaded.host, 'saved-host');
    expect(loaded.port, 4321);
  });
}
