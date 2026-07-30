/// The browser disposition reported by a desktop embedded-browser host.
enum DesktopBrowserWindowOpenDisposition {
  defaultDisposition,
  foregroundTab,
  backgroundTab,
  newWindow,
  other,
}

final class DesktopBrowserWindowOpenRequest {
  const DesktopBrowserWindowOpenRequest({
    required this.url,
    required this.disposition,
    this.frameName = '',
    this.features = '',
    this.hasPostBody = false,
    this.nativeRequestContext,
  });

  final String url;
  final DesktopBrowserWindowOpenDisposition disposition;
  final String frameName;
  final String features;
  final bool hasPostBody;

  /// Opaque handle supplied by the eventual native browser host.
  ///
  /// The host must pass this same handle back when allowing a popup so it can
  /// approve the original navigation instead of reconstructing a URL-only
  /// request and losing POST data or opener state.
  final Object? nativeRequestContext;
}

sealed class DesktopBrowserWindowOpenDecision {
  const DesktopBrowserWindowOpenDecision();
}

final class DenyDesktopBrowserWindowOpen
    extends DesktopBrowserWindowOpenDecision {
  const DenyDesktopBrowserWindowOpen();
}

final class AllowDesktopBrowserPopup extends DesktopBrowserWindowOpenDecision {
  const AllowDesktopBrowserPopup();
}

final class OpenDesktopBrowserWorkspaceTab
    extends DesktopBrowserWindowOpenDecision {
  const OpenDesktopBrowserWorkspaceTab(this.url);

  final String url;
}

/// Matches Paseo 0.2.0's desktop window-open policy.
///
/// A real child window is required for sign-in and payment protocols because
/// converting it to a tab loses `window.opener`, `postMessage`, named-window
/// reuse, the request body, and the page's ability to call `window.close()`.
DesktopBrowserWindowOpenDecision decideDesktopBrowserWindowOpen(
  DesktopBrowserWindowOpenRequest request,
) {
  if (!isAllowedDesktopBrowserUrl(request.url)) {
    return const DenyDesktopBrowserWindowOpen();
  }

  final intent = _readFeatureIntent(request.features);
  final hasNamedTarget =
      request.frameName.isNotEmpty && request.frameName != '_blank';
  final isScriptPopup =
      request.disposition == DesktopBrowserWindowOpenDisposition.newWindow &&
      (intent.requestsPopup || (hasNamedTarget && !intent.disownsOpener));

  if (isScriptPopup || request.hasPostBody) {
    return const AllowDesktopBrowserPopup();
  }
  return OpenDesktopBrowserWorkspaceTab(request.url);
}

bool isAllowedDesktopBrowserUrl(String value) {
  if (value.isEmpty) return true;
  if (value == 'about:blank') return true;
  if (value.contains(RegExp(r'\s'))) return false;
  final parsed = Uri.tryParse(value);
  if (parsed == null) return false;
  return (parsed.scheme == 'http' || parsed.scheme == 'https') &&
      parsed.hasAuthority &&
      parsed.host.isNotEmpty;
}

final class PendingDesktopBrowserWindowOpens {
  static const maxRequestsPerGuest = 20;

  final Map<int, List<String>> _urlsByGuestId = {};

  void add(int guestId, String url) {
    if (!isAllowedDesktopBrowserUrl(url)) return;
    final urls = _urlsByGuestId.putIfAbsent(guestId, () => []);
    if (urls.length >= maxRequestsPerGuest) return;
    urls.add(url);
  }

  List<String> take(int guestId) =>
      List.unmodifiable(_urlsByGuestId.remove(guestId) ?? const <String>[]);

  void delete(int guestId) => _urlsByGuestId.remove(guestId);
}

final class DesktopBrowserPopupSecurity {
  const DesktopBrowserPopupSecurity({
    this.profilePartition = 'persist:tinyrack-browser',
    this.nodeIntegration = false,
    this.nodeIntegrationInSubFrames = false,
    this.nodeIntegrationInWorker = false,
    this.contextIsolation = true,
    this.sandbox = true,
    this.webSecurity = true,
    this.embeddedBrowserTags = false,
    this.allowRunningInsecureContent = false,
  });

  final String profilePartition;
  final bool nodeIntegration;
  final bool nodeIntegrationInSubFrames;
  final bool nodeIntegrationInWorker;
  final bool contextIsolation;
  final bool sandbox;
  final bool webSecurity;
  final bool embeddedBrowserTags;
  final bool allowRunningInsecureContent;
}

final class DesktopBrowserPopupLaunch {
  const DesktopBrowserPopupLaunch({
    required this.sourceGuestId,
    required this.sourceBrowserId,
    required this.request,
    required this.security,
  });

  final int sourceGuestId;
  final String? sourceBrowserId;
  final DesktopBrowserWindowOpenRequest request;
  final DesktopBrowserPopupSecurity security;
}

enum DesktopBrowserWindowOpenOutcome {
  denied,
  popupAllowed,
  workspaceTabOpened,
  workspaceTabPendingIdentity,
}

typedef DesktopBrowserPopupLauncher =
    void Function(DesktopBrowserPopupLaunch launch);
typedef DesktopBrowserWorkspaceTabOpener =
    void Function({required String sourceBrowserId, required String url});

/// Runtime boundary used by a desktop embedded-browser implementation.
///
/// Popup launches deliberately receive the original request and its opaque
/// native context instead of a URL reconstruction. The native host is
/// responsible for approving that original request synchronously so POST and
/// opener state survive.
final class DesktopBrowserWindowOpenRuntime {
  DesktopBrowserWindowOpenRuntime({
    required this.launchPopup,
    required this.openWorkspaceTab,
    PendingDesktopBrowserWindowOpens? pending,
    this.popupSecurity = const DesktopBrowserPopupSecurity(),
  }) : _pending = pending ?? PendingDesktopBrowserWindowOpens();

  final DesktopBrowserPopupLauncher launchPopup;
  final DesktopBrowserWorkspaceTabOpener openWorkspaceTab;
  final PendingDesktopBrowserWindowOpens _pending;
  final DesktopBrowserPopupSecurity popupSecurity;

  DesktopBrowserWindowOpenOutcome handle({
    required int sourceGuestId,
    required String? sourceBrowserId,
    required DesktopBrowserWindowOpenRequest request,
  }) {
    final decision = decideDesktopBrowserWindowOpen(request);
    switch (decision) {
      case DenyDesktopBrowserWindowOpen():
        return DesktopBrowserWindowOpenOutcome.denied;
      case AllowDesktopBrowserPopup():
        launchPopup(
          DesktopBrowserPopupLaunch(
            sourceGuestId: sourceGuestId,
            sourceBrowserId: sourceBrowserId,
            request: request,
            security: popupSecurity,
          ),
        );
        return DesktopBrowserWindowOpenOutcome.popupAllowed;
      case OpenDesktopBrowserWorkspaceTab(:final url):
        if (sourceBrowserId == null || sourceBrowserId.isEmpty) {
          _pending.add(sourceGuestId, url);
          return DesktopBrowserWindowOpenOutcome.workspaceTabPendingIdentity;
        }
        openWorkspaceTab(sourceBrowserId: sourceBrowserId, url: url);
        return DesktopBrowserWindowOpenOutcome.workspaceTabOpened;
    }
  }

  void registerGuestIdentity({
    required int sourceGuestId,
    required String sourceBrowserId,
  }) {
    for (final url in _pending.take(sourceGuestId)) {
      openWorkspaceTab(sourceBrowserId: sourceBrowserId, url: url);
    }
  }

  void forgetGuest(int sourceGuestId) => _pending.delete(sourceGuestId);
}

const _geometryFeatureNames = {
  'height',
  'innerheight',
  'innerwidth',
  'left',
  'outerheight',
  'outerwidth',
  'screenx',
  'screeny',
  'top',
  'width',
  'x',
  'y',
};
const _uiFeatureNames = {
  'location',
  'menubar',
  'resizable',
  'scrollbars',
  'status',
  'toolbar',
};
const _nonPopupFeatureNames = {
  'attributionsrc',
  'noopener',
  'noreferrer',
  'popup',
};

({bool requestsPopup, bool disownsOpener}) _readFeatureIntent(String features) {
  var requestsPopup = false;
  var disownsOpener = false;
  var hasPopupRelevantFeature = false;
  final enabledUiFeatures = <String, bool>{};

  for (final rawFeature in features.split(',')) {
    final separatorIndex = rawFeature.indexOf('=');
    final name = rawFeature
        .substring(0, separatorIndex == -1 ? null : separatorIndex)
        .trim()
        .toLowerCase();
    final value = separatorIndex == -1
        ? ''
        : rawFeature.substring(separatorIndex + 1).trim().toLowerCase();

    if (_geometryFeatureNames.contains(name)) {
      requestsPopup = true;
    }
    if (_uiFeatureNames.contains(name)) {
      hasPopupRelevantFeature = true;
      enabledUiFeatures[name] = _isEnabledFeature(value);
    } else if (name.isNotEmpty && !_nonPopupFeatureNames.contains(name)) {
      hasPopupRelevantFeature = true;
    }
    if (name == 'popup' && _isEnabledFeature(value)) {
      requestsPopup = true;
    }
    if ((name == 'noopener' || name == 'noreferrer') &&
        _isEnabledFeature(value)) {
      disownsOpener = true;
    }
  }

  if (!requestsPopup && hasPopupRelevantFeature) {
    bool enabled(String name) => enabledUiFeatures[name] ?? false;
    requestsPopup =
        (!enabled('location') && !enabled('toolbar')) ||
        !enabled('menubar') ||
        !enabled('resizable') ||
        !enabled('scrollbars') ||
        !enabled('status');
  }

  return (requestsPopup: requestsPopup, disownsOpener: disownsOpener);
}

bool _isEnabledFeature(String value) =>
    value != '0' && value != 'false' && value != 'no';
