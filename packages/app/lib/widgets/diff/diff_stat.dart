import 'package:fluent_ui/fluent_ui.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';

final _compactDiffCountFormatter = NumberFormat.compact(locale: 'en_US')
  ..maximumFractionDigits = 1;

/// Formats a diff count with Paseo's English compact-number contract.
String formatDiffCount(int value) =>
    _compactDiffCountFormatter.format(value).toLowerCase();

/// Paseo's shared additions/deletions summary.
class DiffStat extends StatelessWidget {
  const DiffStat({super.key, required this.additions, required this.deletions});

  final int additions;
  final int deletions;

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w400);
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '+${formatDiffCount(additions)}',
            style: textStyle.copyWith(color: context.statusColors.diffAddition),
          ),
          const SizedBox(width: 4),
          Text(
            '-${formatDiffCount(deletions)}',
            style: textStyle.copyWith(color: context.statusColors.diffDeletion),
          ),
        ],
      ),
    );
  }
}
