import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../attachments/attachment_store.dart';

const composerDraftStoreVersion = 1;
const composerFinalizedDraftTtl = Duration(minutes: 5);
const newWorkspaceComposerDraftKey = 'new-workspace';

enum ComposerWorkspaceFileSelectionKind { wholeFile, lineRange }

/// The selection attached to a workspace file in Paseo's composer.
///
/// A whole file and a line range are intentionally different attachments.  A
/// user can therefore add the same file once for broad context and once for a
/// focused review without one pill silently replacing the other.
final class ComposerWorkspaceFileSelection {
  const ComposerWorkspaceFileSelection.wholeFile()
    : kind = ComposerWorkspaceFileSelectionKind.wholeFile,
      startLine = null,
      endLine = null;

  const ComposerWorkspaceFileSelection._lineRange({
    required this.startLine,
    required this.endLine,
  }) : kind = ComposerWorkspaceFileSelectionKind.lineRange;

  factory ComposerWorkspaceFileSelection.lineRange({
    required int startLine,
    required int endLine,
  }) {
    if (startLine <= 0 || endLine < startLine) {
      throw ArgumentError('Workspace file line range is invalid');
    }
    return ComposerWorkspaceFileSelection._lineRange(
      startLine: startLine,
      endLine: endLine,
    );
  }

  final ComposerWorkspaceFileSelectionKind kind;
  final int? startLine;
  final int? endLine;

  static const wholeFileSelection = ComposerWorkspaceFileSelection.wholeFile();

  String get wireKind => kind == ComposerWorkspaceFileSelectionKind.wholeFile
      ? 'whole_file'
      : 'line_range';

  String get key => kind == ComposerWorkspaceFileSelectionKind.wholeFile
      ? 'whole_file'
      : 'line_range:$startLine-$endLine';

  Map<String, Object?> toJson() =>
      kind == ComposerWorkspaceFileSelectionKind.wholeFile
      ? const {'kind': 'whole_file'}
      : {'kind': 'line_range', 'startLine': startLine, 'endLine': endLine};

  factory ComposerWorkspaceFileSelection.fromJson(Object? value) {
    // Drafts written by the MVP used a string. Keep reading those records so
    // an upgrade does not drop a user's pending prompt.
    if (value == null || value == 'whole_file') return wholeFileSelection;
    if (value is! Map || value['kind'] is! String) {
      throw const FormatException('Invalid workspace file selection');
    }
    switch (value['kind']) {
      case 'whole_file':
        return wholeFileSelection;
      case 'line_range':
        final start = value['startLine'];
        final end = value['endLine'];
        if (start is! int || end is! int) {
          throw const FormatException('Invalid workspace file line range');
        }
        return ComposerWorkspaceFileSelection.lineRange(
          startLine: start,
          endLine: end,
        );
      default:
        throw const FormatException('Unknown workspace file selection');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ComposerWorkspaceFileSelection && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

final class ComposerWorkspaceFileAttachment {
  const ComposerWorkspaceFileAttachment._({
    required this.path,
    required this.selection,
  });

  factory ComposerWorkspaceFileAttachment({
    required String path,
    ComposerWorkspaceFileSelection selection =
        ComposerWorkspaceFileSelection.wholeFileSelection,
  }) {
    final normalized = path
        .trim()
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'^\./'), '');
    if (normalized.isEmpty) {
      throw ArgumentError.value(path, 'path', 'must not be empty');
    }
    return ComposerWorkspaceFileAttachment._(
      path: normalized,
      selection: selection,
    );
  }

  final String path;
  final ComposerWorkspaceFileSelection selection;

  Map<String, Object?> toJson() => {
    'path': path,
    'selection': selection.toJson(),
  };

  factory ComposerWorkspaceFileAttachment.fromJson(Map<String, Object?> json) =>
      ComposerWorkspaceFileAttachment(
        path: json['path'] as String,
        selection: ComposerWorkspaceFileSelection.fromJson(json['selection']),
      );

  @override
  bool operator ==(Object other) =>
      other is ComposerWorkspaceFileAttachment &&
      other.path == path &&
      other.selection == selection;

  @override
  int get hashCode => Object.hash(path, selection);
}

List<ComposerWorkspaceFileAttachment> appendComposerWorkspaceFile(
  List<ComposerWorkspaceFileAttachment> current,
  ComposerWorkspaceFileAttachment attachment,
) {
  if (current.contains(attachment)) return current;
  return List.unmodifiable([...current, attachment]);
}

String buildComposerDraftKey({
  required String serverId,
  required String agentId,
  String? draftId,
}) {
  final normalizedServerId = serverId.trim();
  final normalizedDraftId = draftId?.trim();
  if (normalizedServerId.isEmpty) {
    throw ArgumentError.value(serverId, 'serverId', 'must not be empty');
  }
  if (normalizedDraftId != null && normalizedDraftId.isNotEmpty) {
    return 'draft:$normalizedServerId:$normalizedDraftId';
  }
  final normalizedAgentId = agentId.trim();
  if (normalizedAgentId.isEmpty) {
    throw ArgumentError.value(agentId, 'agentId', 'must not be empty');
  }
  return 'agent:$normalizedServerId:$normalizedAgentId';
}

String buildNewWorkspaceComposerDraftKey([String? draftId]) {
  final normalized = draftId?.trim();
  return normalized == null || normalized.isEmpty
      ? newWorkspaceComposerDraftKey
      : '$newWorkspaceComposerDraftKey:draft:$normalized';
}

enum ComposerDraftLifecycle { active, abandoned, sent }

final class ComposerDraft {
  const ComposerDraft({
    required this.text,
    required this.images,
    this.workspaceFiles = const [],
    this.lifecycle = ComposerDraftLifecycle.active,
    required this.updatedAt,
    this.version = composerDraftStoreVersion,
  });

  final String text;
  final List<AttachmentMetadata> images;
  final List<ComposerWorkspaceFileAttachment> workspaceFiles;
  final ComposerDraftLifecycle lifecycle;
  final int updatedAt;
  final int version;

  bool get hasContent =>
      text.trim().isNotEmpty || images.isNotEmpty || workspaceFiles.isNotEmpty;

  Map<String, Object?> toJson() => {
    'text': text,
    'images': images.map((image) => image.toJson()).toList(growable: false),
    'workspaceFiles': workspaceFiles
        .map((attachment) => attachment.toJson())
        .toList(growable: false),
    'lifecycle': lifecycle.name,
    'updatedAt': updatedAt,
    'version': version,
  };

  factory ComposerDraft.fromJson(Map<String, Object?> json) => ComposerDraft(
    text: json['text'] as String,
    images: (json['images'] as List<Object?>)
        .map(
          (image) => AttachmentMetadata.fromJson(
            (image as Map).cast<String, Object?>(),
          ),
        )
        .toList(growable: false),
    workspaceFiles: ((json['workspaceFiles'] as List<Object?>?) ?? const [])
        .map(
          (attachment) => ComposerWorkspaceFileAttachment.fromJson(
            (attachment as Map).cast<String, Object?>(),
          ),
        )
        .toList(growable: false),
    lifecycle: ComposerDraftLifecycle.values.byName(
      json['lifecycle'] as String,
    ),
    updatedAt: json['updatedAt'] as int,
    version: json['version'] as int,
  );
}

abstract interface class ComposerDraftStore {
  Future<ComposerDraft?> load(String draftKey);

  Future<void> save(String draftKey, ComposerDraft draft);

  Future<ComposerDraft> attachWorkspaceFile(
    String draftKey,
    ComposerWorkspaceFileAttachment attachment,
  );

  Future<void> clear(
    String draftKey, {
    required ComposerDraftLifecycle lifecycle,
  });

  Future<Set<String>> collectActiveAttachmentIds();
}

final class PreferencesComposerDraftStore implements ComposerDraftStore {
  PreferencesComposerDraftStore({
    Future<SharedPreferences> Function()? preferences,
    DateTime Function()? clock,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now;

  static const _prefix = 'tinyrack.composer-draft.v1.';
  static const _indexKey = 'tinyrack.composer-draft.v1.index';
  static Future<void> _writeQueue = Future.value();

  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _clock;

  @override
  Future<ComposerDraft?> load(String draftKey) {
    return _serialize(() async {
      final preferences = await _preferences();
      final key = _storageKey(draftKey);
      final encoded = preferences.getString(key);
      if (encoded == null) return null;
      try {
        final draft = ComposerDraft.fromJson(
          (jsonDecode(encoded) as Map).cast<String, Object?>(),
        );
        if (draft.version != composerDraftStoreVersion) {
          await _removeRecordNow(preferences, key);
          return null;
        }
        if (draft.lifecycle == ComposerDraftLifecycle.active) return draft;
        final age = _clock().millisecondsSinceEpoch - draft.updatedAt;
        if (age >= composerFinalizedDraftTtl.inMilliseconds) {
          await _removeRecordNow(preferences, key);
        }
        return null;
      } catch (_) {
        await _removeRecordNow(preferences, key);
        return null;
      }
    });
  }

  @override
  Future<void> save(String draftKey, ComposerDraft draft) async {
    final key = _storageKey(draftKey);
    await _serialize(() async {
      final preferences = await _preferences();
      await preferences.setString(key, jsonEncode(draft));
      final index = preferences.getStringList(_indexKey)?.toSet() ?? {};
      if (index.add(key)) {
        await preferences.setStringList(_indexKey, index.toList()..sort());
      }
    });
  }

  @override
  Future<ComposerDraft> attachWorkspaceFile(
    String draftKey,
    ComposerWorkspaceFileAttachment attachment,
  ) {
    return _serialize(() async {
      final preferences = await _preferences();
      final key = _storageKey(draftKey);
      ComposerDraft? existing;
      final encoded = preferences.getString(key);
      if (encoded != null) {
        try {
          final candidate = ComposerDraft.fromJson(
            (jsonDecode(encoded) as Map).cast<String, Object?>(),
          );
          if (candidate.version == composerDraftStoreVersion &&
              candidate.lifecycle == ComposerDraftLifecycle.active) {
            existing = candidate;
          }
        } catch (_) {
          // Replace malformed or obsolete draft data with a valid record.
        }
      }
      final draft = ComposerDraft(
        text: existing?.text ?? '',
        images: existing?.images ?? const [],
        workspaceFiles: appendComposerWorkspaceFile(
          existing?.workspaceFiles ?? const [],
          attachment,
        ),
        updatedAt: _clock().millisecondsSinceEpoch,
      );
      await preferences.setString(key, jsonEncode(draft));
      final index = preferences.getStringList(_indexKey)?.toSet() ?? {};
      if (index.add(key)) {
        await preferences.setStringList(_indexKey, index.toList()..sort());
      }
      return draft;
    });
  }

  @override
  Future<void> clear(
    String draftKey, {
    required ComposerDraftLifecycle lifecycle,
  }) {
    return save(
      draftKey,
      ComposerDraft(
        text: '',
        images: const [],
        workspaceFiles: const [],
        lifecycle: lifecycle,
        updatedAt: _clock().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<Set<String>> collectActiveAttachmentIds() {
    return _serialize(() async {
      final preferences = await _preferences();
      final index = preferences.getStringList(_indexKey)?.toSet() ?? {};
      final retainedKeys = <String>{};
      final referencedIds = <String>{};
      final now = _clock().millisecondsSinceEpoch;
      for (final key in index) {
        final encoded = preferences.getString(key);
        if (encoded == null) continue;
        try {
          final draft = ComposerDraft.fromJson(
            (jsonDecode(encoded) as Map).cast<String, Object?>(),
          );
          if (draft.version != composerDraftStoreVersion) {
            await preferences.remove(key);
            continue;
          }
          if (draft.lifecycle == ComposerDraftLifecycle.active) {
            retainedKeys.add(key);
            referencedIds.addAll(draft.images.map((image) => image.id));
            continue;
          }
          if (now - draft.updatedAt <
              composerFinalizedDraftTtl.inMilliseconds) {
            retainedKeys.add(key);
          } else {
            await preferences.remove(key);
          }
        } catch (_) {
          await preferences.remove(key);
        }
      }
      if (retainedKeys.isEmpty) {
        await preferences.remove(_indexKey);
      } else if (retainedKeys.length != index.length) {
        await preferences.setStringList(
          _indexKey,
          retainedKeys.toList()..sort(),
        );
      }
      return referencedIds;
    });
  }

  static Future<void> _removeRecordNow(
    SharedPreferences preferences,
    String key,
  ) async {
    await preferences.remove(key);
    final index = preferences.getStringList(_indexKey)?.toSet() ?? {};
    if (!index.remove(key)) return;
    if (index.isEmpty) {
      await preferences.remove(_indexKey);
    } else {
      await preferences.setStringList(_indexKey, index.toList()..sort());
    }
  }

  static Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  static String _storageKey(String draftKey) =>
      '$_prefix${base64Url.encode(utf8.encode(draftKey)).replaceAll('=', '')}';
}
