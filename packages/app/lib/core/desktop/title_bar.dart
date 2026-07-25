import 'package:fluent_ui/fluent_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_shell.dart';

const double kTitleBarHeight = 32;

/// A custom WinUI-style caption bar: app title + drag region + minimize/
/// maximize/close buttons, replacing the OS-native title bar on Windows
/// (see `desktop_shell.dart`'s `setTitleBarStyle(TitleBarStyle.hidden)`).
/// No-op wrapper (renders [child] unchanged) on every other platform.
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isWindowsDesktop) return child;

    return Column(
      children: [
        SizedBox(
          height: kTitleBarHeight,
          child: Row(
            children: [
              Expanded(
                child: DragToMoveArea(
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Text(
                        'Coding Agent',
                        style: FluentTheme.of(context).typography.caption,
                      ),
                    ],
                  ),
                ),
              ),
              const _CaptionButton(
                icon: FluentIcons.chrome_minimize,
                onPressed: _minimize,
              ),
              const _CaptionButton(
                icon: FluentIcons.chrome_full_screen,
                onPressed: _toggleMaximize,
              ),
              _CaptionButton(
                icon: FluentIcons.chrome_close,
                hoverColor: Colors.red,
                onPressed: () => windowManager.close(),
              ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

Future<void> _minimize() => windowManager.minimize();

Future<void> _toggleMaximize() async {
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
  } else {
    await windowManager.maximize();
  }
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.icon,
    required this.onPressed,
    this.hoverColor,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: kTitleBarHeight,
      child: HoverButton(
        onPressed: onPressed,
        builder: (context, states) {
          final hovering = states.contains(WidgetState.hovered);
          return Container(
            color: hovering
                ? (hoverColor ?? Colors.white.withValues(alpha: 0.06))
                : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(icon, size: 10),
          );
        },
      ),
    );
  }
}
