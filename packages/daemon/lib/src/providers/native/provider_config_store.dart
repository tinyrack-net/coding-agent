/// Disk persistence for user-configured LLM providers.
///
/// Layout: `<dataDir>/providers.json` holding `{providers: [ProviderConfig]}`.
/// Writes are atomic (tmp file + rename), matching project_store.dart. The API
/// key for each provider lives separately in the encrypted [CredentialStore],
/// keyed by the same provider id.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class ProviderConfigStore {
  ProviderConfigStore({String? dataDir}) : dataDir = dataDir ?? defaultDataDir();

  final String dataDir;
  static const _uuid = Uuid();

  List<ProviderConfig>? _cache;

  static String defaultDataDir() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    return p.join(home, '.tinyrack-agent');
  }

  String get _filePath => p.join(dataDir, 'providers.json');

  /// All configured providers, in insertion order.
  Future<List<ProviderConfig>> list() async {
    _cache ??= await _load();
    return List.unmodifiable(_cache!);
  }

  Future<ProviderConfig?> get(String id) async {
    _cache ??= await _load();
    return _cache!.where((config) => config.id == id).firstOrNull;
  }

  /// Creates (empty or unknown [ProviderConfig.id]) or updates in place.
  /// Returns the stored config, with a generated id on create.
  Future<ProviderConfig> upsert(ProviderConfig config) async {
    _cache ??= await _load();
    final idx = config.id.isEmpty
        ? -1
        : _cache!.indexWhere((existing) => existing.id == config.id);
    final stored =
        idx >= 0 ? config : config.copyWith(id: _uuid.v4());
    if (idx >= 0) {
      _cache![idx] = stored;
    } else {
      _cache!.add(stored);
    }
    await _save();
    return stored;
  }

  /// Removes a provider. Returns whether anything was removed.
  Future<bool> delete(String id) async {
    _cache ??= await _load();
    final before = _cache!.length;
    _cache!.removeWhere((config) => config.id == id);
    if (_cache!.length == before) return false;
    await _save();
    return true;
  }

  Future<List<ProviderConfig>> _load() async {
    final file = File(_filePath);
    if (!file.existsSync()) return [];
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return ((json['providers'] as List?) ?? const [])
          .cast<Map<String, Object?>>()
          .map(ProviderConfig.fromJson)
          .where((config) => config.id.isNotEmpty)
          .toList();
    } catch (_) {
      // Corrupt store: start fresh rather than failing every request.
      return [];
    }
  }

  /// Atomic write (tmp + rename).
  Future<void> _save() async {
    final file = File(_filePath);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'providers': [
          for (final config in _cache ?? const <ProviderConfig>[])
            config.toJson(),
        ],
      }),
      flush: true,
    );
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    await tmp.rename(file.path);
  }
}
