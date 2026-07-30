import 'dart:async';

enum DesktopAppReleaseChannel { stable, beta }

enum DesktopAppUpdateCheckIntent { automatic, manual }

final class DesktopAppUpdateInfo {
  const DesktopAppUpdateInfo({
    required this.version,
    this.releaseNotes,
    this.releaseDate,
  });

  final String version;
  final String? releaseNotes;
  final String? releaseDate;
}

final class DesktopAppRuntimeCheckResult {
  const DesktopAppRuntimeCheckResult({
    required this.isUpdateAvailable,
    required this.updateInfo,
  });

  final bool isUpdateAvailable;
  final DesktopAppUpdateInfo updateInfo;
}

final class DesktopAppUpdateCheckResult {
  const DesktopAppUpdateCheckResult({
    required this.hasUpdate,
    required this.readyToInstall,
    required this.currentVersion,
    required this.latestVersion,
    required this.body,
    required this.date,
    required this.errorMessage,
  });

  final bool hasUpdate;
  final bool readyToInstall;
  final String currentVersion;
  final String latestVersion;
  final String? body;
  final String? date;
  final String? errorMessage;
}

final class DesktopAppUpdateInstallResult {
  const DesktopAppUpdateInstallResult({
    required this.installed,
    required this.version,
    required this.message,
  });

  final bool installed;
  final String? version;
  final String message;
}

final class DesktopAppUpdateRuntimeConfiguration {
  const DesktopAppUpdateRuntimeConfiguration({
    required this.releaseChannel,
    required this.shouldAdmitUpdate,
    required this.onUpdateAvailable,
    required this.onUpdateDownloaded,
    required this.onUpdateNotAvailable,
    required this.onError,
  });

  final DesktopAppReleaseChannel releaseChannel;
  final FutureOr<bool> Function(DesktopAppUpdateInfo info) shouldAdmitUpdate;
  final void Function(DesktopAppUpdateInfo info) onUpdateAvailable;
  final void Function(DesktopAppUpdateInfo info) onUpdateDownloaded;
  final void Function() onUpdateNotAvailable;
  final void Function(Object error, StackTrace stackTrace) onError;
}

/// Platform updater boundary. Windows implementations can wrap MSIX/AppInstaller
/// or another signed installer without leaking platform details into selection.
abstract interface class DesktopAppUpdateRuntime {
  void configure(DesktopAppUpdateRuntimeConfiguration configuration);

  Future<DesktopAppRuntimeCheckResult?> checkForUpdates();

  Future<void> downloadUpdate(DesktopAppUpdateCancellation cancellation);

  Future<void> quitAndInstall({required bool silent, required bool restart});
}

/// Cooperative deadline used for quit-time validation and preparation.
final class DesktopAppUpdateCancellation {
  DesktopAppUpdateCancellation();

  bool _isCancelled = false;
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelled.complete();
  }
}

typedef DesktopAppUpdateAdmission =
    FutureOr<bool> Function(
      DesktopAppUpdateInfo info,
      DesktopAppReleaseChannel channel,
      DesktopAppUpdateCheckIntent intent,
    );

/// Paseo-compatible update selector.
///
/// Every install starts with a serialized manifest check. A downloaded artifact
/// is merely a cache: it is installed only when the fresh check still selects
/// that version. If a newer eligible version supersedes it, preparation loops
/// until that newer artifact is ready.
final class DesktopAppUpdateService {
  factory DesktopAppUpdateService({
    required DesktopAppUpdateRuntime runtime,
    required bool Function() isPackaged,
    DesktopAppUpdateAdmission? shouldAdmitUpdate,
    void Function(Object error, StackTrace stackTrace)? reportCheckError,
    void Function(Object error, StackTrace stackTrace)? reportRuntimeError,
    void Function(String message)? reportInstallError,
  }) => DesktopAppUpdateService._(
    runtime,
    isPackaged,
    shouldAdmitUpdate ?? ((_, _, _) => true),
    reportCheckError,
    reportRuntimeError,
    reportInstallError,
  );

  DesktopAppUpdateService._(
    this._runtime,
    this._isPackaged,
    this._shouldAdmitUpdate,
    this._reportCheckError,
    this._reportRuntimeError,
    this._reportInstallError,
  );

  final DesktopAppUpdateRuntime _runtime;
  final bool Function() _isPackaged;
  final DesktopAppUpdateAdmission _shouldAdmitUpdate;
  final void Function(Object error, StackTrace stackTrace)? _reportCheckError;
  final void Function(Object error, StackTrace stackTrace)? _reportRuntimeError;
  final void Function(String message)? _reportInstallError;

  DesktopAppUpdateInfo? _cachedUpdateInfo;
  String? _downloadedUpdateVersion;
  DesktopAppReleaseChannel? _configuredReleaseChannel;
  ({String version, String message})? _preparationError;
  String? _preparingUpdateVersion;
  Future<void> _checkQueue = Future<void>.value();

  bool _isReadyToInstallVersion(String version) =>
      _downloadedUpdateVersion == version;

  void _clearUpdateState() {
    _cachedUpdateInfo = null;
    _downloadedUpdateVersion = null;
    _preparationError = null;
    _preparingUpdateVersion = null;
  }

  void _configureRuntime(
    DesktopAppReleaseChannel releaseChannel,
    DesktopAppUpdateCheckIntent intent,
  ) {
    if (_configuredReleaseChannel != releaseChannel) {
      _clearUpdateState();
      _configuredReleaseChannel = releaseChannel;
    }

    _runtime.configure(
      DesktopAppUpdateRuntimeConfiguration(
        releaseChannel: releaseChannel,
        shouldAdmitUpdate: (info) =>
            _shouldAdmitUpdate(info, releaseChannel, intent),
        onUpdateAvailable: (info) {
          final alreadyReady = _downloadedUpdateVersion == info.version;
          _cachedUpdateInfo = info;
          _downloadedUpdateVersion = alreadyReady ? info.version : null;
          if (!alreadyReady && _preparingUpdateVersion == null) {
            _preparingUpdateVersion = info.version;
          }
        },
        onUpdateDownloaded: (info) {
          // An older in-flight download may finish after a newer manifest was
          // selected. It must not replace that newer validated install target.
          _cachedUpdateInfo ??= info;
          _downloadedUpdateVersion = info.version;
          if (_preparingUpdateVersion == info.version) {
            _preparingUpdateVersion = null;
          }
          if (_preparationError?.version == info.version) {
            _preparationError = null;
          }
        },
        onUpdateNotAvailable: _clearUpdateState,
        onError: (error, stackTrace) {
          final preparing = _preparingUpdateVersion;
          if (preparing != null) {
            _preparationError = (
              version: preparing,
              message: _errorMessage(error),
            );
            _preparingUpdateVersion = null;
          }
          _reportRuntimeError?.call(error, stackTrace);
        },
      ),
    );
  }

  Future<T> _runCheckExclusively<T>(Future<T> Function() check) {
    final result = _checkQueue.then((_) => check(), onError: (_) => check());
    _checkQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<DesktopAppUpdateCheckResult> checkForAppUpdate({
    required String currentVersion,
    required DesktopAppReleaseChannel releaseChannel,
    required DesktopAppUpdateCheckIntent intent,
  }) {
    if (!_isPackaged()) {
      return Future.value(_checkResult(currentVersion: currentVersion));
    }

    return _runCheckExclusively(() async {
      _configureRuntime(releaseChannel, intent);
      try {
        final result = await _runtime.checkForUpdates();
        if (result == null || !result.isUpdateAvailable) {
          _clearUpdateState();
          return _checkResult(currentVersion: currentVersion);
        }

        final info = result.updateInfo;
        if (info.version == currentVersion) {
          _clearUpdateState();
          return _checkResult(currentVersion: currentVersion);
        }

        _cachedUpdateInfo = info;
        final preparationError = _preparationError;
        final errorMessage = preparationError?.version == info.version
            ? preparationError?.message
            : null;
        if (errorMessage == null) _preparationError = null;
        return _checkResult(
          currentVersion: currentVersion,
          info: info,
          readyToInstall: _isReadyToInstallVersion(info.version),
          errorMessage: errorMessage,
        );
      } catch (error, stackTrace) {
        _reportCheckError?.call(error, stackTrace);
        return _checkResult(
          currentVersion: currentVersion,
          errorMessage: _errorMessage(error),
        );
      }
    });
  }

  Future<DesktopAppUpdateInstallResult> downloadAndInstallUpdate({
    required String currentVersion,
    required DesktopAppReleaseChannel releaseChannel,
    Future<void> Function()? onBeforeQuit,
  }) async {
    if (!_isPackaged()) {
      return DesktopAppUpdateInstallResult(
        installed: false,
        version: currentVersion,
        message: 'Auto-update is not available in development mode.',
      );
    }

    final check = await checkForAppUpdate(
      currentVersion: currentVersion,
      releaseChannel: releaseChannel,
      intent: DesktopAppUpdateCheckIntent.manual,
    );
    if (!check.hasUpdate) {
      return DesktopAppUpdateInstallResult(
        installed: false,
        version: currentVersion,
        message: check.errorMessage ?? 'No update available.',
      );
    }

    return _installCachedUpdate(
      currentVersion: currentVersion,
      cancellation: DesktopAppUpdateCancellation(),
      restart: true,
      onBeforeQuit: onBeforeQuit,
    );
  }

  Future<bool> installUpdateOnQuit({
    required String currentVersion,
    required DesktopAppReleaseChannel releaseChannel,
    required DesktopAppUpdateCancellation cancellation,
  }) async {
    if (!_isPackaged() || _downloadedUpdateVersion == null) return false;

    final check = await checkForAppUpdate(
      currentVersion: currentVersion,
      releaseChannel: releaseChannel,
      intent: DesktopAppUpdateCheckIntent.automatic,
    );
    if (cancellation.isCancelled || !check.hasUpdate) return false;

    final result = await _installCachedUpdate(
      currentVersion: currentVersion,
      cancellation: cancellation,
      restart: false,
    );
    return result.installed;
  }

  Future<DesktopAppUpdateInstallResult> _installCachedUpdate({
    required String currentVersion,
    required DesktopAppUpdateCancellation cancellation,
    required bool restart,
    Future<void> Function()? onBeforeQuit,
  }) async {
    final cached = _cachedUpdateInfo;
    if (cached == null) {
      return DesktopAppUpdateInstallResult(
        installed: false,
        version: currentVersion,
        message: 'No update available. Check for updates first.',
      );
    }
    if (cancellation.isCancelled) return _deferredResult(currentVersion);

    final readyVersion = cached.version;
    if (!_isReadyToInstallVersion(readyVersion)) {
      try {
        final preparation = await _ensureUpdateDownloaded(
          readyVersion,
          cancellation,
        );
        if (preparation == _Preparation.aborted) {
          return _deferredResult(currentVersion);
        }
        if (preparation == _Preparation.superseded) {
          return DesktopAppUpdateInstallResult(
            installed: false,
            version: currentVersion,
            message: 'A newer update was found and will be installed later.',
          );
        }
      } catch (error) {
        final message = _errorMessage(error);
        _reportInstallError?.call(message);
        return DesktopAppUpdateInstallResult(
          installed: false,
          version: currentVersion,
          message: 'Update failed: $message',
        );
      }
    }

    if (cancellation.isCancelled) return _deferredResult(currentVersion);
    await onBeforeQuit?.call();
    await _runtime.quitAndInstall(silent: !restart, restart: restart);
    return DesktopAppUpdateInstallResult(
      installed: true,
      version: readyVersion,
      message: 'Update downloaded. The app will restart shortly.',
    );
  }

  Future<_Preparation> _ensureUpdateDownloaded(
    String readyVersion,
    DesktopAppUpdateCancellation cancellation,
  ) async {
    while (!_isReadyToInstallVersion(readyVersion)) {
      if (cancellation.isCancelled) return _Preparation.aborted;
      if (_cachedUpdateInfo?.version != readyVersion) {
        return _Preparation.superseded;
      }

      final attemptedVersion = _preparingUpdateVersion ?? readyVersion;
      _preparingUpdateVersion ??= readyVersion;
      try {
        await _runtime.downloadUpdate(cancellation);
      } catch (_) {
        if (attemptedVersion != readyVersion &&
            _cachedUpdateInfo?.version == readyVersion &&
            !cancellation.isCancelled) {
          continue;
        }
        rethrow;
      }

      // Some runtimes return the older, already-active download first.
      if (attemptedVersion == readyVersion &&
          !_isReadyToInstallVersion(readyVersion)) {
        _downloadedUpdateVersion = readyVersion;
        _preparingUpdateVersion = null;
      }
    }
    return cancellation.isCancelled ? _Preparation.aborted : _Preparation.ready;
  }

  DesktopAppUpdateCheckResult _checkResult({
    required String currentVersion,
    DesktopAppUpdateInfo? info,
    bool readyToInstall = false,
    String? errorMessage,
  }) => DesktopAppUpdateCheckResult(
    hasUpdate: info != null,
    readyToInstall: readyToInstall,
    currentVersion: currentVersion,
    latestVersion: info?.version ?? currentVersion,
    body: info?.releaseNotes,
    date: info?.releaseDate,
    errorMessage: errorMessage,
  );

  DesktopAppUpdateInstallResult _deferredResult(String currentVersion) =>
      DesktopAppUpdateInstallResult(
        installed: false,
        version: currentVersion,
        message:
            'Update validation timed out. The update will be installed later.',
      );
}

enum _Preparation { ready, aborted, superseded }

String _errorMessage(Object error) =>
    error.toString().replaceFirst(RegExp(r'^(Exception|Error):\s*'), '');
