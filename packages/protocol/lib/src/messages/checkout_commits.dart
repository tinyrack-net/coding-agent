import 'checkout_diff.dart';
import 'checkout_pr.dart';

enum CheckoutCommitFileStatus { added, modified, deleted, renamed }

final class CheckoutCommitFile {
  const CheckoutCommitFile({
    required this.path,
    required this.additions,
    required this.deletions,
    this.status,
  });

  final String path;
  final int additions;
  final int deletions;
  final CheckoutCommitFileStatus? status;

  factory CheckoutCommitFile.fromJson(Map<String, Object?> json) =>
      CheckoutCommitFile(
        path: _string(json['path'], 'path'),
        additions: _integer(json['additions'], 'additions'),
        deletions: _integer(json['deletions'], 'deletions'),
        status: json['status'] == null
            ? null
            : CheckoutCommitFileStatus.values.byName(
                _string(json['status'], 'status'),
              ),
      );

  Map<String, Object?> toJson() => {
    'path': path,
    'additions': additions,
    'deletions': deletions,
    if (status != null) 'status': status!.name,
  };
}

/// A checkout commit. `isOnBase` remains nullable on decode because hosts
/// predating Paseo 0.2.0 emitted the otherwise-compatible legacy shape.
final class CheckoutCommit {
  const CheckoutCommit({
    required this.sha,
    required this.shortSha,
    required this.subject,
    required this.authorName,
    required this.authorDate,
    required this.isOnRemote,
    required this.files,
    this.isOnBase,
  });

  final String sha;
  final String shortSha;
  final String subject;
  final String authorName;
  final String authorDate;
  final bool isOnRemote;
  final bool? isOnBase;
  final List<CheckoutCommitFile> files;

  factory CheckoutCommit.fromJson(Map<String, Object?> json) {
    final rawIsOnBase = json['isOnBase'];
    if (rawIsOnBase != null && rawIsOnBase is! bool) {
      throw const FormatException('isOnBase must be a boolean');
    }
    return CheckoutCommit(
      sha: _string(json['sha'], 'sha'),
      shortSha: _string(json['shortSha'], 'shortSha'),
      subject: _string(json['subject'], 'subject'),
      authorName: _string(json['authorName'], 'authorName'),
      authorDate: _string(json['authorDate'], 'authorDate'),
      isOnRemote: _boolean(json['isOnRemote'], 'isOnRemote'),
      isOnBase: rawIsOnBase as bool?,
      files: _maps(
        json['files'],
        'files',
      ).map(CheckoutCommitFile.fromJson).toList(growable: false),
    );
  }

  Map<String, Object?> toJson() => {
    'sha': sha,
    'shortSha': shortSha,
    'subject': subject,
    'authorName': authorName,
    'authorDate': authorDate,
    'isOnRemote': isOnRemote,
    if (isOnBase != null) 'isOnBase': isOnBase,
    'files': files.map((file) => file.toJson()).toList(growable: false),
  };
}

final class CheckoutCommitsListRequest {
  const CheckoutCommitsListRequest({
    required this.cwd,
    required this.requestId,
  });

  static const type = 'checkout.commits.list.request';

  final String cwd;
  final String requestId;

  factory CheckoutCommitsListRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return CheckoutCommitsListRequest(
      cwd: _string(json['cwd'], 'cwd'),
      requestId: _string(json['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'requestId': requestId,
  };
}

final class CheckoutCommitsListResponse {
  const CheckoutCommitsListResponse({
    required this.cwd,
    required this.baseRef,
    required this.commits,
    required this.error,
    required this.requestId,
  });

  static const type = 'checkout.commits.list.response';

  final String cwd;
  final String? baseRef;
  final List<CheckoutCommit> commits;
  final CheckoutError? error;
  final String requestId;

  factory CheckoutCommitsListResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _map(json['payload'], 'payload');
    final rawBaseRef = payload['baseRef'];
    final rawError = payload['error'];
    if (rawBaseRef != null && rawBaseRef is! String) {
      throw const FormatException('payload.baseRef must be a string or null');
    }
    if (!payload.containsKey('error')) {
      throw const FormatException('payload.error is required');
    }
    return CheckoutCommitsListResponse(
      cwd: _string(payload['cwd'], 'payload.cwd'),
      baseRef: rawBaseRef as String?,
      commits: _maps(
        payload['commits'],
        'payload.commits',
      ).map(CheckoutCommit.fromJson).toList(growable: false),
      error: rawError == null
          ? null
          : CheckoutError.fromJson(_map(rawError, 'payload.error')),
      requestId: _string(payload['requestId'], 'payload.requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'baseRef': baseRef,
      'commits': commits
          .map((commit) => commit.toJson())
          .toList(growable: false),
      'error': error?.toJson(),
      'requestId': requestId,
    },
  };
}

final class CheckoutCommitFileDiffRequest {
  const CheckoutCommitFileDiffRequest({
    required this.cwd,
    required this.sha,
    required this.path,
    required this.requestId,
  });

  static const type = 'checkout.commits.file_diff.request';

  final String cwd;
  final String sha;
  final String path;
  final String requestId;

  factory CheckoutCommitFileDiffRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return CheckoutCommitFileDiffRequest(
      cwd: _string(json['cwd'], 'cwd'),
      sha: _string(json['sha'], 'sha'),
      path: _string(json['path'], 'path'),
      requestId: _string(json['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'sha': sha,
    'path': path,
    'requestId': requestId,
  };
}

final class CheckoutCommitFileDiffResponse {
  const CheckoutCommitFileDiffResponse({
    required this.cwd,
    required this.sha,
    required this.path,
    required this.file,
    required this.error,
    required this.requestId,
  });

  static const type = 'checkout.commits.file_diff.response';

  final String cwd;
  final String sha;
  final String path;
  final CheckoutDiffFile? file;
  final CheckoutError? error;
  final String requestId;

  factory CheckoutCommitFileDiffResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _map(json['payload'], 'payload');
    if (!payload.containsKey('file') || !payload.containsKey('error')) {
      throw const FormatException(
        'payload.file and payload.error are required',
      );
    }
    final rawFile = payload['file'];
    final rawError = payload['error'];
    return CheckoutCommitFileDiffResponse(
      cwd: _string(payload['cwd'], 'payload.cwd'),
      sha: _string(payload['sha'], 'payload.sha'),
      path: _string(payload['path'], 'payload.path'),
      file: rawFile == null
          ? null
          : CheckoutDiffFile.fromJson(_map(rawFile, 'payload.file')),
      error: rawError == null
          ? null
          : CheckoutError.fromJson(_map(rawError, 'payload.error')),
      requestId: _string(payload['requestId'], 'payload.requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'sha': sha,
      'path': path,
      'file': file?.toJson(),
      'error': error?.toJson(),
      'requestId': requestId,
    },
  };
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected $type');
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$field must be an object');
}

List<Map<String, Object?>> _maps(Object? value, String field) {
  if (value is! List) throw FormatException('$field must be an array');
  return value.map((entry) => _map(entry, '$field[]')).toList(growable: false);
}

String _string(Object? value, String field) {
  if (value is String) return value;
  throw FormatException('$field must be a string');
}

int _integer(Object? value, String field) {
  if (value is int) return value;
  throw FormatException('$field must be an integer');
}

bool _boolean(Object? value, String field) {
  if (value is bool) return value;
  throw FormatException('$field must be a boolean');
}
