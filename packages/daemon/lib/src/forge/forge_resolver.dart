import 'dart:collection';

import 'forge_adapters.dart';
import 'forge_cli.dart';
import 'git_remote.dart';

final class ForgeResolution {
  const ForgeResolution({
    required this.forge,
    required this.host,
    required this.adapter,
  });

  final String forge;
  final String host;
  final ForgeStatusAdapter adapter;
}

final class ForgeResolver {
  ForgeResolver({
    ForgeCommandTransport transport = const ProcessForgeCommandTransport(),
    DateTime Function()? now,
    this.negativeProbeTtl = const Duration(minutes: 1),
    this.maximumEntries = 512,
  }) : _transport = transport,
       _now = now ?? DateTime.now;

  final ForgeCommandTransport _transport;
  final DateTime Function() _now;
  final Duration negativeProbeTtl;
  final int maximumEntries;
  final LinkedHashMap<String, _ProbeCacheEntry> _probes = LinkedHashMap();
  final Map<String, Future<String?>> _inFlight = {};
  final Map<String, ForgeStatusAdapter> _adapters = {};

  ForgeResolution? resolveFromRemoteUrl(String? remoteUrl) {
    if (remoteUrl == null) return null;
    final location = parseGitRemoteLocation(remoteUrl);
    if (location == null) return null;
    final forge =
        forgeForKnownHost(location.host) ?? _freshProbe(location.host)?.forge;
    return forge == null ? null : _resolution(forge, location.host);
  }

  Future<ForgeResolution?> resolveFromRemoteUrlAsync(
    String? remoteUrl, {
    required String cwd,
  }) async {
    if (remoteUrl == null) return null;
    final location = parseGitRemoteLocation(remoteUrl);
    if (location == null) return null;
    final direct = forgeForKnownHost(location.host);
    if (direct != null) return _resolution(direct, location.host);
    final forge = await _probe(location.host, cwd);
    return forge == null ? null : _resolution(forge, location.host);
  }

  void invalidateHost(String host) {
    _probes.remove(normalizeGitRemoteHost(host));
  }

  ForgeResolution _resolution(String forge, String host) => ForgeResolution(
    forge: forge,
    host: host,
    adapter: _adapters.putIfAbsent(
      forge,
      () => createForgeStatusAdapter(forge, transport: _transport),
    ),
  );

  _ProbeCacheEntry? _freshProbe(String rawHost) {
    final host = normalizeGitRemoteHost(rawHost);
    final entry = _probes.remove(host);
    if (entry == null) return null;
    if (entry.expiresAt != null && !_now().isBefore(entry.expiresAt!)) {
      return null;
    }
    _probes[host] = entry;
    return entry;
  }

  Future<String?> _probe(String rawHost, String cwd) {
    final host = normalizeGitRemoteHost(rawHost);
    final cached = _freshProbe(host);
    if (cached != null) return Future.value(cached.forge);
    final existing = _inFlight[host];
    if (existing != null) return existing;
    final pending = _probeUncached(host, cwd)
        .then((forge) {
          _putProbe(
            host,
            _ProbeCacheEntry(
              forge: forge,
              expiresAt: forge == null ? _now().add(negativeProbeTtl) : null,
            ),
          );
          return forge;
        })
        .catchError((Object _) {
          _putProbe(
            host,
            _ProbeCacheEntry(
              forge: null,
              expiresAt: _now().add(negativeProbeTtl),
            ),
          );
          return null;
        })
        .whenComplete(() {
          _inFlight.remove(host);
        });
    _inFlight[host] = pending;
    return pending;
  }

  Future<String?> _probeUncached(String host, String cwd) async {
    for (final forge in const ['github', 'gitlab']) {
      final adapter = _adapters.putIfAbsent(
        forge,
        () => createForgeStatusAdapter(forge, transport: _transport),
      );
      try {
        if (await adapter.isAuthenticated(cwd: cwd, host: host)) return forge;
      } on ForgeCliException {
        // A missing or unauthenticated CLI is a negative probe for this adapter.
      }
    }
    final gitea = _adapters.putIfAbsent(
      'gitea',
      () => createForgeStatusAdapter('gitea', transport: _transport),
    );
    try {
      if (!await gitea.isAuthenticated(cwd: cwd, host: host)) return null;
    } on ForgeCliException {
      return null;
    }
    return await _detectGiteaFamily(host, cwd);
  }

  Future<String> _detectGiteaFamily(String host, String cwd) async {
    final listArgs = ['login', 'list', '-o', 'json'];
    final list = await runForgeCli(_transport, 'tea', listArgs, cwd: cwd);
    final decoded = decodeForgeJson(
      list,
      executable: 'tea',
      args: listArgs,
      cwd: cwd,
    );
    String? login;
    if (decoded is List) {
      for (final raw in decoded.whereType<Map>()) {
        final row = Map<String, Object?>.from(raw);
        final name = row['name']?.toString();
        final sshHost = row['ssh_host']?.toString();
        final urlHost = Uri.tryParse(row['url']?.toString() ?? '')?.host;
        if ([sshHost, urlHost, name].whereType<String>().any(
          (candidate) =>
              normalizeGitRemoteHost(candidate) == normalizeGitRemoteHost(host),
        )) {
          login = name;
          break;
        }
      }
    }
    if (login == null) return 'gitea';
    try {
      final result = await _transport.run(
        'tea',
        ['api', '--login', login, '-i', '/api/forgejo/v1/version'],
        cwd: cwd,
        timeout: const Duration(seconds: 5),
      );
      final status = RegExp(
        r'HTTP/\d(?:\.\d)?\s+(\d{3})',
      ).firstMatch('${result.stderr}\n${result.stdout}');
      final code = int.tryParse(status?.group(1) ?? '');
      if (code != null && code >= 200 && code < 300) return 'forgejo';
    } on ForgeCliException {
      // Inconclusive detection intentionally keeps the historical Gitea default.
    }
    return 'gitea';
  }

  void _putProbe(String host, _ProbeCacheEntry entry) {
    _probes.remove(host);
    _probes[host] = entry;
    while (_probes.length > maximumEntries) {
      _probes.remove(_probes.keys.first);
    }
  }
}

final class _ProbeCacheEntry {
  const _ProbeCacheEntry({required this.forge, required this.expiresAt});

  final String? forge;
  final DateTime? expiresAt;
}
