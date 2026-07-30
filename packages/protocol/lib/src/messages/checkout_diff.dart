import 'checkout_pr.dart';
import 'diff.dart';

enum CheckoutDiffMode { uncommitted, base }

final class CheckoutDiffCompare {
  const CheckoutDiffCompare({
    required this.mode,
    this.baseRef,
    this.ignoreWhitespace = false,
  });

  final CheckoutDiffMode mode;
  final String? baseRef;
  final bool ignoreWhitespace;

  factory CheckoutDiffCompare.fromJson(Map<String, Object?> json) {
    final mode = json['mode'];
    if (mode is! String) {
      throw const FormatException(
        'Checkout diff compare.mode must be a string',
      );
    }
    final baseRef = json['baseRef'];
    final ignoreWhitespace = json['ignoreWhitespace'];
    if (baseRef != null && baseRef is! String) {
      throw const FormatException(
        'Checkout diff compare.baseRef must be a string',
      );
    }
    if (ignoreWhitespace != null && ignoreWhitespace is! bool) {
      throw const FormatException(
        'Checkout diff compare.ignoreWhitespace must be a bool',
      );
    }
    return CheckoutDiffCompare(
      mode: CheckoutDiffMode.values.byName(mode),
      baseRef: baseRef as String?,
      ignoreWhitespace: ignoreWhitespace as bool? ?? false,
    ).normalized();
  }

  CheckoutDiffCompare normalized() => switch (mode) {
    CheckoutDiffMode.uncommitted => CheckoutDiffCompare(
      mode: mode,
      ignoreWhitespace: ignoreWhitespace,
    ),
    CheckoutDiffMode.base => CheckoutDiffCompare(
      mode: mode,
      baseRef: switch (baseRef?.trim()) {
        final value? when value.isNotEmpty => value,
        _ => null,
      },
      ignoreWhitespace: ignoreWhitespace,
    ),
  };

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    if (mode == CheckoutDiffMode.base && baseRef != null) 'baseRef': baseRef,
    if (ignoreWhitespace) 'ignoreWhitespace': true,
  };
}

enum CheckoutDiffLineType { add, remove, context, header }

final class CheckoutDiffToken {
  const CheckoutDiffToken({required this.text, required this.style});

  final String text;
  final String? style;

  factory CheckoutDiffToken.fromJson(Map<String, Object?> json) =>
      CheckoutDiffToken(
        text: _requiredString(json, 'text'),
        style: _nullableString(json, 'style'),
      );

  Map<String, Object?> toJson() => {'text': text, 'style': style};
}

final class CheckoutDiffLine {
  const CheckoutDiffLine({
    required this.type,
    required this.content,
    this.tokens,
  });

  final CheckoutDiffLineType type;
  final String content;
  final List<CheckoutDiffToken>? tokens;

  factory CheckoutDiffLine.fromJson(Map<String, Object?> json) =>
      CheckoutDiffLine(
        type: CheckoutDiffLineType.values.byName(_requiredString(json, 'type')),
        content: _requiredString(json, 'content'),
        tokens: json['tokens'] == null
            ? null
            : _maps(json, 'tokens').map(CheckoutDiffToken.fromJson).toList(),
      );

  Map<String, Object?> toJson() => {
    'type': type.name,
    'content': content,
    if (tokens != null)
      'tokens': tokens!.map((token) => token.toJson()).toList(),
  };
}

final class CheckoutDiffHunk {
  const CheckoutDiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<CheckoutDiffLine> lines;

  factory CheckoutDiffHunk.fromJson(Map<String, Object?> json) =>
      CheckoutDiffHunk(
        oldStart: _requiredInt(json, 'oldStart'),
        oldCount: _requiredInt(json, 'oldCount'),
        newStart: _requiredInt(json, 'newStart'),
        newCount: _requiredInt(json, 'newCount'),
        lines: _maps(json, 'lines').map(CheckoutDiffLine.fromJson).toList(),
      );

  Map<String, Object?> toJson() => {
    'oldStart': oldStart,
    'oldCount': oldCount,
    'newStart': newStart,
    'newCount': newCount,
    'lines': lines.map((line) => line.toJson()).toList(),
  };
}

enum CheckoutDiffFileStatus { ok, too_large, binary }

final class CheckoutDiffFile {
  const CheckoutDiffFile({
    required this.path,
    required this.isNew,
    required this.isDeleted,
    required this.additions,
    required this.deletions,
    required this.hunks,
    this.status,
  });

  final String path;
  final bool isNew;
  final bool isDeleted;
  final int additions;
  final int deletions;
  final List<CheckoutDiffHunk> hunks;
  final CheckoutDiffFileStatus? status;

  factory CheckoutDiffFile.fromJson(Map<String, Object?> json) =>
      CheckoutDiffFile(
        path: _requiredString(json, 'path'),
        isNew: _requiredBool(json, 'isNew'),
        isDeleted: _requiredBool(json, 'isDeleted'),
        additions: _requiredInt(json, 'additions'),
        deletions: _requiredInt(json, 'deletions'),
        hunks: _maps(json, 'hunks').map(CheckoutDiffHunk.fromJson).toList(),
        status: json['status'] == null
            ? null
            : CheckoutDiffFileStatus.values.byName(
                _requiredString(json, 'status'),
              ),
      );

  Map<String, Object?> toJson() => {
    'path': path,
    'isNew': isNew,
    'isDeleted': isDeleted,
    'additions': additions,
    'deletions': deletions,
    'hunks': hunks.map((hunk) => hunk.toJson()).toList(),
    if (status != null) 'status': status!.name,
  };
}

final class SubscribeCheckoutDiffRequest {
  const SubscribeCheckoutDiffRequest({
    required this.subscriptionId,
    required this.cwd,
    required this.compare,
    required this.requestId,
  });

  static const type = 'subscribe_checkout_diff_request';
  final String subscriptionId;
  final String cwd;
  final CheckoutDiffCompare compare;
  final String requestId;

  factory SubscribeCheckoutDiffRequest.fromJson(Map<String, Object?> json) =>
      SubscribeCheckoutDiffRequest(
        subscriptionId: _requiredString(json, 'subscriptionId'),
        cwd: _requiredString(json, 'cwd'),
        compare: CheckoutDiffCompare.fromJson(_requiredMap(json, 'compare')),
        requestId: _requiredString(json, 'requestId'),
      );

  Map<String, Object?> toJson() => {
    'type': type,
    'subscriptionId': subscriptionId,
    'cwd': cwd,
    'compare': compare.normalized().toJson(),
    'requestId': requestId,
  };
}

final class UnsubscribeCheckoutDiffRequest {
  const UnsubscribeCheckoutDiffRequest({required this.subscriptionId});

  static const type = 'unsubscribe_checkout_diff_request';
  final String subscriptionId;

  factory UnsubscribeCheckoutDiffRequest.fromJson(Map<String, Object?> json) =>
      UnsubscribeCheckoutDiffRequest(
        subscriptionId: _requiredString(json, 'subscriptionId'),
      );

  Map<String, Object?> toJson() => {
    'type': type,
    'subscriptionId': subscriptionId,
  };
}

final class CheckoutDiffPayload {
  const CheckoutDiffPayload({
    required this.subscriptionId,
    required this.cwd,
    required this.files,
    required this.error,
  });

  final String subscriptionId;
  final String cwd;
  final List<CheckoutDiffFile> files;
  final CheckoutError? error;

  factory CheckoutDiffPayload.fromJson(Map<String, Object?> json) =>
      CheckoutDiffPayload(
        subscriptionId: _requiredString(json, 'subscriptionId'),
        cwd: _requiredString(json, 'cwd'),
        files: _maps(json, 'files').map(CheckoutDiffFile.fromJson).toList(),
        error: json['error'] == null
            ? null
            : CheckoutError.fromJson(_requiredMap(json, 'error')),
      );

  Map<String, Object?> toJson() => {
    'subscriptionId': subscriptionId,
    'cwd': cwd,
    'files': files.map((file) => file.toJson()).toList(),
    'error': error?.toJson(),
  };

  DiffResponse toLegacyDiff() =>
      DiffResponse(files: files.map(_toLegacyFile).toList());
}

final class SubscribeCheckoutDiffResponse {
  const SubscribeCheckoutDiffResponse({
    required this.payload,
    required this.requestId,
  });

  static const type = 'subscribe_checkout_diff_response';
  final CheckoutDiffPayload payload;
  final String requestId;

  factory SubscribeCheckoutDiffResponse.fromJson(Map<String, Object?> json) {
    final raw = _requiredMap(json, 'payload');
    return SubscribeCheckoutDiffResponse(
      payload: CheckoutDiffPayload.fromJson(raw),
      requestId: _requiredString(raw, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {...payload.toJson(), 'requestId': requestId},
  };
}

final class CheckoutDiffUpdate {
  const CheckoutDiffUpdate(this.payload);

  static const type = 'checkout_diff_update';
  final CheckoutDiffPayload payload;

  factory CheckoutDiffUpdate.fromJson(Map<String, Object?> json) =>
      CheckoutDiffUpdate(
        CheckoutDiffPayload.fromJson(_requiredMap(json, 'payload')),
      );

  Map<String, Object?> toJson() => {'type': type, 'payload': payload.toJson()};
}

CheckoutDiffPayload checkoutDiffPayloadFromLegacy({
  required String subscriptionId,
  required String cwd,
  required DiffResponse diff,
  CheckoutError? error,
}) => CheckoutDiffPayload(
  subscriptionId: subscriptionId,
  cwd: cwd,
  files: diff.files.map(_fromLegacyFile).toList()
    ..sort((left, right) => left.path.compareTo(right.path)),
  error: error,
);

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

CheckoutDiffFile _fromLegacyFile(DiffFile file) => CheckoutDiffFile(
  path: file.path,
  isNew: file.status == DiffFileStatus.added,
  isDeleted: file.status == DiffFileStatus.deleted,
  additions: file.additions,
  deletions: file.deletions,
  status: file.binary
      ? CheckoutDiffFileStatus.binary
      : file.tooLarge
      ? CheckoutDiffFileStatus.too_large
      : CheckoutDiffFileStatus.ok,
  hunks: file.hunks.map((hunk) {
    final match = _hunkHeader.firstMatch(hunk.header);
    return CheckoutDiffHunk(
      oldStart: int.tryParse(match?.group(1) ?? '') ?? 0,
      oldCount: int.tryParse(match?.group(2) ?? '') ?? 1,
      newStart: int.tryParse(match?.group(3) ?? '') ?? 0,
      newCount: int.tryParse(match?.group(4) ?? '') ?? 1,
      lines: [
        CheckoutDiffLine(
          type: CheckoutDiffLineType.header,
          content: hunk.header,
        ),
        ...hunk.lines.map(
          (line) => CheckoutDiffLine(
            type: switch (line.type) {
              DiffLineType.add => CheckoutDiffLineType.add,
              DiffLineType.del => CheckoutDiffLineType.remove,
              DiffLineType.context => CheckoutDiffLineType.context,
            },
            content: line.text,
          ),
        ),
      ],
    );
  }).toList(),
);

DiffFile _toLegacyFile(CheckoutDiffFile file) => DiffFile(
  path: file.path,
  status: file.isNew
      ? DiffFileStatus.added
      : file.isDeleted
      ? DiffFileStatus.deleted
      : DiffFileStatus.modified,
  binary: file.status == CheckoutDiffFileStatus.binary,
  tooLarge: file.status == CheckoutDiffFileStatus.too_large,
  additions: file.additions,
  deletions: file.deletions,
  hunks: file.hunks.map((hunk) {
    var oldLine = hunk.oldStart;
    var newLine = hunk.newStart;
    final header = hunk.lines
        .where((line) => line.type == CheckoutDiffLineType.header)
        .map((line) => line.content)
        .firstOrNull;
    final lines = <DiffLine>[];
    for (final line in hunk.lines) {
      if (line.type == CheckoutDiffLineType.header) continue;
      switch (line.type) {
        case CheckoutDiffLineType.add:
          lines.add(
            DiffLine(
              type: DiffLineType.add,
              text: line.content,
              newLineNo: newLine++,
            ),
          );
        case CheckoutDiffLineType.remove:
          lines.add(
            DiffLine(
              type: DiffLineType.del,
              text: line.content,
              oldLineNo: oldLine++,
            ),
          );
        case CheckoutDiffLineType.context:
          lines.add(
            DiffLine(
              type: DiffLineType.context,
              text: line.content,
              oldLineNo: oldLine++,
              newLineNo: newLine++,
            ),
          );
        case CheckoutDiffLineType.header:
          break;
      }
    }
    return DiffHunk(
      header:
          header ??
          '@@ -${hunk.oldStart},${hunk.oldCount} +${hunk.newStart},${hunk.newCount} @@',
      lines: lines,
    );
  }).toList(),
);

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

List<Map<String, Object?>> _maps(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be an array');
  return value.map((item) {
    if (item is! Map) throw FormatException('$key items must be objects');
    return Map<String, Object?>.from(item);
  }).toList();
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value != null && value is! String) {
    throw FormatException('$key must be a string or null');
  }
  return value as String?;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a bool');
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite || value != value.roundToDouble()) {
    throw FormatException('$key must be an integer');
  }
  return value.toInt();
}
