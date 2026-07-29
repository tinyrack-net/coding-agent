import 'package:fluent_ui/fluent_ui.dart';

import '../core/forge_logic.dart';
import '../core/theme.dart';

enum PullRequestSummaryVariant { success, danger, warning, muted }

enum PullRequestSummaryIcon { check, x, dot, message }

/// Frozen Paseo 0.2.0 collapsible pull-request section.
class PullRequestSection extends StatelessWidget {
  const PullRequestSection({
    super.key,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.summary,
    required this.child,
  });

  final String title;
  final bool open;
  final VoidCallback onToggle;
  final Widget summary;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        button: true,
        expanded: open,
        child: HoverButton(
          key: ValueKey('pr-section-$title'),
          onPressed: onToggle,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                PullRequestGlyph(
                  key: ValueKey('pr-section-chevron-$title'),
                  kind: open
                      ? PullRequestGlyphKind.chevronDown
                      : PullRequestGlyphKind.chevronRight,
                  size: 14,
                  color: context.paseoPalette.foregroundMuted,
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: context.paseoPalette.foregroundMuted,
                  ),
                ),
                const Spacer(),
                summary,
              ],
            ),
          ),
        ),
      ),
      if (open)
        Padding(
          key: ValueKey('pr-section-body-$title'),
          padding: const EdgeInsets.only(bottom: 12),
          child: child,
        ),
    ],
  );
}

class PullRequestSectionSummary extends StatelessWidget {
  const PullRequestSectionSummary({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final visible = children
        .where((child) => child is! PullRequestSummaryPill || child.count != 0)
        .toList(growable: false);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < visible.length; index++) ...[
          if (index > 0) const SizedBox(width: 8),
          visible[index],
        ],
      ],
    );
  }
}

/// Frozen transparent count indicator. Paseo intentionally uses no badge
/// background, border, or padding here.
class PullRequestSummaryPill extends StatelessWidget {
  const PullRequestSummaryPill({
    super.key,
    required this.count,
    required this.variant,
    required this.icon,
  });

  final int count;
  final PullRequestSummaryVariant variant;
  final PullRequestSummaryIcon icon;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    final color = switch (variant) {
      PullRequestSummaryVariant.success => context.paseoPalette.statusSuccess,
      PullRequestSummaryVariant.danger => context.paseoPalette.statusDanger,
      PullRequestSummaryVariant.warning => context.paseoPalette.statusWarning,
      PullRequestSummaryVariant.muted => context.paseoPalette.foregroundMuted,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PullRequestGlyph(
          kind: switch (icon) {
            PullRequestSummaryIcon.check => PullRequestGlyphKind.circleCheck,
            PullRequestSummaryIcon.x => PullRequestGlyphKind.circleX,
            PullRequestSummaryIcon.dot => PullRequestGlyphKind.circleDot,
            PullRequestSummaryIcon.message =>
              PullRequestGlyphKind.messageSquare,
          },
          size: icon == PullRequestSummaryIcon.message ? 11 : 12,
          color: color,
        ),
        const SizedBox(width: 3),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: color,
          ),
        ),
      ],
    );
  }
}

class PullRequestCheckStatusIcon extends StatelessWidget {
  const PullRequestCheckStatusIcon({super.key, required this.status});

  final ForgeCheckStatus status;

  @override
  Widget build(BuildContext context) {
    final (kind, color) = switch (status) {
      ForgeCheckStatus.success => (
        PullRequestGlyphKind.circleCheck,
        context.paseoPalette.statusSuccess,
      ),
      ForgeCheckStatus.failure => (
        PullRequestGlyphKind.circleX,
        context.paseoPalette.statusDanger,
      ),
      ForgeCheckStatus.pending => (
        PullRequestGlyphKind.circleDot,
        context.paseoPalette.statusWarning,
      ),
      ForgeCheckStatus.skipped => (
        PullRequestGlyphKind.circleSlash,
        context.paseoPalette.foregroundMuted,
      ),
    };
    return PullRequestGlyph(kind: kind, size: 14, color: color);
  }
}

class PullRequestCheckRowLayout extends StatelessWidget {
  const PullRequestCheckRowLayout({
    super.key,
    required this.status,
    required this.name,
    this.workflow,
    this.trailing,
    this.onPressed,
    this.enabled = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  });

  final ForgeCheckStatus status;
  final String name;
  final String? workflow;
  final Widget? trailing;
  final VoidCallback? onPressed;
  final bool enabled;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => HoverButton(
    onPressed: enabled ? onPressed : null,
    forceEnabled: enabled,
    focusEnabled: false,
    builder: (context, states) => Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: padding,
      color: states.contains(WidgetState.hovered)
          ? context.paseoPalette.surface1
          : Colors.transparent,
      child: Row(
        children: [
          PullRequestCheckStatusIcon(status: status),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: context.paseoPalette.foreground,
              ),
            ),
          ),
          if (workflow != null && workflow!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                workflow!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: context.paseoPalette.foregroundMuted,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    ),
  );
}

class PullRequestCheckTrailing extends StatelessWidget {
  const PullRequestCheckTrailing({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var index = 0; index < children.length; index++) ...[
        if (index > 0) const SizedBox(width: 8),
        children[index],
      ],
    ],
  );
}

class PullRequestCheckDuration extends StatelessWidget {
  const PullRequestCheckDuration(this.value, {super.key});

  final String value;

  @override
  Widget build(BuildContext context) => Text(
    value,
    style: TextStyle(fontSize: 12, color: context.paseoPalette.foregroundMuted),
  );
}

class PullRequestEmptyText extends StatelessWidget {
  const PullRequestEmptyText(this.value, {super.key});

  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Text(
      value,
      style: TextStyle(
        fontSize: 12,
        color: context.paseoPalette.foregroundMuted,
      ),
    ),
  );
}

enum PullRequestGlyphKind {
  chevronDown,
  chevronRight,
  circleCheck,
  circleX,
  circleDot,
  circleSlash,
  messageSquare,
}

class PullRequestGlyph extends StatelessWidget {
  const PullRequestGlyph({
    super.key,
    required this.kind,
    required this.size,
    required this.color,
  });

  final PullRequestGlyphKind kind;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: PullRequestGlyphPainter(kind: kind, color: color),
    ),
  );
}

class PullRequestGlyphPainter extends CustomPainter {
  const PullRequestGlyphPainter({required this.kind, required this.color});

  final PullRequestGlyphKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.scale(scale);
    switch (kind) {
      case PullRequestGlyphKind.chevronDown:
        _path(canvas, paint, const [
          Offset(6, 9),
          Offset(12, 15),
          Offset(18, 9),
        ]);
      case PullRequestGlyphKind.chevronRight:
        _path(canvas, paint, const [
          Offset(9, 6),
          Offset(15, 12),
          Offset(9, 18),
        ]);
      case PullRequestGlyphKind.circleCheck:
        canvas.drawCircle(const Offset(12, 12), 10, paint);
        _path(canvas, paint, const [
          Offset(9, 12),
          Offset(11, 14),
          Offset(15, 10),
        ]);
      case PullRequestGlyphKind.circleX:
        canvas.drawCircle(const Offset(12, 12), 10, paint);
        _path(canvas, paint, const [Offset(9, 9), Offset(15, 15)]);
        _path(canvas, paint, const [Offset(15, 9), Offset(9, 15)]);
      case PullRequestGlyphKind.circleDot:
        canvas.drawCircle(const Offset(12, 12), 10, paint);
        canvas.drawCircle(
          const Offset(12, 12),
          1,
          paint..style = PaintingStyle.fill,
        );
      case PullRequestGlyphKind.circleSlash:
        canvas.drawCircle(const Offset(12, 12), 10, paint);
        _path(canvas, paint, const [Offset(9, 9), Offset(15, 15)]);
      case PullRequestGlyphKind.messageSquare:
        final path = Path()
          ..moveTo(21, 15)
          ..quadraticBezierTo(21, 17, 19, 17)
          ..lineTo(8, 17)
          ..lineTo(3, 21)
          ..lineTo(3, 5)
          ..quadraticBezierTo(3, 3, 5, 3)
          ..lineTo(19, 3)
          ..quadraticBezierTo(21, 3, 21, 5)
          ..close();
        canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  void _path(Canvas canvas, Paint paint, List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant PullRequestGlyphPainter oldDelegate) =>
      kind != oldDelegate.kind || color != oldDelegate.color;
}
