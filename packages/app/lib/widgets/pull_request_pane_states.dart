import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';

/// Frozen Paseo 0.2.0 loading state for the pull-request pane.
class PullRequestPaneSkeleton extends StatefulWidget {
  const PullRequestPaneSkeleton({super.key});

  @override
  State<PullRequestPaneSkeleton> createState() =>
      _PullRequestPaneSkeletonState();
}

class _PullRequestPaneSkeletonState extends State<PullRequestPaneSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.4, end: 0.8).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ColoredBox(
      key: const ValueKey('pr-pane-skeleton'),
      color: context.paseoPalette.surfaceSidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonPulse(
                    key: const ValueKey('pr-pane-skeleton-title'),
                    pulse: _pulse,
                    width: constraints.maxWidth * .75,
                    height: 16,
                  ),
                  const SizedBox(height: 8),
                  _SkeletonPulse(
                    key: const ValueKey('pr-pane-skeleton-subtitle'),
                    pulse: _pulse,
                    width: constraints.maxWidth * .4,
                    height: 12,
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.paseoPalette.border),
              ),
            ),
            child: Row(
              children: [
                _SkeletonPulse(
                  key: const ValueKey('pr-pane-skeleton-toolbar-0'),
                  pulse: _pulse,
                  width: 96,
                  height: 24,
                  radius: 8,
                ),
                const SizedBox(width: 8),
                _SkeletonPulse(
                  key: const ValueKey('pr-pane-skeleton-toolbar-1'),
                  pulse: _pulse,
                  width: 96,
                  height: 24,
                  radius: 8,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    'Checks',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: context.paseoPalette.foregroundMuted,
                    ),
                  ),
                ),
                for (var row = 0; row < 3; row++) ...[
                  if (row > 0) const SizedBox(height: 4),
                  _CheckSkeletonRow(row: row, pulse: _pulse),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _ActivitySkeleton(pulse: _pulse),
          ),
        ],
      ),
    ),
  );
}

class _CheckSkeletonRow extends StatelessWidget {
  const _CheckSkeletonRow({required this.row, required this.pulse});

  final int row;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('pr-pane-skeleton-check-$row'),
    constraints: const BoxConstraints(minHeight: 32),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          _SkeletonPulse(
            key: ValueKey('pr-pane-skeleton-check-dot-$row'),
            pulse: pulse,
            width: 14,
            height: 14,
            radius: 9999,
          ),
          const SizedBox(width: 8),
          _SkeletonPulse(
            key: ValueKey('pr-pane-skeleton-check-name-$row'),
            pulse: pulse,
            width: constraints.maxWidth * .6,
            height: 12,
          ),
        ],
      ),
    ),
  );
}

class _ActivitySkeleton extends StatelessWidget {
  const _ActivitySkeleton({required this.pulse});

  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('pr-pane-activity-skeleton'),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Column(
      children: [
        for (var row = 0; row < 3; row++) ...[
          if (row > 0) const SizedBox(height: 12),
          Row(
            key: ValueKey('pr-activity-skeleton-row-$row'),
            children: [
              _SkeletonPulse(
                key: ValueKey('pr-activity-skeleton-avatar-$row'),
                pulse: pulse,
                width: 20,
                height: 20,
                radius: 9999,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SkeletonPulse(
                        key: ValueKey('pr-activity-skeleton-wide-$row'),
                        pulse: pulse,
                        width: constraints.maxWidth * .7,
                        height: 12,
                      ),
                      const SizedBox(height: 4),
                      _SkeletonPulse(
                        key: ValueKey('pr-activity-skeleton-narrow-$row'),
                        pulse: pulse,
                        width: constraints.maxWidth * .45,
                        height: 10,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

class _SkeletonPulse extends StatelessWidget {
  const _SkeletonPulse({
    super.key,
    required this.pulse,
    required this.width,
    required this.height,
    this.radius = 2,
  });

  final Animation<double> pulse;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: pulse,
    child: SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.paseoPalette.surface2,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    ),
  );
}

/// Frozen Paseo 0.2.0 fatal load error with an explicit retry action.
class PullRequestPaneError extends StatelessWidget {
  const PullRequestPaneError({super.key, required this.onRetry, this.message});

  final VoidCallback onRetry;
  final String? message;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey('pr-pane-error'),
    color: context.paseoPalette.surfaceSidebar,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message ?? 'Failed to refresh git state.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: context.paseoPalette.foregroundMuted,
              ),
            ),
            const SizedBox(height: 12),
            _RetryButton(onPressed: onRetry),
          ],
        ),
      ),
    ),
  );
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: HoverButton(
      key: const ValueKey('pr-pane-error-retry'),
      onPressed: onPressed,
      builder: (context, states) {
        final pressed = states.contains(WidgetState.pressed);
        final hovered = states.contains(WidgetState.hovered);
        return Opacity(
          opacity: pressed ? .85 : 1,
          child: Container(
            constraints: const BoxConstraints(minHeight: 24),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: hovered
                  ? context.paseoPalette.surfaceSidebarHover
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  FluentIcons.refresh,
                  size: 12,
                  color: context.paseoPalette.foreground,
                ),
                const SizedBox(width: 6),
                Text(
                  'Retry',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.paseoPalette.foreground,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
