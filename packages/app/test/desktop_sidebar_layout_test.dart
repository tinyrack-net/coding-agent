import 'package:coding_agent_app/layout/desktop_sidebar_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves window chrome ownership exactly', () {
    var layout = resolveDesktopAppChromeLayout(
      desktopSidebarRendered: true,
      hasTopLeftWindowControls: true,
      sidebarControlsEnabled: true,
    );
    expect(layout.sidebarCorners, DesktopChromeCorners.topLeft);
    expect(layout.contentCorners, DesktopChromeCorners.topRight);
    expect(layout.sidebarToggleOwner, SidebarToggleOwner.window);

    layout = resolveDesktopAppChromeLayout(
      desktopSidebarRendered: true,
      hasTopLeftWindowControls: false,
      sidebarControlsEnabled: true,
    );
    expect(layout.sidebarCorners, DesktopChromeCorners.none);
    expect(layout.contentCorners, DesktopChromeCorners.both);
    expect(layout.sidebarToggleOwner, SidebarToggleOwner.content);

    layout = resolveDesktopAppChromeLayout(
      desktopSidebarRendered: false,
      hasTopLeftWindowControls: true,
      sidebarControlsEnabled: false,
    );
    expect(layout.sidebarToggleOwner, SidebarToggleOwner.none);
  });

  test('clamps sidebar width to preserve a 400px center pane', () {
    expect(
      resolveDesktopSidebarWidth(requestedWidth: 600, viewportWidth: 751),
      351,
    );
    expect(
      resolveDesktopSidebarWidth(requestedWidth: 600, viewportWidth: 720),
      320,
    );
    expect(
      resolveDesktopSidebarWidth(requestedWidth: 600, viewportWidth: 1440),
      600,
    );
    expect(
      resolveDesktopSidebarWidth(requestedWidth: 100, viewportWidth: 1440),
      200,
    );
  });

  test('keeps temporarily narrow explorer widths render-only', () {
    expect(
      resolveDesktopExplorerWidth(requestedWidth: 400, viewportWidth: 751),
      351,
    );
    expect(
      resolveDesktopExplorerWidth(requestedWidth: 400, viewportWidth: 1440),
      400,
    );
  });

  test('yields navigation when settings or explorer need shell width', () {
    final settingsMinimum = resolveDesktopAppContentMinimum(
      isSettingsRoute: true,
      isWorkspaceExplorerOpen: false,
      requestedExplorerWidth: 400,
      viewportWidth: 751,
    );
    expect(settingsMinimum, 720);
    expect(
      canDesktopAppSidebarShare(
        contentMinimumWidth: settingsMinimum,
        requestedSidebarWidth: 320,
        viewportWidth: 751,
      ),
      isFalse,
    );

    final explorerMinimum = resolveDesktopAppContentMinimum(
      isSettingsRoute: false,
      isWorkspaceExplorerOpen: true,
      requestedExplorerWidth: 400,
      viewportWidth: 751,
    );
    expect(explorerMinimum, 751);
    expect(
      canDesktopAppSidebarShare(
        contentMinimumWidth: explorerMinimum,
        requestedSidebarWidth: 320,
        viewportWidth: 751,
      ),
      isFalse,
    );
    expect(
      canDesktopAppSidebarShare(
        contentMinimumWidth: resolveDesktopAppContentMinimum(
          isSettingsRoute: false,
          isWorkspaceExplorerOpen: true,
          requestedExplorerWidth: 400,
          viewportWidth: 1120,
        ),
        requestedSidebarWidth: 320,
        viewportWidth: 1120,
      ),
      isTrue,
    );
  });
}
