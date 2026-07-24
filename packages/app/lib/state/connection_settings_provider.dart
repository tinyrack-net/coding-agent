import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the app connects to the daemon (persisted, editable in settings).
class ConnectionSettings {
  const ConnectionSettings({
    this.host = '127.0.0.1',
    this.port = 6868,
    this.token,
  });

  final String host;
  final int port;
  final String? token;

  Uri get uri => Uri(scheme: 'ws', host: host, port: port);

  @override
  bool operator ==(Object other) =>
      other is ConnectionSettings &&
      other.host == host &&
      other.port == port &&
      other.token == token;

  @override
  int get hashCode => Object.hash(host, port, token);
}

/// Loads persisted settings on startup and saves edits from the settings UI.
class ConnectionSettingsNotifier extends Notifier<ConnectionSettings> {
  static const _hostKey = 'daemon.host';
  static const _portKey = 'daemon.port';
  static const _tokenKey = 'daemon.token';

  @override
  ConnectionSettings build() {
    Future.microtask(_load);
    return const ConnectionSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final host = prefs.getString(_hostKey);
      final port = prefs.getInt(_portKey);
      final token = prefs.getString(_tokenKey);
      if (host == null && port == null && token == null) return;
      state = ConnectionSettings(
        host: host ?? state.host,
        port: port ?? state.port,
        token: token == null || token.isEmpty ? null : token,
      );
    } catch (_) {
      // Keep defaults when the platform store is unavailable.
    }
  }

  Future<void> save({
    required String host,
    required int port,
    String? token,
  }) async {
    final normalizedToken = token == null || token.isEmpty ? null : token;
    state = ConnectionSettings(host: host, port: port, token: normalizedToken);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_hostKey, host);
      await prefs.setInt(_portKey, port);
      if (normalizedToken == null) {
        await prefs.remove(_tokenKey);
      } else {
        await prefs.setString(_tokenKey, normalizedToken);
      }
    } catch (_) {
      // Settings still apply for this session even if persistence fails.
    }
  }
}

final connectionSettingsProvider =
    NotifierProvider<ConnectionSettingsNotifier, ConnectionSettings>(
  ConnectionSettingsNotifier.new,
);
