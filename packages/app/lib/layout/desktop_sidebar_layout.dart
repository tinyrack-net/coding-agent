const defaultSidebarWidth = 320.0;
const minSidebarWidth = 200.0;
const maxSidebarWidth = 600.0;
const compactFormFactorWidth = 500.0;

const defaultExplorerSidebarWidth = 400.0;
const minExplorerSidebarWidth = 280.0;
const maxExplorerSidebarWidth = 2000.0;

const minDesktopCenterWidth = 400.0;
const settingsDesktopSplitMinWidth = 720.0;

enum DesktopChromeCorners { none, topLeft, topRight, both }

enum SidebarToggleOwner { none, window, content }

class DesktopAppChromeLayout {
  const DesktopAppChromeLayout({
    required this.sidebarCorners,
    required this.contentCorners,
    required this.sidebarToggleOwner,
  });

  final DesktopChromeCorners sidebarCorners;
  final DesktopChromeCorners contentCorners;
  final SidebarToggleOwner sidebarToggleOwner;
}

DesktopAppChromeLayout resolveDesktopAppChromeLayout({
  required bool desktopSidebarRendered,
  required bool hasTopLeftWindowControls,
  required bool sidebarControlsEnabled,
}) {
  final sidebarOwnsTopLeft = desktopSidebarRendered && hasTopLeftWindowControls;
  final SidebarToggleOwner toggleOwner;
  if (!sidebarControlsEnabled) {
    toggleOwner = SidebarToggleOwner.none;
  } else {
    toggleOwner = hasTopLeftWindowControls
        ? SidebarToggleOwner.window
        : SidebarToggleOwner.content;
  }
  return DesktopAppChromeLayout(
    sidebarCorners: sidebarOwnsTopLeft
        ? DesktopChromeCorners.topLeft
        : DesktopChromeCorners.none,
    contentCorners: sidebarOwnsTopLeft
        ? DesktopChromeCorners.topRight
        : DesktopChromeCorners.both,
    sidebarToggleOwner: toggleOwner,
  );
}

double _resolveDesktopPanelWidth({
  required double requestedWidth,
  required double viewportWidth,
  required double minimumWidth,
  required double maximumWidth,
}) {
  final maximumVisibleWidth = (viewportWidth - minDesktopCenterWidth).clamp(
    minimumWidth,
    maximumWidth,
  );
  return requestedWidth.clamp(minimumWidth, maximumVisibleWidth);
}

double resolveDesktopSidebarWidth({
  required double requestedWidth,
  required double viewportWidth,
}) => _resolveDesktopPanelWidth(
  requestedWidth: requestedWidth,
  viewportWidth: viewportWidth,
  minimumWidth: minSidebarWidth,
  maximumWidth: maxSidebarWidth,
);

double resolveDesktopExplorerWidth({
  required double requestedWidth,
  required double viewportWidth,
}) => _resolveDesktopPanelWidth(
  requestedWidth: requestedWidth,
  viewportWidth: viewportWidth,
  minimumWidth: minExplorerSidebarWidth,
  maximumWidth: maxExplorerSidebarWidth,
);

double resolveDesktopAppContentMinimum({
  required bool isSettingsRoute,
  required bool isWorkspaceExplorerOpen,
  required double requestedExplorerWidth,
  required double viewportWidth,
}) {
  final workspaceMinimum = isWorkspaceExplorerOpen
      ? minDesktopCenterWidth +
            resolveDesktopExplorerWidth(
              requestedWidth: requestedExplorerWidth,
              viewportWidth: viewportWidth,
            )
      : 0.0;
  final settingsMinimum = isSettingsRoute ? settingsDesktopSplitMinWidth : 0.0;
  return settingsMinimum > workspaceMinimum
      ? settingsMinimum
      : workspaceMinimum;
}

bool canDesktopAppSidebarShare({
  required double contentMinimumWidth,
  required double requestedSidebarWidth,
  required double viewportWidth,
}) =>
    viewportWidth -
        resolveDesktopSidebarWidth(
          requestedWidth: requestedSidebarWidth,
          viewportWidth: viewportWidth,
        ) >=
    contentMinimumWidth;
