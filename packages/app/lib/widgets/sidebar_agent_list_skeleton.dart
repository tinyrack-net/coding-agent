import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';

const _sectionOpacities = <double>[1, 0.7, 0.4];

/// Paseo's decorative initial-load placeholder for the workspace sidebar.
class SidebarAgentListSkeleton extends StatefulWidget {
  const SidebarAgentListSkeleton({super.key});

  @override
  State<SidebarAgentListSkeleton> createState() =>
      _SidebarAgentListSkeletonState();
}

class _SidebarAgentListSkeletonState extends State<SidebarAgentListSkeleton>
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
    child: ClipRect(
      child: SingleChildScrollView(
        key: const ValueKey('sidebar-agent-list-skeleton'),
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8, bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var section = 0; section < _sectionOpacities.length; section++)
              Opacity(
                key: ValueKey('sidebar-skeleton-section-$section'),
                opacity: _sectionOpacities[section],
                child: _SkeletonSection(section: section, pulse: _pulse),
              ),
          ],
        ),
      ),
    ),
  );
}

class _SkeletonSection extends StatelessWidget {
  const _SkeletonSection({required this.section, required this.pulse});

  final int section;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                _SkeletonPulse(
                  key: ValueKey('sidebar-skeleton-chevron-$section'),
                  pulse: pulse,
                  width: 14,
                  height: 14,
                  radius: 2,
                ),
                const SizedBox(width: 8),
                _SkeletonPulse(
                  key: ValueKey('sidebar-skeleton-project-icon-$section'),
                  pulse: pulse,
                  width: 16,
                  height: 16,
                  radius: 2,
                ),
                const SizedBox(width: 8),
                _SkeletonPulse(
                  key: ValueKey('sidebar-skeleton-section-title-$section'),
                  pulse: pulse,
                  width: constraints.maxWidth * 0.45,
                  height: 12,
                  radius: 2,
                ),
              ],
            ),
          ),
        ),
        for (var row = 0; row < 3; row++) ...[
          if (row > 0) const SizedBox(height: 4),
          Padding(
            key: ValueKey('sidebar-skeleton-row-$section-$row'),
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            child: Row(
              children: [
                _SkeletonPulse(
                  key: ValueKey('sidebar-skeleton-row-dot-$section-$row'),
                  pulse: pulse,
                  width: 8,
                  height: 8,
                  radius: 9999,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SkeletonPulse(
                    key: ValueKey('sidebar-skeleton-row-title-$section-$row'),
                    pulse: pulse,
                    height: 12,
                    radius: 2,
                  ),
                ),
                const SizedBox(width: 8),
                _SkeletonPulse(
                  key: ValueKey('sidebar-skeleton-row-badge-$section-$row'),
                  pulse: pulse,
                  width: 40,
                  height: 20,
                  radius: 6,
                ),
              ],
            ),
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
    this.width,
    required this.height,
    required this.radius,
  });

  final Animation<double> pulse;
  final double? width;
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
