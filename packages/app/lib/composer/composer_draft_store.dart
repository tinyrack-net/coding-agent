import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../attachments/attachment_store.dart';

const composerDraftStoreVersion = 1;
const composerFinalizedDraftTtl = Duration(minutes: 5);
const newWorkspaceComposerDraftKey = 'new-workspace';

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
    this.lifecycle = ComposerDraftLifecycle.active,
    required this.updatedAt,
    this.version = composerDraftStoreVersion,
  });

  final String text;
  final List<AttachmentMetadata> images;
  final ComposerDraftLifecycle lifecycle;
  final int updatedAt;
  final int version;

  bool get hasContent => text.trim().isNotEmpty || images.isNotEmpty;

  Map<String, Object?> toJson() => {
    'text': text,
    'images': images.map((image) => image.toJson()).toList(growable: false),
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
  Future<void> clear(
    String draftKey, {
    required ComposerDraftLifecycle lifecycle,
  }) {
    return save(
      draftKey,
      ComposerDraft(
        text: '',
        images: const [],
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
