import 'dart:async';
import 'dart:collection';

import 'package:coding_agent_app/core/desktop/desktop_app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const currentVersion = '1.2.3';
  const older = DesktopAppUpdateInfo(
    version: '1.2.4',
    releaseDate: '2026-04-28T00:00:00.000Z',
  );
  const newer = DesktopAppUpdateInfo(
    version: '1.2.5',
    releaseDate: '2026-04-29T00:00:00.000Z',
  );

  test(
    'serializes checks so a manual check cannot race an automatic poll',
    () async {
      final runtime = _FakeDesktopAppUpdateRuntime();
      final service = _service(runtime);
      final automatic = runtime.deferNextCheck();
      final automaticPending = service.checkForAppUpdate(
        currentVersion: currentVersion,
        releaseChannel: DesktopAppReleaseChannel.stable,
        intent: DesktopAppUpdateCheckIntent.automatic,
      );
      runtime.nextCheck(older);
      final manualPending = service.checkForAppUpdate(
        currentVersion: currentVersion,
        releaseChannel: DesktopAppReleaseChannel.stable,
        intent: DesktopAppUpdateCheckIntent.manual,
      );

      await Future<void>.delayed(Duration.zero);
      expect(runtime.checkCount, 1);

      automatic.complete(null);
      await automaticPending;
      final manual = await manualPending;

      expect(runtime.checkCount, 2);
      expect(manual.latestVersion, older.version);
    },
  );

  test(
    'manual install rechecks and installs the newest eligible version',
    () async {
      final runtime = _FakeDesktopAppUpdateRuntime();
      final service = _service(runtime);
      runtime.nextCheck(older);
      await service.checkForAppUpdate(
        currentVersion: currentVersion,
        releaseChannel: DesktopAppReleaseChannel.stable,
        intent: DesktopAppUpdateCheckIntent.automatic,
      );
      runtime.finishUpdateDownload(older);

      runtime.nextCheck(newer);
      final result = await service.downloadAndInstallUpdate(
        currentVersion: currentVersion,
        releaseChannel: DesktopAppReleaseChannel.stable,
      );

      expect(result.installed, isTrue);
      expect(result.version, newer.version);
      expect(runtime.installedVersions, [newer.version]);
      expect(runtime.installModes, [(silent: false, restart: true)]);
    },
  );

  test('quit revalidation replaces an older downloaded release', () async {
    final runtime = _FakeDesktopAppUpdateRuntime();
    final service = _service(runtime);
    runtime.nextCheck(older);
    await service.checkForAppUpdate(
      currentVersion: currentVersion,
      releaseChannel: DesktopAppReleaseChannel.stable,
      intent: DesktopAppUpdateCheckIntent.automatic,
    );
    runtime.finishUpdateDownload(older);

    runtime.nextCheck(newer);
    final installed = await service.installUpdateOnQuit(
      currentVersion: currentVersion,
      releaseChannel: DesktopAppReleaseChannel.stable,
      cancellation: DesktopAppUpdateCancellation(),
    );

    expect(installed, isTrue);
    expect(runtime.downloadedVersions, [older.version, newer.version]);
    expect(runtime.installedVersions, [newer.version]);
    expect(runtime.installModes, [(silent: true, restart: false)]);
  });

  test(
    'waits out a stale active download before preparing the newest release',
    () async {
      final runtime = _FakeDesktopAppUpdateRuntime();
      final service = _service(runtime);
      runtime.nextCheck(older);
      await service.checkForAppUpdate(
        currentVersion: currentVersion,
        releaseChannel: DesktopAppReleaseChannel.stable,
        intent: DesktopAppUpdateCheckIntent.automatic,
      );
      final staleDownload = runtime.beginUpdateDownload(older);

      runtime.nextCheck(newer);
      final installPending = service.downloadAndInstallUpdate(
        currentVersion: currentVersion,
        releaseChannel: DesktopAppReleaseChannel.stable,
      );
      await Future<void>.delayed(Duration.zero);
      expect(runtime.downloadCallCount, 1);

      staleDownload.complete();
      final result = await installPending;

      expect(result.installed, isTrue);
      expect(runtime.downloadedVersions, [older.version, newer.version]);
      expect(runtime.installedVersions, [newer.version]);
    },
  );

  test('fails closed when quit-time manifest validation is offline', () async {
    final runtime = _FakeDesktopAppUpdateRuntime();
    final service = _service(runtime);
    runtime.nextCheck(older);
    await service.checkForAppUpdate(
      currentVersion: currentVersion,
      releaseChannel: DesktopAppReleaseChannel.stable,
      intent: DesktopAppUpdateCheckIntent.automatic,
    );
    runtime.finishUpdateDownload(older);
    runtime.failNextCheck(Exception('offline'));

    final installed = await service.installUpdateOnQuit(
      currentVersion: currentVersion,
      releaseChannel: DesktopAppReleaseChannel.stable,
      cancellation: DesktopAppUpdateCancellation(),
    );

    expect(installed, isFalse);
    expect(runtime.installedVersions, isEmpty);
  });

  test('does not install when quit-time validation has expired', () async {
    final runtime = _FakeDesktopAppUpdateRuntime();
    final service = _service(runtime);
    runtime.nextCheck(older);
    await service.checkForAppUpdate(
      currentVersion: currentVersion,
      releaseChannel: DesktopAppReleaseChannel.stable,
      intent: DesktopAppUpdateCheckIntent.automatic,
    );
    runtime.finishUpdateDownload(older);
    runtime.nextCheck(newer);
    final cancellation = DesktopAppUpdateCancellation()..cancel();

    final installed = await service.installUpdateOnQuit(
      currentVersion: currentVersion,
      releaseChannel: DesktopAppReleaseChannel.stable,
      cancellation: cancellation,
    );

    expect(installed, isFalse);
    expect(runtime.installedVersions, isEmpty);
  });

  test(
    'cannot install late when cancellation wins during preparation',
    () async {
      final runtime = _FakeDesktopAppUpdateRuntime();
      final service = _service(runtime);
      runtime.nextCheck(older);
      await service.checkForAppUpdate(
        currentVersion: currentVersion,
        releaseChannel: DesktopAppReleaseChannel.stable,
        intent: DesktopAppUpdateCheckIntent.automatic,
      );
      runtime.finishUpdateDownload(older);

      runtime.nextCheck(newer);
      final replacementDownload = runtime.beginUpdateDownload(newer);
      final cancellation = DesktopAppUpdateCancellation();
      final installPending = service.installUpdateOnQuit(
        currentVersion: currentVersion,
        releaseChannel: DesktopAppReleaseChannel.stable,
        cancellation: cancellation,
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      replacementDownload.complete();

      expect(await installPending, isFalse);
      expect(runtime.installedVersions, isEmpty);
    },
  );

  test(
    'never falls back to an older cache when newest release is ineligible',
    () async {
      var automaticChecks = 0;
      final runtime = _FakeDesktopAppUpdateRuntime();
      final service = _service(
        runtime,
        shouldAdmitUpdate: (info, _, intent) {
          if (intent == DesktopAppUpdateCheckIntent.automatic) {
            automaticChecks += 1;
            return automaticChecks == 1;
          }
          return true;
        },
      );
      runtime.nextCheck(older);
      await service.checkForAppUpdate(
        currentVersion: currentVersion,
        releaseChannel: DesktopAppReleaseChannel.stable,
        intent: DesktopAppUpdateCheckIntent.automatic,
      );
      runtime.finishUpdateDownload(older);
      runtime.nextCheck(newer);

      final installed = await service.installUpdateOnQuit(
        currentVersion: currentVersion,
        releaseChannel: DesktopAppReleaseChannel.stable,
        cancellation: DesktopAppUpdateCancellation(),
      );

      expect(installed, isFalse);
      expect(runtime.installedVersions, isEmpty);
    },
  );

  test('development builds neither check nor install', () async {
    final runtime = _FakeDesktopAppUpdateRuntime();
    final service = _service(runtime, packaged: false);

    final check = await service.checkForAppUpdate(
      currentVersion: currentVersion,
      releaseChannel: DesktopAppReleaseChannel.stable,
      intent: DesktopAppUpdateCheckIntent.manual,
    );
    final install = await service.downloadAndInstallUpdate(
      currentVersion: currentVersion,
      releaseChannel: DesktopAppReleaseChannel.stable,
    );

    expect(check.hasUpdate, isFalse);
    expect(runtime.checkCount, 0);
    expect(install.installed, isFalse);
    expect(install.message, contains('development mode'));
  });
}

DesktopAppUpdateService _service(
  _FakeDesktopAppUpdateRuntime runtime, {
  bool packaged = true,
  DesktopAppUpdateAdmission? shouldAdmitUpdate,
}) => DesktopAppUpdateService(
  runtime: runtime,
  isPackaged: () => packaged,
  shouldAdmitUpdate: shouldAdmitUpdate,
);

final class _DeferredCheck {
  final Completer<DesktopAppRuntimeCheckResult?> _completer =
      Completer<DesktopAppRuntimeCheckResult?>();

  Future<DesktopAppRuntimeCheckResult?> get future => _completer.future;

  void complete(DesktopAppUpdateInfo? info) => _completer.complete(
    info == null
        ? null
        : DesktopAppRuntimeCheckResult(
            isUpdateAvailable: true,
            updateInfo: info,
          ),
  );
}

final class _DeferredDownload {
  _DeferredDownload(this._complete);

  final void Function() _complete;

  void complete() => _complete();
}

final class _FakeDesktopAppUpdateRuntime implements DesktopAppUpdateRuntime {
  DesktopAppUpdateRuntimeConfiguration? _configuration;
  final Queue<Future<DesktopAppRuntimeCheckResult?> Function()> _checks =
      Queue();
  DesktopAppUpdateInfo? _downloadableUpdate;
  DesktopAppUpdateInfo? _downloadedUpdate;
  ({DesktopAppUpdateInfo info, Completer<void> completer})? _activeDownload;

  int checkCount = 0;
  int downloadCallCount = 0;
  final List<String> downloadedVersions = [];
  final List<String> installedVersions = [];
  final List<({bool silent, bool restart})> installModes = [];

  @override
  void configure(DesktopAppUpdateRuntimeConfiguration configuration) {
    _configuration = configuration;
  }

  void nextCheck(DesktopAppUpdateInfo info) {
    _checks.add(
      () => Future.value(
        DesktopAppRuntimeCheckResult(isUpdateAvailable: true, updateInfo: info),
      ),
    );
  }

  _DeferredCheck deferNextCheck() {
    final deferred = _DeferredCheck();
    _checks.add(() => deferred.future);
    return deferred;
  }

  void failNextCheck(Object error) {
    _checks.add(() => Future.error(error));
  }

  @override
  Future<DesktopAppRuntimeCheckResult?> checkForUpdates() async {
    checkCount += 1;
    final result = await _checks.removeFirst()();
    final configuration = _configuration!;
    if (result == null ||
        !result.isUpdateAvailable ||
        !await configuration.shouldAdmitUpdate(result.updateInfo)) {
      configuration.onUpdateNotAvailable();
      return result == null
          ? null
          : DesktopAppRuntimeCheckResult(
              isUpdateAvailable: false,
              updateInfo: result.updateInfo,
            );
    }
    _downloadableUpdate = result.updateInfo;
    configuration.onUpdateAvailable(result.updateInfo);
    return result;
  }

  _DeferredDownload beginUpdateDownload(DesktopAppUpdateInfo info) {
    final completer = Completer<void>();
    _activeDownload = (info: info, completer: completer);
    return _DeferredDownload(() {
      finishUpdateDownload(info);
      _activeDownload = null;
      completer.complete();
    });
  }

  void finishUpdateDownload(DesktopAppUpdateInfo info) {
    _downloadedUpdate = info;
    downloadedVersions.add(info.version);
    _configuration!.onUpdateDownloaded(info);
  }

  @override
  Future<void> downloadUpdate(DesktopAppUpdateCancellation cancellation) async {
    downloadCallCount += 1;
    final active = _activeDownload;
    if (active != null) {
      return active.completer.future;
    }
    if (cancellation.isCancelled) return;
    final info = _downloadableUpdate!;
    finishUpdateDownload(info);
  }

  @override
  Future<void> quitAndInstall({
    required bool silent,
    required bool restart,
  }) async {
    installedVersions.add(_downloadedUpdate!.version);
    installModes.add((silent: silent, restart: restart));
  }
}
