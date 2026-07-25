import 'package:fluent_ui/fluent_ui.dart';

/// A `PageHeader.leading` back button for routes pushed on top of the
/// persistent shell (New workspace/Projects/Status/Settings) — `ScaffoldPage`
/// has no automatic back affordance the way a Material `Scaffold`'s `AppBar`
/// does, so without this a pushed screen has no way back except the
/// sidebar (which only works if the destination differs from the current
/// route).
class PageBackButton extends StatelessWidget {
  const PageBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Back',
      child: IconButton(
        icon: const Icon(FluentIcons.back),
        onPressed: () => Navigator.of(context).pop(),
      ),
    );
  }
}
