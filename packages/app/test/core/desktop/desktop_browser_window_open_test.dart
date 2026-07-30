import 'package:coding_agent_app/core/desktop/desktop_browser_window_open.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DesktopBrowserWindowOpenRequest request({
    String url = 'https://example.com/target',
    DesktopBrowserWindowOpenDisposition disposition =
        DesktopBrowserWindowOpenDisposition.newWindow,
    String frameName = '_blank',
    String features = '',
    bool hasPostBody = false,
    Object? nativeRequestContext,
  }) => DesktopBrowserWindowOpenRequest(
    url: url,
    disposition: disposition,
    frameName: frameName,
    features: features,
    hasPostBody: hasPostBody,
    nativeRequestContext: nativeRequestContext,
  );

  group('Paseo desktop window-open policy', () {
    test('routes ordinary and Shift-clicked links to workspace tabs', () {
      for (final disposition in [
        DesktopBrowserWindowOpenDisposition.foregroundTab,
        DesktopBrowserWindowOpenDisposition.newWindow,
      ]) {
        expect(
          decideDesktopBrowserWindowOpen(request(disposition: disposition)),
          isA<OpenDesktopBrowserWorkspaceTab>().having(
            (decision) => decision.url,
            'url',
            'https://example.com/target',
          ),
        );
      }
    });

    test('keeps script and named sign-in windows as real popups', () {
      for (final popupRequest in [
        request(
          url: 'https://login.example.com/signin',
          frameName: 'oauth',
          features: 'width=500,height=600',
        ),
        request(url: 'https://login.example.com/signin', frameName: 'oauth'),
        request(
          url: 'https://login.example.com/signin',
          features: 'noopener,popup=yes',
        ),
        request(
          url: 'https://login.example.com/signin',
          features: 'menubar=no,toolbar=no,status=no,scrollbars=no',
        ),
        request(
          url: 'https://login.example.com/signin',
          features: 'dialog=yes',
        ),
      ]) {
        expect(
          decideDesktopBrowserWindowOpen(popupRequest),
          isA<AllowDesktopBrowserPopup>(),
        );
      }
    });

    test('disowned named targets and non-popup features remain tabs', () {
      for (final features in ['noopener', 'noreferrer']) {
        expect(
          decideDesktopBrowserWindowOpen(
            request(frameName: 'secure-target', features: features),
          ),
          isA<OpenDesktopBrowserWorkspaceTab>(),
        );
      }
      for (final features in [
        'noopener',
        'noreferrer',
        'attributionsrc=https://example.com/register',
        'popup=false',
      ]) {
        expect(
          decideDesktopBrowserWindowOpen(request(features: features)),
          isA<OpenDesktopBrowserWorkspaceTab>(),
        );
      }
      expect(
        decideDesktopBrowserWindowOpen(
          request(
            features:
                'toolbar=yes,location=yes,menubar=yes,status=yes,'
                'scrollbars=yes,resizable=yes,noopener',
          ),
        ),
        isA<OpenDesktopBrowserWorkspaceTab>(),
      );
    });

    test('keeps POST-backed opens intact and denies unsupported schemes', () {
      expect(
        decideDesktopBrowserWindowOpen(
          request(
            disposition: DesktopBrowserWindowOpenDisposition.foregroundTab,
            hasPostBody: true,
          ),
        ),
        isA<AllowDesktopBrowserPopup>(),
      );
      expect(
        decideDesktopBrowserWindowOpen(
          request(url: 'file:///etc/passwd', frameName: 'oauth'),
        ),
        isA<DenyDesktopBrowserWindowOpen>(),
      );
      for (final malformed in [
        'https:',
        'http://',
        'https:?state=oauth',
        'https:// example.com',
      ]) {
        expect(
          decideDesktopBrowserWindowOpen(request(url: malformed)),
          isA<DenyDesktopBrowserWindowOpen>(),
          reason: malformed,
        );
      }
    });
  });

  group('pending window opens', () {
    test('holds allowed requests until identity registration', () {
      final pending = PendingDesktopBrowserWindowOpens()
        ..add(101, 'https://example.com/first')
        ..add(101, 'file:///etc/passwd')
        ..add(101, 'https://example.com/second');

      expect(pending.take(101), [
        'https://example.com/first',
        'https://example.com/second',
      ]);
      expect(pending.take(101), isEmpty);
    });

    test('caps each guest and drops destroyed guests', () {
      final pending = PendingDesktopBrowserWindowOpens();
      for (var index = 0; index < 25; index += 1) {
        pending.add(202, 'https://example.com/$index');
      }
      expect(
        pending.take(202),
        hasLength(PendingDesktopBrowserWindowOpens.maxRequestsPerGuest),
      );

      pending.add(203, 'https://example.com/target');
      pending.delete(203);
      expect(pending.take(203), isEmpty);
    });
  });

  group('desktop browser runtime', () {
    test('allows sign-in popup with original request and secure profile', () {
      final launches = <DesktopBrowserPopupLaunch>[];
      final tabs = <({String browserId, String url})>[];
      final runtime = DesktopBrowserWindowOpenRuntime(
        launchPopup: launches.add,
        openWorkspaceTab: ({required sourceBrowserId, required url}) {
          tabs.add((browserId: sourceBrowserId, url: url));
        },
      );
      final nativeRequestContext = Object();
      final popupRequest = request(
        url: 'https://login.example.com/authorize',
        frameName: 'oauth',
        features: 'width=480,height=720',
        hasPostBody: true,
        nativeRequestContext: nativeRequestContext,
      );

      expect(
        runtime.handle(
          sourceGuestId: 7,
          sourceBrowserId: 'browser-1',
          request: popupRequest,
        ),
        DesktopBrowserWindowOpenOutcome.popupAllowed,
      );
      expect(tabs, isEmpty);
      expect(launches, hasLength(1));
      expect(identical(launches.single.request, popupRequest), isTrue);
      expect(
        identical(
          launches.single.request.nativeRequestContext,
          nativeRequestContext,
        ),
        isTrue,
      );
      expect(launches.single.sourceGuestId, 7);
      expect(launches.single.sourceBrowserId, 'browser-1');
      expect(launches.single.security.profilePartition, isNotEmpty);
      expect(launches.single.security.nodeIntegration, isFalse);
      expect(launches.single.security.contextIsolation, isTrue);
      expect(launches.single.security.sandbox, isTrue);
      expect(launches.single.security.webSecurity, isTrue);
      expect(launches.single.security.embeddedBrowserTags, isFalse);
      expect(launches.single.security.allowRunningInsecureContent, isFalse);
    });

    test('queues only tabs while guest identity is registering', () {
      final launches = <DesktopBrowserPopupLaunch>[];
      final tabs = <({String browserId, String url})>[];
      final runtime = DesktopBrowserWindowOpenRuntime(
        launchPopup: launches.add,
        openWorkspaceTab: ({required sourceBrowserId, required url}) {
          tabs.add((browserId: sourceBrowserId, url: url));
        },
      );

      expect(
        runtime.handle(
          sourceGuestId: 11,
          sourceBrowserId: null,
          request: request(
            disposition: DesktopBrowserWindowOpenDisposition.foregroundTab,
          ),
        ),
        DesktopBrowserWindowOpenOutcome.workspaceTabPendingIdentity,
      );
      runtime.registerGuestIdentity(
        sourceGuestId: 11,
        sourceBrowserId: 'browser-registered',
      );

      expect(launches, isEmpty);
      expect(tabs, [
        (browserId: 'browser-registered', url: 'https://example.com/target'),
      ]);
    });
  });
}
