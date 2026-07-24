import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import 'exe_resolver.dart';

/// Probes which provider CLIs exist on this machine and describes them for
/// `provider.list`. Model catalogs are static for the MVP.
class ProviderRegistry {
  ProviderRegistry(this._resolver);

  final ExeResolver _resolver;
  List<ProviderInfo>? _cached;

  static const _claudeModels = [
    ProviderModel(id: 'claude-fable-5', displayName: 'Fable 5'),
    ProviderModel(id: 'claude-opus-4-8', displayName: 'Opus 4.8'),
    ProviderModel(id: 'claude-sonnet-5', displayName: 'Sonnet 5'),
    ProviderModel(id: 'claude-haiku-4-5-20251001', displayName: 'Haiku 4.5'),
  ];

  static const _codexModels = [
    ProviderModel(id: 'gpt-5.4-codex', displayName: 'GPT-5.4 Codex'),
    ProviderModel(id: 'gpt-5.4', displayName: 'GPT-5.4'),
  ];

  Future<List<ProviderInfo>> list({bool refresh = false}) async {
    if (!refresh && _cached != null) return _cached!;
    final results = await Future.wait([
      _probe(ProviderId.claude, 'claude', 'Claude Code', _claudeModels),
      _probe(ProviderId.codex, 'codex', 'Codex', _codexModels),
    ]);
    return _cached = results;
  }

  Future<ProviderInfo> _probe(
    ProviderId id,
    String command,
    String displayName,
    List<ProviderModel> models,
  ) async {
    final path = await _resolver.resolve(command);
    if (path == null) {
      return ProviderInfo(
        id: id,
        displayName: displayName,
        available: false,
        unavailableReason: '$command not found on PATH',
      );
    }
    String? version;
    try {
      final result = ExeResolver.isBatchShim(path)
          ? await Process.run('cmd', ['/c', path, '--version'])
          : await Process.run(path, ['--version']);
      if (result.exitCode == 0) {
        version = (result.stdout as String).trim().split('\n').first.trim();
      }
    } on ProcessException {
      // Executable exists but won't run; report as available=false below.
    }
    if (version == null) {
      return ProviderInfo(
        id: id,
        displayName: displayName,
        available: false,
        executablePath: path,
        unavailableReason: '$command --version failed',
      );
    }
    return ProviderInfo(
      id: id,
      displayName: displayName,
      available: true,
      executablePath: path,
      version: version,
      models: models,
    );
  }
}
