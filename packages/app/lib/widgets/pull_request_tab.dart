import 'package:fluent_ui/fluent_ui.dart';

import '../core/forge.dart';

String formatPullRequestTabLabel(num? pullRequestNumber) =>
    pullRequestNumber == null ? '—' : '${pullRequestNumber.toInt()}';

class PullRequestTabIcon extends StatelessWidget {
  const PullRequestTabIcon({
    super.key,
    required this.forge,
    required this.size,
    required this.color,
  });

  final String forge;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final presentation = getForgePresentation(forge.toLowerCase());
    return ForgeBrandIcon(
      iconKind: presentation.icon,
      size: size,
      color: color,
      useBrandColor: false,
    );
  }
}
