import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../git/git_service.dart';
import 'checkout_diff_highlighter.dart';

typedef CheckoutCommitsBaseRefResolver = Future<String?> Function(String cwd);

/// Frozen Paseo 0.2.0 commit-history and per-file commit-diff boundary.
final class CheckoutCommitsService {
  CheckoutCommitsService({
    required this.git,
    required CheckoutCommitsBaseRefResolver resolveStoredBaseRef,
  }) : _resolveStoredBaseRef = resolveStoredBaseRef;

  final GitService git;
  final CheckoutCommitsBaseRefResolver _resolveStoredBaseRef;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    return switch (message['type']) {
      CheckoutCommitsListRequest.type => _list(message),
      CheckoutCommitFileDiffRequest.type => _fileDiff(message),
      _ => null,
    };
  }

  Future<Map<String, Object?>> _list(Map<String, Object?> message) async {
    final request = CheckoutCommitsListRequest.fromJson(message);
    final cwd = _expandTilde(request.cwd);
    try {
      final result = await git.listCheckoutCommits(
        cwd,
        storedBaseRef: await _resolveStoredBaseRef(cwd),
      );
      return CheckoutCommitsListResponse(
        cwd: request.cwd,
        baseRef: result.baseRef,
        commits: result.commits,
        error: null,
        requestId: request.requestId,
      ).toJson();
    } on Object catch (error) {
      return CheckoutCommitsListResponse(
        cwd: request.cwd,
        baseRef: null,
        commits: const [],
        error: CheckoutError(
          code: CheckoutErrorCode.unknown,
          message: _message(error),
        ),
        requestId: request.requestId,
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _fileDiff(Map<String, Object?> message) async {
    final request = CheckoutCommitFileDiffRequest.fromJson(message);
    try {
      _validateGitRef(request.sha, 'commit');
      _validatePath(request.path);
      final cwd = _expandTilde(request.cwd);
      var file = await git.commitFileDiff(
        cwd,
        sha: request.sha,
        path: request.path,
      );
      if (file != null) {
        final contents = await Future.wait<String?>([
          git.readFileAtRef(cwd, ref: '${request.sha}^', path: file.path),
          git.readFileAtRef(cwd, ref: request.sha, path: file.path),
        ]);
        file = highlightCheckoutDiffFile(
          file,
          oldFileContent: contents[0],
          newFileContent: contents[1],
        );
      }
      final wireFile = file == null
          ? null
          : checkoutDiffPayloadFromLegacy(
              subscriptionId: '',
              cwd: request.cwd,
              diff: DiffResponse(files: [file]),
            ).files.single;
      return CheckoutCommitFileDiffResponse(
        cwd: request.cwd,
        sha: request.sha,
        path: request.path,
        file: wireFile,
        error: null,
        requestId: request.requestId,
      ).toJson();
    } on Object catch (error) {
      return CheckoutCommitFileDiffResponse(
        cwd: request.cwd,
        sha: request.sha,
        path: request.path,
        file: null,
        error: CheckoutError(
          code: CheckoutErrorCode.unknown,
          message: _message(error),
        ),
        requestId: request.requestId,
      ).toJson();
    }
  }
}

final _safeGitRef = RegExp(r'^[A-Za-z0-9._/-]+$');

void _validateGitRef(String value, String label) {
  if (!_safeGitRef.hasMatch(value) ||
      value.contains('..') ||
      value.contains('@{')) {
    throw StateError('Invalid $label: $value');
  }
}

void _validatePath(String value) {
  if (value.isEmpty ||
      p.isAbsolute(value) ||
      value.split(RegExp(r'[/\\]')).contains('..')) {
    throw StateError('Invalid path: $value');
  }
}

String _message(Object error) =>
    '$error'.replaceFirst(RegExp(r'^[^:]+Exception: '), '');

String _expandTilde(String value) {
  if (value != '~' && !value.startsWith('~/') && !value.startsWith(r'~\')) {
    return value;
  }
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home == null || home.isEmpty) return value;
  return value == '~' ? home : p.join(home, value.substring(2));
}
