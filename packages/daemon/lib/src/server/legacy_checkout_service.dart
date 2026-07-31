/// Paseo 0.2.0 pre-namespaced checkout compatibility handlers.
///
/// The current daemon exposes richer `checkout.*` services, but Paseo 0.2.0
/// desktop clients still send these legacy messages.  Keep the adapter small
/// and deliberately stateless: all durable state remains in Git.
library;

import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';

import '../git/git_runner.dart';
import '../git/git_service.dart';

typedef LegacyGitMutation = FutureOr<void> Function(String cwd, String action);

final class LegacyCheckoutService {
  LegacyCheckoutService({required GitService git, this.onMutation})
    : _git = git;

  static const _paseoStashPrefix = 'paseo-auto-stash:';
  final GitService _git;
  final LegacyGitMutation? onMutation;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    return switch (message['type']) {
      CheckoutCommitRequest.type => _commit(
        CheckoutCommitRequest.fromJson(message),
      ),
      ValidateBranchRequest.type => _validateBranch(
        ValidateBranchRequest.fromJson(message),
      ),
      BranchSuggestionsRequest.type => _suggestBranches(
        BranchSuggestionsRequest.fromJson(message),
      ),
      StashSaveRequest.type => _stashSave(StashSaveRequest.fromJson(message)),
      StashPopRequest.type => _stashPop(StashPopRequest.fromJson(message)),
      StashListRequest.type => _stashList(StashListRequest.fromJson(message)),
      _ => null,
    };
  }

  Future<Map<String, Object?>> _commit(CheckoutCommitRequest request) async {
    try {
      final message = request.message?.trim() ?? '';
      if (message.isEmpty) {
        throw StateError('Commit message is required');
      }
      if (request.addAll ?? true) {
        await _git.runner.run(['add', '--all'], cwd: request.cwd);
      }
      await _git.runner.run(['commit', '-m', message], cwd: request.cwd);
      await onMutation?.call(request.cwd, 'commit-changes');
      return CheckoutCommitResponse(
        cwd: request.cwd,
        success: true,
        error: null,
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return CheckoutCommitResponse(
        cwd: request.cwd,
        success: false,
        error: _checkoutError(error),
        requestId: request.requestId,
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _validateBranch(
    ValidateBranchRequest request,
  ) async {
    var exists = false;
    String? resolvedRef;
    var isRemote = false;
    String? error;
    try {
      final branch = _normalizeBranch(request.branchName);
      if (branch == null)
        throw StateError('Invalid branch: ${request.branchName}');
      final local = await _git.runner.run(
        ['rev-parse', '--verify', '--quiet', 'refs/heads/$branch'],
        cwd: request.cwd,
        check: false,
      );
      if (local.ok) {
        exists = true;
        resolvedRef = branch;
      } else {
        final remote = await _git.runner.run(
          ['rev-parse', '--verify', '--quiet', 'refs/remotes/origin/$branch'],
          cwd: request.cwd,
          check: false,
        );
        if (remote.ok) {
          exists = true;
          resolvedRef = 'origin/$branch';
          isRemote = true;
        }
      }
    } catch (caught) {
      error = _errorMessage(caught);
    }
    return ValidateBranchResponse(
      exists: exists,
      resolvedRef: resolvedRef,
      isRemote: isRemote,
      error: error,
      requestId: request.requestId,
    ).toJson();
  }

  Future<Map<String, Object?>> _suggestBranches(
    BranchSuggestionsRequest request,
  ) async {
    try {
      final query = request.query?.trim().toLowerCase() ?? '';
      final limit = request.limit ?? 50;
      final local = await _listRefs(request.cwd, 'refs/heads');
      final remote = await _listRefs(request.cwd, 'refs/remotes/origin');
      final details = <String, _BranchMeta>{};
      for (final ref in local) {
        final branch = _normalizeRefName(ref.name);
        if (branch == null) continue;
        final prior = details[branch];
        details[branch] = _BranchMeta(
          date: ref.date > (prior?.date ?? 0) ? ref.date : (prior?.date ?? 0),
          local: true,
          remote: prior?.remote ?? false,
        );
      }
      for (final ref in remote) {
        final branch = _normalizeRefName(ref.name);
        if (branch == null) continue;
        final prior = details[branch];
        details[branch] = _BranchMeta(
          date: ref.date > (prior?.date ?? 0) ? ref.date : (prior?.date ?? 0),
          local: prior?.local ?? false,
          remote: true,
        );
      }
      final names =
          details.keys
              .where(
                (name) => query.isEmpty || name.toLowerCase().contains(query),
              )
              .toList()
            ..sort((a, b) {
              if (query.isNotEmpty) {
                final ap = a.toLowerCase().startsWith(query);
                final bp = b.toLowerCase().startsWith(query);
                if (ap != bp) return ap ? -1 : 1;
              }
              final byDate = details[b]!.date.compareTo(details[a]!.date);
              return byDate != 0 ? byDate : a.compareTo(b);
            });
      final selected = names.take(limit).toList(growable: false);
      final branchDetails = [
        for (final name in selected)
          BranchSuggestionDetail(
            name: name,
            committerDate: details[name]!.date,
            hasLocal: details[name]!.local,
            hasRemote: details[name]!.remote,
          ),
      ];
      return BranchSuggestionsResponse(
        branches: selected,
        branchDetails: branchDetails,
        error: null,
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return BranchSuggestionsResponse(
        branches: const [],
        branchDetails: const [],
        error: _errorMessage(error),
        requestId: request.requestId,
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _stashSave(StashSaveRequest request) async {
    try {
      final branch = request.branch?.trim();
      final label = branch == null || branch.isEmpty ? 'unnamed' : branch;
      await _git.runner.run([
        'stash',
        'push',
        '--include-untracked',
        '-m',
        '$_paseoStashPrefix $label',
      ], cwd: request.cwd);
      await onMutation?.call(request.cwd, 'stash-push');
      return StashSaveResponse(
        cwd: request.cwd,
        success: true,
        error: null,
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return StashSaveResponse(
        cwd: request.cwd,
        success: false,
        error: _checkoutError(error),
        requestId: request.requestId,
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _stashPop(StashPopRequest request) async {
    try {
      await _git.runner.run([
        'stash',
        'pop',
        'stash@{${request.stashIndex}}',
      ], cwd: request.cwd);
      await onMutation?.call(request.cwd, 'stash-pop');
      return StashPopResponse(
        cwd: request.cwd,
        success: true,
        error: null,
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return StashPopResponse(
        cwd: request.cwd,
        success: false,
        error: _checkoutError(error),
        requestId: request.requestId,
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _stashList(StashListRequest request) async {
    try {
      final result = await _git.runner.run([
        'stash',
        'list',
        '--format=%gd%x00%s',
      ], cwd: request.cwd);
      final paseoOnly = request.paseoOnly != false;
      final entries = <StashEntry>[];
      for (final line in result.stdout.split(RegExp(r'\r?\n'))) {
        if (line.trim().isEmpty) continue;
        final separator = line.indexOf('\u0000');
        if (separator < 0) continue;
        final ref = line.substring(0, separator);
        final subject = line.substring(separator + 1);
        final match = RegExp(r'\{(\d+)\}').firstMatch(ref);
        if (match == null) continue;
        final index = int.parse(match.group(1)!);
        final prefixIndex = subject.indexOf(_paseoStashPrefix);
        final isPaseo = prefixIndex >= 0;
        if (paseoOnly && !isPaseo) continue;
        final branch = isPaseo
            ? subject.substring(prefixIndex + _paseoStashPrefix.length).trim()
            : null;
        entries.add(
          StashEntry(
            index: index,
            message: subject,
            branch: branch == null || branch.isEmpty ? null : branch,
            isPaseo: isPaseo,
          ),
        );
      }
      return StashListResponse(
        cwd: request.cwd,
        entries: entries,
        error: null,
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return StashListResponse(
        cwd: request.cwd,
        entries: const [],
        error: _checkoutError(error),
        requestId: request.requestId,
      ).toJson();
    }
  }

  Future<List<_GitRef>> _listRefs(String cwd, String prefix) async {
    final result = await _git.runner.run([
      'for-each-ref',
      '--sort=-committerdate',
      '--format=%(refname)%09%(committerdate:unix)',
      prefix,
    ], cwd: cwd);
    final refs = <_GitRef>[];
    for (final line in result.stdout.split(RegExp(r'\r?\n'))) {
      final fields = line.trim().split('\t');
      if (fields.length < 2 || fields[0].isEmpty) continue;
      refs.add(_GitRef(fields[0], int.tryParse(fields[1]) ?? 0));
    }
    return refs;
  }
}

/// Desktop editor launching is intentionally owned by the Flutter shell.  A
/// legacy daemon client still receives a typed response so the request cannot
/// hang when it connects to a headless daemon.
final class LegacyEditorService {
  static const _unsupported =
      'Editor opening moved to the desktop app and is no longer supported by the daemon';

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    switch (message['type']) {
      case ListAvailableEditorsRequest.type:
        final request = ListAvailableEditorsRequest.fromJson(message);
        return ListAvailableEditorsResponse(
          requestId: request.requestId,
          editors: const [],
          error: _unsupported,
        ).toJson();
      case OpenInEditorRequest.type:
        final request = OpenInEditorRequest.fromJson(message);
        return OpenInEditorResponse(
          requestId: request.requestId,
          error: _unsupported,
        ).toJson();
      default:
        return null;
    }
  }
}

final class _GitRef {
  const _GitRef(this.name, this.date);
  final String name;
  final int date;
}

final class _BranchMeta {
  const _BranchMeta({
    required this.date,
    required this.local,
    required this.remote,
  });
  final int date;
  final bool local;
  final bool remote;
}

String? _normalizeRefName(String raw) {
  var value = raw.trim();
  if (value.startsWith('refs/heads/')) value = value.substring(11);
  if (value.startsWith('refs/remotes/')) value = value.substring(13);
  if (value.startsWith('origin/')) value = value.substring(7);
  if (value.isEmpty || value == 'HEAD' || value == 'origin') return null;
  return value;
}

String? _normalizeBranch(String raw) {
  final value = _normalizeRefName(raw);
  if (value == null ||
      value.length > 255 ||
      value.contains('..') ||
      value.contains(' ') ||
      value.contains('~') ||
      value.contains('^') ||
      value.contains(':') ||
      value.contains('?') ||
      value.contains('*') ||
      value.contains('[') ||
      value.startsWith('/') ||
      value.endsWith('/') ||
      value.endsWith('.lock')) {
    return null;
  }
  return value;
}

CheckoutError _checkoutError(Object error) {
  final message = _errorMessage(error);
  final lower = message.toLowerCase();
  final code = lower.contains('not a git repository')
      ? CheckoutErrorCode.notGitRepo
      : lower.contains('conflict')
      ? CheckoutErrorCode.mergeConflict
      : CheckoutErrorCode.unknown;
  return CheckoutError(code: code, message: message);
}

String _errorMessage(Object error) => error is GitException
    ? error.message
    : '$error'.replaceFirst(RegExp(r'^[^:]+Exception: '), '');
