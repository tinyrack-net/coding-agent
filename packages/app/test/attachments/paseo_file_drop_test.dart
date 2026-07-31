// Contract tests for the port of Paseo 0.2.0's frozen `components/file-drop/*`
// cluster.
//
// Upstream ships no test file for any of the six modules, so every case here
// pins a contract read off the frozen source: the drag-counter arithmetic, the
// order in which a drop fans out to the sink, which drags are advertised as
// droppable, the desktop-source-wins-over-DOM attach sequence, and — for the
// two widgets — the visual contract (what shows while a drag is active, in
// which colours and at which spacing).
import 'dart:async';
import 'dart:typed_data';

import 'package:coding_agent_app/attachments/paseo_attachment_stores.dart';
import 'package:coding_agent_app/attachments/paseo_file_drop.dart';
import 'package:coding_agent_app/attachments/workspace_file_drag.dart';
import 'package:coding_agent_app/composer/composer_draft_store.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final class _FakeDataTransfer implements FileDropDataTransfer {
  _FakeDataTransfer({
    List<String>? types,
    this.files = const [],
    Map<String, String>? data,
  }) : _data = data ?? {},
       _types = types ?? (data?.keys.toList() ?? []);

  final List<String> _types;
  final Map<String, String> _data;

  @override
  final List<DroppedFile> files;

  @override
  Iterable<String> get types => _types;

  @override
  String effectAllowed = '';

  @override
  String dropEffect = '';

  @override
  String getData(String format) => _data[format] ?? '';

  @override
  void setData(String format, String data) {
    _data[format] = data;
    if (!_types.contains(format)) _types.add(format);
  }
}

final class _RecordedSink {
  final List<List<ImageAttachment>> files = [];
  final List<List<DroppedItem>> generic = [];
  final List<WorkspaceFileDragPayload> workspaceFiles = [];

  FileDropSink build({bool withGeneric = true, bool withWorkspace = true}) =>
      FileDropSink(
        onFiles: files.add,
        onGenericFiles: withGeneric ? generic.add : null,
        onWorkspaceFile: withWorkspace ? workspaceFiles.add : null,
      );
}

final class _FakePersister implements PaseoDropAttachmentPersister {
  _FakePersister({this.failOn});

  /// Persisting anything whose identity contains this string throws.
  final String? failOn;

  final List<String> fromFileUri = [];
  final List<String> fromBlob = [];
  final List<String> mimeTypes = [];
  final List<AttachmentBlob> blobs = [];

  @override
  Future<ImageAttachment> persistFromFileUri({
    required String uri,
    required String mimeType,
  }) async {
    fromFileUri.add(uri);
    mimeTypes.add(mimeType);
    if (failOn != null && uri.contains(failOn!)) {
      throw StateError('boom: $uri');
    }
    return _attachment(id: uri, mimeType: mimeType);
  }

  @override
  Future<ImageAttachment> persistFromBlob({
    required AttachmentBlob blob,
    required String mimeType,
    String? fileName,
  }) async {
    fromBlob.add(fileName ?? '');
    mimeTypes.add(mimeType);
    blobs.add(blob);
    if (failOn != null && (fileName ?? '').contains(failOn!)) {
      throw StateError('boom: $fileName');
    }
    return _attachment(id: fileName ?? '', mimeType: mimeType, name: fileName);
  }
}

ImageAttachment _attachment({
  required String id,
  required String mimeType,
  String? name,
}) => AttachmentMetadata(
  id: id,
  mimeType: mimeType,
  storageType: AttachmentStorageType.nativeFile,
  storageKey: 'key:$id',
  fileName: name,
  createdAt: 0,
);

final class _FakeDesktopSource implements PaseoDesktopDropEventSource {
  _FakeDesktopSource({
    this.available = true,
    this.throwOnAttach = false,
    this.throwOnDispose = false,
    this.disposeReturnsRejectedFuture = false,
    this.gate,
  });

  final bool available;
  final bool throwOnAttach;
  final bool throwOnDispose;
  final bool disposeReturnsRejectedFuture;

  /// When set, `attach` waits on this before resolving.
  final Future<void>? gate;

  int attachCount = 0;
  int disposeCount = 0;
  void Function(DesktopDragDropPayload)? emit;

  @override
  Future<PaseoDropListenerDisposer?> attach(
    void Function(DesktopDragDropPayload payload) onEvent,
  ) async {
    attachCount++;
    if (gate != null) await gate;
    if (throwOnAttach) throw StateError('no desktop host');
    if (!available) return null;
    emit = onEvent;
    return () {
      disposeCount++;
      if (throwOnDispose) throw StateError('unlisten failed');
      if (disposeReturnsRejectedFuture) {
        return Future<void>.error(StateError('async unlisten failed'));
      }
      return null;
    };
  }
}

final class _FakeDomSource implements PaseoDomDropEventSource {
  _FakeDomSource({this.hasElement = true});

  final bool hasElement;
  int attachCount = 0;
  int disposeCount = 0;
  PaseoDomDropHandlers? handlers;

  @override
  PaseoDropListenerDisposer? attach(PaseoDomDropHandlers handlers) {
    attachCount++;
    if (!hasElement) return null;
    this.handlers = handlers;
    return () => disposeCount++;
  }
}

final class _Diagnostics {
  final List<String> messages = [];
  final List<Object?> details = [];

  void call(String message, Object? detail) {
    messages.add(message);
    details.add(detail);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

DroppedFile _file(String name, {String type = ''}) => InMemoryDroppedFile(
  name: name,
  type: type,
  bytes: Uint8List.fromList([1, 2, 3]),
);

String _workspacePayload({
  String serverId = 'server-1',
  String workspaceId = 'ws-1',
  String path = 'lib/main.dart',
}) => serializeWorkspaceFileDragPayload(
  WorkspaceFileDragPayload(
    serverId: serverId,
    workspaceId: workspaceId,
    attachment: ComposerWorkspaceFileAttachment(path: path),
  ),
);

({
  PaseoFileDropController controller,
  PaseoDropListeners listeners,
  _RecordedSink sink,
  _FakePersister persister,
  _Diagnostics warnings,
  _Diagnostics errors,
})
_harness({
  bool disabled = false,
  bool registerSink = true,
  bool withGeneric = true,
  bool withWorkspace = true,
  String? failOn,
  PaseoDesktopDropEventSource? desktopSource,
  PaseoDomDropEventSource? domSource,
  bool dropSupported = true,
}) {
  final controller = PaseoFileDropController();
  final recorded = _RecordedSink();
  if (registerSink) {
    final sink = recorded.build(
      withGeneric: withGeneric,
      withWorkspace: withWorkspace,
    );
    controller.registerSink(() => sink);
  }
  final persister = _FakePersister(failOn: failOn);
  final warnings = _Diagnostics();
  final errors = _Diagnostics();
  final listeners = PaseoDropListeners(
    controller: controller,
    persister: persister,
    disabled: disabled,
    desktopSource: desktopSource,
    domSource: domSource,
    dropSupported: dropSupported,
    onWarn: warnings.call,
    onError: errors.call,
  );
  return (
    controller: controller,
    listeners: listeners,
    sink: recorded,
    persister: persister,
    warnings: warnings,
    errors: errors,
  );
}

Widget _zone({
  required PaseoFileDropController controller,
  bool disabled = false,
  bool dropSupported = true,
  String Function(String key)? translate,
  Widget child = const SizedBox(width: 200, height: 200),
}) => FluentApp(
  theme: buildAppTheme(),
  // Centred so the zone is handed loose constraints, the way upstream's
  // "no default flex, the caller's style owns sizing" container is.
  home: Center(
    child: PaseoFileDropZone(
      controller: controller,
      disabled: disabled,
      dropSupported: dropSupported,
      translate: translate,
      child: child,
    ),
  ),
);

double _overlayOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(find.byKey(PaseoFileDropBackdrop.overlayKey))
    .opacity;

/// The palette the pumped backdrop actually resolved, so the colour
/// expectations below read the same token the widget did.
PaseoPalette _palette(WidgetTester tester) =>
    tester.element(find.byType(PaseoFileDropBackdrop)).paseoPalette;

void main() {
  // -------------------------------------------------------------------------
  // types.ts
  // -------------------------------------------------------------------------
  group('dropped items', () {
    test('carry upstream\'s union discriminants verbatim', () {
      expect(DroppedFileItem(_file('a.png')).kind, 'web-file');
      expect(const DroppedPathItem('/tmp/a.png').kind, 'desktop-path');
    });

    test(
      'an in-memory file reports an unknown type as the empty string',
      () async {
        final file = _file('a.bin');
        expect(file.type, '');
        expect(await file.readAsBytes(), [1, 2, 3]);
      },
    );

    test('a sink may omit both optional handlers', () {
      final sink = FileDropSink(onFiles: (_) {});
      expect(sink.onGenericFiles, isNull);
      expect(sink.onWorkspaceFile, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // context.ts + the zone's sink registry
  // -------------------------------------------------------------------------
  group('controller', () {
    test('starts with every flag down and no sink', () {
      final controller = PaseoFileDropController();
      expect(controller.isDragging.value, isFalse);
      expect(controller.suppressed.value, isFalse);
      expect(controller.hasSink.value, isFalse);
      expect(controller.getSink(), isNull);
    });

    test('registering a sink raises hasSink and exposes it', () {
      final controller = PaseoFileDropController();
      final sink = FileDropSink(onFiles: (_) {});
      controller.registerSink(() => sink);
      expect(controller.hasSink.value, isTrue);
      expect(controller.getSink(), same(sink));
    });

    test('the getter is re-read on every lookup', () {
      final controller = PaseoFileDropController();
      var current = FileDropSink(onFiles: (_) {});
      controller.registerSink(() => current);
      final replacement = FileDropSink(onFiles: (_) {});
      current = replacement;
      expect(controller.getSink(), same(replacement));
    });

    test('a getter may report no sink even while registered', () {
      final controller = PaseoFileDropController();
      controller.registerSink(() => null);
      expect(controller.hasSink.value, isTrue);
      expect(controller.getSink(), isNull);
    });

    test('disposing the active registration clears hasSink', () {
      final controller = PaseoFileDropController();
      final dispose = controller.registerSink(
        () => FileDropSink(onFiles: (_) {}),
      );
      dispose();
      expect(controller.hasSink.value, isFalse);
      expect(controller.getSink(), isNull);
    });

    test('a replaced registration cannot tear down its replacement', () {
      final controller = PaseoFileDropController();
      final second = FileDropSink(onFiles: (_) {});
      final disposeFirst = controller.registerSink(
        () => FileDropSink(onFiles: (_) {}),
      );
      controller.registerSink(() => second);
      disposeFirst();
      expect(controller.hasSink.value, isTrue);
      expect(controller.getSink(), same(second));
    });
  });

  // -------------------------------------------------------------------------
  // use-file-drop.ts
  // -------------------------------------------------------------------------
  group('sink registration', () {
    test('no-ops without a zone above it', () {
      final registration = PaseoFileDropRegistration(
        controller: null,
        sink: FileDropSink(onFiles: (_) {}),
        disabled: true,
      );
      registration.disabled = false;
      registration.dispose();
      expect(registration.sink, isNotNull);
    });

    test('registers on construction', () {
      final controller = PaseoFileDropController();
      final sink = FileDropSink(onFiles: (_) {});
      PaseoFileDropRegistration(controller: controller, sink: sink);
      expect(controller.hasSink.value, isTrue);
      expect(controller.getSink(), same(sink));
    });

    test('publishes its initial disabled flag as suppression', () {
      final controller = PaseoFileDropController();
      PaseoFileDropRegistration(
        controller: controller,
        sink: FileDropSink(onFiles: (_) {}),
        disabled: true,
      );
      expect(controller.suppressed.value, isTrue);
    });

    test('reassigning the sink neither re-registers nor drops it', () {
      final controller = PaseoFileDropController();
      var registrations = 0;
      controller.hasSink.addListener(() => registrations++);
      final registration = PaseoFileDropRegistration(
        controller: controller,
        sink: FileDropSink(onFiles: (_) {}),
      );
      final replacement = FileDropSink(onFiles: (_) {});
      registration.sink = replacement;
      expect(registrations, 1);
      expect(controller.getSink(), same(replacement));
    });

    test('toggling disabled writes straight through to suppressed', () {
      final controller = PaseoFileDropController();
      final registration = PaseoFileDropRegistration(
        controller: controller,
        sink: FileDropSink(onFiles: (_) {}),
      );
      registration.disabled = true;
      expect(controller.suppressed.value, isTrue);
      registration.disabled = false;
      expect(controller.suppressed.value, isFalse);
    });

    test('dispose unregisters and un-suppresses', () {
      final controller = PaseoFileDropController();
      final registration = PaseoFileDropRegistration(
        controller: controller,
        sink: FileDropSink(onFiles: (_) {}),
        disabled: true,
      );
      registration.dispose();
      expect(controller.hasSink.value, isFalse);
      expect(controller.suppressed.value, isFalse);
    });

    test('a double dispose cannot un-suppress a later registration', () {
      final controller = PaseoFileDropController();
      final first = PaseoFileDropRegistration(
        controller: controller,
        sink: FileDropSink(onFiles: (_) {}),
      );
      first.dispose();
      PaseoFileDropRegistration(
        controller: controller,
        sink: FileDropSink(onFiles: (_) {}),
        disabled: true,
      );
      first.dispose();
      expect(controller.suppressed.value, isTrue);
      expect(controller.hasSink.value, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // use-drop-listeners.ts — DOM path
  // -------------------------------------------------------------------------
  group('dom drag enter', () {
    test('always prevents the default and stops propagation', () {
      final harness = _harness(disabled: true);
      final event = DomDragEvent(dataTransfer: _FakeDataTransfer());
      harness.listeners.handleDragEnter(event);
      expect(event.defaultPrevented, isTrue);
      expect(event.propagationStopped, isTrue);
    });

    test('raises the drag flag for an OS file drag', () {
      final harness = _harness();
      harness.listeners.handleDragEnter(
        DomDragEvent(dataTransfer: _FakeDataTransfer(types: ['Files'])),
      );
      expect(harness.controller.isDragging.value, isTrue);
    });

    test('ignores a drag carrying neither files nor a workspace file', () {
      final harness = _harness();
      harness.listeners.handleDragEnter(
        DomDragEvent(dataTransfer: _FakeDataTransfer(types: ['text/plain'])),
      );
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('raises the flag for a workspace-file drag the sink handles', () {
      final harness = _harness();
      harness.listeners.handleDragEnter(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(types: [workspaceFileDragMime]),
        ),
      );
      expect(harness.controller.isDragging.value, isTrue);
    });

    test('ignores a workspace-file drag when the sink cannot take one', () {
      final harness = _harness(withWorkspace: false);
      harness.listeners.handleDragEnter(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(types: [workspaceFileDragMime]),
        ),
      );
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('ignores everything while disabled', () {
      final harness = _harness(disabled: true);
      harness.listeners.handleDragEnter(
        DomDragEvent(dataTransfer: _FakeDataTransfer(types: ['Files'])),
      );
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('does not advertise while suppressed', () {
      final harness = _harness();
      harness.controller.suppressed.value = true;
      harness.listeners.handleDragEnter(
        DomDragEvent(dataTransfer: _FakeDataTransfer(types: ['Files'])),
      );
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('does not advertise without a registered consumer', () {
      final harness = _harness(registerSink: false);
      harness.listeners.handleDragEnter(
        DomDragEvent(dataTransfer: _FakeDataTransfer(types: ['Files'])),
      );
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('a suppressed enter still counts, so its leave balances out', () {
      final harness = _harness();
      harness.controller.suppressed.value = true;
      harness.listeners.handleDragEnter(
        DomDragEvent(dataTransfer: _FakeDataTransfer(types: ['Files'])),
      );
      harness.controller.suppressed.value = false;

      // Counter is 1: a nested enter then takes it to 2, and one leave must not
      // be enough to end the drag.
      harness.listeners.handleDragEnter(
        DomDragEvent(dataTransfer: _FakeDataTransfer(types: ['Files'])),
      );
      expect(harness.controller.isDragging.value, isTrue);
      harness.listeners.handleDragLeave(DomDragEvent());
      expect(harness.controller.isDragging.value, isTrue);
      harness.listeners.handleDragLeave(DomDragEvent());
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('tolerates a drag with no payload at all', () {
      final harness = _harness();
      harness.listeners.handleDragEnter(DomDragEvent());
      expect(harness.controller.isDragging.value, isFalse);
    });
  });

  group('dom drag over', () {
    test('advertises copy when the drop would be accepted', () {
      final harness = _harness();
      final dataTransfer = _FakeDataTransfer(types: ['Files']);
      harness.listeners.handleDragOver(
        DomDragEvent(dataTransfer: dataTransfer),
      );
      expect(dataTransfer.dropEffect, 'copy');
    });

    test('advertises none while suppressed', () {
      final harness = _harness();
      harness.controller.suppressed.value = true;
      final dataTransfer = _FakeDataTransfer(types: ['Files']);
      harness.listeners.handleDragOver(
        DomDragEvent(dataTransfer: dataTransfer),
      );
      expect(dataTransfer.dropEffect, 'none');
    });

    test('advertises none while disabled', () {
      final harness = _harness(disabled: true);
      final dataTransfer = _FakeDataTransfer(types: ['Files']);
      harness.listeners.handleDragOver(
        DomDragEvent(dataTransfer: dataTransfer),
      );
      expect(dataTransfer.dropEffect, 'none');
    });

    test('advertises none without a registered consumer', () {
      final harness = _harness(registerSink: false);
      final dataTransfer = _FakeDataTransfer(types: ['Files']);
      harness.listeners.handleDragOver(
        DomDragEvent(dataTransfer: dataTransfer),
      );
      expect(dataTransfer.dropEffect, 'none');
    });

    test('advertises none for a drag the zone does not take', () {
      final harness = _harness();
      final dataTransfer = _FakeDataTransfer(types: ['text/plain']);
      harness.listeners.handleDragOver(
        DomDragEvent(dataTransfer: dataTransfer),
      );
      expect(dataTransfer.dropEffect, 'none');
    });

    test('advertises copy for a workspace-file drag the sink handles', () {
      final harness = _harness();
      final dataTransfer = _FakeDataTransfer(types: [workspaceFileDragMime]);
      harness.listeners.handleDragOver(
        DomDragEvent(dataTransfer: dataTransfer),
      );
      expect(dataTransfer.dropEffect, 'copy');
    });

    test('advertises none for a workspace-file drag the sink cannot take', () {
      final harness = _harness(withWorkspace: false);
      final dataTransfer = _FakeDataTransfer(types: [workspaceFileDragMime]);
      harness.listeners.handleDragOver(
        DomDragEvent(dataTransfer: dataTransfer),
      );
      expect(dataTransfer.dropEffect, 'none');
    });

    test('leaves an absent payload alone', () {
      final harness = _harness();
      final event = DomDragEvent();
      harness.listeners.handleDragOver(event);
      expect(event.defaultPrevented, isTrue);
      expect(event.propagationStopped, isTrue);
    });
  });

  group('dom drag leave', () {
    test('ends the drag only when the last nested enter is balanced', () {
      final harness = _harness();
      final files = _FakeDataTransfer(types: ['Files']);
      harness.listeners.handleDragEnter(DomDragEvent(dataTransfer: files));
      harness.listeners.handleDragEnter(DomDragEvent(dataTransfer: files));
      harness.listeners.handleDragLeave(DomDragEvent());
      expect(harness.controller.isDragging.value, isTrue);
      harness.listeners.handleDragLeave(DomDragEvent());
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('ignores leaves while disabled', () {
      final harness = _harness(disabled: true);
      harness.controller.isDragging.value = true;
      harness.listeners.handleDragLeave(DomDragEvent());
      expect(harness.controller.isDragging.value, isTrue);
    });
  });

  group('dom drop', () {
    test('ends the drag and resets the counter even while disabled', () async {
      final harness = _harness(disabled: true);
      harness.controller.isDragging.value = true;
      final event = DomDragEvent(dataTransfer: _FakeDataTransfer());
      await harness.listeners.handleDrop(event);
      expect(harness.controller.isDragging.value, isFalse);
      expect(event.defaultPrevented, isTrue);
      expect(event.propagationStopped, isTrue);
      expect(harness.sink.generic, isEmpty);
    });

    test('rejects the drop while suppressed', () async {
      final harness = _harness();
      harness.controller.suppressed.value = true;
      await harness.listeners.handleDrop(
        DomDragEvent(dataTransfer: _FakeDataTransfer(files: [_file('a.png')])),
      );
      expect(harness.sink.generic, isEmpty);
      expect(harness.sink.files, isEmpty);
    });

    test('does nothing without a registered consumer', () async {
      final harness = _harness(registerSink: false);
      await harness.listeners.handleDrop(
        DomDragEvent(dataTransfer: _FakeDataTransfer(files: [_file('a.png')])),
      );
      expect(harness.persister.fromBlob, isEmpty);
    });

    test('hands every dropped file to the generic handler', () async {
      final harness = _harness();
      await harness.listeners.handleDrop(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(
            files: [_file('a.png'), _file('notes.txt')],
          ),
        ),
      );
      expect(harness.sink.generic, hasLength(1));
      expect(harness.sink.generic.single, hasLength(2));
      expect(
        harness.sink.generic.single.every((i) => i is DroppedFileItem),
        isTrue,
      );
    });

    test('skips the generic handler for an empty drop', () async {
      final harness = _harness();
      await harness.listeners.handleDrop(
        DomDragEvent(dataTransfer: _FakeDataTransfer()),
      );
      expect(harness.sink.generic, isEmpty);
    });

    test('persists raster images and forwards them to onFiles', () async {
      final harness = _harness();
      await harness.listeners.handleDrop(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(
            files: [
              _file('a.png', type: 'image/png'),
              _file('notes.txt'),
              _file('b.jpeg'),
            ],
          ),
        ),
      );
      expect(harness.persister.fromBlob, ['a.png', 'b.jpeg']);
      expect(harness.persister.mimeTypes, ['image/png', 'image/jpeg']);
      expect(harness.sink.files.single.map((a) => a.id), ['a.png', 'b.jpeg']);
    });

    test('carries the file\'s claimed media type onto the blob', () async {
      final harness = _harness();
      await harness.listeners.handleDrop(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(
            files: [_file('a.png', type: 'image/png')],
          ),
        ),
      );
      expect(harness.persister.blobs.single.type, 'image/png');
      expect(harness.persister.blobs.single.bytes, [1, 2, 3]);
    });

    test('never calls onFiles when nothing dropped was an image', () async {
      final harness = _harness();
      await harness.listeners.handleDrop(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(files: [_file('notes.txt')]),
        ),
      );
      expect(harness.sink.files, isEmpty);
      expect(harness.persister.fromBlob, isEmpty);
      expect(harness.sink.generic, hasLength(1));
    });

    test('reports a persist failure and drops the whole batch', () async {
      final harness = _harness(failOn: 'b.png');
      await harness.listeners.handleDrop(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(
            files: [_file('a.png'), _file('b.png')],
          ),
        ),
      );
      expect(harness.sink.files, isEmpty);
      expect(harness.errors.messages, [
        '[useDropListeners] Failed to process dropped files:',
      ]);
    });

    test(
      'delivers a workspace-file payload before the generic files',
      () async {
        final harness = _harness();
        final order = <String>[];
        final controller = harness.controller;
        controller.registerSink(
          () => FileDropSink(
            onFiles: (_) => order.add('files'),
            onGenericFiles: (_) => order.add('generic'),
            onWorkspaceFile: (_) => order.add('workspace'),
          ),
        );
        await harness.listeners.handleDrop(
          DomDragEvent(
            dataTransfer: _FakeDataTransfer(
              data: {workspaceFileDragMime: _workspacePayload()},
              files: [_file('a.png')],
            ),
          ),
        );
        expect(order, ['workspace', 'generic', 'files']);
      },
    );

    test('parses the workspace-file payload it delivers', () async {
      final harness = _harness();
      await harness.listeners.handleDrop(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(
            data: {
              workspaceFileDragMime: _workspacePayload(path: 'lib/app.dart'),
            },
          ),
        ),
      );
      expect(
        harness.sink.workspaceFiles.single.attachment.path,
        'lib/app.dart',
      );
      expect(harness.sink.workspaceFiles.single.serverId, 'server-1');
    });

    test('ignores an unparseable workspace-file payload', () async {
      final harness = _harness();
      await harness.listeners.handleDrop(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(
            data: {workspaceFileDragMime: '{"version":99}'},
          ),
        ),
      );
      expect(harness.sink.workspaceFiles, isEmpty);
    });

    test('ignores an empty workspace-file payload string', () async {
      final harness = _harness();
      await harness.listeners.handleDrop(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(data: {workspaceFileDragMime: ''}),
        ),
      );
      expect(harness.sink.workspaceFiles, isEmpty);
    });

    test('ignores a workspace-file payload a sink cannot take', () async {
      final harness = _harness(withWorkspace: false);
      await harness.listeners.handleDrop(
        DomDragEvent(
          dataTransfer: _FakeDataTransfer(
            data: {workspaceFileDragMime: _workspacePayload()},
          ),
        ),
      );
      expect(harness.sink.workspaceFiles, isEmpty);
    });

    test('tolerates a drop with no payload at all', () async {
      final harness = _harness();
      await harness.listeners.handleDrop(DomDragEvent());
      expect(harness.sink.generic, isEmpty);
      expect(harness.sink.files, isEmpty);
    });

    test('routes to the sink registered at drop time', () async {
      final harness = _harness();
      final captured = <String>[];
      final controller = harness.controller;
      controller.registerSink(
        () => FileDropSink(onFiles: (_) => captured.add('original')),
      );
      final drop = harness.listeners.handleDrop(
        DomDragEvent(dataTransfer: _FakeDataTransfer(files: [_file('a.png')])),
      );
      controller.registerSink(
        () => FileDropSink(onFiles: (_) => captured.add('replacement')),
      );
      await drop;
      expect(captured, ['original']);
    });
  });

  // -------------------------------------------------------------------------
  // use-drop-listeners.ts — desktop path
  // -------------------------------------------------------------------------
  group('desktop drag events', () {
    test('enter and over raise the drag flag', () async {
      final harness = _harness();
      await harness.listeners.handleDesktopEvent(
        const DesktopDragEnter(['/tmp/a.png']),
      );
      expect(harness.controller.isDragging.value, isTrue);
      harness.controller.isDragging.value = false;
      await harness.listeners.handleDesktopEvent(const DesktopDragOver());
      expect(harness.controller.isDragging.value, isTrue);
    });

    test('enter and over are ignored while disabled', () async {
      final harness = _harness(disabled: true);
      await harness.listeners.handleDesktopEvent(const DesktopDragEnter());
      await harness.listeners.handleDesktopEvent(const DesktopDragOver());
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('leave lowers the drag flag even while disabled', () async {
      final harness = _harness(disabled: true);
      harness.controller.isDragging.value = true;
      await harness.listeners.handleDesktopEvent(const DesktopDragLeave());
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('a drop always ends the drag, even while suppressed', () async {
      final harness = _harness();
      harness.controller.isDragging.value = true;
      harness.controller.suppressed.value = true;
      await harness.listeners.handleDesktopEvent(
        const DesktopDrop(['/tmp/a.png']),
      );
      expect(harness.controller.isDragging.value, isFalse);
      expect(harness.sink.generic, isEmpty);
      expect(harness.sink.files, isEmpty);
    });

    test('a drop is rejected while disabled', () async {
      final harness = _harness(disabled: true);
      await harness.listeners.handleDesktopEvent(
        const DesktopDrop(['/tmp/a.png']),
      );
      expect(harness.persister.fromFileUri, isEmpty);
    });

    test('a drop does nothing without a registered consumer', () async {
      final harness = _harness(registerSink: false);
      await harness.listeners.handleDesktopEvent(
        const DesktopDrop(['/tmp/a.png']),
      );
      expect(harness.persister.fromFileUri, isEmpty);
    });

    test('every dropped path reaches the generic handler', () async {
      final harness = _harness();
      await harness.listeners.handleDesktopEvent(
        const DesktopDrop(['/tmp/a.png', '/tmp/notes.txt']),
      );
      final items = harness.sink.generic.single;
      expect(items.map((item) => (item as DroppedPathItem).path), [
        '/tmp/a.png',
        '/tmp/notes.txt',
      ]);
    });

    test('an empty drop skips the generic handler', () async {
      final harness = _harness();
      await harness.listeners.handleDesktopEvent(const DesktopDrop([]));
      expect(harness.sink.generic, isEmpty);
    });

    test('image paths are persisted by uri and forwarded', () async {
      final harness = _harness();
      await harness.listeners.handleDesktopEvent(
        const DesktopDrop(['/tmp/a.png', '/tmp/notes.txt', '/tmp/b.TIFF']),
      );
      expect(harness.persister.fromFileUri, ['/tmp/a.png', '/tmp/b.TIFF']);
      expect(harness.persister.mimeTypes, ['image/png', 'image/tiff']);
      expect(harness.sink.files.single, hasLength(2));
    });

    test('a drop of no images never calls onFiles', () async {
      final harness = _harness();
      await harness.listeners.handleDesktopEvent(
        const DesktopDrop(['/tmp/notes.txt']),
      );
      expect(harness.sink.files, isEmpty);
      expect(harness.sink.generic, hasLength(1));
    });

    test('a persist failure is reported and drops the whole batch', () async {
      final harness = _harness(failOn: 'b.png');
      await harness.listeners.handleDesktopEvent(
        const DesktopDrop(['/tmp/a.png', '/tmp/b.png']),
      );
      expect(harness.sink.files, isEmpty);
      expect(harness.errors.messages, [
        '[useDropListeners] Failed to persist dropped files:',
      ]);
    });

    test('a sink without a generic handler still receives images', () async {
      final harness = _harness(withGeneric: false);
      await harness.listeners.handleDesktopEvent(
        const DesktopDrop(['/tmp/a.png']),
      );
      expect(harness.sink.generic, isEmpty);
      expect(harness.sink.files.single, hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  // use-drop-listeners.ts — disabled transitions and attach/detach
  // -------------------------------------------------------------------------
  group('disabled transitions', () {
    test('becoming disabled clears an in-progress drag', () {
      final harness = _harness();
      harness.listeners.handleDragEnter(
        DomDragEvent(dataTransfer: _FakeDataTransfer(types: ['Files'])),
      );
      expect(harness.controller.isDragging.value, isTrue);
      harness.listeners.disabled = true;
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('becoming disabled also resets the nesting counter', () {
      final harness = _harness();
      final files = _FakeDataTransfer(types: ['Files']);
      harness.listeners.handleDragEnter(DomDragEvent(dataTransfer: files));
      harness.listeners.handleDragEnter(DomDragEvent(dataTransfer: files));
      harness.listeners.disabled = true;
      harness.listeners.disabled = false;

      // With the counter reset, a single enter/leave pair must end the drag.
      harness.listeners.handleDragEnter(DomDragEvent(dataTransfer: files));
      expect(harness.controller.isDragging.value, isTrue);
      harness.listeners.handleDragLeave(DomDragEvent());
      expect(harness.controller.isDragging.value, isFalse);
    });

    test('becoming enabled leaves the drag flag alone', () {
      final harness = _harness(disabled: true);
      harness.controller.isDragging.value = true;
      harness.listeners.disabled = false;
      expect(harness.controller.isDragging.value, isTrue);
    });

    test('constructing disabled clears the flag immediately', () {
      final controller = PaseoFileDropController();
      controller.isDragging.value = true;
      PaseoDropListeners(
        controller: controller,
        persister: _FakePersister(),
        disabled: true,
      );
      expect(controller.isDragging.value, isFalse);
    });
  });

  group('attach', () {
    test('prefers the desktop source and never attaches the dom one', () async {
      final desktop = _FakeDesktopSource();
      final dom = _FakeDomSource();
      final harness = _harness(desktopSource: desktop, domSource: dom);
      await harness.listeners.attach();
      expect(desktop.attachCount, 1);
      expect(dom.attachCount, 0);
    });

    test('routes desktop events once attached', () async {
      final desktop = _FakeDesktopSource();
      final harness = _harness(desktopSource: desktop);
      await harness.listeners.attach();
      desktop.emit!(const DesktopDragEnter());
      expect(harness.controller.isDragging.value, isTrue);
    });

    test(
      'falls back to the dom source when the host has no desktop drag',
      () async {
        final desktop = _FakeDesktopSource(available: false);
        final dom = _FakeDomSource();
        final harness = _harness(desktopSource: desktop, domSource: dom);
        await harness.listeners.attach();
        expect(dom.attachCount, 1);
        expect(dom.handlers, isNotNull);
      },
    );

    test(
      'uses the dom source when there is no desktop source at all',
      () async {
        final dom = _FakeDomSource();
        final harness = _harness(domSource: dom);
        await harness.listeners.attach();
        expect(dom.attachCount, 1);
      },
    );

    test('warns and falls back when the desktop source throws', () async {
      final desktop = _FakeDesktopSource(throwOnAttach: true);
      final dom = _FakeDomSource();
      final harness = _harness(desktopSource: desktop, domSource: dom);
      await harness.listeners.attach();
      expect(harness.warnings.messages, [
        '[useDropListeners] Failed to listen for desktop drag-drop:',
      ]);
      expect(dom.attachCount, 1);
    });

    test('routes dom events through the attached handlers', () async {
      final dom = _FakeDomSource();
      final harness = _harness(domSource: dom);
      await harness.listeners.attach();
      dom.handlers!.onDragEnter(
        DomDragEvent(dataTransfer: _FakeDataTransfer(types: ['Files'])),
      );
      expect(harness.controller.isDragging.value, isTrue);
      await dom.handlers!.onDrop(
        DomDragEvent(dataTransfer: _FakeDataTransfer(files: [_file('a.png')])),
      );
      expect(harness.controller.isDragging.value, isFalse);
      expect(harness.sink.files, hasLength(1));
    });

    test('attaches nothing on a platform without drag-and-drop', () async {
      final desktop = _FakeDesktopSource();
      final dom = _FakeDomSource();
      final harness = _harness(
        desktopSource: desktop,
        domSource: dom,
        dropSupported: false,
      );
      await harness.listeners.attach();
      expect(desktop.attachCount, 0);
      expect(dom.attachCount, 0);
    });

    test('a dom source with no element leaves nothing to dispose', () async {
      final dom = _FakeDomSource(hasElement: false);
      final harness = _harness(domSource: dom);
      await harness.listeners.attach();
      harness.listeners.dispose();
      expect(dom.disposeCount, 0);
    });
  });

  group('dispose', () {
    test('detaches the desktop listener', () async {
      final desktop = _FakeDesktopSource();
      final harness = _harness(desktopSource: desktop);
      await harness.listeners.attach();
      harness.listeners.dispose();
      expect(desktop.disposeCount, 1);
    });

    test('detaches the dom listener', () async {
      final dom = _FakeDomSource();
      final harness = _harness(domSource: dom);
      await harness.listeners.attach();
      harness.listeners.dispose();
      expect(dom.disposeCount, 1);
    });

    test('detaches only once', () async {
      final dom = _FakeDomSource();
      final harness = _harness(domSource: dom);
      await harness.listeners.attach();
      harness.listeners.dispose();
      harness.listeners.dispose();
      expect(dom.disposeCount, 1);
    });

    test('tears down a desktop listener that lands after disposal', () async {
      final gate = Completer<void>();
      final desktop = _FakeDesktopSource(gate: gate.future);
      final dom = _FakeDomSource();
      final harness = _harness(desktopSource: desktop, domSource: dom);

      final pending = harness.listeners.attach();
      harness.listeners.dispose();
      gate.complete();
      await pending;

      expect(desktop.disposeCount, 1);
      expect(dom.attachCount, 0);
    });

    test('skips the dom fallback when disposed mid-attach', () async {
      final gate = Completer<void>();
      final desktop = _FakeDesktopSource(available: false, gate: gate.future);
      final dom = _FakeDomSource();
      final harness = _harness(desktopSource: desktop, domSource: dom);

      final pending = harness.listeners.attach();
      harness.listeners.dispose();
      gate.complete();
      await pending;

      expect(dom.attachCount, 0);
    });

    test('warns when a synchronous detach throws', () async {
      final desktop = _FakeDesktopSource(throwOnDispose: true);
      final harness = _harness(desktopSource: desktop);
      await harness.listeners.attach();
      harness.listeners.dispose();
      expect(harness.warnings.messages, [
        '[useDropListeners] Failed to remove desktop drag-drop listener:',
      ]);
    });

    test('warns when an asynchronous detach rejects', () async {
      final desktop = _FakeDesktopSource(disposeReturnsRejectedFuture: true);
      final harness = _harness(desktopSource: desktop);
      await harness.listeners.attach();
      harness.listeners.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(harness.warnings.messages, [
        '[useDropListeners] Failed to remove desktop drag-drop listener:',
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // attachments/service.ts — the default persister
  // -------------------------------------------------------------------------
  group('store-backed persister', () {
    test('saves a path as a file-uri source without reading it', () async {
      final store = _RecordingStore();
      final persister = PaseoStoreDropAttachmentPersister(store);
      await persister.persistFromFileUri(
        uri: '/tmp/a.png',
        mimeType: 'image/png',
      );
      final input = store.saved.single;
      expect(input.source, isA<FileUriAttachmentSource>());
      expect((input.source as FileUriAttachmentSource).uri, '/tmp/a.png');
      expect(input.mimeType, 'image/png');
      expect(input.fileName, isNull);
    });

    test('saves bytes as a blob source carrying the file name', () async {
      final store = _RecordingStore();
      final persister = PaseoStoreDropAttachmentPersister(store);
      await persister.persistFromBlob(
        blob: AttachmentBlob(bytes: Uint8List.fromList([9]), type: 'image/png'),
        mimeType: 'image/png',
        fileName: 'a.png',
      );
      final input = store.saved.single;
      expect(input.source, isA<BlobAttachmentSource>());
      expect(input.fileName, 'a.png');
    });
  });

  // -------------------------------------------------------------------------
  // file-drop-zone.tsx / file-drop-backdrop.tsx
  // -------------------------------------------------------------------------
  group('zone', () {
    testWidgets('publishes its controller to the subtree', (tester) async {
      final controller = PaseoFileDropController();
      late PaseoFileDropController seen;
      await tester.pumpWidget(
        _zone(
          controller: controller,
          child: Builder(
            builder: (context) {
              seen = PaseoFileDropScope.maybeOf(context)!;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, same(controller));
    });

    testWidgets('renders the backdrop above its child', (tester) async {
      await tester.pumpWidget(_zone(controller: PaseoFileDropController()));
      expect(find.byType(PaseoFileDropBackdrop), findsOneWidget);
      expect(find.byType(Stack), findsWidgets);
    });

    testWidgets('renders no backdrop where drag-and-drop does not exist', (
      tester,
    ) async {
      await tester.pumpWidget(
        _zone(controller: PaseoFileDropController(), dropSupported: false),
      );
      expect(find.byType(PaseoFileDropBackdrop), findsNothing);
    });

    testWidgets('still provides context where drag-and-drop does not exist', (
      tester,
    ) async {
      PaseoFileDropController? seen;
      await tester.pumpWidget(
        _zone(
          controller: PaseoFileDropController(),
          dropSupported: false,
          child: Builder(
            builder: (context) {
              seen = PaseoFileDropScope.maybeOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, isNotNull);
    });

    testWidgets('sizes itself to its child', (tester) async {
      await tester.pumpWidget(
        _zone(
          controller: PaseoFileDropController(),
          child: const SizedBox(width: 120, height: 90),
        ),
      );
      expect(
        tester.getSize(find.byType(PaseoFileDropZone)),
        const Size(120, 90),
      );
    });

    testWidgets('owns a controller when none is supplied', (tester) async {
      PaseoFileDropController? seen;
      await tester.pumpWidget(
        FluentApp(
          theme: buildAppTheme(),
          home: PaseoFileDropZone(
            child: Builder(
              builder: (context) {
                seen = PaseoFileDropScope.maybeOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(seen, isNotNull);
    });
  });

  group('backdrop', () {
    testWidgets('renders nothing without a zone above it', (tester) async {
      await tester.pumpWidget(
        FluentApp(theme: buildAppTheme(), home: const PaseoFileDropBackdrop()),
      );
      expect(find.text(PaseoFileDropBackdrop.dropFilesHereLabel), findsNothing);
    });

    testWidgets('resolves its label through the injected translator', (
      tester,
    ) async {
      // The frozen key exists in the vendored resources, so a widget that
      // hardcodes English silently opts out of the other seven locales.
      final controller = PaseoFileDropController();
      await tester.pumpWidget(
        _zone(
          controller: controller,
          translate: (key) => key == PaseoFileDropBackdrop.dropFilesHereKey
              ? 'ここにファイルをドロップ'
              : key,
        ),
      );
      controller.hasSink.value = true;
      controller.isDragging.value = true;
      await tester.pump();

      expect(find.text('ここにファイルをドロップ'), findsOneWidget);
      expect(find.text(PaseoFileDropBackdrop.dropFilesHereLabel), findsNothing);
    });

    testWidgets('falls back to the frozen English with no translator', (
      tester,
    ) async {
      final controller = PaseoFileDropController();
      await tester.pumpWidget(_zone(controller: controller));
      controller.hasSink.value = true;
      controller.isDragging.value = true;
      await tester.pump();

      expect(
        find.text(PaseoFileDropBackdrop.dropFilesHereLabel),
        findsOneWidget,
      );
    });

    testWidgets('stays hidden until a drag arrives', (tester) async {
      final controller = PaseoFileDropController();
      await tester.pumpWidget(_zone(controller: controller));
      expect(_overlayOpacity(tester), 0);
    });

    testWidgets('shows while a drag is active with a consumer mounted', (
      tester,
    ) async {
      final controller = PaseoFileDropController();
      await tester.pumpWidget(_zone(controller: controller));
      controller.hasSink.value = true;
      controller.isDragging.value = true;
      await tester.pump();
      expect(_overlayOpacity(tester), 1);
    });

    testWidgets('stays hidden while a drag is active with no consumer', (
      tester,
    ) async {
      final controller = PaseoFileDropController();
      await tester.pumpWidget(_zone(controller: controller));
      controller.isDragging.value = true;
      await tester.pump();
      expect(_overlayOpacity(tester), 0);
    });

    testWidgets('hides again while the consumer is suppressed', (tester) async {
      final controller = PaseoFileDropController();
      await tester.pumpWidget(_zone(controller: controller));
      controller.hasSink.value = true;
      controller.isDragging.value = true;
      await tester.pump();
      controller.suppressed.value = true;
      await tester.pump();
      expect(_overlayOpacity(tester), 0);
    });

    testWidgets('stays hidden while the zone is disabled', (tester) async {
      final controller = PaseoFileDropController();
      await tester.pumpWidget(_zone(controller: controller, disabled: true));
      controller.hasSink.value = true;
      controller.isDragging.value = true;
      await tester.pump();
      expect(_overlayOpacity(tester), 0);
    });

    testWidgets('fades over 150ms', (tester) async {
      final controller = PaseoFileDropController();
      await tester.pumpWidget(_zone(controller: controller));
      controller.hasSink.value = true;
      controller.isDragging.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      final mid = tester
          .widget<FadeTransition>(
            find.descendant(
              of: find.byKey(PaseoFileDropBackdrop.overlayKey),
              matching: find.byType(FadeTransition),
            ),
          )
          .opacity
          .value;
      expect(mid, greaterThan(0));
      expect(mid, lessThan(1));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FadeTransition>(
              find.descendant(
                of: find.byKey(PaseoFileDropBackdrop.overlayKey),
                matching: find.byType(FadeTransition),
              ),
            )
            .opacity
            .value,
        1,
      );
    });

    testWidgets('never intercepts pointers', (tester) async {
      await tester.pumpWidget(_zone(controller: PaseoFileDropController()));
      expect(
        find.descendant(
          of: find.byType(PaseoFileDropBackdrop),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );
    });

    testWidgets('dims with surface0 at 70%', (tester) async {
      await tester.pumpWidget(_zone(controller: PaseoFileDropController()));
      final dim = tester.widget<Opacity>(
        find.byKey(PaseoFileDropBackdrop.dimKey),
      );
      expect(dim.opacity, PaseoFileDropBackdrop.dimOpacity);
      expect(dim.opacity, 0.7);
      final colored = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byKey(PaseoFileDropBackdrop.dimKey),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(colored.color, _palette(tester).surface0);
    });

    testWidgets('labels the drop target with an accented upload glyph', (
      tester,
    ) async {
      await tester.pumpWidget(_zone(controller: PaseoFileDropController()));
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byType(PaseoFileDropBackdrop),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, FluentIcons.upload);
      expect(icon.size, PaseoFileDropBackdrop.iconSize);
      expect(icon.size, 32);
      expect(icon.color, buildAppTheme().accentColor.normal);
      expect(
        find.text(PaseoFileDropBackdrop.dropFilesHereLabel),
        findsOneWidget,
      );
    });

    testWidgets('separates glyph and label by one spacing step', (
      tester,
    ) async {
      await tester.pumpWidget(_zone(controller: PaseoFileDropController()));
      final gap = tester.widget<SizedBox>(
        find.byKey(PaseoFileDropBackdrop.gapKey),
      );
      expect(gap.height, PaseoSpacing.s2);
      expect(gap.height, 8);
    });

    testWidgets('renders the label medium-weight in the foreground colour', (
      tester,
    ) async {
      await tester.pumpWidget(_zone(controller: PaseoFileDropController()));
      final text = tester.widget<Text>(
        find.text(PaseoFileDropBackdrop.dropFilesHereLabel),
      );
      expect(text.style?.fontWeight, FontWeight.w500);
      expect(text.style?.color, _palette(tester).foreground);
    });
  });
}

final class _RecordingStore implements PaseoAttachmentStore {
  final List<SaveAttachmentInput> saved = [];

  @override
  AttachmentStorageType get storageType => AttachmentStorageType.nativeFile;

  @override
  Future<AttachmentMetadata> save(SaveAttachmentInput input) async {
    saved.add(input);
    return _attachment(id: 'saved', mimeType: input.mimeType ?? '');
  }

  @override
  Future<String> encodeBase64(AttachmentMetadata attachment) async => '';

  @override
  Future<String> resolvePreviewUrl(AttachmentMetadata attachment) async => '';

  @override
  bool get supportsPreviewUrlRelease => false;

  @override
  Future<void> releasePreviewUrl({
    required AttachmentMetadata attachment,
    required String url,
  }) async {}

  @override
  Future<void> delete(AttachmentMetadata attachment) async {}

  @override
  Future<void> garbageCollect(Set<String> referencedIds) async {}
}
