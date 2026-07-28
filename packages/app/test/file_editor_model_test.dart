import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/workspace/file_editor_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

const _v1 = ReadyFileVersion(
  cwd: '/repo',
  path: 'notes.txt',
  size: 3,
  modifiedAt: '2026-01-01T00:00:00.000Z',
  revision: 'rev-1',
);
const _v2 = ReadyFileVersion(
  cwd: '/repo',
  path: 'notes.txt',
  size: 4,
  modifiedAt: '2026-01-01T00:00:01.000Z',
  revision: 'rev-2',
);

final class _Clock implements FileEditorClock {
  void Function()? callback;
  var cleared = false;

  @override
  void clearTimer(Object handle) {
    cleared = true;
    callback = null;
  }

  @override
  Object setTimer(void Function() callback, Duration delay) {
    expect(delay, const Duration(milliseconds: 800));
    this.callback = callback;
    return Object();
  }

  void fire() {
    final pending = callback;
    callback = null;
    pending?.call();
  }
}

final class _Session implements FileEditorSession {
  FileEditorFile file = const FileEditorFile(
    content: 'new',
    hasBom: false,
    version: _v2,
  );
  FileWriteResult result = const WrittenFileResult(
    modifiedAt: '2026-01-01T00:00:01.000Z',
    size: 4,
    revision: 'rev-2',
  );
  Object? readError;
  Object? writeError;
  Completer<FileWriteResult>? writeCompleter;
  final writes = <({String content, String modifiedAt, String? revision})>[];

  @override
  Future<FileEditorFile> read() async {
    if (readError case final error?) throw error;
    return file;
  }

  @override
  Future<FileWriteResult> write({
    required String content,
    required String expectedModifiedAt,
    String? expectedRevision,
  }) async {
    writes.add((
      content: content,
      modifiedAt: expectedModifiedAt,
      revision: expectedRevision,
    ));
    if (writeError case final error?) throw error;
    if (writeCompleter case final pending?) return pending.future;
    return result;
  }
}

FileEditorModel _model(
  _Session session,
  _Clock clock, {
  String content = 'old',
}) => FileEditorModel(
  file: FileEditorFile(content: content, hasBom: false, version: _v1),
  session: session,
  clock: clock,
);

void main() {
  test('detects line separators and compares revisions', () {
    expect(detectFileLineSeparator('a\r\nb'), FileLineSeparator.crlf);
    expect(detectFileLineSeparator('a\rb'), FileLineSeparator.cr);
    expect(detectFileLineSeparator('a\nb'), FileLineSeparator.lf);
    expect(detectFileLineSeparator('a'), FileLineSeparator.lf);
    expect(sameFileVersion(_v1, _v1), isTrue);
    expect(sameFileVersion(_v1, _v2), isFalse);
    expect(
      sameFileVersion(
        const MissingFileVersion(cwd: '/repo', path: 'x'),
        const MissingFileVersion(cwd: '/repo', path: 'x'),
      ),
      isTrue,
    );
  });

  test('edit autosaves with expected version and reaches clean', () async {
    final session = _Session();
    final clock = _Clock();
    final model = _model(session, clock);
    addTearDown(model.dispose);

    model.edit('next');
    expect(model.snapshot.status, FileEditorStatus.dirty);
    expect(model.snapshot.modified, isTrue);
    clock.fire();
    await Future<void>.delayed(Duration.zero);

    expect(session.writes.single.content, 'next');
    expect(session.writes.single.revision, 'rev-1');
    expect(model.snapshot.status, FileEditorStatus.clean);
    expect(model.snapshot.version, isA<ReadyFileVersion>());
  });

  test(
    'external updates reload clean files and conflict dirty files',
    () async {
      final session = _Session();
      final model = _model(session, _Clock());
      addTearDown(model.dispose);

      model.receiveFileVersion(_v2);
      await Future<void>.delayed(Duration.zero);
      expect(model.snapshot.content, 'new');
      expect(model.snapshot.status, FileEditorStatus.clean);

      model.edit('mine');
      model.receiveFileVersion(
        const MissingFileVersion(cwd: '/repo', path: 'notes.txt'),
      );
      expect(model.snapshot.status, FileEditorStatus.conflict);
      expect(model.snapshot.observedVersion, isA<MissingFileVersion>());
    },
  );

  test(
    'conflict can overwrite or reload and errors remain retryable',
    () async {
      final session = _Session();
      final model = _model(session, _Clock());
      addTearDown(model.dispose);

      model.edit('mine');
      model.receiveFileVersion(_v2);
      expect(model.snapshot.status, FileEditorStatus.conflict);
      await model.overwrite();
      expect(session.writes.single.revision, 'rev-2');
      expect(model.snapshot.status, FileEditorStatus.clean);

      model.edit('again');
      session.result = const ConflictFileResult(_v2);
      await model.save();
      expect(model.snapshot.status, FileEditorStatus.conflict);
      await model.reload();
      expect(model.snapshot.content, 'new');

      model.edit('failure');
      session.writeError = StateError('offline');
      await model.save();
      expect(model.snapshot.status, FileEditorStatus.error);
      expect(model.snapshot.error, contains('offline'));
      session
        ..writeError = null
        ..result = const WrittenFileResult(
          modifiedAt: '2026-01-01T00:00:02.000Z',
          size: 7,
        );
      await model.save();
      expect(model.snapshot.status, FileEditorStatus.clean);
    },
  );

  test('BOM is preserved and autosave can be suspended and resumed', () async {
    final session = _Session();
    final clock = _Clock();
    final model = FileEditorModel(
      file: const FileEditorFile(content: 'old', hasBom: true, version: _v1),
      session: session,
      clock: clock,
    );
    addTearDown(model.dispose);

    model.edit('next');
    final resume = model.suspendAutosave();
    expect(clock.callback, isNull);
    resume();
    expect(clock.callback, isNotNull);
    clock.fire();
    await Future<void>.delayed(Duration.zero);
    expect(session.writes.single.content, '\uFEFFnext');
  });

  test(
    'write result errors and reload errors preserve actionable state',
    () async {
      final session = _Session()..result = const FileWriteError('read only');
      final model = _model(session, _Clock());
      addTearDown(model.dispose);

      model.edit('mine');
      await model.save();
      expect(model.snapshot.status, FileEditorStatus.error);
      expect(model.snapshot.error, 'read only');

      session
        ..result = const WrittenFileResult(
          modifiedAt: '2026-01-01T00:00:02.000Z',
          size: 4,
        )
        ..readError = StateError('gone');
      await model.save();
      model.receiveFileVersion(_v2);
      await Future<void>.delayed(Duration.zero);
      expect(model.snapshot.status, FileEditorStatus.error);
      expect(model.snapshot.error, contains('gone'));
    },
  );

  test(
    'an update arriving during save is reconciled after the write',
    () async {
      final session = _Session()..writeCompleter = Completer<FileWriteResult>();
      final model = _model(session, _Clock());
      addTearDown(model.dispose);

      model.edit('mine');
      final saving = model.save();
      expect(model.snapshot.status, FileEditorStatus.saving);
      model.receiveFileVersion(_v2);
      session.writeCompleter!.complete(
        const WrittenFileResult(
          modifiedAt: '2026-01-01T00:00:02.000Z',
          size: 4,
          revision: 'mine',
        ),
      );
      await saving;
      expect(model.snapshot.status, FileEditorStatus.conflict);
      expect(model.snapshot.observedVersion, _v2);
    },
  );

  test(
    'same ready version can acquire a revision and fallback identity works',
    () {
      final session = _Session();
      const withoutRevision = ReadyFileVersion(
        cwd: '/repo',
        path: 'notes.txt',
        size: 3,
        modifiedAt: '2026-01-01T00:00:00.000Z',
      );
      final model = FileEditorModel(
        file: const FileEditorFile(
          content: 'old',
          hasBom: false,
          version: withoutRevision,
        ),
        session: session,
        clock: _Clock(),
      );
      addTearDown(model.dispose);

      expect(sameFileVersion(withoutRevision, _v1), isTrue);
      model.receiveFileVersion(_v1);
      expect((model.snapshot.version as ReadyFileVersion).revision, 'rev-1');
      expect(
        sameFileVersion(
          const ErrorFileVersion(cwd: '/repo', path: 'x', error: 'a'),
          const ErrorFileVersion(cwd: '/repo', path: 'x', error: 'b'),
        ),
        isFalse,
      );
    },
  );
}
