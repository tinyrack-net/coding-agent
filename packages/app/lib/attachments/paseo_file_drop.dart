/// Port of Paseo 0.2.0's frozen `components/file-drop/*` cluster — the
/// drag-and-drop *area* that sits around a composer:
///
/// - `file-drop/types.ts` — what a dropped thing is (a web `File` or a plain
///   desktop path) and what a consumer registers to receive them.
/// - `file-drop/context.ts` — the three drag flags a zone publishes and the
///   sink-registration handle its descendants use.
/// - `file-drop/use-file-drop.ts` — the consumer side: register a sink, and
///   suppress the zone while the consumer is busy.
/// - `file-drop/use-drop-listeners.ts` — the event side: window-scoped desktop
///   drag events *or* element-scoped HTML5 drag events, routed to the sink.
/// - `file-drop/file-drop-zone.tsx` — the area widget that owns the flags and
///   renders the backdrop.
/// - `file-drop/file-drop-backdrop.tsx` — the dim "Drop files here" overlay.
///
/// The first four are pure logic here: nothing in them imports a plugin,
/// `dart:io`, or `dart:html`. The drag/drop event source is injected behind
/// [PaseoDesktopDropEventSource] / [PaseoDomDropEventSource], so the whole
/// routing contract is exercised in tests without a real desktop drag.
///
/// Reuse notes — this file deliberately declares no rule it can borrow:
///
/// - [workspaceFileDragMime], [parseWorkspaceFileDragPayload] and
///   [WorkspaceFileDragPayload] come from `attachments/workspace_file_drag.dart`.
/// - The drag-data surface extends the existing
///   [WorkspaceFileDataTransfer] (`attachments/workspace_file_data_transfer.dart`)
///   rather than declaring a second `DataTransfer` shim; [FileDropDataTransfer]
///   only adds the `files` list that the workspace-file drag never needed.
/// - `isRasterImageFile` / `isRasterImagePath` / `resolveRasterImageMimeType`
///   come from `attachments/paseo_attachment_rules.dart`, so there is exactly
///   one raster-image MIME table in the app.
/// - Upstream's `attachments/service.ts` (`persistAttachmentFrom*`) is the
///   default [PaseoDropAttachmentPersister], implemented on top of the already
///   ported [PaseoAttachmentStore] / [SaveAttachmentInput] from
///   `attachments/paseo_attachment_stores.dart`.
/// - `AttachmentMetadata` (upstream's `ImageAttachment`) is the app's existing
///   type from `attachments/attachment_store.dart`, reached through the
///   re-export in `attachments/paseo_attachment_stores.dart`.
///
/// Overlap with the app's existing drop handling: `widgets/composer.dart`,
/// `widgets/draft_session_composer.dart`, `widgets/terminal_pane.dart` and
/// `screens/new_workspace_screen.dart` each wrap themselves in a
/// `desktop_drop` `DropTarget` and handle `onDragEntered/Exited/Done`
/// themselves, with per-widget `_dropActive` state and their own inline
/// backdrop. That is upstream's *consumer* and *zone* collapsed into one
/// widget. This port keeps them separated the way upstream does — the zone
/// owns the flags and the backdrop, the consumer only registers a sink — so a
/// consumer's layout can never collapse the backdrop. Nothing here is wired
/// into those widgets yet; reconciling them means turning each `DropTarget`
/// into a [PaseoDesktopDropEventSource] adapter feeding one shared
/// [PaseoFileDropController].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';
import 'paseo_attachment_rules.dart';
import 'paseo_attachment_stores.dart';
import 'workspace_file_data_transfer.dart';
import 'workspace_file_drag.dart';

// ---------------------------------------------------------------------------
// types.ts
// ---------------------------------------------------------------------------

/// Upstream's `ImageAttachment`, which is a bare alias of `AttachmentMetadata`.
///
/// Kept as an alias so the sink signature reads the way upstream's does: what
/// reaches [FileDropSink.onFiles] is always an attachment that has *already*
/// been persisted, never a raw file.
typedef ImageAttachment = AttachmentMetadata;

/// A file handed over by the host during a drop.
///
/// Deviation: upstream types this as the DOM `File`. Dart has no `File` with a
/// media type, and the logic half must stay plugin-free, so this exposes
/// exactly the three members upstream reads off one — `name`, `type` and the
/// bytes. `type` is non-nullable and empty-when-unknown because that is what a
/// browser reports (`""`, never `null`), and
/// [isRasterImageFile] already treats the empty string as "fall back to the
/// name".
abstract interface class DroppedFile {
  /// The file name as the host reported it, e.g. `screenshot.png`.
  String get name;

  /// The media type the host claimed, or `''` when it claimed none.
  String get type;

  /// The file's bytes. Called at most once per drop, and only for files that
  /// already passed the raster-image filter.
  Future<Uint8List> readAsBytes();
}

/// A [DroppedFile] whose bytes are already in memory.
///
/// Exists so callers (and tests) have a usable implementation without pulling
/// a plugin into this library; a real host adapter wraps its own file handle
/// instead.
final class InMemoryDroppedFile implements DroppedFile {
  const InMemoryDroppedFile({
    required this.name,
    required this.bytes,
    this.type = '',
  });

  @override
  final String name;

  @override
  final String type;

  /// The payload [readAsBytes] hands back.
  final Uint8List bytes;

  @override
  Future<Uint8List> readAsBytes() async => bytes;
}

/// One item from a drop, before anything has been read or persisted.
///
/// Deviation: upstream is a structural union discriminated by a `kind` string.
/// Dart uses a sealed class so `switch` is exhaustive, but [kind] is kept as a
/// real field because the discriminant is part of the contract consumers match
/// on (upstream's `composer/attachments/drop.ts` branches on it).
sealed class DroppedItem {
  const DroppedItem();

  /// The union discriminant, verbatim from upstream.
  String get kind;
}

/// A file the host handed over by value.
final class DroppedFileItem extends DroppedItem {
  const DroppedFileItem(this.file);

  @override
  String get kind => 'web-file';

  final DroppedFile file;
}

/// A file the host handed over by absolute path, with no bytes attached.
final class DroppedPathItem extends DroppedItem {
  const DroppedPathItem(this.path);

  @override
  String get kind => 'desktop-path';

  final String path;
}

/// What a consumer (e.g. a composer) registers to receive files dropped onto
/// the surrounding [PaseoFileDropZone].
///
/// Raster images arrive already persisted via [onFiles]; everything else
/// arrives raw via [onGenericFiles]. The split is why [onFiles] takes
/// attachments and the other two take unread items: only images are worth
/// paying a store round trip for before the consumer has said yes.
final class FileDropSink {
  const FileDropSink({
    required this.onFiles,
    this.onGenericFiles,
    this.onWorkspaceFile,
  });

  /// Raster images, already persisted to the attachment store.
  final void Function(List<ImageAttachment> images) onFiles;

  /// Every dropped item, images included, unread.
  ///
  /// Nullable because a consumer that only accepts images simply omits it, and
  /// the listener then never assembles the list.
  final void Function(List<DroppedItem> items)? onGenericFiles;

  /// A file dragged out of the workspace explorer rather than off the OS.
  ///
  /// Its presence is also what decides whether an in-app workspace-file drag
  /// is even advertised as droppable — see [PaseoDropListeners.handleDragOver].
  final void Function(WorkspaceFileDragPayload payload)? onWorkspaceFile;
}

// ---------------------------------------------------------------------------
// context.ts (+ the sink registry that lives in file-drop-zone.tsx)
// ---------------------------------------------------------------------------

/// The drag state a zone publishes, plus its sink registry.
///
/// Deviation: upstream stores the three flags in Reanimated `SharedValue`s so
/// toggling them triggers no React render. The Flutter analogue is a
/// [ValueNotifier] read by a listener that wraps *only* the backdrop, which
/// buys the same property: a drag entering or leaving repaints the overlay and
/// nothing else.
final class PaseoFileDropController {
  /// Drag-active flag. Written by the listeners, read by the backdrop.
  final ValueNotifier<bool> isDragging = ValueNotifier<bool>(false);

  /// The active sink can't accept right now (e.g. the composer is submitting):
  /// hide the backdrop and reject drops.
  final ValueNotifier<bool> suppressed = ValueNotifier<bool>(false);

  /// Whether a consumer is currently registered — no consumer (e.g. an
  /// archived agent), no backdrop and no accepted drop.
  final ValueNotifier<bool> hasSink = ValueNotifier<bool>(false);

  FileDropSink? Function()? _activeGetSink;

  /// Registers the active sink and returns its disposer.
  ///
  /// Takes a getter rather than a sink so the zone always reads the consumer's
  /// latest handlers without the consumer having to re-register whenever it
  /// rebuilds.
  ///
  /// Registering a second sink replaces the first; the *first* one's disposer
  /// then does nothing, so a replaced-then-unmounted consumer cannot tear down
  /// the consumer that took its place.
  VoidCallback registerSink(FileDropSink? Function() getSink) {
    _activeGetSink = getSink;
    hasSink.value = true;
    return () {
      if (identical(_activeGetSink, getSink)) {
        _activeGetSink = null;
        hasSink.value = false;
      }
    };
  }

  /// The currently registered sink, or `null` when none is registered (or the
  /// registered getter itself currently has nothing to offer).
  FileDropSink? getSink() => _activeGetSink?.call();

  /// Releases the three notifiers. The controller is dead afterwards.
  void dispose() {
    isDragging.dispose();
    suppressed.dispose();
    hasSink.dispose();
  }
}

// ---------------------------------------------------------------------------
// use-file-drop.ts
// ---------------------------------------------------------------------------

/// The consumer half of a drop zone: a live registration of one [FileDropSink].
///
/// Deviation: upstream is a React hook that re-reads `sink` through a ref on
/// every render, so passing a fresh object each render neither re-registers
/// nor re-renders. The Dart analogue is a mutable [sink] field on a
/// long-lived object — assigning it is the ref update, and it deliberately
/// does *not* re-register.
///
/// Constructing one with a `null` controller is a no-op, mirroring
/// `useFileDrop` used without a `FileDropZone` ancestor.
final class PaseoFileDropRegistration {
  PaseoFileDropRegistration({
    required PaseoFileDropController? controller,
    required this.sink,
    bool disabled = false,
  }) : _controller = controller {
    _disabled = disabled;
    _unregister = controller?.registerSink(() => sink);
    controller?.suppressed.value = disabled;
  }

  final PaseoFileDropController? _controller;
  VoidCallback? _unregister;
  bool _disabled = false;
  bool _disposed = false;

  /// The handlers the zone will call on the next drop.
  ///
  /// Assigning a new value is the ref update: it deliberately does *not*
  /// re-register, so a consumer may hand over a freshly built sink on every
  /// rebuild for free.
  FileDropSink sink;

  /// Whether the consumer can accept right now.
  ///
  /// Writes straight through to [PaseoFileDropController.suppressed].
  ///
  /// Deviation: upstream's effect cleanup resets `suppressed` to `false`
  /// before re-applying the new value on every change. That intermediate write
  /// is unobservable (a `SharedValue` set to a value it will immediately
  /// overwrite in the same tick), so this assigns the new value directly.
  bool get disabled => _disabled;

  set disabled(bool value) {
    if (_disabled == value) return;
    _disabled = value;
    if (_disposed) return;
    _controller?.suppressed.value = value;
  }

  /// Unregisters the sink and clears the suppression this registration set.
  ///
  /// Idempotent: upstream's two effects each clean up once, and a double
  /// dispose here must not un-suppress a zone some *other* registration has
  /// since suppressed.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _unregister?.call();
    _unregister = null;
    _controller?.suppressed.value = false;
  }
}

// ---------------------------------------------------------------------------
// use-drop-listeners.ts — event payloads
// ---------------------------------------------------------------------------

/// A window-scoped desktop drag event, as a Tauri-style host reports it.
sealed class DesktopDragDropPayload {
  const DesktopDragDropPayload();
}

/// The pointer entered the window while dragging.
///
/// [paths] is carried for fidelity with upstream's payload even though the
/// handler ignores it: nothing is accepted until the drop.
final class DesktopDragEnter extends DesktopDragDropPayload {
  const DesktopDragEnter([this.paths = const []]);

  final List<String> paths;
}

/// The pointer moved inside the window while dragging.
final class DesktopDragOver extends DesktopDragDropPayload {
  const DesktopDragOver();
}

/// The drag was released over the window.
final class DesktopDrop extends DesktopDragDropPayload {
  const DesktopDrop(this.paths);

  final List<String> paths;
}

/// The pointer left the window, ending the drag.
final class DesktopDragLeave extends DesktopDragDropPayload {
  const DesktopDragLeave();
}

/// The drag payload of an HTML5-style drag event.
///
/// Extends the app's existing [WorkspaceFileDataTransfer] — which already
/// models `types`, `dropEffect` and `getData` for the workspace-file drag — and
/// adds only the file list that an OS-file drop needs.
abstract interface class FileDropDataTransfer
    implements WorkspaceFileDataTransfer {
  /// The files carried by this drag, empty when the drag carries none.
  List<DroppedFile> get files;
}

/// An element-scoped HTML5 drag event.
///
/// Deviation: Flutter has no event bubbling, so `preventDefault()` and
/// `stopPropagation()` cannot suppress anything by themselves. They are kept
/// as recorded flags ([defaultPrevented], [propagationStopped]) so a host
/// adapter can forward them to the real DOM event and so the port's ordering
/// contract — *every* handler calls both, first thing, even when it then bails
/// out — stays pinned.
final class DomDragEvent {
  DomDragEvent({this.dataTransfer});

  /// The drag payload, or `null` when the host reported none.
  final FileDropDataTransfer? dataTransfer;

  bool _defaultPrevented = false;
  bool _propagationStopped = false;

  /// Whether [preventDefault] was called on this event.
  bool get defaultPrevented => _defaultPrevented;

  /// Whether [stopPropagation] was called on this event.
  bool get propagationStopped => _propagationStopped;

  void preventDefault() => _defaultPrevented = true;

  void stopPropagation() => _propagationStopped = true;
}

// ---------------------------------------------------------------------------
// use-drop-listeners.ts — injected collaborators
// ---------------------------------------------------------------------------

/// Removes a previously attached listener.
///
/// `FutureOr` because upstream's desktop unlisten is a promise while a Flutter
/// host's is usually synchronous; both are handled, and a rejected future is
/// reported through [PaseoDropDiagnostic] exactly like upstream's `console.warn`.
typedef PaseoDropListenerDisposer = FutureOr<void> Function();

/// Receives the diagnostics upstream sends to `console.warn` / `console.error`.
///
/// Injected rather than hard-wired to `print` so the listeners stay free of
/// side effects and tests can assert that a failure was actually reported.
/// Messages are passed verbatim from upstream.
typedef PaseoDropDiagnostic = void Function(String message, Object? detail);

/// A window-scoped desktop drag source (upstream's Tauri
/// `onDragDropEvent`).
abstract interface class PaseoDesktopDropEventSource {
  /// Attaches [onEvent] and returns its disposer, or `null` when this host
  /// cannot report drags at all.
  ///
  /// `null` collapses upstream's two separate unavailability checks — no
  /// desktop host, and a host without `onDragDropEvent` — since both make the
  /// listeners fall through to the DOM path identically.
  Future<PaseoDropListenerDisposer?> attach(
    void Function(DesktopDragDropPayload payload) onEvent,
  );
}

/// The four element-scoped handlers an HTML5 source must forward.
final class PaseoDomDropHandlers {
  const PaseoDomDropHandlers({
    required this.onDragEnter,
    required this.onDragOver,
    required this.onDragLeave,
    required this.onDrop,
  });

  final void Function(DomDragEvent event) onDragEnter;
  final void Function(DomDragEvent event) onDragOver;
  final void Function(DomDragEvent event) onDragLeave;
  final Future<void> Function(DomDragEvent event) onDrop;
}

/// An element-scoped HTML5 drag source (upstream's `element.addEventListener`).
abstract interface class PaseoDomDropEventSource {
  /// Attaches [handlers] and returns their disposer, or `null` when there is
  /// no element to attach to (upstream's null `containerRef.current`).
  PaseoDropListenerDisposer? attach(PaseoDomDropHandlers handlers);
}

/// Persists dropped raster images, upstream's `attachments/service.ts`.
abstract interface class PaseoDropAttachmentPersister {
  /// Stores a file the host handed over by path, without reading it here.
  Future<ImageAttachment> persistFromFileUri({
    required String uri,
    required String mimeType,
  });

  /// Stores bytes the host handed over by value.
  Future<ImageAttachment> persistFromBlob({
    required AttachmentBlob blob,
    required String mimeType,
    String? fileName,
  });
}

/// The default [PaseoDropAttachmentPersister], writing through a
/// [PaseoAttachmentStore].
///
/// Deviation: upstream's service resolves a lazily-created store singleton on
/// every call (`await getAttachmentStore()`). The store is injected here
/// instead, because a singleton lookup would drag platform selection into a
/// library that must stay testable without one.
final class PaseoStoreDropAttachmentPersister
    implements PaseoDropAttachmentPersister {
  const PaseoStoreDropAttachmentPersister(this.store);

  final PaseoAttachmentStore store;

  @override
  Future<ImageAttachment> persistFromFileUri({
    required String uri,
    required String mimeType,
  }) => store.save(
    SaveAttachmentInput(
      source: FileUriAttachmentSource(uri),
      mimeType: mimeType,
    ),
  );

  @override
  Future<ImageAttachment> persistFromBlob({
    required AttachmentBlob blob,
    required String mimeType,
    String? fileName,
  }) => store.save(
    SaveAttachmentInput(
      source: BlobAttachmentSource(blob),
      mimeType: mimeType,
      fileName: fileName,
    ),
  );
}

// ---------------------------------------------------------------------------
// use-drop-listeners.ts — the listeners themselves
// ---------------------------------------------------------------------------

/// Routes host drag events onto a [PaseoFileDropController] and the registered
/// sink.
///
/// Drag state is written to the controller's notifiers (no widget rebuild
/// outside the backdrop); dropped files are routed to the sink that was
/// registered *at drop time*, never a freshly looked-up one, so a drop always
/// lands on the consumer the user dropped on.
///
/// Deviation: upstream's hook body is an effect; here [attach] is the effect
/// body and [dispose] is its cleanup. The individual handlers are public so
/// the routing contract can be driven directly in tests, which is the whole
/// reason the event sources are injected.
final class PaseoDropListeners {
  PaseoDropListeners({
    required this.controller,
    required this.persister,
    bool disabled = false,
    this.desktopSource,
    this.domSource,
    this.dropSupported = true,
    this.onWarn,
    this.onError,
  }) {
    _disabled = disabled;
    // Upstream's "clear an in-progress drag when the zone becomes disabled"
    // effect also runs on mount.
    if (_disabled) _clearDrag();
  }

  /// The zone's flags and sink registry.
  final PaseoFileDropController controller;

  /// Where persisted raster images go.
  final PaseoDropAttachmentPersister persister;

  /// Window-scoped source, tried first. `null` means this host has none.
  final PaseoDesktopDropEventSource? desktopSource;

  /// Element-scoped source, used only when the desktop source did not attach.
  final PaseoDomDropEventSource? domSource;

  /// Whether this platform has drag-and-drop at all.
  ///
  /// Mirrors upstream's `if (!isWeb) return;`: on a platform without it, no
  /// listener is attached and no source is even consulted.
  final bool dropSupported;

  /// Receives upstream's `console.warn` diagnostics.
  final PaseoDropDiagnostic? onWarn;

  /// Receives upstream's `console.error` diagnostics.
  final PaseoDropDiagnostic? onError;

  bool _disabled = false;
  int _dragCounter = 0;
  bool _disposed = false;
  bool _didCleanup = false;
  PaseoDropListenerDisposer? _cleanup;

  /// When true the zone hides the backdrop and rejects drops atomically.
  bool get disabled => _disabled;

  set disabled(bool value) {
    if (_disabled == value) return;
    _disabled = value;
    if (value) _clearDrag();
  }

  void _clearDrag() {
    controller.isDragging.value = false;
    _dragCounter = 0;
  }

  // -------------------------------------------------------------------------
  // Attach / detach
  // -------------------------------------------------------------------------

  /// Attaches the listeners: the desktop source first, and the DOM source only
  /// if the desktop source did not take over.
  ///
  /// Desktop drag-drop is *window*-scoped, not element-scoped: with multiple
  /// zones mounted every zone would react to the same drop, which is why
  /// upstream notes it is dormant in practice and the element-scoped path is
  /// what actually runs.
  Future<void> attach() async {
    if (!dropSupported) return;

    final desktopAttached = await _setupDesktopDragDrop();
    if (_disposed || desktopAttached) return;
    _setupDomDragDrop();
  }

  /// Detaches whatever [attach] attached. Safe to call before [attach]
  /// finishes: the pending attach then tears itself down as soon as it lands.
  void dispose() {
    _disposed = true;
    _runCleanup();
  }

  void _runCleanup([PaseoDropListenerDisposer? unlisten]) {
    if (_didCleanup) return;
    final cleanupFn = unlisten ?? _cleanup;
    // Note the ordering: bailing out here leaves `_didCleanup` false, so a
    // disposer that arrives *later* (an attach that resolved after dispose)
    // still runs. Upstream relies on the same ordering.
    if (cleanupFn == null) return;
    _didCleanup = true;
    try {
      final result = cleanupFn();
      if (result is Future<void>) {
        unawaited(
          result.catchError(
            (Object error) => onWarn?.call(
              '[useDropListeners] Failed to remove desktop drag-drop listener:',
              error,
            ),
          ),
        );
      }
    } catch (error) {
      onWarn?.call(
        '[useDropListeners] Failed to remove desktop drag-drop listener:',
        error,
      );
    }
  }

  Future<bool> _setupDesktopDragDrop() async {
    final source = desktopSource;
    if (source == null) return false;

    try {
      final unlisten = await source.attach(handleDesktopEvent);
      if (unlisten == null) return false;

      if (_disposed) {
        _runCleanup(unlisten);
        return true;
      }

      _cleanup = unlisten;
      return true;
    } catch (error) {
      onWarn?.call(
        '[useDropListeners] Failed to listen for desktop drag-drop:',
        error,
      );
      return false;
    }
  }

  void _setupDomDragDrop() {
    final source = domSource;
    if (source == null) return;

    final unlisten = source.attach(
      PaseoDomDropHandlers(
        onDragEnter: handleDragEnter,
        onDragOver: handleDragOver,
        onDragLeave: handleDragLeave,
        onDrop: handleDrop,
      ),
    );
    if (unlisten == null) return;
    _cleanup = unlisten;
  }

  // -------------------------------------------------------------------------
  // Desktop (window-scoped) routing
  // -------------------------------------------------------------------------

  /// Handles one window-scoped desktop drag event.
  ///
  /// Deviation: upstream's callback is synchronous and leaves the persistence
  /// promise floating. This returns that work as a future so a test can await
  /// it; every *synchronous* effect (the drag flag, the generic-file callback)
  /// still happens before the first suspension, so a caller that ignores the
  /// future observes exactly upstream's behaviour.
  Future<void> handleDesktopEvent(DesktopDragDropPayload payload) async {
    switch (payload) {
      case DesktopDragLeave():
        controller.isDragging.value = false;
        return;
      case DesktopDragEnter():
      case DesktopDragOver():
        if (!_disabled) controller.isDragging.value = true;
        return;
      case DesktopDrop(:final paths):
        // A drop always ends the current drag operation.
        controller.isDragging.value = false;

        if (_disabled || controller.suppressed.value) return;

        final sink = controller.getSink();
        if (sink == null) return;

        final items = [for (final path in paths) DroppedPathItem(path)];
        final onGenericFiles = sink.onGenericFiles;
        if (onGenericFiles != null && items.isNotEmpty) {
          onGenericFiles(items);
        }

        final imagePaths = paths.where(isRasterImagePath).toList();
        if (imagePaths.isEmpty) return;

        try {
          final attachments = await Future.wait(
            imagePaths.map(_filePathToImageAttachment),
          );
          if (attachments.isEmpty) return;
          // Use the sink captured at drop time, not a fresh getSink() —
          // routing belongs to the composer the user dropped on (matches the
          // DOM path below). No post-persist busy re-check: a mixed drop's own
          // generic upload flips the busy flag, and re-checking would discard
          // the image from the same drop.
          sink.onFiles(attachments);
        } catch (error) {
          onError?.call(
            '[useDropListeners] Failed to persist dropped files:',
            error,
          );
        }
    }
  }

  // -------------------------------------------------------------------------
  // DOM (element-scoped) routing
  // -------------------------------------------------------------------------

  /// A drag entered the zone's element.
  void handleDragEnter(DomDragEvent event) {
    event.preventDefault();
    event.stopPropagation();

    if (_disabled) return;

    // Incremented before the suppression check on purpose: the matching
    // dragleave decrements unconditionally, so skipping the increment here
    // would drive the counter negative and strand a later drag as "active".
    _dragCounter++;
    if (controller.suppressed.value || !controller.hasSink.value) return;

    if (_acceptsDrag(event.dataTransfer)) {
      controller.isDragging.value = true;
    }
  }

  /// A drag moved over the zone's element.
  ///
  /// Only advertises "copy" when the drop would actually be accepted, so the
  /// cursor doesn't promise a drop that the handler then discards (suppressed,
  /// archived, or no consumer mounted).
  void handleDragOver(DomDragEvent event) {
    event.preventDefault();
    event.stopPropagation();

    final dataTransfer = event.dataTransfer;
    if (dataTransfer == null) return;

    final canAccept =
        _acceptsDrag(dataTransfer) &&
        !_disabled &&
        !controller.suppressed.value &&
        controller.hasSink.value;
    dataTransfer.dropEffect = canAccept ? 'copy' : 'none';
  }

  /// A drag left the zone's element (or one of its descendants).
  void handleDragLeave(DomDragEvent event) {
    event.preventDefault();
    event.stopPropagation();

    if (_disabled) return;

    _dragCounter--;
    if (_dragCounter == 0) {
      controller.isDragging.value = false;
    }
  }

  /// A drag was released on the zone's element.
  Future<void> handleDrop(DomDragEvent event) async {
    event.preventDefault();
    event.stopPropagation();

    controller.isDragging.value = false;
    _dragCounter = 0;

    if (_disabled || controller.suppressed.value) return;

    final sink = controller.getSink();
    if (sink == null) return;

    final dataTransfer = event.dataTransfer;
    final serializedWorkspaceFile = dataTransfer?.getData(
      workspaceFileDragMime,
    );
    final onWorkspaceFile = sink.onWorkspaceFile;
    // Deviation: upstream tests the serialized string for JS truthiness, where
    // `""` (the value `getData` returns for an absent format) is falsy.
    if (serializedWorkspaceFile != null &&
        serializedWorkspaceFile.isNotEmpty &&
        onWorkspaceFile != null) {
      final payload = parseWorkspaceFileDragPayload(serializedWorkspaceFile);
      if (payload != null) {
        onWorkspaceFile(payload);
      }
    }

    final files = dataTransfer?.files ?? const <DroppedFile>[];
    final genericItems = [for (final file in files) DroppedFileItem(file)];

    final onGenericFiles = sink.onGenericFiles;
    if (onGenericFiles != null && genericItems.isNotEmpty) {
      onGenericFiles(genericItems);
    }

    final imageFiles = files
        .where((file) => isRasterImageFile(name: file.name, type: file.type))
        .toList();
    if (imageFiles.isEmpty) return;

    try {
      // Deviation: `Promise.all` rejects on the first failure while
      // `Future.wait` waits for every future before throwing. Either way the
      // whole batch is dropped and nothing reaches `onFiles`, so only the
      // timing of the diagnostic differs.
      final attachments = await Future.wait(
        imageFiles.map(_fileToImageAttachment),
      );
      // No post-persist busy re-check: a mixed drop's own generic upload flips
      // the busy flag, and re-checking would discard the image from the same
      // drop. The guard at drop start already rejects drops that begin while
      // busy.
      sink.onFiles(attachments);
    } catch (error) {
      onError?.call(
        '[useDropListeners] Failed to process dropped files:',
        error,
      );
    }
  }

  /// Whether [dataTransfer] carries something this zone would take: OS files,
  /// or an in-app workspace file the registered sink actually handles.
  bool _acceptsDrag(FileDropDataTransfer? dataTransfer) {
    if (dataTransfer == null) return false;
    final types = dataTransfer.types.toSet();
    final acceptsWorkspaceFile =
        types.contains(workspaceFileDragMime) &&
        controller.getSink()?.onWorkspaceFile != null;
    return types.contains('Files') || acceptsWorkspaceFile;
  }

  Future<ImageAttachment> _filePathToImageAttachment(String path) async {
    final mimeType = resolveRasterImageMimeType(path: path);
    if (mimeType == null) {
      throw StateError("Unsupported image type for '$path'.");
    }
    return persister.persistFromFileUri(uri: path, mimeType: mimeType);
  }

  Future<ImageAttachment> _fileToImageAttachment(DroppedFile file) async {
    final mimeType = resolveRasterImageMimeType(
      mimeType: file.type,
      path: file.name,
    );
    if (mimeType == null) {
      throw StateError("Unsupported image type for '${file.name}'.");
    }
    final bytes = await file.readAsBytes();
    return persister.persistFromBlob(
      blob: AttachmentBlob(bytes: bytes, type: file.type),
      mimeType: mimeType,
      fileName: file.name,
    );
  }
}

// ---------------------------------------------------------------------------
// file-drop-zone.tsx
// ---------------------------------------------------------------------------

/// Publishes a [PaseoFileDropController] to the subtree under a
/// [PaseoFileDropZone].
///
/// Deviation: upstream's context value carries only the three flags and
/// `registerSink`. [disabled] is carried here too — see [PaseoFileDropZone] for
/// why the zone cannot simply force `isDragging` to false the way upstream's
/// effect does.
class PaseoFileDropScope extends InheritedWidget {
  const PaseoFileDropScope({
    required this.controller,
    required this.disabled,
    required super.child,
    super.key,
  });

  final PaseoFileDropController controller;

  /// Whether the surrounding zone is currently refusing drops.
  final bool disabled;

  /// The nearest zone's controller, or `null` when there is no zone above —
  /// mirroring `useFileDropContext()` returning `null`.
  static PaseoFileDropController? maybeOf(BuildContext context) =>
      maybeScopeOf(context)?.controller;

  /// The nearest scope itself, for readers that also need [disabled].
  static PaseoFileDropScope? maybeScopeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaseoFileDropScope>();

  @override
  bool updateShouldNotify(PaseoFileDropScope oldWidget) =>
      !identical(oldWidget.controller, controller) ||
      oldWidget.disabled != disabled;
}

/// Defines a drag-and-drop area and renders its dim backdrop.
///
/// Files are consumed by any descendant that registers a
/// [PaseoFileDropRegistration] against [PaseoFileDropScope.maybeOf] — the drop
/// area, the backdrop, and the consumer are decoupled, so a consumer's layout
/// can never collapse the backdrop.
///
/// Deviations:
/// - Upstream takes a `style` prop that sizes the area. Flutter callers size a
///   widget by wrapping it, so there is no style prop; the zone lays out as a
///   loose [Stack], which takes the size of [child] exactly as upstream's
///   `position: relative` container with no default flex does.
/// - Upstream forces `isDragging` to false from the listener effect when the
///   zone becomes disabled. Writing to a [ValueNotifier] from `didUpdateWidget`
///   would mark the backdrop dirty mid-build, so the flag is published to the
///   subtree instead and folded into the backdrop's visibility. The actual
///   clearing still happens where upstream puts it — in
///   [PaseoDropListeners.disabled], which the caller keeps in sync.
class PaseoFileDropZone extends StatefulWidget {
  const PaseoFileDropZone({
    required this.child,
    this.controller,
    this.disabled = false,
    this.dropSupported = true,
    this.translate,
    super.key,
  });

  final Widget child;

  /// Forwarded to the backdrop so its label resolves through the app's
  /// translator rather than shipping English into the other seven locales.
  final String Function(String key)? translate;

  /// The controller to publish. When omitted the zone owns (and disposes) one.
  final PaseoFileDropController? controller;

  /// When true, no drops are accepted and the backdrop stays hidden.
  final bool disabled;

  /// Whether this platform has drag-and-drop.
  ///
  /// Mirrors upstream's `isWeb` branch: on a platform without it the zone still
  /// renders its layout container and still provides the context (so consumers
  /// no-op safely), but renders no backdrop.
  final bool dropSupported;

  @override
  State<PaseoFileDropZone> createState() => _PaseoFileDropZoneState();
}

class _PaseoFileDropZoneState extends State<PaseoFileDropZone> {
  PaseoFileDropController? _ownedController;

  PaseoFileDropController get _controller =>
      widget.controller ?? (_ownedController ??= PaseoFileDropController());

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PaseoFileDropScope(
      controller: _controller,
      disabled: widget.disabled,
      child: widget.dropSupported
          ? Stack(
              children: [
                widget.child,
                Positioned.fill(
                  child: PaseoFileDropBackdrop(translate: widget.translate),
                ),
              ],
            )
          : widget.child,
    );
  }
}

// ---------------------------------------------------------------------------
// file-drop-backdrop.tsx
// ---------------------------------------------------------------------------

/// The "Drop files here" overlay rendered by [PaseoFileDropZone].
///
/// Listens to the controller's notifiers directly, so a drag entering or
/// leaving repaints this overlay and nothing else — the Flutter equivalent of
/// upstream reading the shared values on the UI thread.
class PaseoFileDropBackdrop extends StatelessWidget {
  const PaseoFileDropBackdrop({super.key, this.translate});

  /// Resolves `composer.attachments.dropFilesHere`.
  ///
  /// Injected rather than read from a global, matching the translator idiom
  /// the ported rules already use (`ComposerTranslator`,
  /// `defaultWorktreeArchiveWarningLabels`). Falling back to the frozen
  /// English keeps the widget usable before a locale has loaded, since
  /// `Translations` resolves asynchronously off the asset bundle.
  final String Function(String key)? translate;

  /// The frozen English for `composer.attachments.dropFilesHere`.
  static const String dropFilesHereLabel = 'Drop files here';

  /// The key this label resolves through.
  static const String dropFilesHereKey = 'composer.attachments.dropFilesHere';

  /// Fade duration of the overlay, frozen from upstream's `withTiming(...,
  /// { duration: 150 })`.
  static const Duration fadeDuration = Duration(milliseconds: 150);

  /// Opacity of the dim layer, frozen from upstream's `opacity: 0.7`.
  static const double dimOpacity = 0.7;

  /// Size of the upload glyph, frozen from upstream's `size={32}`.
  static const double iconSize = 32;

  /// Key on the fading overlay, so tests can read the target opacity.
  static const Key overlayKey = ValueKey('paseo-file-drop-backdrop-overlay');

  /// Key on the dim layer, so tests can read its colour and opacity.
  static const Key dimKey = ValueKey('paseo-file-drop-backdrop-dim');

  /// Key on the glyph/label gap, so tests can read the spacing step. [Icon]
  /// builds its own [SizedBox], so the gap needs an identity of its own.
  static const Key gapKey = ValueKey('paseo-file-drop-backdrop-gap');

  @override
  Widget build(BuildContext context) {
    final scope = PaseoFileDropScope.maybeScopeOf(context);
    if (scope == null) return const SizedBox.shrink();

    final controller = scope.controller;
    final palette = context.paseoPalette;

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([
          controller.isDragging,
          controller.suppressed,
          controller.hasSink,
        ]),
        builder: (context, child) {
          final active =
              controller.isDragging.value &&
              controller.hasSink.value &&
              !controller.suppressed.value &&
              !scope.disabled;
          return AnimatedOpacity(
            key: overlayKey,
            opacity: active ? 1 : 0,
            duration: fadeDuration,
            child: child,
          );
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Opacity(
                key: dimKey,
                opacity: dimOpacity,
                child: ColoredBox(color: palette.surface0),
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    FluentIcons.upload,
                    size: iconSize,
                    color: context.tokens.primary,
                  ),
                  const SizedBox(key: gapKey, height: PaseoSpacing.s2),
                  Text(
                    translate?.call(dropFilesHereKey) ?? dropFilesHereLabel,
                    // Deviation: upstream pins 16px (`fontSize.base`). This app
                    // renders every ported label off the Fluent type ramp, so
                    // the label follows `bodyMedium` and only the weight and
                    // colour are carried over verbatim.
                    style: context.textStyles.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: palette.foreground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
