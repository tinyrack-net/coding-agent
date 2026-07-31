// Ports of the upstream Vitest suites for Paseo 0.2.0's six desktop-host
// runtime modules — `features/browser-webviews/registry.test.ts`,
// `features/browser-webviews/index.test.ts`,
// `features/browser-keyboard/index.test.ts`, `features/auto-updater.test.ts`,
// `features/menu.test.ts` and `features/editor-targets/runtime.test.ts` —
// together with the edges those suites leave unpinned: the application-menu
// template itself (upstream never asserts on it), the shortcut-capture state
// machine, the terminal context menu, the navigation guards, the
// electron-updater adapter's one-shot event wiring, PATH resolution on both
// platform flavours, and every branch of the `cmd.exe` quoting rule.
import 'dart:async';
import 'dart:typed_data';

import 'package:coding_agent_app/desktop/paseo_desktop_features.dart'
    show
        EditorTargetImageIcon,
        EditorTargetSymbol,
        EditorTargetSymbolIcon,
        paseoBrowserProfilePartition,
        parseRolloutManifest;
import 'package:coding_agent_app/desktop/paseo_desktop_webviews.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes — browser-webviews
// ---------------------------------------------------------------------------

final class _FakeRenderer implements BrowserWebContentsIdentity {
  _FakeRenderer(this.id);

  @override
  final int id;

  @override
  bool isDestroyed() => false;
}

final class _FakeBrowserGuest implements RegisteredBrowserWebContents {
  _FakeBrowserGuest(this.id, this.hostWebContents, this.session);

  @override
  final int id;

  @override
  final BrowserWebContentsIdentity? hostWebContents;

  @override
  final Object session;

  final List<bool> backgroundThrottlingCalls = <bool>[];
  void Function()? _destroyedListener;
  bool _destroyed = false;

  @override
  bool isDestroyed() => _destroyed;

  @override
  void setBackgroundThrottling(bool allowed) =>
      backgroundThrottlingCalls.add(allowed);

  @override
  void onceDestroyed(void Function() listener) => _destroyedListener = listener;

  void destroy() {
    _destroyed = true;
    _destroyedListener?.call();
  }
}

final class _FakePaseoBrowserWebContents implements PaseoBrowserWebContents {
  _FakePaseoBrowserWebContents(this.id, {this.destroyed = false});

  @override
  final int id;

  bool destroyed;
  final List<String> reloads = <String>[];
  bool loadingMainFrame = false;

  @override
  bool isDestroyed() => destroyed;

  @override
  bool isLoadingMainFrame() => loadingMainFrame;

  @override
  void stop() => reloads.add('stop');

  @override
  void reload() => reloads.add('reload');

  @override
  void reloadIgnoringCache() => reloads.add('force-reload');

  void destroy() => destroyed = true;
}

final class _FakeNavigationEvent implements BrowserWebviewNavigationEvent {
  _FakeNavigationEvent(this.url);

  @override
  final String? url;

  bool prevented = false;

  @override
  void preventDefault() => prevented = true;
}

final class _FakeNavigationHost implements BrowserWebviewNavigationHost {
  void Function(BrowserWebviewNavigationEvent)? willNavigate;
  void Function(BrowserWebviewNavigationEvent)? willFrameNavigate;
  void Function(BrowserWebviewNavigationEvent)? willRedirect;

  @override
  void onWillNavigate(void Function(BrowserWebviewNavigationEvent) listener) =>
      willNavigate = listener;

  @override
  void onWillFrameNavigate(
    void Function(BrowserWebviewNavigationEvent) listener,
  ) => willFrameNavigate = listener;

  @override
  void onWillRedirect(void Function(BrowserWebviewNavigationEvent) listener) =>
      willRedirect = listener;
}

PaseoBrowserWebviews _createWebviews({
  Map<int, PaseoBrowserWebContents> contents = const {},
}) => PaseoBrowserWebviews(findWebContentsById: (id) => contents[id]);

// ---------------------------------------------------------------------------
// Fakes — browser-keyboard
// ---------------------------------------------------------------------------

final class _SentMessage {
  const _SentMessage(this.channel, this.payload);

  final String channel;
  final Object? payload;

  @override
  bool operator ==(Object other) =>
      other is _SentMessage &&
      other.channel == channel &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash(channel, payload);

  @override
  String toString() => '_SentMessage($channel, $payload)';
}

final class _FakeFrame implements BrowserKeyboardFrame {
  _FakeFrame(this._contents, {this.detached = false});

  final _FakeBrowserContents _contents;

  @override
  final bool detached;

  @override
  void send(String channel, Object? payload) =>
      _contents.send(channel, payload);
}

final class _FakeInputEvent implements BrowserKeyboardInputEvent {
  bool prevented = false;

  @override
  void preventDefault() => prevented = true;
}

/// Doubles as guest and host, exactly as upstream's `FakeBrowserContents` does.
final class _FakeBrowserContents
    implements BrowserKeyboardGuestContents, BrowserKeyboardHostContents {
  _FakeBrowserContents(this._webContentsId, {this.detachedFrame = false});

  final int _webContentsId;

  /// When true the single frame in the subtree reports itself detached, which
  /// must stop the policy from being delivered.
  final bool detachedFrame;

  final List<bool> ignoredMenuShortcuts = <bool>[];
  final List<String> reloads = <String>[];
  final List<_SentMessage> sent = <_SentMessage>[];
  bool loadingMainFrame = false;

  bool _destroyed = false;
  final List<void Function()> _destroyedListeners = <void Function()>[];
  final List<void Function()> _domReadyListeners = <void Function()>[];
  final List<void Function(BrowserKeyboardInputEvent, BrowserKeyboardKeyInput)>
  _inputListeners =
      <void Function(BrowserKeyboardInputEvent, BrowserKeyboardKeyInput)>[];

  /// Throws once destroyed, mirroring Electron — this is what proves the port
  /// captures the id up front instead of re-reading it in a late listener.
  @override
  int get id {
    if (_destroyed) {
      throw StateError('Object has been destroyed');
    }
    return _webContentsId;
  }

  @override
  List<BrowserKeyboardFrame> get framesInSubtree => <BrowserKeyboardFrame>[
    _FakeFrame(this, detached: detachedFrame),
  ];

  @override
  bool isDestroyed() => _destroyed;

  @override
  bool isLoadingMainFrame() => loadingMainFrame;

  @override
  void onceDestroyed(void Function() listener) =>
      _destroyedListeners.add(listener);

  @override
  void onDomReady(void Function() listener) => _domReadyListeners.add(listener);

  @override
  void onBeforeInputEvent(
    void Function(BrowserKeyboardInputEvent, BrowserKeyboardKeyInput) listener,
  ) => _inputListeners.add(listener);

  @override
  void send(String channel, Object? payload) =>
      sent.add(_SentMessage(channel, payload));

  @override
  void setIgnoreMenuShortcuts(bool ignore) => ignoredMenuShortcuts.add(ignore);

  @override
  void stop() => reloads.add('stop');

  @override
  void reload() => reloads.add('reload');

  @override
  void reloadIgnoringCache() => reloads.add('force-reload');

  void destroy() {
    _destroyed = true;
    for (final listener in List<void Function()>.from(_destroyedListeners)) {
      listener();
    }
  }

  void domReady() {
    for (final listener in List<void Function()>.from(_domReadyListeners)) {
      listener();
    }
  }

  bool input(BrowserKeyboardKeyInput keyInput) {
    final event = _FakeInputEvent();
    for (final listener
        in List<
          void Function(BrowserKeyboardInputEvent, BrowserKeyboardKeyInput)
        >.from(_inputListeners)) {
      listener(event, keyInput);
    }
    return event.prevented;
  }
}

final class _FakeIpcEvent implements BrowserKeyboardIpcEvent {
  _FakeIpcEvent(this.sender);

  @override
  final BrowserKeyboardContentsIdentity sender;

  final List<_SentMessage> replies = <_SentMessage>[];

  @override
  void reply(String channel, Object? payload) =>
      replies.add(_SentMessage(channel, payload));
}

final class _FakeIpcRegistrar implements BrowserKeyboardIpcRegistrar {
  final Map<
    String,
    void Function(BrowserKeyboardIpcEvent event, Object? payload)
  >
  handlers =
      <String, void Function(BrowserKeyboardIpcEvent event, Object? payload)>{};
  final Map<
    String,
    void Function(BrowserKeyboardIpcEvent event, Object? payload)
  >
  listeners =
      <String, void Function(BrowserKeyboardIpcEvent event, Object? payload)>{};

  @override
  void handle(
    String channel,
    void Function(BrowserKeyboardIpcEvent event, Object? payload) handler,
  ) => handlers[channel] = handler;

  @override
  void on(
    String channel,
    void Function(BrowserKeyboardIpcEvent event, Object? payload) handler,
  ) => listeners[channel] = handler;
}

final class _KeyboardHarness {
  _KeyboardHarness({this.useMeta = false})
    : registry = PaseoBrowserWebviewRegistry() {
    keyboard = BrowserKeyboard(registry, isMac: useMeta);
  }

  final PaseoBrowserWebviewRegistry registry;

  /// The command modifier for this harness's platform, matching upstream's
  /// `process.platform === "darwin" ? { meta: true } : { control: true }`.
  final bool useMeta;

  late final BrowserKeyboard keyboard;

  void attach({
    required String browserId,
    required _FakeBrowserContents contents,
    required _FakeBrowserContents hostContents,
  }) {
    final webContentsId = contents.id;
    registry.registerWebContents(
      webContentsId: webContentsId,
      browserId: browserId,
      hostWebContentsId: hostContents.id,
    );
    contents.onceDestroyed(() => registry.unregisterWebContents(webContentsId));
    keyboard.attach(contents: contents, hostContents: hostContents);
  }

  BrowserKeyboardKeyInput command({
    required String code,
    required String key,
    bool shift = false,
    bool alt = false,
    bool isAutoRepeat = false,
    String type = 'keyDown',
  }) => BrowserKeyboardKeyInput(
    code: code,
    key: key,
    alt: alt,
    control: !useMeta,
    meta: useMeta,
    shift: shift,
    isAutoRepeat: isAutoRepeat,
    type: type,
  );
}

// ---------------------------------------------------------------------------
// Fakes — menu
// ---------------------------------------------------------------------------

final class _FakeWindowWebContents implements ReloadableWindowWebContents {
  _FakeWindowWebContents(this.id);

  @override
  final int id;

  final List<String> reloads = <String>[];
  bool loadingMainFrame = false;

  @override
  bool isLoadingMainFrame() => loadingMainFrame;

  @override
  void stop() => reloads.add('stop');

  @override
  void reload() => reloads.add('reload');

  @override
  void reloadIgnoringCache() => reloads.add('force-reload');
}

final class _FakeWindow implements ReloadableWindow {
  _FakeWindow(this.webContents);

  @override
  final _FakeWindowWebContents webContents;
}

final class _BrowserReloads {
  final _FakeWindow firstWindow = _FakeWindow(_FakeWindowWebContents(101));
  final _FakeWindow secondWindow = _FakeWindow(_FakeWindowWebContents(202));
  final _FakeWindowWebContents firstBrowser = _FakeWindowWebContents(11);
  final _FakeWindowWebContents secondBrowser = _FakeWindowWebContents(22);
  final List<int> resolvedHostWindowIds = <int>[];

  ReloadableWebContents? activeBrowserForHostWindow(int hostWebContentsId) {
    resolvedHostWindowIds.add(hostWebContentsId);
    return hostWebContentsId == 101 ? firstBrowser : secondBrowser;
  }
}

// ---------------------------------------------------------------------------
// Fakes — auto-updater
// ---------------------------------------------------------------------------

final class _MissingFileError implements Exception {
  const _MissingFileError();
}

final class _FakeStagingUserIdHost implements StagingUserIdHost {
  _FakeStagingUserIdHost({this.digest});

  final Map<String, String> files = <String, String>{};
  final Set<String> directories = <String>{};
  final List<String> warnings = <String>[];
  final List<int> randomByteRequests = <int>[];
  final List<Uint8List> hashedInputs = <Uint8List>[];

  /// When set, [sha1] answers with this instead of a derived digest.
  final Uint8List? digest;

  Object? readError;
  Object? writeError;

  @override
  Future<String> readTextFile(String path) async {
    final error = readError;
    if (error != null) throw error;
    final contents = files[path];
    if (contents == null) throw const _MissingFileError();
    return contents;
  }

  @override
  bool isNotFoundError(Object error) => error is _MissingFileError;

  @override
  Future<void> createDirectory(String path) async => directories.add(path);

  @override
  Future<void> writeTextFile(String path, String contents) async {
    final error = writeError;
    if (error != null) throw error;
    files[path] = contents;
  }

  @override
  Uint8List randomBytes(int byteCount) {
    randomByteRequests.add(byteCount);
    return Uint8List.fromList(
      List<int>.generate(byteCount, (index) => index % 256),
    );
  }

  @override
  Uint8List sha1(Uint8List bytes) {
    hashedInputs.add(bytes);
    final fixed = digest;
    if (fixed != null) return fixed;
    // A deterministic stand-in: SHA-1 is 20 bytes, and only the derivation's
    // version/variant rewriting is under test here.
    return Uint8List.fromList(
      List<int>.generate(20, (index) => (bytes.length + index * 7) % 256),
    );
  }

  @override
  void warn(String message) => warnings.add(message);
}

final class _FakeElectronUpdater implements ElectronUpdaterPort {
  bool? autoDownloadValue;
  bool? autoRunAppAfterInstallValue;
  bool? autoInstallOnAppQuitValue;
  bool? allowPrereleaseValue;
  String? channelValue;
  bool? allowDowngradeValue;
  Future<bool> Function(DesktopAppUpdateInfo info)? rolloutHook;

  final List<void Function(DesktopAppUpdateInfo)> availableListeners =
      <void Function(DesktopAppUpdateInfo)>[];
  final List<void Function(DesktopAppUpdateInfo)> downloadedListeners =
      <void Function(DesktopAppUpdateInfo)>[];
  final List<void Function()> notAvailableListeners = <void Function()>[];
  final List<void Function(Object, StackTrace)> errorListeners =
      <void Function(Object, StackTrace)>[];

  final List<String> calls = <String>[];
  DesktopAppRuntimeCheckResult? checkResult;

  @override
  set autoDownload(bool value) => autoDownloadValue = value;

  @override
  set autoRunAppAfterInstall(bool value) => autoRunAppAfterInstallValue = value;

  @override
  set autoInstallOnAppQuit(bool value) => autoInstallOnAppQuitValue = value;

  @override
  set allowPrerelease(bool value) => allowPrereleaseValue = value;

  @override
  set channel(String value) => channelValue = value;

  @override
  set allowDowngrade(bool value) => allowDowngradeValue = value;

  @override
  set isUserWithinRollout(
    Future<bool> Function(DesktopAppUpdateInfo info)? hook,
  ) => rolloutHook = hook;

  @override
  void onUpdateAvailable(void Function(DesktopAppUpdateInfo info) listener) =>
      availableListeners.add(listener);

  @override
  void onUpdateDownloaded(void Function(DesktopAppUpdateInfo info) listener) =>
      downloadedListeners.add(listener);

  @override
  void onUpdateNotAvailable(void Function() listener) =>
      notAvailableListeners.add(listener);

  @override
  void onError(void Function(Object error, StackTrace stackTrace) listener) =>
      errorListeners.add(listener);

  @override
  Future<DesktopAppRuntimeCheckResult?> checkForUpdates() async {
    calls.add('checkForUpdates');
    return checkResult;
  }

  @override
  Future<void> downloadUpdate() async => calls.add('downloadUpdate');

  @override
  void quitAndInstall({required bool silent, required bool restart}) =>
      calls.add('quitAndInstall(silent: $silent, restart: $restart)');
}

DesktopAppUpdateRuntimeConfiguration _updateConfiguration({
  required DesktopAppReleaseChannel channel,
  FutureOr<bool> Function(DesktopAppUpdateInfo info)? shouldAdmitUpdate,
  void Function(DesktopAppUpdateInfo info)? onUpdateAvailable,
  void Function(DesktopAppUpdateInfo info)? onUpdateDownloaded,
  void Function()? onUpdateNotAvailable,
  void Function(Object error, StackTrace stackTrace)? onError,
}) => DesktopAppUpdateRuntimeConfiguration(
  releaseChannel: channel,
  shouldAdmitUpdate: shouldAdmitUpdate ?? ((_) => true),
  onUpdateAvailable: onUpdateAvailable ?? ((_) {}),
  onUpdateDownloaded: onUpdateDownloaded ?? ((_) {}),
  onUpdateNotAvailable: onUpdateNotAvailable ?? () {},
  onError: onError ?? ((_, _) {}),
);

// ---------------------------------------------------------------------------
// Fakes — editor runtime
// ---------------------------------------------------------------------------

final class _SpawnRecord {
  _SpawnRecord(this.command, this.args, this.options);

  final String command;
  final List<String> args;
  final EditorProcessSpawnOptions options;
  bool unrefed = false;
}

final class _FakeChild implements SpawnedEditorProcess {
  _FakeChild(this._record, {this.failWith});

  final _SpawnRecord _record;
  final Object? failWith;

  @override
  void onceError(void Function(Object error) handler) {
    final error = failWith;
    if (error != null) scheduleMicrotask(() => handler(error));
  }

  @override
  void onceSpawn(void Function() handler) {
    if (failWith != null) return;
    scheduleMicrotask(handler);
  }

  @override
  void unref() => _record.unrefed = true;
}

// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // browser-webviews/registry.ts
  // =========================================================================
  group('PaseoBrowserWebviewRegistry', () {
    test('keeps one authoritative webContents target per host and browser', () {
      final registry = PaseoBrowserWebviewRegistry();

      registry.registerWebContents(
        webContentsId: 1,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.registerWorkspace(
        const BrowserWorkspaceRegistration(
          browserId: 'browser-a',
          workspaceId: 'workspace-a',
        ),
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );
      registry.registerWebContents(
        webContentsId: 2,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );

      expect(registry.getBrowserIdForWebContents(1), isNull);
      expect(registry.getBrowserIdForWebContents(2), 'browser-a');
      expect(
        registry.getRegistrationForWebContents(2),
        const BrowserWebContentsRegistration(
          browserId: 'browser-a',
          hostWebContentsId: 101,
        ),
      );
      expect(
        registry.getWebContentsIdForBrowserInHostWindow(101, 'browser-a'),
        2,
      );
      expect(registry.getWorkspaceId('browser-a'), 'workspace-a');
      expect(registry.getActiveBrowserIdForHostWindow(101), 'browser-a');
    });

    test('keeps the active browser when the same guest registers again', () {
      final registry = PaseoBrowserWebviewRegistry();

      registry.registerWebContents(
        webContentsId: 1,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );

      registry.registerWebContents(
        webContentsId: 1,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );

      expect(
        registry.getActiveBrowserIdForWorkspaceInHostWindow(101, 'workspace-a'),
        'browser-a',
      );
      expect(
        registry.getWebContentsIdForBrowserInHostWindow(101, 'browser-a'),
        1,
      );
    });

    test('ignores stale destroy events after a duplicate browserId moved', () {
      final registry = PaseoBrowserWebviewRegistry();

      registry.registerWebContents(
        webContentsId: 1,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 2,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.unregisterWebContents(1);

      expect(
        registry.getWebContentsIdForBrowserInHostWindow(101, 'browser-a'),
        2,
      );
    });

    test('returns the active browser only from the requested host window', () {
      final registry = PaseoBrowserWebviewRegistry();

      registry.registerWebContents(
        webContentsId: 11,
        browserId: 'browser-first-window',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 22,
        browserId: 'browser-second-window',
        hostWebContentsId: 202,
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-first-window',
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 202,
        workspaceId: 'workspace-a',
        browserId: 'browser-second-window',
      );

      expect(
        registry.getActiveBrowserIdForHostWindow(101),
        'browser-first-window',
      );
      expect(
        registry.getActiveBrowserIdForHostWindow(202),
        'browser-second-window',
      );
      expect(
        registry.getActiveBrowserIdForWorkspaceInHostWindow(101, 'workspace-a'),
        'browser-first-window',
      );
      expect(
        registry.getActiveBrowserIdForWorkspaceInHostWindow(202, 'workspace-a'),
        'browser-second-window',
      );
    });

    test('keeps active updates and clears inside their owning host window', () {
      final registry = PaseoBrowserWebviewRegistry();

      registry.registerWebContents(
        webContentsId: 11,
        browserId: 'browser-first-window',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 22,
        browserId: 'browser-second-window',
        hostWebContentsId: 202,
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-first-window',
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 202,
        workspaceId: 'workspace-a',
        browserId: 'browser-second-window',
      );

      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-second-window',
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: null,
      );

      expect(registry.getActiveBrowserIdForHostWindow(101), isNull);
      expect(
        registry.getActiveBrowserIdForHostWindow(202),
        'browser-second-window',
      );
    });

    test('keeps same-browser active references in separate host windows', () {
      final registry = PaseoBrowserWebviewRegistry();

      registry.registerWebContents(
        webContentsId: 11,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );
      registry.registerWebContents(
        webContentsId: 22,
        browserId: 'browser-a',
        hostWebContentsId: 202,
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 202,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );

      expect(registry.getActiveBrowserIdForHostWindow(101), 'browser-a');
      expect(registry.getActiveBrowserIdForHostWindow(202), 'browser-a');
      expect(
        registry.getWebContentsIdForBrowserInHostWindow(101, 'browser-a'),
        11,
      );
      expect(
        registry.getWebContentsIdForBrowserInHostWindow(202, 'browser-a'),
        22,
      );
    });

    test("removes only the closing host's same-browser guest", () {
      final registry = PaseoBrowserWebviewRegistry();

      registry.registerWebContents(
        webContentsId: 11,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 22,
        browserId: 'browser-a',
        hostWebContentsId: 202,
      );

      registry.unregisterHostWebContents(101);

      expect(registry.getRegistrationForWebContents(11), isNull);
      expect(
        registry.getWebContentsIdForBrowserInHostWindow(101, 'browser-a'),
        isNull,
      );
      expect(
        registry.getRegistrationForWebContents(22),
        const BrowserWebContentsRegistration(
          browserId: 'browser-a',
          hostWebContentsId: 202,
        ),
      );
      expect(
        registry.getWebContentsIdForBrowserInHostWindow(202, 'browser-a'),
        22,
      );
    });

    test('unregisters a browser only from the requesting host', () {
      final registry = PaseoBrowserWebviewRegistry();
      registry.registerWebContents(
        webContentsId: 11,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 22,
        browserId: 'browser-a',
        hostWebContentsId: 202,
      );
      registry.registerWorkspace(
        const BrowserWorkspaceRegistration(
          browserId: 'browser-a',
          workspaceId: 'workspace-a',
        ),
      );

      registry.unregisterBrowserFromHost(101, 'browser-a');

      expect(
        registry.getWebContentsIdForBrowserInHostWindow(101, 'browser-a'),
        isNull,
      );
      expect(
        registry.getWebContentsIdForBrowserInHostWindow(202, 'browser-a'),
        22,
      );
      expect(registry.getWorkspaceId('browser-a'), 'workspace-a');
    });

    test("keeps another host's active browser when one guest is destroyed", () {
      final registry = PaseoBrowserWebviewRegistry();

      registry.registerWebContents(
        webContentsId: 11,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 22,
        browserId: 'browser-a',
        hostWebContentsId: 202,
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 202,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );

      registry.unregisterWebContents(11);

      expect(registry.getActiveBrowserIdForHostWindow(101), isNull);
      expect(registry.getActiveBrowserIdForHostWindow(202), 'browser-a');
      expect(
        registry.getWebContentsIdForBrowserInHostWindow(202, 'browser-a'),
        22,
      );
    });

    test(
      'keeps the same-window active selection made before the guest attaches',
      () {
        final registry = PaseoBrowserWebviewRegistry();

        registry.setWorkspaceActiveBrowser(
          hostWebContentsId: 101,
          workspaceId: 'workspace-a',
          browserId: 'browser-a',
        );
        registry.registerWebContents(
          webContentsId: 11,
          browserId: 'browser-a',
          hostWebContentsId: 101,
        );

        expect(registry.getActiveBrowserIdForHostWindow(101), 'browser-a');
      },
    );

    test(
      'keeps a pre-attach selection when another host attaches the same browser',
      () {
        final registry = PaseoBrowserWebviewRegistry();

        registry.setWorkspaceActiveBrowser(
          hostWebContentsId: 101,
          workspaceId: 'workspace-a',
          browserId: 'browser-a',
        );
        registry.registerWebContents(
          webContentsId: 11,
          browserId: 'browser-a',
          hostWebContentsId: 202,
        );

        expect(registry.getActiveBrowserIdForHostWindow(101), 'browser-a');
        expect(registry.getActiveBrowserIdForHostWindow(202), isNull);
      },
    );

    test(
      'keeps a pre-attach selection when another host tears down the same browser',
      () {
        final registry = PaseoBrowserWebviewRegistry();

        registry.setWorkspaceActiveBrowser(
          hostWebContentsId: 101,
          workspaceId: 'workspace-a',
          browserId: 'browser-a',
        );
        registry.registerWebContents(
          webContentsId: 22,
          browserId: 'browser-a',
          hostWebContentsId: 202,
        );
        registry.unregisterWebContents(22);
        registry.registerWebContents(
          webContentsId: 11,
          browserId: 'browser-a',
          hostWebContentsId: 101,
        );

        expect(registry.getActiveBrowserIdForHostWindow(101), 'browser-a');
      },
    );

    test('reports when another host still owns the same browser', () {
      final registry = PaseoBrowserWebviewRegistry();
      registry.registerWebContents(
        webContentsId: 11,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 22,
        browserId: 'browser-a',
        hostWebContentsId: 202,
      );

      expect(registry.hasBrowserInOtherHostWindow(101, 'browser-a'), isTrue);
      expect(registry.hasBrowserInOtherHostWindow(202, 'browser-a'), isTrue);
      expect(registry.hasBrowserInOtherHostWindow(101, 'browser-b'), isFalse);

      registry.unregisterWebContents(22);

      expect(registry.hasBrowserInOtherHostWindow(101, 'browser-a'), isFalse);
    });

    test('sorts browser ids and filters them by workspace', () {
      final registry = PaseoBrowserWebviewRegistry();
      registry.registerWebContents(
        webContentsId: 3,
        browserId: 'browser-c',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 1,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 2,
        browserId: 'browser-b',
        hostWebContentsId: 101,
      );
      registry.registerWorkspace(
        const BrowserWorkspaceRegistration(
          browserId: 'browser-a',
          workspaceId: 'workspace-a',
        ),
      );
      registry.registerWorkspace(
        const BrowserWorkspaceRegistration(
          browserId: 'browser-c',
          workspaceId: 'workspace-a',
        ),
      );

      expect(registry.listBrowserIds(), <String>[
        'browser-a',
        'browser-b',
        'browser-c',
      ]);
      expect(registry.listBrowserIdsForWorkspace('workspace-a'), <String>[
        'browser-a',
        'browser-c',
      ]);
      expect(registry.listBrowserIdsForWorkspace('workspace-z'), isEmpty);
    });

    test('drops the whole browser and every active reference to it', () {
      final registry = PaseoBrowserWebviewRegistry();
      registry.registerWebContents(
        webContentsId: 11,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 22,
        browserId: 'browser-a',
        hostWebContentsId: 202,
      );
      registry.registerWorkspace(
        const BrowserWorkspaceRegistration(
          browserId: 'browser-a',
          workspaceId: 'workspace-a',
        ),
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 202,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );

      registry.unregisterBrowser('browser-a');

      expect(registry.listBrowserIds(), isEmpty);
      expect(registry.getWorkspaceId('browser-a'), isNull);
      expect(registry.getActiveBrowserIdForHostWindow(101), isNull);
      expect(registry.getActiveBrowserIdForHostWindow(202), isNull);
      expect(
        registry.getMostRecentActiveBrowserIdForWorkspace('workspace-a'),
        isNull,
      );
    });

    test('follows the most recently activated host window for a workspace', () {
      final registry = PaseoBrowserWebviewRegistry();
      registry.registerWebContents(
        webContentsId: 11,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );
      registry.registerWebContents(
        webContentsId: 22,
        browserId: 'browser-b',
        hostWebContentsId: 202,
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 202,
        workspaceId: 'workspace-a',
        browserId: 'browser-b',
      );

      expect(
        registry.getMostRecentActiveBrowserIdForWorkspace('workspace-a'),
        'browser-b',
      );

      // Re-activating in window 101 moves it to the end of the host-window map.
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );

      expect(
        registry.getMostRecentActiveBrowserIdForWorkspace('workspace-a'),
        'browser-a',
      );
      expect(
        registry.getMostRecentActiveBrowserIdForWorkspace('workspace-z'),
        isNull,
      );
    });

    test(
      'binds a workspace on activation only for an already-attached browser',
      () {
        final registry = PaseoBrowserWebviewRegistry();

        registry.setWorkspaceActiveBrowser(
          hostWebContentsId: 101,
          workspaceId: 'workspace-a',
          browserId: 'browser-ghost',
        );
        expect(registry.getWorkspaceId('browser-ghost'), isNull);

        registry.registerWebContents(
          webContentsId: 11,
          browserId: 'browser-real',
          hostWebContentsId: 101,
        );
        registry.setWorkspaceActiveBrowser(
          hostWebContentsId: 101,
          workspaceId: 'workspace-a',
          browserId: 'browser-real',
        );
        expect(registry.getWorkspaceId('browser-real'), 'workspace-a');
      },
    );

    test('clearing the last workspace drops the host window entry', () {
      final registry = PaseoBrowserWebviewRegistry();

      // Clearing an unknown host window is a no-op rather than an error.
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 999,
        workspaceId: 'workspace-a',
        browserId: null,
      );

      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-b',
        browserId: 'browser-b',
      );
      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-b',
        browserId: null,
      );

      expect(registry.getActiveBrowserIdForHostWindow(101), 'browser-a');

      registry.setWorkspaceActiveBrowser(
        hostWebContentsId: 101,
        workspaceId: 'workspace-a',
        browserId: null,
      );

      expect(registry.getActiveBrowserIdForHostWindow(101), isNull);
    });

    test('unregistering an unknown guest changes nothing', () {
      final registry = PaseoBrowserWebviewRegistry();
      registry.registerWebContents(
        webContentsId: 11,
        browserId: 'browser-a',
        hostWebContentsId: 101,
      );

      registry.unregisterWebContents(999);
      registry.unregisterBrowserFromHost(101, 'browser-missing');

      expect(registry.getBrowserIdForWebContents(11), 'browser-a');
    });
  });

  // =========================================================================
  // browser-webviews/index.ts
  // =========================================================================
  group('browser webview attachment', () {
    test('accepts only allowed URLs on the shared profile partition', () {
      expect(
        isPaseoBrowserWebviewAttach(
          src: 'https://example.com',
          partition: paseoBrowserProfilePartition,
        ),
        isTrue,
      );
      expect(
        isPaseoBrowserWebviewAttach(
          src: 'https://example.com',
          partition: 'persist:paseo-browser-tab-a',
        ),
        isFalse,
      );
      expect(
        isPaseoBrowserWebviewAttach(
          src: 'https://example.com',
          partition: 'persist:foreign',
        ),
        isFalse,
      );
    });

    test(
      'treats an absent src as allowed but still requires the partition',
      () {
        expect(
          isPaseoBrowserWebviewAttach(partition: paseoBrowserProfilePartition),
          isTrue,
        );
        expect(
          isPaseoBrowserWebviewAttach(
            src: '',
            partition: paseoBrowserProfilePartition,
          ),
          isTrue,
        );
        expect(
          isPaseoBrowserWebviewAttach(src: 'https://example.com'),
          isFalse,
        );
        expect(
          isPaseoBrowserWebviewAttach(
            src: 'file:///etc/passwd',
            partition: paseoBrowserProfilePartition,
          ),
          isFalse,
        );
        expect(
          isPaseoBrowserWebviewAttach(
            src: 'about:blank',
            partition: paseoBrowserProfilePartition,
          ),
          isTrue,
        );
      },
    );

    test(
      'binds explicit browser identity to the renderer that hosts the guest',
      () {
        final webviews = _createWebviews();
        final profileSession = Object();
        final renderer = _FakeRenderer(1);
        final guest = _FakeBrowserGuest(101, renderer, profileSession);

        final registered = webviews.registerAttachedPaseoBrowser(
          browserId: 'browser-a',
          workspaceId: 'workspace-a',
          webContentsId: guest.id,
          sender: renderer,
          profileSession: profileSession,
          findWebContents: (_) => guest,
        );

        expect(registered, isTrue);
        expect(webviews.getPaseoBrowserIdForWebContents(guest), 'browser-a');
        expect(webviews.getPaseoBrowserWorkspaceId('browser-a'), 'workspace-a');
        expect(webviews.listRegisteredPaseoBrowserIds(), <String>['browser-a']);
        expect(
          webviews.listRegisteredPaseoBrowserIdsForWorkspace('workspace-a'),
          <String>['browser-a'],
        );
      },
    );

    test('rejects a guest hosted by another renderer', () {
      final webviews = _createWebviews();
      final profileSession = Object();
      final owner = _FakeRenderer(1);
      final claimant = _FakeRenderer(2);
      final guest = _FakeBrowserGuest(201, owner, profileSession);

      final registered = webviews.registerAttachedPaseoBrowser(
        browserId: 'browser-rejected-owner',
        workspaceId: 'workspace-a',
        webContentsId: guest.id,
        sender: claimant,
        profileSession: profileSession,
        findWebContents: (_) => guest,
      );

      expect(registered, isFalse);
      expect(webviews.getPaseoBrowserIdForWebContents(guest), isNull);
    });

    test('rejects a guest outside the shared profile', () {
      final webviews = _createWebviews();
      final profileSession = Object();
      final renderer = _FakeRenderer(1);
      final guest = _FakeBrowserGuest(301, renderer, Object());

      final registered = webviews.registerAttachedPaseoBrowser(
        browserId: 'browser-rejected-profile',
        workspaceId: 'workspace-a',
        webContentsId: guest.id,
        sender: renderer,
        profileSession: profileSession,
        findWebContents: (_) => guest,
      );

      expect(registered, isFalse);
      expect(webviews.getPaseoBrowserIdForWebContents(guest), isNull);
    });

    test('rejects a missing or already-destroyed guest', () {
      final webviews = _createWebviews();
      final profileSession = Object();
      final renderer = _FakeRenderer(1);
      final guest = _FakeBrowserGuest(401, renderer, profileSession)..destroy();

      expect(
        webviews.registerAttachedPaseoBrowser(
          browserId: 'browser-missing',
          workspaceId: 'workspace-a',
          webContentsId: 999,
          sender: renderer,
          profileSession: profileSession,
          findWebContents: (_) => null,
        ),
        isFalse,
      );
      expect(
        webviews.registerAttachedPaseoBrowser(
          browserId: 'browser-destroyed',
          workspaceId: 'workspace-a',
          webContentsId: guest.id,
          sender: renderer,
          profileSession: profileSession,
          findWebContents: (_) => guest,
        ),
        isFalse,
      );
      expect(webviews.listRegisteredPaseoBrowserIds(), isEmpty);
    });

    test('concurrent windows cannot swap browser identities', () {
      final webviews = _createWebviews();
      final profileSession = Object();
      final firstRenderer = _FakeRenderer(1);
      final secondRenderer = _FakeRenderer(2);
      final firstGuest = _FakeBrowserGuest(401, firstRenderer, profileSession);
      final secondGuest = _FakeBrowserGuest(
        402,
        secondRenderer,
        profileSession,
      );
      final guests = <int, _FakeBrowserGuest>{
        firstGuest.id: firstGuest,
        secondGuest.id: secondGuest,
      };

      webviews.registerAttachedPaseoBrowser(
        browserId: 'browser-second',
        workspaceId: 'workspace-second',
        webContentsId: secondGuest.id,
        sender: secondRenderer,
        profileSession: profileSession,
        findWebContents: (id) => guests[id],
      );
      webviews.registerAttachedPaseoBrowser(
        browserId: 'browser-first',
        workspaceId: 'workspace-first',
        webContentsId: firstGuest.id,
        sender: firstRenderer,
        profileSession: profileSession,
        findWebContents: (id) => guests[id],
      );

      expect(
        webviews.getPaseoBrowserIdForWebContents(firstGuest),
        'browser-first',
      );
      expect(
        webviews.getPaseoBrowserIdForWebContents(secondGuest),
        'browser-second',
      );
    });

    test('unregisters the same browser only from its requesting host', () {
      final webviews = _createWebviews();
      final profileSession = Object();
      final firstRenderer = _FakeRenderer(11);
      final secondRenderer = _FakeRenderer(22);
      final firstGuest = _FakeBrowserGuest(501, firstRenderer, profileSession);
      final secondGuest = _FakeBrowserGuest(
        502,
        secondRenderer,
        profileSession,
      );

      for (final pair in <(_FakeRenderer, _FakeBrowserGuest)>[
        (firstRenderer, firstGuest),
        (secondRenderer, secondGuest),
      ]) {
        webviews.registerAttachedPaseoBrowser(
          browserId: 'browser-shared-hosts',
          workspaceId: 'workspace-shared',
          webContentsId: pair.$2.id,
          sender: pair.$1,
          profileSession: profileSession,
          findWebContents: (_) => pair.$2,
        );
      }

      webviews.unregisterPaseoBrowserFromHost(
        firstRenderer.id,
        'browser-shared-hosts',
      );

      expect(webviews.getPaseoBrowserIdForWebContents(firstGuest), isNull);
      expect(
        webviews.getPaseoBrowserIdForWebContents(secondGuest),
        'browser-shared-hosts',
      );
      expect(
        webviews.getPaseoBrowserWorkspaceId('browser-shared-hosts'),
        'workspace-shared',
      );

      webviews.unregisterPaseoBrowser('browser-shared-hosts');
      expect(webviews.listRegisteredPaseoBrowserIds(), isEmpty);
    });

    test(
      'prepares throttling once and removes registration when the guest is destroyed',
      () {
        final webviews = _createWebviews();
        final profileSession = Object();
        final renderer = _FakeRenderer(31);
        final guest = _FakeBrowserGuest(601, renderer, profileSession);
        webviews.preparePaseoBrowserWebContents(guest);
        webviews.registerAttachedPaseoBrowser(
          browserId: 'browser-cleanup',
          workspaceId: 'workspace-cleanup',
          webContentsId: guest.id,
          sender: renderer,
          profileSession: profileSession,
          findWebContents: (_) => guest,
        );

        expect(guest.backgroundThrottlingCalls, <bool>[false]);
        expect(
          webviews.getPaseoBrowserIdForWebContents(guest),
          'browser-cleanup',
        );

        guest.destroy();

        expect(webviews.getPaseoBrowserIdForWebContents(guest), isNull);
        expect(guest.backgroundThrottlingCalls, <bool>[false]);
      },
    );

    test('a null or destroyed contents never resolves to a browser id', () {
      final webviews = _createWebviews();
      expect(webviews.getPaseoBrowserIdForWebContents(null), isNull);
    });

    test('closing a host window forgets everything it owned', () {
      final webviews = _createWebviews();
      final profileSession = Object();
      final renderer = _FakeRenderer(7);
      final guest = _FakeBrowserGuest(701, renderer, profileSession);
      webviews.registerAttachedPaseoBrowser(
        browserId: 'browser-a',
        workspaceId: 'workspace-a',
        webContentsId: guest.id,
        sender: renderer,
        profileSession: profileSession,
        findWebContents: (_) => guest,
      );
      webviews.setWorkspaceActivePaseoBrowserId(
        hostWebContentsId: 7,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );

      expect(
        webviews.getWorkspaceActivePaseoBrowserId('workspace-a'),
        'browser-a',
      );
      expect(
        webviews.getWorkspaceActivePaseoBrowserIdForHostWindow(
          'workspace-a',
          7,
        ),
        'browser-a',
      );

      webviews.unregisterPaseoBrowserHost(7);

      expect(webviews.listRegisteredPaseoBrowserIds(), isEmpty);
      expect(webviews.getWorkspaceActivePaseoBrowserId('workspace-a'), isNull);
    });

    test('resolves a live guest and prunes a vanished one', () {
      final live = _FakePaseoBrowserWebContents(801);
      final dead = _FakePaseoBrowserWebContents(802, destroyed: true);
      final webviews = _createWebviews(
        contents: <int, PaseoBrowserWebContents>{801: live, 802: dead},
      );
      final profileSession = Object();
      final renderer = _FakeRenderer(9);
      final liveGuest = _FakeBrowserGuest(801, renderer, profileSession);
      final deadGuest = _FakeBrowserGuest(802, renderer, profileSession);

      webviews.registerAttachedPaseoBrowser(
        browserId: 'browser-live',
        workspaceId: 'workspace-a',
        webContentsId: 801,
        sender: renderer,
        profileSession: profileSession,
        findWebContents: (_) => liveGuest,
      );
      webviews.registerAttachedPaseoBrowser(
        browserId: 'browser-dead',
        workspaceId: 'workspace-a',
        webContentsId: 802,
        sender: renderer,
        profileSession: profileSession,
        findWebContents: (_) => deadGuest,
      );

      expect(
        webviews.getPaseoBrowserWebContentsForHostWindow('browser-live', 9),
        same(live),
      );
      expect(
        webviews.getPaseoBrowserWebContentsForHostWindow('browser-dead', 9),
        isNull,
      );
      // Pruned on the way out, so the registry self-heals.
      expect(webviews.listRegisteredPaseoBrowserIds(), <String>[
        'browser-live',
      ]);
      expect(
        webviews.getPaseoBrowserWebContentsForHostWindow('browser-unknown', 9),
        isNull,
      );
    });

    test('resolves the active guest for a host window', () {
      final live = _FakePaseoBrowserWebContents(901);
      final webviews = _createWebviews(
        contents: <int, PaseoBrowserWebContents>{901: live},
      );
      final profileSession = Object();
      final renderer = _FakeRenderer(3);
      final guest = _FakeBrowserGuest(901, renderer, profileSession);

      expect(
        webviews.getActivePaseoBrowserWebContentsForHostWindow(3),
        isNull,
        reason: 'no active browser yet',
      );

      webviews.registerAttachedPaseoBrowser(
        browserId: 'browser-a',
        workspaceId: 'workspace-a',
        webContentsId: 901,
        sender: renderer,
        profileSession: profileSession,
        findWebContents: (_) => guest,
      );
      webviews.setWorkspaceActivePaseoBrowserId(
        hostWebContentsId: 3,
        workspaceId: 'workspace-a',
        browserId: 'browser-a',
      );

      expect(
        webviews.getActivePaseoBrowserWebContentsForHostWindow(3),
        same(live),
      );

      live.destroy();
      expect(webviews.getActivePaseoBrowserWebContentsForHostWindow(3), isNull);
    });

    test('guards every navigation event against disallowed URLs', () {
      final webviews = _createWebviews();
      final host = _FakeNavigationHost();
      webviews.registerBrowserWebviewNavigationGuards(host);

      expect(host.willNavigate, isNotNull);
      expect(host.willFrameNavigate, isNotNull);
      expect(host.willRedirect, isNotNull);

      for (final listener in <void Function(BrowserWebviewNavigationEvent)>[
        host.willNavigate!,
        host.willFrameNavigate!,
        host.willRedirect!,
      ]) {
        final allowed = _FakeNavigationEvent('https://example.com/');
        final blocked = _FakeNavigationEvent('file:///etc/passwd');
        final blank = _FakeNavigationEvent('about:blank');
        final absent = _FakeNavigationEvent(null);
        listener(allowed);
        listener(blocked);
        listener(blank);
        listener(absent);

        expect(allowed.prevented, isFalse);
        expect(blocked.prevented, isTrue);
        expect(blank.prevented, isFalse);
        expect(absent.prevented, isFalse);
      }
    });
  });

  // =========================================================================
  // browser-keyboard/index.ts
  // =========================================================================
  group('BrowserKeyboard', () {
    test('forwards a validated guest shortcut to its host', () {
      final harness = _KeyboardHarness();
      final guest = _FakeBrowserContents(51);
      final host = _FakeBrowserContents(52);
      harness.attach(
        browserId: 'browser-a',
        contents: guest,
        hostContents: host,
      );

      harness.keyboard.forwardShortcutInput(guest, <String, Object?>{
        'alt': false,
        'browserId': 'browser-a',
        'code': 'KeyB',
        'control': true,
        'key': 'b',
        'meta': false,
        'repeat': false,
        'shift': false,
      });

      expect(host.sent, hasLength(1));
      expect(host.sent.single.channel, browserKeyboardShortcutOutputChannel);
      final payload = host.sent.single.payload! as BrowserShortcutInput;
      expect(payload.browserId, 'browser-a');
      expect(payload.code, 'KeyB');
      expect(payload.key, 'b');
      expect(payload.control, isTrue);
      expect(payload.repeat, isFalse);
    });

    test(
      'drops a shortcut that claims a different browser or is malformed',
      () {
        final harness = _KeyboardHarness();
        final guest = _FakeBrowserContents(55);
        final host = _FakeBrowserContents(56);
        harness.attach(
          browserId: 'browser-a',
          contents: guest,
          hostContents: host,
        );

        // Malformed payload.
        harness.keyboard.forwardShortcutInput(guest, 'not a record');
        // Claims another browser.
        harness.keyboard.forwardShortcutInput(guest, <String, Object?>{
          'alt': false,
          'browserId': 'browser-b',
          'code': 'KeyB',
          'control': true,
          'key': 'b',
          'meta': false,
          'shift': false,
        });
        // Sender is not attached at all.
        harness.keyboard
            .forwardShortcutInput(_FakeBrowserContents(999), <String, Object?>{
              'alt': false,
              'browserId': 'browser-a',
              'code': 'KeyB',
              'control': true,
              'key': 'b',
              'meta': false,
              'shift': false,
            });

        expect(host.sent, isEmpty);
      },
    );

    test(
      'handles a reserved shortcut once when the same guest attaches again',
      () {
        final harness = _KeyboardHarness();
        final guest = _FakeBrowserContents(53);
        final host = _FakeBrowserContents(54);
        harness.attach(
          browserId: 'browser-a',
          contents: guest,
          hostContents: host,
        );
        harness.attach(
          browserId: 'browser-a',
          contents: guest,
          hostContents: host,
        );

        final wasPrevented = guest.input(
          harness.command(code: 'KeyR', key: 'r'),
        );

        expect(wasPrevented, isTrue);
        expect(guest.reloads, <String>['reload']);
      },
    );

    test(
      'stops a load in progress instead of reloading, and force-reloads',
      () {
        final harness = _KeyboardHarness();
        final guest = _FakeBrowserContents(57);
        final host = _FakeBrowserContents(58);
        harness.attach(
          browserId: 'browser-a',
          contents: guest,
          hostContents: host,
        );

        guest.loadingMainFrame = true;
        expect(guest.input(harness.command(code: 'KeyR', key: 'r')), isTrue);
        guest.loadingMainFrame = false;
        expect(
          guest.input(harness.command(code: 'KeyR', key: 'r', shift: true)),
          isTrue,
        );

        expect(guest.reloads, <String>['stop', 'force-reload']);
      },
    );

    test(
      'republishes the latest shortcut policy when the next guest document is ready',
      () {
        final harness = _KeyboardHarness();
        final guest = _FakeBrowserContents(61);
        final host = _FakeBrowserContents(62);
        const rawPrefix = <String, Object?>{
          'alt': false,
          'code': 'KeyB',
          'control': true,
          'meta': false,
          'repeat': false,
          'shift': false,
        };
        const initialRaw = <String, Object?>{
          'menuPrefixes': <Object?>[rawPrefix],
          'prefixes': <Object?>[rawPrefix],
        };
        const latestRaw = <String, Object?>{
          'menuPrefixes': <Object?>[],
          'prefixes': <Object?>[],
        };
        const expectedPrefix = BrowserShortcutPrefix(
          alt: false,
          code: 'KeyB',
          control: true,
          meta: false,
          shift: false,
          excludesRepeat: true,
        );
        const initialPolicy = BrowserKeyboardPolicy(
          menuPrefixes: <BrowserShortcutPrefix>[expectedPrefix],
          prefixes: <BrowserShortcutPrefix>[expectedPrefix],
        );
        const latestPolicy = BrowserKeyboardPolicy(
          menuPrefixes: <BrowserShortcutPrefix>[],
          prefixes: <BrowserShortcutPrefix>[],
        );

        harness.keyboard.publish(host.id, initialRaw);
        harness.attach(
          browserId: 'browser-a',
          contents: guest,
          hostContents: host,
        );
        harness.keyboard.publish(host.id, latestRaw);

        guest.domReady();

        expect(guest.sent, <_SentMessage>[
          const _SentMessage(
            browserKeyboardPolicyOutputChannel,
            BrowserKeyboardPolicyMessage(
              policy: initialPolicy,
              browserId: 'browser-a',
            ),
          ),
          const _SentMessage(
            browserKeyboardPolicyOutputChannel,
            BrowserKeyboardPolicyMessage(
              policy: latestPolicy,
              browserId: 'browser-a',
            ),
          ),
          const _SentMessage(
            browserKeyboardPolicyOutputChannel,
            BrowserKeyboardPolicyMessage(
              policy: latestPolicy,
              browserId: 'browser-a',
            ),
          ),
        ]);
      },
    );

    test('drops a malformed policy whole', () {
      final harness = _KeyboardHarness();
      final guest = _FakeBrowserContents(63);
      final host = _FakeBrowserContents(64);
      harness.attach(
        browserId: 'browser-a',
        contents: guest,
        hostContents: host,
      );

      harness.keyboard.publish(host.id, <String, Object?>{
        'menuPrefixes': <Object?>[],
        'prefixes': <Object?>[
          <String, Object?>{'code': 'KeyB'},
        ],
      });
      harness.keyboard.publish(host.id, 'not a record');

      expect(guest.sent, isEmpty);
    });

    test('never sends a policy to a detached frame or a destroyed guest', () {
      final harness = _KeyboardHarness();
      final guest = _FakeBrowserContents(65, detachedFrame: true);
      final host = _FakeBrowserContents(66);
      harness.attach(
        browserId: 'browser-a',
        contents: guest,
        hostContents: host,
      );
      harness.keyboard.publish(host.id, <String, Object?>{
        'menuPrefixes': <Object?>[],
        'prefixes': <Object?>[],
      });

      expect(guest.sent, isEmpty);
    });

    test('ignores guest lifecycle events after the host is destroyed', () {
      final harness = _KeyboardHarness();
      final guest = _FakeBrowserContents(71);
      final host = _FakeBrowserContents(72);
      harness.attach(
        browserId: 'browser-a',
        contents: guest,
        hostContents: host,
      );
      harness.keyboard.publish(host.id, <String, Object?>{
        'menuPrefixes': <Object?>[],
        'prefixes': <Object?>[],
      });

      host.destroy();
      guest.domReady();

      expect(guest.sent, <_SentMessage>[
        const _SentMessage(
          browserKeyboardPolicyOutputChannel,
          BrowserKeyboardPolicyMessage(
            policy: BrowserKeyboardPolicy(
              menuPrefixes: <BrowserShortcutPrefix>[],
              prefixes: <BrowserShortcutPrefix>[],
            ),
            browserId: 'browser-a',
          ),
        ),
      ]);
    });

    test(
      'refuses to attach a guest the registry does not place in this host',
      () {
        final registry = PaseoBrowserWebviewRegistry();
        final keyboard = BrowserKeyboard(registry, isMac: false);
        final guest = _FakeBrowserContents(73);
        final host = _FakeBrowserContents(74);

        // No registration at all.
        keyboard.attach(contents: guest, hostContents: host);
        keyboard.publish(host.id, <String, Object?>{
          'menuPrefixes': <Object?>[],
          'prefixes': <Object?>[],
        });
        expect(guest.sent, isEmpty);

        // Registered, but to a different host window.
        registry.registerWebContents(
          webContentsId: 73,
          browserId: 'browser-a',
          hostWebContentsId: 999,
        );
        keyboard.attach(contents: guest, hostContents: host);
        keyboard.publish(host.id, <String, Object?>{
          'menuPrefixes': <Object?>[],
          'prefixes': <Object?>[],
        });
        expect(guest.sent, isEmpty);
      },
    );

    test(
      'owns browser chrome shortcuts and leaves customizable shortcuts to policy',
      () {
        final harness = _KeyboardHarness();
        final guest = _FakeBrowserContents(81);
        final host = _FakeBrowserContents(82);
        harness.attach(
          browserId: 'browser-a',
          contents: guest,
          hostContents: host,
        );

        final reservedWasPrevented = guest.input(
          harness.command(code: 'KeyL', key: 'l'),
        );
        final customizableWasPrevented = guest.input(
          harness.command(code: 'KeyT', key: 't'),
        );
        final enterWasPrevented = guest.input(
          const BrowserKeyboardKeyInput(code: 'Enter', key: 'Enter'),
        );

        expect(reservedWasPrevented, isTrue);
        expect(customizableWasPrevented, isFalse);
        expect(enterWasPrevented, isFalse);
        expect(guest.ignoredMenuShortcuts, <bool>[false, false, true]);
        expect(host.sent, <_SentMessage>[
          const _SentMessage(
            browserKeyboardReservedShortcutOutputChannel,
            BrowserReservedShortcutMessage(
              action: BrowserReservedShortcut.focusUrl,
              browserId: 'browser-a',
            ),
          ),
        ]);
        expect(
          (host.sent.single.payload! as BrowserReservedShortcutMessage)
              .toJson(),
          <String, Object?>{'action': 'focus-url', 'browserId': 'browser-a'},
        );
      },
    );

    test('uses the macOS command modifier when the host says it is a Mac', () {
      final harness = _KeyboardHarness(useMeta: true);
      final guest = _FakeBrowserContents(83);
      final host = _FakeBrowserContents(84);
      harness.attach(
        browserId: 'browser-a',
        contents: guest,
        hostContents: host,
      );

      // Meta+R reloads on a Mac...
      expect(guest.input(harness.command(code: 'KeyR', key: 'r')), isTrue);
      // ...while Control+R does not.
      expect(
        guest.input(
          const BrowserKeyboardKeyInput(code: 'KeyR', key: 'r', control: true),
        ),
        isFalse,
      );
      expect(guest.reloads, <String>['reload']);
    });

    test(
      'keeps policy-owned shortcuts out of the application menu without preempting the page',
      () {
        final harness = _KeyboardHarness();
        final guest = _FakeBrowserContents(91);
        final host = _FakeBrowserContents(92);
        harness.keyboard.publish(host.id, <String, Object?>{
          'menuPrefixes': <Object?>[
            <String, Object?>{
              'alt': false,
              'code': 'KeyW',
              'control': true,
              'meta': false,
              'repeat': false,
              'shift': false,
            },
          ],
          'prefixes': <Object?>[
            <String, Object?>{
              'alt': false,
              'code': 'KeyW',
              'control': true,
              'meta': false,
              'repeat': false,
              'shift': false,
            },
          ],
        });
        harness.attach(
          browserId: 'browser-a',
          contents: guest,
          hostContents: host,
        );

        final wasPrevented = guest.input(
          const BrowserKeyboardKeyInput(code: 'KeyW', key: 'w', control: true),
        );

        expect(wasPrevented, isFalse);
        expect(guest.ignoredMenuShortcuts, <bool>[true]);
      },
    );

    test(
      'keeps idle policy shortcuts out of the application menu while a chord is pending',
      () {
        final harness = _KeyboardHarness();
        final guest = _FakeBrowserContents(101);
        final host = _FakeBrowserContents(102);
        harness.keyboard.publish(host.id, <String, Object?>{
          'menuPrefixes': <Object?>[
            <String, Object?>{
              'alt': false,
              'code': 'KeyW',
              'control': true,
              'meta': false,
              'repeat': false,
              'shift': false,
            },
          ],
          'prefixes': <Object?>[
            <String, Object?>{
              'alt': false,
              'code': 'F11',
              'control': true,
              'meta': false,
              'repeat': false,
              'shift': false,
            },
          ],
        });
        harness.attach(
          browserId: 'browser-a',
          contents: guest,
          hostContents: host,
        );

        final wasPrevented = guest.input(
          const BrowserKeyboardKeyInput(code: 'KeyW', key: 'w', control: true),
        );

        expect(wasPrevented, isFalse);
        expect(guest.ignoredMenuShortcuts, <bool>[true]);
      },
    );

    test('a destroyed guest stops receiving anything', () {
      final harness = _KeyboardHarness();
      final guest = _FakeBrowserContents(111);
      final host = _FakeBrowserContents(112);
      harness.attach(
        browserId: 'browser-a',
        contents: guest,
        hostContents: host,
      );

      guest.destroy();
      harness.keyboard.publish(host.id, <String, Object?>{
        'menuPrefixes': <Object?>[],
        'prefixes': <Object?>[],
      });

      expect(guest.sent, isEmpty);
    });

    test(
      'detachHost forgets the window policy without detaching its guests',
      () {
        final harness = _KeyboardHarness();
        final guest = _FakeBrowserContents(121);
        final host = _FakeBrowserContents(122);
        harness.attach(
          browserId: 'browser-a',
          contents: guest,
          hostContents: host,
        );
        harness.keyboard.publish(host.id, <String, Object?>{
          'menuPrefixes': <Object?>[],
          'prefixes': <Object?>[],
        });
        expect(guest.sent, hasLength(1));

        harness.keyboard.detachHost(host.id);
        guest.domReady();

        expect(guest.sent, hasLength(1));
      },
    );

    test(
      'registerIpc wires policy publish, shortcut forwarding and policy requests',
      () {
        final harness = _KeyboardHarness();
        final ipc = _FakeIpcRegistrar();
        harness.keyboard.registerIpc(ipc);

        expect(ipc.handlers.keys, <String>[browserKeyboardPolicyInputChannel]);
        expect(ipc.listeners.keys, <String>[
          browserKeyboardShortcutInputChannel,
          browserKeyboardPolicyRequestChannel,
        ]);

        final guest = _FakeBrowserContents(131);
        final host = _FakeBrowserContents(132);
        harness.attach(
          browserId: 'browser-a',
          contents: guest,
          hostContents: host,
        );

        ipc.handlers[browserKeyboardPolicyInputChannel]!(
          _FakeIpcEvent(host),
          <String, Object?>{
            'menuPrefixes': <Object?>[],
            'prefixes': <Object?>[],
          },
        );
        expect(guest.sent, hasLength(1));

        ipc.listeners[browserKeyboardShortcutInputChannel]!(
          _FakeIpcEvent(guest),
          <String, Object?>{
            'alt': false,
            'browserId': 'browser-a',
            'code': 'KeyB',
            'control': true,
            'key': 'b',
            'meta': false,
            'shift': false,
          },
        );
        expect(host.sent, hasLength(1));

        final requestEvent = _FakeIpcEvent(guest);
        ipc.listeners[browserKeyboardPolicyRequestChannel]!(requestEvent, null);
        expect(requestEvent.replies, <_SentMessage>[
          const _SentMessage(
            browserKeyboardPolicyOutputChannel,
            BrowserKeyboardPolicyMessage(
              policy: BrowserKeyboardPolicy(
                menuPrefixes: <BrowserShortcutPrefix>[],
                prefixes: <BrowserShortcutPrefix>[],
              ),
              browserId: 'browser-a',
            ),
          ),
        ]);

        // An unattached sender, and an attached one with no policy, both answer
        // with nothing rather than a partial payload.
        final strangerEvent = _FakeIpcEvent(_FakeBrowserContents(999));
        ipc.listeners[browserKeyboardPolicyRequestChannel]!(
          strangerEvent,
          null,
        );
        expect(strangerEvent.replies, isEmpty);
      },
    );

    test('the policy message exposes upstream flat wire shape', () {
      const message = BrowserKeyboardPolicyMessage(
        policy: BrowserKeyboardPolicy(
          menuPrefixes: <BrowserShortcutPrefix>[],
          prefixes: <BrowserShortcutPrefix>[],
        ),
        browserId: 'browser-a',
      );

      expect(message.menuPrefixes, isEmpty);
      expect(message.prefixes, isEmpty);
      expect(message.toJson()['browserId'], 'browser-a');
      expect(
        BrowserReservedShortcutMessage(
          action: BrowserReservedShortcut.reload,
          browserId: 'b',
        ).actionWireName,
        'reload',
      );
      expect(
        BrowserReservedShortcutMessage(
          action: BrowserReservedShortcut.forceReload,
          browserId: 'b',
        ).actionWireName,
        'force-reload',
      );
    });
  });

  // =========================================================================
  // menu.ts
  // =========================================================================
  group('reloadActiveBrowserOrWindow', () {
    test(
      'reloads only the active browser belonging to the supplied window',
      () {
        final browserReloads = _BrowserReloads();

        reloadActiveBrowserOrWindow(
          win: browserReloads.firstWindow,
          getActiveBrowserContentsForHostWindow:
              browserReloads.activeBrowserForHostWindow,
        );

        expect(browserReloads.resolvedHostWindowIds, <int>[101]);
        expect(browserReloads.firstBrowser.reloads, <String>['reload']);
        expect(browserReloads.secondBrowser.reloads, isEmpty);
        expect(browserReloads.firstWindow.webContents.reloads, isEmpty);
      },
    );

    test(
      'force reloads only the active browser belonging to the supplied window',
      () {
        final browserReloads = _BrowserReloads();

        reloadActiveBrowserOrWindow(
          win: browserReloads.secondWindow,
          getActiveBrowserContentsForHostWindow:
              browserReloads.activeBrowserForHostWindow,
          ignoreCache: true,
        );

        expect(browserReloads.resolvedHostWindowIds, <int>[202]);
        expect(browserReloads.firstBrowser.reloads, isEmpty);
        expect(browserReloads.secondBrowser.reloads, <String>['force-reload']);
        expect(browserReloads.secondWindow.webContents.reloads, isEmpty);
      },
    );

    test('stops an in-flight browser load instead of reloading it', () {
      final browserReloads = _BrowserReloads();
      browserReloads.firstBrowser.loadingMainFrame = true;

      reloadActiveBrowserOrWindow(
        win: browserReloads.firstWindow,
        getActiveBrowserContentsForHostWindow:
            browserReloads.activeBrowserForHostWindow,
      );

      expect(browserReloads.firstBrowser.reloads, <String>['stop']);
    });

    test('force reload ignores an in-flight load', () {
      final browserReloads = _BrowserReloads();
      browserReloads.firstBrowser.loadingMainFrame = true;

      reloadActiveBrowserOrWindow(
        win: browserReloads.firstWindow,
        getActiveBrowserContentsForHostWindow:
            browserReloads.activeBrowserForHostWindow,
        ignoreCache: true,
      );

      expect(browserReloads.firstBrowser.reloads, <String>['force-reload']);
    });

    test('falls back to the window when it has no active browser', () {
      final window = _FakeWindow(_FakeWindowWebContents(303));

      reloadActiveBrowserOrWindow(
        win: window,
        getActiveBrowserContentsForHostWindow: (_) => null,
      );
      reloadActiveBrowserOrWindow(
        win: window,
        getActiveBrowserContentsForHostWindow: (_) => null,
        ignoreCache: true,
      );

      expect(window.webContents.reloads, <String>['reload', 'force-reload']);
    });
  });

  group('application menu template', () {
    test('adds the macOS app menu and the front item only on a Mac', () {
      final mac = buildPaseoApplicationMenuTemplate(
        isMac: true,
        appName: 'Paseo',
        capturingShortcut: false,
      );
      final other = buildPaseoApplicationMenuTemplate(
        isMac: false,
        appName: 'Paseo',
        capturingShortcut: false,
      );

      expect(mac.map((item) => (item as DesktopMenuSubmenu).label), <String>[
        'Paseo',
        'File',
        'Edit',
        'View',
        'Window',
      ]);
      expect(other.map((item) => (item as DesktopMenuSubmenu).label), <String>[
        'File',
        'Edit',
        'View',
        'Window',
      ]);

      final macWindow = mac.last as DesktopMenuSubmenu;
      final otherWindow = other.last as DesktopMenuSubmenu;
      expect(macWindow.items, <DesktopMenuItem>[
        const DesktopMenuRoleItem(DesktopMenuRole.minimize),
        const DesktopMenuRoleItem(DesktopMenuRole.zoom),
        const DesktopMenuSeparator(),
        const DesktopMenuRoleItem(DesktopMenuRole.front),
      ]);
      expect(otherWindow.items, <DesktopMenuItem>[
        const DesktopMenuRoleItem(DesktopMenuRole.minimize),
        const DesktopMenuRoleItem(DesktopMenuRole.zoom),
        const DesktopMenuRoleItem(DesktopMenuRole.close),
      ]);
    });

    test('carries the exact File and View accelerators', () {
      final template = buildPaseoApplicationMenuTemplate(
        isMac: false,
        appName: 'Paseo',
        capturingShortcut: false,
      );
      final file = template.first as DesktopMenuSubmenu;
      final view = template[2] as DesktopMenuSubmenu;

      expect(file.items, <DesktopMenuItem>[
        const DesktopMenuCommandItem(
          label: 'New Window',
          accelerator: 'CmdOrCtrl+Shift+N',
          command: DesktopMenuCommand.newWindow,
        ),
      ]);
      expect(view.items, <DesktopMenuItem>[
        const DesktopMenuCommandItem(
          label: 'Zoom In',
          accelerator: 'CmdOrCtrl+=',
          command: DesktopMenuCommand.zoomIn,
        ),
        const DesktopMenuCommandItem(
          label: 'Zoom Out',
          accelerator: 'CmdOrCtrl+-',
          command: DesktopMenuCommand.zoomOut,
        ),
        const DesktopMenuCommandItem(
          label: 'Actual Size',
          accelerator: 'CmdOrCtrl+0',
          command: DesktopMenuCommand.actualSize,
        ),
        const DesktopMenuSeparator(),
        const DesktopMenuCommandItem(
          label: 'Reload',
          accelerator: 'CmdOrCtrl+R',
          command: DesktopMenuCommand.reload,
        ),
        const DesktopMenuCommandItem(
          label: 'Force Reload',
          accelerator: 'CmdOrCtrl+Shift+R',
          command: DesktopMenuCommand.forceReload,
        ),
        const DesktopMenuRoleItem(DesktopMenuRole.toggleDevTools),
        const DesktopMenuSeparator(),
        const DesktopMenuRoleItem(DesktopMenuRole.toggleFullScreen),
      ]);
      expect(DesktopMenuRole.toggleFullScreen.wireName, 'togglefullscreen');
      expect(DesktopMenuRole.hideOthers.wireName, 'hideOthers');
    });

    test('disables only the zoom items while capturing a shortcut', () {
      final capturing = buildPaseoApplicationMenuTemplate(
        isMac: false,
        appName: 'Paseo',
        capturingShortcut: true,
      );
      final view = capturing[2] as DesktopMenuSubmenu;
      final commands = view.items.whereType<DesktopMenuCommandItem>().toList();

      expect(
        commands
            .where((item) => !item.enabled)
            .map((item) => item.command)
            .toList(),
        <DesktopMenuCommand>[
          DesktopMenuCommand.zoomIn,
          DesktopMenuCommand.zoomOut,
          DesktopMenuCommand.actualSize,
        ],
      );
      expect(
        commands
            .where((item) => item.enabled)
            .map((item) => item.command)
            .toList(),
        <DesktopMenuCommand>[
          DesktopMenuCommand.reload,
          DesktopMenuCommand.forceReload,
        ],
      );
    });
  });

  group('terminal context menu', () {
    test('builds only for the terminal kind', () {
      expect(buildTerminalContextMenuTemplate(null), isNull);
      expect(
        buildTerminalContextMenuTemplate(const ShowContextMenuInput()),
        isNull,
      );
      expect(
        buildTerminalContextMenuTemplate(
          const ShowContextMenuInput(kind: 'editor'),
        ),
        isNull,
      );
      expect(
        buildTerminalContextMenuTemplate(
          const ShowContextMenuInput(kind: terminalContextMenuKind),
        ),
        isNotNull,
      );
    });

    test('enables Copy only for an explicit selection', () {
      expect(
        buildTerminalContextMenuTemplate(
          const ShowContextMenuInput(kind: 'terminal', hasSelection: true),
        ),
        <DesktopMenuItem>[
          const DesktopMenuRoleItem(
            DesktopMenuRole.copy,
            label: 'Copy',
            enabled: true,
          ),
          const DesktopMenuRoleItem(DesktopMenuRole.paste, label: 'Paste'),
          const DesktopMenuSeparator(),
          const DesktopMenuRoleItem(
            DesktopMenuRole.selectAll,
            label: 'Select All',
          ),
        ],
      );

      for (final input in <ShowContextMenuInput>[
        const ShowContextMenuInput(kind: 'terminal'),
        const ShowContextMenuInput(kind: 'terminal', hasSelection: false),
      ]) {
        final template = buildTerminalContextMenuTemplate(input)!;
        expect((template.first as DesktopMenuRoleItem).enabled, isFalse);
      }
    });
  });

  group('PaseoApplicationMenu', () {
    test(
      'installs nothing until setup, then rebuilds on every state change',
      () {
        final installed = <List<DesktopMenuItem>>[];
        final popped = <List<DesktopMenuItem>>[];
        final menu = PaseoApplicationMenu(
          isMac: false,
          appName: 'Paseo',
          setApplicationMenu: installed.add,
          popupContextMenu: popped.add,
        );

        menu.setCapturingShortcut(true);
        expect(installed, isEmpty, reason: 'not set up yet');
        expect(menu.isCapturingShortcut, isTrue);

        menu.setup();
        expect(installed, hasLength(1));

        menu.setCapturingShortcut(false);
        expect(installed, hasLength(2));
        expect(menu.isCapturingShortcut, isFalse);
        expect(popped, isEmpty);
      },
    );

    test('treats every non-true capturing value as not capturing', () {
      final installed = <List<DesktopMenuItem>>[];
      final menu = PaseoApplicationMenu(
        isMac: false,
        appName: 'Paseo',
        setApplicationMenu: installed.add,
        popupContextMenu: (_) {},
      )..setup();

      for (final value in <Object?>[null, 'true', 1, false, <Object?>[]]) {
        menu.setCapturingShortcut(value);
        expect(menu.isCapturingShortcut, isFalse, reason: 'value: $value');
      }
      menu.setCapturingShortcut(true);
      expect(menu.isCapturingShortcut, isTrue);
    });

    test('a window load resets a stranded capture exactly once', () {
      final installed = <List<DesktopMenuItem>>[];
      final menu = PaseoApplicationMenu(
        isMac: false,
        appName: 'Paseo',
        setApplicationMenu: installed.add,
        popupContextMenu: (_) {},
      )..setup();
      installed.clear();

      menu.handleWindowDidFinishLoad();
      expect(installed, isEmpty, reason: 'nothing to reset');

      menu.setCapturingShortcut(true);
      installed.clear();
      menu.handleWindowDidFinishLoad();
      expect(menu.isCapturingShortcut, isFalse);
      expect(installed, hasLength(1));

      installed.clear();
      menu.handleWindowDidFinishLoad();
      expect(installed, isEmpty);
    });

    test(
      'shows a context menu only for a terminal request from a real window',
      () {
        final popped = <List<DesktopMenuItem>>[];
        final menu = PaseoApplicationMenu(
          isMac: false,
          appName: 'Paseo',
          setApplicationMenu: (_) {},
          popupContextMenu: popped.add,
        )..setup();

        expect(
          menu.showContextMenu(
            hasWindow: false,
            input: const ShowContextMenuInput(kind: 'terminal'),
          ),
          isFalse,
        );
        expect(
          menu.showContextMenu(
            hasWindow: true,
            input: const ShowContextMenuInput(kind: 'editor'),
          ),
          isFalse,
        );
        expect(menu.showContextMenu(hasWindow: true), isFalse);
        expect(
          menu.showContextMenu(
            hasWindow: true,
            input: const ShowContextMenuInput(
              kind: 'terminal',
              hasSelection: true,
            ),
          ),
          isTrue,
        );
        expect(popped, hasLength(1));
        expect(popped.single, hasLength(4));
      },
    );
  });

  // =========================================================================
  // auto-updater.ts
  // =========================================================================
  group('shouldInstallAppUpdateOnQuit', () {
    test('keeps Linux AppImage updates on the manual install path', () {
      expect(
        shouldInstallAppUpdateOnQuit(
          platform: EditorTargetPlatform.linux,
          isAppImage: true,
        ),
        isFalse,
      );
      expect(
        shouldInstallAppUpdateOnQuit(
          platform: EditorTargetPlatform.linux,
          isAppImage: false,
        ),
        isTrue,
      );
      expect(
        shouldInstallAppUpdateOnQuit(
          platform: EditorTargetPlatform.darwin,
          isAppImage: false,
        ),
        isTrue,
      );
      expect(
        shouldInstallAppUpdateOnQuit(
          platform: EditorTargetPlatform.win32,
          isAppImage: false,
        ),
        isTrue,
      );
      // The AppImage flag is meaningless off Linux and must not gate anything.
      expect(
        shouldInstallAppUpdateOnQuit(
          platform: EditorTargetPlatform.darwin,
          isAppImage: true,
        ),
        isTrue,
      );
    });
  });

  group('shouldAdmitToRollout', () {
    test(
      'admits beta, missing rollout hours, zero-hour rollout, and missing release date',
      () {
        expect(
          shouldAdmitToRollout(
            channel: DesktopAppReleaseChannel.beta,
            rolloutHours: 24,
            releaseDate: '2026-04-28T00:00:00.000Z',
            now: DateTime.parse('2026-04-28T01:00:00.000Z'),
            bucket: 0.99,
          ),
          isTrue,
        );
        expect(
          shouldAdmitToRollout(
            channel: DesktopAppReleaseChannel.stable,
            rolloutHours: null,
            releaseDate: '2026-04-28T00:00:00.000Z',
            now: DateTime.parse('2026-04-28T01:00:00.000Z'),
            bucket: 0.99,
          ),
          isTrue,
        );
        expect(
          shouldAdmitToRollout(
            channel: DesktopAppReleaseChannel.stable,
            rolloutHours: 0,
            releaseDate: '2026-04-28T00:00:00.000Z',
            now: DateTime.parse('2026-04-28T01:00:00.000Z'),
            bucket: 0.99,
          ),
          isTrue,
        );
        expect(
          shouldAdmitToRollout(
            channel: DesktopAppReleaseChannel.stable,
            rolloutHours: 24,
            releaseDate: null,
            now: DateTime.parse('2026-04-28T01:00:00.000Z'),
            bucket: 0.99,
          ),
          isTrue,
        );
      },
    );

    test(
      'blocks future releases and respects the linear threshold mid-rollout',
      () {
        expect(
          shouldAdmitToRollout(
            channel: DesktopAppReleaseChannel.stable,
            rolloutHours: 24,
            releaseDate: '2026-04-28T02:00:00.000Z',
            now: DateTime.parse('2026-04-28T01:00:00.000Z'),
            bucket: 0,
          ),
          isFalse,
        );
        expect(
          shouldAdmitToRollout(
            channel: DesktopAppReleaseChannel.stable,
            rolloutHours: 24,
            releaseDate: '2026-04-28T00:00:00.000Z',
            now: DateTime.parse('2026-04-28T12:00:00.000Z'),
            bucket: 0.49,
          ),
          isTrue,
        );
        expect(
          shouldAdmitToRollout(
            channel: DesktopAppReleaseChannel.stable,
            rolloutHours: 24,
            releaseDate: '2026-04-28T00:00:00.000Z',
            now: DateTime.parse('2026-04-28T12:00:00.000Z'),
            bucket: 0.51,
          ),
          isFalse,
        );
      },
    );

    test(
      'blocks the bucket-zero client at exact release time, admits as soon as time advances',
      () {
        expect(
          shouldAdmitToRollout(
            channel: DesktopAppReleaseChannel.stable,
            rolloutHours: 24,
            releaseDate: '2026-04-28T00:00:00.000Z',
            now: DateTime.parse('2026-04-28T00:00:00.000Z'),
            bucket: 0,
          ),
          isFalse,
        );
        expect(
          shouldAdmitToRollout(
            channel: DesktopAppReleaseChannel.stable,
            rolloutHours: 24,
            releaseDate: '2026-04-28T00:00:00.000Z',
            now: DateTime.parse('2026-04-28T00:00:00.001Z'),
            bucket: 0,
          ),
          isTrue,
        );
      },
    );

    test('admits the highest-bucket client at and past the rollout end', () {
      const maxBucket = (0x100000000 - 1) / 0x100000000;
      expect(
        shouldAdmitToRollout(
          channel: DesktopAppReleaseChannel.stable,
          rolloutHours: 24,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: DateTime.parse('2026-04-29T00:00:00.000Z'),
          bucket: maxBucket,
        ),
        isTrue,
      );
      expect(
        shouldAdmitToRollout(
          channel: DesktopAppReleaseChannel.stable,
          rolloutHours: 24,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: DateTime.parse('2027-04-28T00:00:00.000Z'),
          bucket: maxBucket,
        ),
        isTrue,
      );
    });

    test('admits when releaseDate is unparseable', () {
      expect(
        shouldAdmitToRollout(
          channel: DesktopAppReleaseChannel.stable,
          rolloutHours: 24,
          releaseDate: 'not a date',
          now: DateTime.parse('2026-04-28T12:00:00.000Z'),
          bucket: 0.99,
        ),
        isTrue,
      );
    });

    test('treats garbage manifest rollout fields as missing and admits', () {
      final parsed = parseRolloutManifest(<String, Object?>{
        'rolloutHours': 'not a number',
        'releaseDate': 12345,
      });

      expect(
        shouldAdmitToRollout(
          channel: DesktopAppReleaseChannel.stable,
          rolloutHours: parsed.rolloutHours,
          releaseDate: parsed.releaseDate,
          now: DateTime.parse('2026-04-28T12:00:00.000Z'),
          bucket: 0.99,
        ),
        isTrue,
      );
    });
  });

  group('staging user id', () {
    test('accepts exactly the builder-util-runtime UUID shape', () {
      expect(isBuilderUtilUuid('123e4567-e89b-42d3-a456-426614174000'), isTrue);
      expect(isBuilderUtilUuid('123E4567-E89B-42D3-A456-426614174000'), isTrue);
      expect(isBuilderUtilUuid('00000000-0000-0000-0000-000000000000'), isTrue);
      expect(isBuilderUtilUuid('not-a-uuid'), isFalse);
      expect(isBuilderUtilUuid(''), isFalse);
      expect(isBuilderUtilUuid('123e4567-e89b-42d3-a456-42661417400'), isFalse);
      expect(
        isBuilderUtilUuid(' 123e4567-e89b-42d3-a456-426614174000'),
        isFalse,
      );
      expect(isBuilderUtilUuid('123e4567e89b42d3a456426614174000'), isFalse);
    });

    test('creates and then reuses the on-disk staging user id', () async {
      final host = _FakeStagingUserIdHost();
      const filePath = '/home/user/.config/Paseo/.updaterId';

      final first = await resolveStagingUserId(host: host, filePath: filePath);
      final stored = host.files[filePath]!.trim();
      final second = await resolveStagingUserId(host: host, filePath: filePath);

      expect(isBuilderUtilUuid(stored), isTrue);
      expect(second, first);
      expect(host.directories, <String>{'/home/user/.config/Paseo'});
      expect(host.randomByteRequests, <int>[4096]);
      expect(host.warnings, isEmpty);
      // The namespace bytes come first, then the 4096 random bytes.
      expect(host.hashedInputs.single, hasLength(16 + 4096));
      expect(
        host.hashedInputs.single.sublist(0, 16),
        builderUtilOidNamespaceBytes,
      );
    });

    test('stamps the RFC 4122 version and variant onto the digest', () async {
      final host = _FakeStagingUserIdHost(
        digest: Uint8List.fromList(List<int>.filled(20, 0xff)),
      );
      final id = await resolveStagingUserId(
        host: host,
        filePath: '/data/.updaterId',
      );

      expect(id, 'ffffffff-ffff-5fff-bfff-ffffffffffff');
      expect(isBuilderUtilUuid(id), isTrue);
    });

    test('regenerates rather than trusting a corrupt stored id', () async {
      final host = _FakeStagingUserIdHost();
      const filePath = '/data/.updaterId';
      host.files[filePath] = '  not-a-uuid  ';

      final id = await resolveStagingUserId(host: host, filePath: filePath);

      expect(id, isNot('not-a-uuid'));
      expect(isBuilderUtilUuid(id), isTrue);
      // A corrupt file is not a read *failure*, so nothing is warned about.
      expect(host.warnings, isEmpty);
    });

    test('trims surrounding whitespace off a valid stored id', () async {
      final host = _FakeStagingUserIdHost();
      const filePath = '/data/.updaterId';
      host.files[filePath] = '  123e4567-e89b-42d3-a456-426614174000\n';

      expect(
        await resolveStagingUserId(host: host, filePath: filePath),
        '123e4567-e89b-42d3-a456-426614174000',
      );
      expect(host.randomByteRequests, isEmpty);
    });

    test('warns but still yields an id when read or write fails', () async {
      final readFailure = _FakeStagingUserIdHost()
        ..readError = StateError('permission denied');
      final readId = await resolveStagingUserId(
        host: readFailure,
        filePath: '/data/.updaterId',
      );
      expect(isBuilderUtilUuid(readId), isTrue);
      expect(readFailure.warnings.single, contains("Couldn't read"));

      final writeFailure = _FakeStagingUserIdHost()
        ..writeError = StateError('read-only volume');
      final writeId = await resolveStagingUserId(
        host: writeFailure,
        filePath: '/data/.updaterId',
      );
      expect(isBuilderUtilUuid(writeId), isTrue);
      expect(writeFailure.warnings.single, contains("Couldn't write"));
    });

    test('memoises a single read across concurrent callers', () async {
      final host = _FakeStagingUserIdHost();
      final stagingUserId = StagingUserId(
        host: host,
        userDataDirectory: () => '/home/user/.config/Paseo',
      );

      final results = await Future.wait<String>(<Future<String>>[
        stagingUserId.get(),
        stagingUserId.get(),
        stagingUserId.get(),
      ]);

      expect(results.toSet(), hasLength(1));
      expect(host.randomByteRequests, <int>[4096]);
      expect(
        host.files.keys.single,
        '/home/user/.config/Paseo/${StagingUserId.fileName}',
      );
      expect(host.directories, <String>{'/home/user/.config/Paseo'});
    });

    test(
      'resolves the userData path with Windows separators when asked',
      () async {
        final host = _FakeStagingUserIdHost();
        final stagingUserId = StagingUserId(
          host: host,
          userDataDirectory: () => r'C:\Users\u\AppData\Roaming\Paseo',
          pathOps: DesktopBrowserPathOps.windows,
        );

        await stagingUserId.get();

        expect(
          host.files.keys.single,
          r'C:\Users\u\AppData\Roaming\Paseo\.updaterId',
        );
        expect(host.directories, <String>{r'C:\Users\u\AppData\Roaming\Paseo'});
      },
    );
  });

  group('ElectronStyleAppUpdateRuntime', () {
    test('pins the four safety settings and follows the release channel', () {
      final updater = _FakeElectronUpdater();
      final runtime = ElectronStyleAppUpdateRuntime(updater);

      runtime.configure(
        _updateConfiguration(channel: DesktopAppReleaseChannel.stable),
      );

      expect(updater.autoDownloadValue, isTrue);
      expect(updater.autoInstallOnAppQuitValue, isFalse);
      expect(updater.allowDowngradeValue, isFalse);
      expect(updater.allowPrereleaseValue, isFalse);
      expect(updater.channelValue, 'latest');

      runtime.configure(
        _updateConfiguration(channel: DesktopAppReleaseChannel.beta),
      );

      expect(updater.allowPrereleaseValue, isTrue);
      expect(updater.channelValue, 'beta');
    });

    test('subscribes to each updater event exactly once', () {
      final updater = _FakeElectronUpdater();
      final runtime = ElectronStyleAppUpdateRuntime(updater);
      final available = <String>[];
      final downloaded = <String>[];
      var notAvailable = 0;
      final errors = <Object>[];

      final configuration = _updateConfiguration(
        channel: DesktopAppReleaseChannel.stable,
        onUpdateAvailable: (info) => available.add(info.version),
        onUpdateDownloaded: (info) => downloaded.add(info.version),
        onUpdateNotAvailable: () => notAvailable += 1,
        onError: (error, _) => errors.add(error),
      );
      runtime
        ..configure(configuration)
        ..configure(configuration)
        ..configure(configuration);

      expect(updater.availableListeners, hasLength(1));
      expect(updater.downloadedListeners, hasLength(1));
      expect(updater.notAvailableListeners, hasLength(1));
      expect(updater.errorListeners, hasLength(1));

      updater.availableListeners.single(
        const DesktopAppUpdateInfo(version: '1.2.3'),
      );
      updater.downloadedListeners.single(
        const DesktopAppUpdateInfo(version: '1.2.3'),
      );
      updater.notAvailableListeners.single();
      updater.errorListeners.single('boom', StackTrace.empty);

      expect(available, <String>['1.2.3']);
      expect(downloaded, <String>['1.2.3']);
      expect(notAvailable, 1);
      expect(errors, <Object>['boom']);
    });

    test(
      'a failing rollout gate admits the update rather than pinning the user',
      () async {
        final updater = _FakeElectronUpdater();
        final runtime = ElectronStyleAppUpdateRuntime(updater);

        runtime.configure(
          _updateConfiguration(
            channel: DesktopAppReleaseChannel.stable,
            shouldAdmitUpdate: (_) => throw StateError('manifest fetch failed'),
          ),
        );
        expect(
          await updater.rolloutHook!(
            const DesktopAppUpdateInfo(version: '9.9.9'),
          ),
          isTrue,
        );

        runtime.configure(
          _updateConfiguration(
            channel: DesktopAppReleaseChannel.stable,
            shouldAdmitUpdate: (_) => false,
          ),
        );
        expect(
          await updater.rolloutHook!(
            const DesktopAppUpdateInfo(version: '9.9.9'),
          ),
          isFalse,
        );
      },
    );

    test('forwards checks, downloads and the quit-time install', () async {
      final updater = _FakeElectronUpdater()
        ..checkResult = const DesktopAppRuntimeCheckResult(
          isUpdateAvailable: true,
          updateInfo: DesktopAppUpdateInfo(version: '2.0.0'),
        );
      final runtime = ElectronStyleAppUpdateRuntime(updater);

      final result = await runtime.checkForUpdates();
      expect(result?.updateInfo.version, '2.0.0');

      await runtime.downloadUpdate(DesktopAppUpdateCancellation());
      await runtime.quitAndInstall(silent: true, restart: false);

      expect(updater.calls, <String>[
        'checkForUpdates',
        'downloadUpdate',
        'quitAndInstall(silent: true, restart: false)',
      ]);
      // The relaunch flag is written immediately before quitting because the
      // installer outlives this process.
      expect(updater.autoRunAppAfterInstallValue, isFalse);

      await runtime.quitAndInstall(silent: false, restart: true);
      expect(updater.autoRunAppAfterInstallValue, isTrue);
    });
  });

  // =========================================================================
  // editor-targets/runtime.ts
  // =========================================================================
  group('editor target runtime', () {
    test(
      'resolves command aliases and safely launches Windows command scripts',
      () async {
        final records = <_SpawnRecord>[];
        final runtime = createEditorTargetRuntime(
          platform: EditorTargetPlatform.win32,
          env: <String, String>{
            'PATH': 'C:/Program Files/Editors & Tools/bin',
            'ELECTRON_RUN_AS_NODE': '1',
          },
          pathExists: (targetPath) =>
              targetPath == 'C:/Program Files/Editors & Tools/bin/code.cmd',
          spawn: (command, args, options) {
            final record = _SpawnRecord(command, args, options);
            records.add(record);
            return _FakeChild(record);
          },
          openPath: (_) async => '',
          revealPath: (_) {},
          loadIcon: (_) async =>
              const EditorTargetSymbolIcon(EditorTargetSymbol.terminal),
          homeDirectory: 'C:/Users/u',
        );

        final command = runtime.resolveCommand(<String>['missing', 'code']);
        expect(command, 'C:/Program Files/Editors & Tools/bin/code.cmd');
        await runtime.spawnDetached(
          command: command!,
          args: <String>[
            'C:/repo & workspace',
            'C:/repo/src/file & calculator.ts',
          ],
        );

        expect(records, hasLength(1));
        final record = records.single;
        expect(
          record.command,
          '"C:/Program Files/Editors & Tools/bin/code.cmd"',
        );
        expect(record.args, <String>[
          '"C:/repo & workspace"',
          '"C:/repo/src/file & calculator.ts"',
        ]);
        expect(
          record.options,
          const EditorProcessSpawnOptions(
            detached: true,
            env: <String, String>{
              'PATH': 'C:/Program Files/Editors & Tools/bin',
            },
            shell: true,
            stdio: 'ignore',
          ),
        );
        expect(record.unrefed, isTrue);
      },
    );

    test('never shell-quotes a real executable', () async {
      final records = <_SpawnRecord>[];
      final runtime = createEditorTargetRuntime(
        platform: EditorTargetPlatform.linux,
        env: const <String, String>{'PATH': '/usr/bin'},
        pathExists: (targetPath) => targetPath == '/usr/bin/code',
        spawn: (command, args, options) {
          final record = _SpawnRecord(command, args, options);
          records.add(record);
          return _FakeChild(record);
        },
        openPath: (_) async => '',
        revealPath: (_) {},
        loadIcon: (_) async =>
            const EditorTargetSymbolIcon(EditorTargetSymbol.folder),
        homeDirectory: '/home/u',
      );

      expect(runtime.resolveCommand(<String>['code']), '/usr/bin/code');
      await runtime.spawnDetached(
        command: '/usr/bin/code',
        args: <String>['/repo & workspace'],
      );

      expect(records.single.command, '/usr/bin/code');
      expect(records.single.args, <String>['/repo & workspace']);
      expect(records.single.options.shell, isFalse);
    });

    test('surfaces a synchronous and an asynchronous spawn failure', () async {
      final runtime = createEditorTargetRuntime(
        platform: EditorTargetPlatform.linux,
        env: const <String, String>{},
        pathExists: (_) => false,
        spawn: (command, args, options) {
          if (command == '/bin/throws') throw StateError('ENOENT');
          return _FakeChild(
            _SpawnRecord(command, args, options),
            failWith: StateError('spawn failed'),
          );
        },
        openPath: (_) async => '',
        revealPath: (_) {},
        loadIcon: (_) async =>
            const EditorTargetSymbolIcon(EditorTargetSymbol.folder),
        homeDirectory: '/home/u',
      );

      await expectLater(
        runtime.spawnDetached(command: '/bin/throws', args: const <String>[]),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        runtime.spawnDetached(command: '/bin/fails', args: const <String>[]),
        throwsA(isA<StateError>()),
      );
    });

    test('openPath throws only on a non-empty error message', () async {
      var revealed = '';
      final runtime = createEditorTargetRuntime(
        platform: EditorTargetPlatform.darwin,
        env: const <String, String>{},
        pathExists: (_) => false,
        spawn: (command, args, options) =>
            _FakeChild(_SpawnRecord(command, args, options)),
        openPath: (path) async => path == '/bad' ? 'no such folder' : '',
        revealPath: (path) => revealed = path,
        loadIcon: (fileName) async => EditorTargetImageIcon('data:$fileName'),
        homeDirectory: '/Users/u',
      );

      await runtime.openPath('/good');
      await expectLater(
        runtime.openPath('/bad'),
        throwsA(isA<EditorTargetError>()),
      );

      runtime.revealPath('/reveal/me');
      expect(revealed, '/reveal/me');
      expect(
        await runtime.loadIcon('vscode.png'),
        const EditorTargetImageIcon('data:vscode.png'),
      );
    });

    test(
      'probes the three macOS application directories, and only on macOS',
      () async {
        final probed = <String>[];
        EditorTargetRuntime build(EditorTargetPlatform platform) =>
            createEditorTargetRuntime(
              platform: platform,
              env: const <String, String>{},
              pathExists: (path) {
                probed.add(path);
                return path == '/Users/u/Applications/Zed.app';
              },
              spawn: (command, args, options) =>
                  _FakeChild(_SpawnRecord(command, args, options)),
              openPath: (_) async => '',
              revealPath: (_) {},
              loadIcon: (_) async =>
                  const EditorTargetSymbolIcon(EditorTargetSymbol.folder),
              homeDirectory: '/Users/u',
            );

        expect(
          build(EditorTargetPlatform.linux).hasMacApplication('Zed'),
          isFalse,
        );
        expect(probed, isEmpty, reason: 'never touches disk off macOS');

        expect(
          build(EditorTargetPlatform.darwin).hasMacApplication('Zed'),
          isTrue,
        );
        expect(probed, <String>[
          '/Applications/Zed.app',
          '/Users/u/Applications/Zed.app',
        ]);
      },
    );

    test('openMacApplication goes through the detached spawn path', () async {
      final records = <_SpawnRecord>[];
      final runtime = createEditorTargetRuntime(
        platform: EditorTargetPlatform.darwin,
        env: const <String, String>{
          'PASEO_SUPERVISED': '1',
          'HOME': '/Users/u',
        },
        pathExists: (_) => true,
        spawn: (command, args, options) {
          final record = _SpawnRecord(command, args, options);
          records.add(record);
          return _FakeChild(record);
        },
        openPath: (_) async => '',
        revealPath: (_) {},
        loadIcon: (_) async =>
            const EditorTargetSymbolIcon(EditorTargetSymbol.folder),
        homeDirectory: '/Users/u',
      );

      await runtime.openMacApplication(
        applicationName: 'Zed',
        paths: <String>['/repo'],
      );

      expect(records.single.command, '/usr/bin/open');
      expect(records.single.args, <String>['-a', 'Zed', '/repo']);
      expect(records.single.options.env, <String, String>{'HOME': '/Users/u'});
    });
  });

  group('editor runtime helpers', () {
    test('strips only the supervision variables from a child environment', () {
      expect(
        createExternalProcessEnv(<String, String>{
          'PATH': '/usr/bin',
          'EMPTY': '',
          'PASEO_NODE_ENV': 'production',
          'PASEO_DESKTOP_MANAGED': '1',
          'PASEO_SUPERVISED': '1',
          'ELECTRON_RUN_AS_NODE': '1',
          'ELECTRON_NO_ATTACH_CONSOLE': '1',
        }),
        <String, String>{'PATH': '/usr/bin', 'EMPTY': ''},
      );
      expect(editorRuntimeControlEnvKeys, hasLength(5));
    });

    test('prefers an absolute command, then walks PATH', () {
      const existing = <String>{
        '/opt/editor/bin/code',
        '/usr/local/bin/zed',
        '/usr/bin/zed',
      };
      bool exists(String path) => existing.contains(path);

      expect(
        resolveEditorExecutable(
          <String>['/opt/editor/bin/code'],
          env: const <String, String>{},
          pathExists: exists,
          platform: EditorTargetPlatform.linux,
        ),
        '/opt/editor/bin/code',
      );
      // PATH order decides between two installs.
      expect(
        resolveEditorExecutable(
          <String>['zed'],
          env: const <String, String>{'PATH': '/usr/local/bin:/usr/bin'},
          pathExists: exists,
          platform: EditorTargetPlatform.linux,
        ),
        '/usr/local/bin/zed',
      );
      expect(
        resolveEditorExecutable(
          <String>['zed'],
          env: const <String, String>{'PATH': '/usr/bin:/usr/local/bin'},
          pathExists: exists,
          platform: EditorTargetPlatform.linux,
        ),
        '/usr/bin/zed',
      );
      expect(
        resolveEditorExecutable(
          <String>['ghost'],
          env: const <String, String>{'PATH': '/usr/bin'},
          pathExists: exists,
          platform: EditorTargetPlatform.linux,
        ),
        isNull,
      );
      // Empty PATH segments are skipped rather than probing the cwd.
      expect(
        resolveEditorExecutable(
          <String>['zed'],
          env: const <String, String>{'PATH': '::/usr/bin:'},
          pathExists: exists,
          platform: EditorTargetPlatform.linux,
        ),
        '/usr/bin/zed',
      );
    });

    test('falls back through the Path and path spellings, null-ish only', () {
      bool exists(String path) => path == 'C:/tools/code.exe';

      expect(
        resolveEditorExecutable(
          <String>['code'],
          env: const <String, String>{'Path': 'C:/tools'},
          pathExists: exists,
          platform: EditorTargetPlatform.win32,
        ),
        'C:/tools/code.exe',
      );
      expect(
        resolveEditorExecutable(
          <String>['code'],
          env: const <String, String>{'path': 'C:/tools'},
          pathExists: exists,
          platform: EditorTargetPlatform.win32,
        ),
        'C:/tools/code.exe',
      );
      // An explicitly empty PATH wins over Path, matching JS `??`.
      expect(
        resolveEditorExecutable(
          <String>['code'],
          env: const <String, String>{'PATH': '', 'Path': 'C:/tools'},
          pathExists: exists,
          platform: EditorTargetPlatform.win32,
        ),
        isNull,
      );
    });

    test(
      'probes Windows extensions in priority order, and not at all when one is given',
      () {
        final probes = <String>[];
        bool exists(String path) {
          probes.add(path);
          return path == 'C:/tools/code.cmd';
        }

        expect(
          resolveEditorExecutable(
            <String>['code'],
            env: const <String, String>{'PATH': 'C:/tools'},
            pathExists: exists,
            platform: EditorTargetPlatform.win32,
          ),
          'C:/tools/code.cmd',
        );
        expect(probes, <String>['C:/tools/code.exe', 'C:/tools/code.cmd']);

        probes.clear();
        expect(
          resolveEditorExecutable(
            <String>['code.exe'],
            env: const <String, String>{'PATH': 'C:/tools'},
            pathExists: exists,
            platform: EditorTargetPlatform.win32,
          ),
          isNull,
        );
        expect(probes, <String>['C:/tools/code.exe']);
      },
    );

    test('classifies Windows command scripts', () {
      expect(
        isWindowsCommandScript('C:/tools/code.cmd', EditorTargetPlatform.win32),
        isTrue,
      );
      expect(
        isWindowsCommandScript('C:/tools/code.BAT', EditorTargetPlatform.win32),
        isTrue,
      );
      expect(
        isWindowsCommandScript('C:/tools/code.exe', EditorTargetPlatform.win32),
        isFalse,
      );
      expect(
        isWindowsCommandScript('C:/tools/code', EditorTargetPlatform.win32),
        isFalse,
      );
      // The extension is meaningless off Windows.
      expect(
        isWindowsCommandScript('/usr/bin/code.cmd', EditorTargetPlatform.linux),
        isFalse,
      );
    });

    test('quotes exactly the cmd.exe metacharacters', () {
      expect(escapeWindowsCmdValue('plain'), 'plain');
      expect(escapeWindowsCmdValue(''), '');
      for (final unsafe in <String>[
        'a b',
        'a&b',
        'a|b',
        'a^b',
        'a<b',
        'a>b',
        'a(b',
        'a)b',
        'a!b',
      ]) {
        expect(
          escapeWindowsCmdValue(unsafe),
          '"$unsafe"',
          reason: 'value: $unsafe',
        );
      }
    });

    test('re-quotes a pre-quoted value instead of trusting it', () {
      // A caller cannot smuggle an unescaped `&` past the check by pre-quoting.
      expect(escapeWindowsCmdValue('"a & b"'), '"a & b"');
      expect(escapeWindowsCmdValue('"plain"'), '"plain"');
      expect(escapeWindowsCmdValue('"'), '""');
      expect(escapeWindowsCmdValue('""'), '""');
    });

    test('escapes embedded quotes and doubles trailing backslashes', () {
      expect(escapeWindowsCmdValue(r'say "hi"'), r'"say \"hi\""');
      expect(escapeWindowsCmdValue(r'a\"b'), r'"a\\\"b"');
      expect(escapeWindowsCmdValue('a b\\'), r'"a b\\"');
      expect(escapeWindowsCmdValue('a b\\\\'), r'"a b\\\\"');
    });

    test('applies the platform flavour of absolute-path detection', () {
      expect(
        editorRuntimeIsAbsolutePath('/usr/bin', EditorTargetPlatform.linux),
        isTrue,
      );
      expect(
        editorRuntimeIsAbsolutePath('usr/bin', EditorTargetPlatform.linux),
        isFalse,
      );
      expect(
        editorRuntimeIsAbsolutePath(r'C:\tools', EditorTargetPlatform.win32),
        isTrue,
      );
      expect(
        editorRuntimeIsAbsolutePath('C:/tools', EditorTargetPlatform.win32),
        isTrue,
      );
      // A drive letter is not a root on POSIX.
      expect(
        editorRuntimeIsAbsolutePath('C:/tools', EditorTargetPlatform.linux),
        isFalse,
      );
    });
  });
}
