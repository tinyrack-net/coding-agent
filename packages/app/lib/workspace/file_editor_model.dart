import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/foundation.dart';

enum FileEditorStatus { loading, clean, dirty, saving, conflict, error }

enum FileLineSeparator {
  lf('\n'),
  crlf('\r\n'),
  cr('\r');

  const FileLineSeparator(this.value);
  final String value;
}

final class FileEditorFile {
  const FileEditorFile({
    required this.content,
    required this.hasBom,
    required this.version,
  });

  final String content;
  final bool hasBom;
  final ReadyFileVersion version;
}

abstract interface class FileEditorSession {
  Future<FileEditorFile> read();

  Future<FileWriteResult> write({
    required String content,
    required String expectedModifiedAt,
    String? expectedRevision,
  });
}

abstract interface class FileEditorClock {
  Object setTimer(VoidCallback callback, Duration delay);
  void clearTimer(Object handle);
}

final class SystemFileEditorClock implements FileEditorClock {
  const SystemFileEditorClock();

  @override
  Object setTimer(VoidCallback callback, Duration delay) =>
      Timer(delay, callback);

  @override
  void clearTimer(Object handle) => (handle as Timer).cancel();
}

@immutable
final class FileEditorSnapshot {
  const FileEditorSnapshot({
    required this.status,
    required this.content,
    required this.lineSeparator,
    required this.modified,
    required this.version,
    required this.observedVersion,
    required this.error,
  });

  final FileEditorStatus status;
  final String content;
  final FileLineSeparator lineSeparator;
  final bool modified;
  final FileVersion version;
  final FileVersion observedVersion;
  final String? error;

  FileEditorSnapshot copyWith({
    FileEditorStatus? status,
    String? content,
    FileLineSeparator? lineSeparator,
    bool? modified,
    FileVersion? version,
    FileVersion? observedVersion,
    String? error,
    bool clearError = false,
  }) => FileEditorSnapshot(
    status: status ?? this.status,
    content: content ?? this.content,
    lineSeparator: lineSeparator ?? this.lineSeparator,
    modified: modified ?? this.modified,
    version: version ?? this.version,
    observedVersion: observedVersion ?? this.observedVersion,
    error: clearError ? null : error ?? this.error,
  );
}

final class FileEditorModel extends ChangeNotifier {
  FileEditorModel({
    required FileEditorFile file,
    required this.session,
    this.clock = const SystemFileEditorClock(),
  }) : _persistedContent = file.content,
       _hasBom = file.hasBom,
       _snapshot = FileEditorSnapshot(
         status: FileEditorStatus.clean,
         content: file.content,
         lineSeparator: detectFileLineSeparator(file.content),
         modified: false,
         version: file.version,
         observedVersion: file.version,
         error: null,
       );

  final FileEditorSession session;
  final FileEditorClock clock;
  FileEditorSnapshot _snapshot;
  String _persistedContent;
  bool _hasBom;
  Object? _autosave;
  int _saveSequence = 0;
  bool _disposed = false;
  FileVersion? _observedWhileSaving;

  FileEditorSnapshot get snapshot => _snapshot;

  void edit(String content) {
    if (_disposed || content == _snapshot.content) return;
    final modified = content != _persistedContent;
    var status = modified ? FileEditorStatus.dirty : FileEditorStatus.clean;
    if (_snapshot.status == FileEditorStatus.conflict ||
        _snapshot.status == FileEditorStatus.loading) {
      status = FileEditorStatus.conflict;
    }
    _set(
      _snapshot.copyWith(
        status: status,
        content: content,
        modified: modified,
        clearError: true,
      ),
    );
    if (status == FileEditorStatus.dirty) {
      _scheduleAutosave();
    } else {
      _clearAutosave();
    }
  }

  Future<void> save() async {
    if (_disposed ||
        (_snapshot.status != FileEditorStatus.dirty &&
            _snapshot.status != FileEditorStatus.error)) {
      return;
    }
    final observed = _snapshot.observedVersion;
    if (observed is! ReadyFileVersion) {
      _enterConflict(observed);
      return;
    }
    await _performWrite(observed);
  }

  void receiveFileVersion(FileVersion version) {
    if (_disposed) return;
    if (sameFileVersion(version, _snapshot.observedVersion)) {
      if (version is ReadyFileVersion &&
          _snapshot.observedVersion is ReadyFileVersion &&
          version.revision != null &&
          (_snapshot.observedVersion as ReadyFileVersion).revision == null) {
        final current = _snapshot.version;
        _set(
          _snapshot.copyWith(
            version: current is ReadyFileVersion
                ? ReadyFileVersion(
                    cwd: current.cwd,
                    path: current.path,
                    size: current.size,
                    modifiedAt: current.modifiedAt,
                    revision: version.revision,
                  )
                : current,
            observedVersion: version,
          ),
        );
      }
      return;
    }
    _set(_snapshot.copyWith(observedVersion: version));
    if (_snapshot.status == FileEditorStatus.saving) {
      _observedWhileSaving = version;
    } else if (_snapshot.status == FileEditorStatus.clean ||
        _snapshot.status == FileEditorStatus.loading) {
      unawaited(_reloadFromDisk(version));
    } else {
      _enterConflict(version);
    }
  }

  Future<void> overwrite() async {
    if (_disposed || _snapshot.status != FileEditorStatus.conflict) return;
    final observed = _snapshot.observedVersion;
    if (observed is ReadyFileVersion) await _performWrite(observed);
  }

  Future<void> reload() => _reloadFromDisk(_snapshot.observedVersion);

  VoidCallback suspendAutosave() {
    final wasScheduled = _autosave != null;
    _clearAutosave();
    var resumed = false;
    return () {
      if (resumed || _disposed) return;
      resumed = true;
      if (wasScheduled && _snapshot.status == FileEditorStatus.dirty) {
        _scheduleAutosave();
      }
    };
  }

  Future<void> _performWrite(ReadyFileVersion expected) async {
    _clearAutosave();
    final sequence = ++_saveSequence;
    final content = _snapshot.content;
    _observedWhileSaving = null;
    _set(_snapshot.copyWith(status: FileEditorStatus.saving, clearError: true));
    FileWriteResult result;
    try {
      result = await session.write(
        content: _hasBom ? '\uFEFF$content' : content,
        expectedModifiedAt: expected.modifiedAt,
        expectedRevision: expected.revision,
      );
    } catch (error) {
      if (_disposed || sequence != _saveSequence) return;
      _set(_snapshot.copyWith(status: FileEditorStatus.error, error: '$error'));
      return;
    }
    if (_disposed || sequence != _saveSequence) return;
    switch (result) {
      case FileWriteError():
        _set(
          _snapshot.copyWith(
            status: FileEditorStatus.error,
            error: result.error,
          ),
        );
      case ConflictFileResult():
        _enterConflict(result.version);
      case WrittenFileResult():
        final written = ReadyFileVersion(
          cwd: _snapshot.version.cwd,
          path: _snapshot.version.path,
          size: result.size,
          modifiedAt: result.modifiedAt,
          revision: result.revision,
        );
        final pending = _observedWhileSaving;
        _observedWhileSaving = null;
        _persistedContent = content;
        if (pending != null && !sameFileVersion(pending, written)) {
          _set(
            _snapshot.copyWith(
              status: FileEditorStatus.conflict,
              modified: _snapshot.content != _persistedContent,
              version: written,
              observedVersion: pending,
              clearError: true,
            ),
          );
          return;
        }
        final modified = _snapshot.content != _persistedContent;
        _set(
          _snapshot.copyWith(
            status: modified ? FileEditorStatus.dirty : FileEditorStatus.clean,
            modified: modified,
            version: written,
            observedVersion: written,
            clearError: true,
          ),
        );
        if (modified) _scheduleAutosave();
    }
  }

  Future<void> _reloadFromDisk(FileVersion version) async {
    _clearAutosave();
    if (version is! ReadyFileVersion) {
      _enterConflict(version);
      return;
    }
    final sequence = ++_saveSequence;
    _set(
      _snapshot.copyWith(status: FileEditorStatus.loading, clearError: true),
    );
    try {
      final file = await session.read();
      if (_disposed ||
          sequence != _saveSequence ||
          _snapshot.status != FileEditorStatus.loading) {
        return;
      }
      _persistedContent = file.content;
      _hasBom = file.hasBom;
      _set(
        FileEditorSnapshot(
          status: FileEditorStatus.clean,
          content: file.content,
          lineSeparator: detectFileLineSeparator(file.content),
          modified: false,
          version: file.version,
          observedVersion: file.version,
          error: null,
        ),
      );
    } catch (error) {
      if (_disposed || sequence != _saveSequence) return;
      _set(_snapshot.copyWith(status: FileEditorStatus.error, error: '$error'));
    }
  }

  void _enterConflict(FileVersion version) {
    _clearAutosave();
    _set(
      _snapshot.copyWith(
        status: FileEditorStatus.conflict,
        modified: _snapshot.content != _persistedContent,
        observedVersion: version,
        error: version is ErrorFileVersion ? version.error : null,
        clearError: version is! ErrorFileVersion,
      ),
    );
  }

  void _scheduleAutosave() {
    _clearAutosave();
    _autosave = clock.setTimer(() {
      _autosave = null;
      unawaited(save());
    }, const Duration(milliseconds: 800));
  }

  void _clearAutosave() {
    final autosave = _autosave;
    if (autosave == null) return;
    clock.clearTimer(autosave);
    _autosave = null;
  }

  void _set(FileEditorSnapshot snapshot) {
    _snapshot = snapshot;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveSequence++;
    _clearAutosave();
    super.dispose();
  }
}

FileLineSeparator detectFileLineSeparator(String content) {
  for (var index = 0; index < content.length; index++) {
    final character = content.codeUnitAt(index);
    if (character == 10) return FileLineSeparator.lf;
    if (character == 13) {
      return index + 1 < content.length && content.codeUnitAt(index + 1) == 10
          ? FileLineSeparator.crlf
          : FileLineSeparator.cr;
    }
  }
  return FileLineSeparator.lf;
}

bool sameFileVersion(FileVersion left, FileVersion right) {
  if (left.runtimeType != right.runtimeType ||
      left.cwd != right.cwd ||
      left.path != right.path) {
    return false;
  }
  if (left is ReadyFileVersion && right is ReadyFileVersion) {
    if (left.revision != null && right.revision != null) {
      return left.revision == right.revision;
    }
    return left.modifiedAt == right.modifiedAt && left.size == right.size;
  }
  if (left is ErrorFileVersion && right is ErrorFileVersion) {
    return left.error == right.error;
  }
  return true;
}
