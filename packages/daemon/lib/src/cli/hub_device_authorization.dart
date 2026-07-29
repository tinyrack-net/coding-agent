import 'dart:async';
import 'dart:io';

import 'hub_cloud_device_authorization.dart';

abstract interface class HubAuthorizationWaiter {
  Future<void> wait(Duration duration);
  int nowMilliseconds();
}

abstract interface class HubBrowserOpener {
  Future<void> open(String url);
}

abstract interface class HubAuthorizationReporter {
  void instructions(String verificationUri, String userCode);
}

typedef HubBrowserLaunch =
    Future<void> Function(String command, List<String> arguments);

final class HubSystemBrowser implements HubBrowserOpener {
  HubSystemBrowser({String? operatingSystem, HubBrowserLaunch? launch})
    : _operatingSystem = operatingSystem ?? Platform.operatingSystem,
      _launch = launch ?? _launchDetached;

  final String _operatingSystem;
  final HubBrowserLaunch _launch;

  @override
  Future<void> open(String url) async {
    if (_operatingSystem == 'windows') {
      await _launch('rundll32.exe', ['url.dll,FileProtocolHandler', url]);
      return;
    }
    await _launch(_operatingSystem == 'macos' ? 'open' : 'xdg-open', [url]);
  }
}

final class HubDeviceAuthorizationWorkflow {
  const HubDeviceAuthorizationWorkflow({
    required this.cloud,
    required this.waiter,
    required this.browser,
    required this.reporter,
    this.openBrowser = true,
  });

  final HubCloudDeviceAuthorization cloud;
  final HubAuthorizationWaiter waiter;
  final HubBrowserOpener browser;
  final HubAuthorizationReporter reporter;
  final bool openBrowser;

  Future<String> authorize(String hubUrl, String displayName) async {
    final authorization = await cloud.start(hubUrl, displayName);
    reporter.instructions(
      authorization.verificationUri.toString(),
      authorization.userCode,
    );
    if (openBrowser) {
      try {
        await browser.open(authorization.verificationUriComplete.toString());
      } on Object {
        // Browser launch is a convenience; the printed code remains usable.
      }
    }

    var interval = authorization.interval;
    final expiresAt = authorization.expiresAt.millisecondsSinceEpoch;
    while (true) {
      final remaining = expiresAt - waiter.nowMilliseconds();
      if (remaining <= 0) {
        throw const HubDeviceAuthorizationException(
          'Daemon registration expired',
        );
      }
      await waiter.wait(
        Duration(milliseconds: _min(interval * 1000, remaining)),
      );
      if (waiter.nowMilliseconds() >= expiresAt) {
        throw const HubDeviceAuthorizationException(
          'Daemon registration expired',
        );
      }
      final pollLifetime = expiresAt - waiter.nowMilliseconds();
      if (pollLifetime <= 0) {
        throw const HubDeviceAuthorizationException(
          'Daemon registration expired',
        );
      }
      final outcome = await cloud.poll(
        hubUrl,
        authorization.deviceCode,
        Duration(milliseconds: pollLifetime),
      );
      if (waiter.nowMilliseconds() >= expiresAt) {
        throw const HubDeviceAuthorizationException(
          'Daemon registration expired',
        );
      }
      if (outcome is HubDeviceAuthorizationRetryLater) continue;
      interval = switch (outcome) {
        HubDeviceAuthorizationPending(:final interval) => interval,
        HubDeviceAuthorizationSlowDown(:final interval) => interval,
        HubDeviceAuthorizationApproved(:final interval) => interval,
        HubDeviceAuthorizationDenied(:final interval) => interval,
        HubDeviceAuthorizationExpired(:final interval) => interval,
        HubDeviceAuthorizationEnrolled(:final interval) => interval,
        HubDeviceAuthorizationRetryLater() => interval,
      };
      switch (outcome) {
        case HubDeviceAuthorizationApproved(:final enrollmentToken):
          return enrollmentToken;
        case HubDeviceAuthorizationDenied():
          throw const HubDeviceAuthorizationException(
            'Daemon registration was denied',
          );
        case HubDeviceAuthorizationExpired():
          throw const HubDeviceAuthorizationException(
            'Daemon registration expired',
          );
        case HubDeviceAuthorizationEnrolled():
          throw const HubDeviceAuthorizationException(
            'Daemon registration was already used',
          );
        case HubDeviceAuthorizationPending():
        case HubDeviceAuthorizationSlowDown():
        case HubDeviceAuthorizationRetryLater():
          continue;
      }
    }
  }
}

HubDeviceAuthorizationWorkflow createHubDeviceAuthorizationWorkflow({
  HubCloudDeviceAuthorization? cloud,
  bool? openBrowser,
}) => HubDeviceAuthorizationWorkflow(
  cloud: cloud ?? HubCloudDeviceAuthorizationClient(),
  waiter: const _SystemAuthorizationWaiter(),
  browser: HubSystemBrowser(),
  reporter: const _StderrAuthorizationReporter(),
  openBrowser: openBrowser ?? stderr.hasTerminal,
);

final class _SystemAuthorizationWaiter implements HubAuthorizationWaiter {
  const _SystemAuthorizationWaiter();

  @override
  int nowMilliseconds() => DateTime.now().millisecondsSinceEpoch;

  @override
  Future<void> wait(Duration duration) => Future<void>.delayed(duration);
}

final class _StderrAuthorizationReporter implements HubAuthorizationReporter {
  const _StderrAuthorizationReporter();

  @override
  void instructions(String verificationUri, String userCode) {
    stderr.writeln('Open $verificationUri and enter code $userCode');
  }
}

Future<void> _launchDetached(String command, List<String> arguments) async {
  await Process.start(
    command,
    arguments,
    mode: ProcessStartMode.detached,
    runInShell: false,
  );
}

int _min(int left, int right) => left < right ? left : right;
