import 'dart:collection';

import 'forge_cli.dart';
import 'forge_models.dart';
import 'forge_resolver.dart';
import 'git_remote.dart';

final class WorkspaceForgeStatusService {
  WorkspaceForgeStatusService({
    ForgeResolver? resolver,
    DateTime Function()? now,
    this.cacheTtl = const Duration(seconds: 15),
    this.maximumEntries = 256,
  }) : resolver = resolver ?? ForgeResolver(),
       _now = now ?? DateTime.now;

  final ForgeResolver resolver;
  final DateTime Function() _now;
  final Duration cacheTtl;
  final int maximumEntries;
  final LinkedHashMap<String, _ForgeCacheEntry> _cache = LinkedHashMap();

  Future<WorkspaceForgeSnapshot> load({
    required String cwd,
    required String? remoteUrl,
    required String? headRef,
    String? headSha,
    String? headRepositoryOwner,
    bool force = false,
  }) {
    if (remoteUrl == null || headRef == null) {
      return Future.value(
        WorkspaceForgeSnapshot.unavailable(
          ForgeAuthState.noRemote,
          now: _now(),
        ),
      );
    }
    final key = [
      cwd,
      remoteUrl,
      headRef,
      headSha,
      headRepositoryOwner,
    ].join('\x00');
    final cached = _cache.remove(key);
    if (!force && cached != null && _now().isBefore(cached.expiresAt)) {
      _cache[key] = cached;
      return cached.value;
    }
    final value = _loadUncached(
      cwd: cwd,
      remoteUrl: remoteUrl,
      headRef: headRef,
      headSha: headSha,
      headRepositoryOwner: headRepositoryOwner,
    );
    _cache[key] = _ForgeCacheEntry(
      value: value,
      expiresAt: _now().add(cacheTtl),
    );
    while (_cache.length > maximumEntries) {
      _cache.remove(_cache.keys.first);
    }
    value.catchError((Object _) {
      if (identical(_cache[key]?.value, value)) _cache.remove(key);
      return WorkspaceForgeSnapshot.unavailable(
        ForgeAuthState.error,
        now: _now(),
      );
    });
    return value;
  }

  void invalidate(String cwd) {
    _cache.removeWhere((key, _) => key.startsWith('$cwd\x00'));
  }

  Future<WorkspaceForgeSnapshot> _loadUncached({
    required String cwd,
    required String remoteUrl,
    required String headRef,
    String? headSha,
    String? headRepositoryOwner,
  }) async {
    final location = parseGitRemoteLocation(remoteUrl);
    if (location == null) {
      return WorkspaceForgeSnapshot.unavailable(
        ForgeAuthState.noRemote,
        now: _now(),
      );
    }
    final resolution = await resolver.resolveFromRemoteUrlAsync(
      remoteUrl,
      cwd: cwd,
    );
    if (resolution == null) {
      return WorkspaceForgeSnapshot.unavailable(
        ForgeAuthState.unauthenticated,
        forge: location.host,
        now: _now(),
      );
    }
    try {
      if (!await resolution.adapter.isAuthenticated(
        cwd: cwd,
        host: resolution.host,
      )) {
        return WorkspaceForgeSnapshot.unavailable(
          ForgeAuthState.unauthenticated,
          forge: resolution.forge,
          now: _now(),
        );
      }
    } on ForgeCliMissingException {
      return WorkspaceForgeSnapshot.unavailable(
        ForgeAuthState.cliMissing,
        forge: resolution.forge,
        now: _now(),
      );
    } on ForgeAuthenticationException {
      return WorkspaceForgeSnapshot.unavailable(
        ForgeAuthState.unauthenticated,
        forge: resolution.forge,
        now: _now(),
      );
    } on ForgeCliException catch (error) {
      return WorkspaceForgeSnapshot.unavailable(
        ForgeAuthState.error,
        forge: resolution.forge,
        error: error.message,
        now: _now(),
      );
    }

    try {
      final pullRequest = await resolution.adapter.getCurrentPullRequestStatus(
        cwd: cwd,
        headRef: headRef,
        headSha: headSha,
        headRepositoryOwner: headRepositoryOwner,
        repositoryOwner: location.owner,
        repositoryName: location.repo,
      );
      return WorkspaceForgeSnapshot(
        featuresEnabled: true,
        authState: ForgeAuthState.authenticated,
        forge: resolution.forge,
        pullRequest: pullRequest,
        error: null,
        refreshedAt: _now().toUtc().toIso8601String(),
      );
    } on ForgeCliMissingException {
      return WorkspaceForgeSnapshot.unavailable(
        ForgeAuthState.cliMissing,
        forge: resolution.forge,
        now: _now(),
      );
    } on ForgeAuthenticationException {
      return WorkspaceForgeSnapshot.unavailable(
        ForgeAuthState.unauthenticated,
        forge: resolution.forge,
        now: _now(),
      );
    } on ForgeCliException catch (error) {
      return WorkspaceForgeSnapshot(
        featuresEnabled: true,
        authState: ForgeAuthState.authenticated,
        forge: resolution.forge,
        pullRequest: null,
        error: error.message,
        refreshedAt: _now().toUtc().toIso8601String(),
      );
    } on FormatException catch (error) {
      return WorkspaceForgeSnapshot(
        featuresEnabled: true,
        authState: ForgeAuthState.authenticated,
        forge: resolution.forge,
        pullRequest: null,
        error: error.message,
        refreshedAt: _now().toUtc().toIso8601String(),
      );
    }
  }
}

final class _ForgeCacheEntry {
  const _ForgeCacheEntry({required this.value, required this.expiresAt});

  final Future<WorkspaceForgeSnapshot> value;
  final DateTime expiresAt;
}
