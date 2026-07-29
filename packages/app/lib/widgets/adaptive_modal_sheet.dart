import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';

const adaptiveModalCompactBreakpoint = 720.0;
const adaptiveModalDesktopMaxWidth = 520.0;
const adaptiveModalDesktopMaxHeightFactor = .85;
const adaptiveModalCompactInitialHeightFactor = .65;
const adaptiveModalCompactMaxHeightFactor = .9;
const adaptiveModalHorizontalPadding = 24.0;
const adaptiveModalContentPadding = 24.0;
const adaptiveModalFooterVerticalPadding = 12.0;

final class CompactSheetSafeAreaPadding {
  const CompactSheetSafeAreaPadding({
    this.contentPaddingBottom,
    this.footerPaddingBottom,
  });

  final double? contentPaddingBottom;
  final double? footerPaddingBottom;
}

CompactSheetSafeAreaPadding resolveCompactSheetSafeAreaPadding({
  required bool isCompact,
  required bool hasFooter,
  required double safeAreaBottom,
  double baseContentPadding = adaptiveModalContentPadding,
  double baseFooterPadding = adaptiveModalFooterVerticalPadding,
}) {
  if (!isCompact || safeAreaBottom <= 0) {
    return const CompactSheetSafeAreaPadding();
  }
  if (hasFooter) {
    return CompactSheetSafeAreaPadding(
      footerPaddingBottom: baseFooterPadding + safeAreaBottom,
    );
  }
  return CompactSheetSafeAreaPadding(
    contentPaddingBottom: baseContentPadding + safeAreaBottom,
  );
}

Future<T?> showAdaptiveModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  barrierLabel: 'Dismiss',
  barrierColor: const Color(0x8C000000),
  transitionDuration: const Duration(milliseconds: 160),
  pageBuilder: (context, _, _) => builder(context),
  transitionBuilder: (context, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  ),
);

class AdaptiveModalSheet extends StatelessWidget {
  const AdaptiveModalSheet({
    super.key,
    required this.title,
    required this.content,
    required this.onClose,
    this.actions = const [],
    this.desktopMaxWidth = adaptiveModalDesktopMaxWidth,
    this.compactInitialHeightFactor = adaptiveModalCompactInitialHeightFactor,
    this.compactMaxHeightFactor = adaptiveModalCompactMaxHeightFactor,
  }) : assert(compactInitialHeightFactor >= .2),
       assert(compactInitialHeightFactor <= compactMaxHeightFactor),
       assert(compactMaxHeightFactor <= 1);

  final String title;
  final Widget content;
  final VoidCallback onClose;
  final List<Widget> actions;
  final double desktopMaxWidth;
  final double compactInitialHeightFactor;
  final double compactMaxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final compact = media.size.width < adaptiveModalCompactBreakpoint;
    final safeArea = resolveCompactSheetSafeAreaPadding(
      isCompact: compact,
      hasFooter: actions.isNotEmpty,
      safeAreaBottom: media.viewPadding.bottom,
    );
    return AnimatedPadding(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: compact
          ? _CompactAdaptiveModalSheet(
              title: title,
              content: content,
              onClose: onClose,
              actions: actions,
              safeArea: safeArea,
              initialHeightFactor: compactInitialHeightFactor,
              maxHeightFactor: compactMaxHeightFactor,
            )
          : _DesktopAdaptiveModalSheet(
              title: title,
              content: content,
              onClose: onClose,
              actions: actions,
              maxWidth: desktopMaxWidth,
            ),
    );
  }
}

class _DesktopAdaptiveModalSheet extends StatelessWidget {
  const _DesktopAdaptiveModalSheet({
    required this.title,
    required this.content,
    required this.onClose,
    required this.actions,
    required this.maxWidth,
  });

  final String title;
  final Widget content;
  final VoidCallback onClose;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(adaptiveModalHorizontalPadding),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: size.height * adaptiveModalDesktopMaxHeightFactor,
          ),
          child: _AdaptiveModalCard(
            title: title,
            content: content,
            onClose: onClose,
            actions: actions,
          ),
        ),
      ),
    );
  }
}

class _CompactAdaptiveModalSheet extends StatefulWidget {
  const _CompactAdaptiveModalSheet({
    required this.title,
    required this.content,
    required this.onClose,
    required this.actions,
    required this.safeArea,
    required this.initialHeightFactor,
    required this.maxHeightFactor,
  });

  final String title;
  final Widget content;
  final VoidCallback onClose;
  final List<Widget> actions;
  final CompactSheetSafeAreaPadding safeArea;
  final double initialHeightFactor;
  final double maxHeightFactor;

  @override
  State<_CompactAdaptiveModalSheet> createState() =>
      _CompactAdaptiveModalSheetState();
}

class _CompactAdaptiveModalSheetState
    extends State<_CompactAdaptiveModalSheet> {
  var _closing = false;

  bool _handleDrag(DraggableScrollableNotification notification) {
    if (!_closing && notification.extent <= .25) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onClose();
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<DraggableScrollableNotification>(
        onNotification: _handleDrag,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: widget.initialHeightFactor,
            minChildSize: .2,
            maxChildSize: widget.maxHeightFactor,
            snap: true,
            snapSizes: [widget.initialHeightFactor, widget.maxHeightFactor],
            builder: (context, scrollController) => _AdaptiveModalCard(
              title: widget.title,
              content: widget.content,
              onClose: widget.onClose,
              actions: widget.actions,
              scrollController: scrollController,
              contentPaddingBottom:
                  widget.safeArea.contentPaddingBottom ??
                  adaptiveModalContentPadding,
              footerPaddingBottom:
                  widget.safeArea.footerPaddingBottom ??
                  adaptiveModalFooterVerticalPadding,
              compact: true,
            ),
          ),
        ),
      );
}

class _AdaptiveModalCard extends StatelessWidget {
  const _AdaptiveModalCard({
    required this.title,
    required this.content,
    required this.onClose,
    required this.actions,
    this.scrollController,
    this.contentPaddingBottom = adaptiveModalContentPadding,
    this.footerPaddingBottom = adaptiveModalFooterVerticalPadding,
    this.compact = false,
  });

  final String title;
  final Widget content;
  final VoidCallback onClose;
  final List<Widget> actions;
  final ScrollController? scrollController;
  final double contentPaddingBottom;
  final double footerPaddingBottom;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = FluentTheme.of(context);
    final paseo = context.paseoPalette;
    return Container(
      key: const ValueKey('adaptive-modal-sheet-card'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: compact ? paseo.surface0 : paseo.surface1,
        borderRadius: compact
            ? const BorderRadius.vertical(top: Radius.circular(16))
            : BorderRadius.circular(12),
        border: Border.all(color: paseo.surface2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (compact)
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                color: palette.resources.textFillColorSecondary,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          _AdaptiveModalHeader(title: title, onClose: onClose),
          Flexible(
            child: SingleChildScrollView(
              key: const ValueKey('adaptive-modal-sheet-scroll'),
              controller: scrollController,
              padding: EdgeInsets.fromLTRB(
                adaptiveModalContentPadding,
                adaptiveModalContentPadding,
                adaptiveModalContentPadding,
                contentPaddingBottom,
              ),
              child: content,
            ),
          ),
          if (actions.isNotEmpty)
            _AdaptiveModalFooter(
              actions: actions,
              paddingBottom: footerPaddingBottom,
            ),
        ],
      ),
    );
  }
}

class _AdaptiveModalHeader extends StatelessWidget {
  const _AdaptiveModalHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: adaptiveModalHorizontalPadding,
        vertical: 16,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.surface2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.foreground,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('adaptive-modal-sheet-close'),
            onPressed: onClose,
            icon: Icon(
              FluentIcons.chrome_close,
              size: 16,
              color: palette.foregroundMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdaptiveModalFooter extends StatelessWidget {
  const _AdaptiveModalFooter({
    required this.actions,
    required this.paddingBottom,
  });

  final List<Widget> actions;
  final double paddingBottom;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    return Container(
      padding: EdgeInsets.fromLTRB(
        adaptiveModalHorizontalPadding,
        adaptiveModalFooterVerticalPadding,
        adaptiveModalHorizontalPadding,
        paddingBottom,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.surface2)),
      ),
      child: Row(
        children: [
          for (var index = 0; index < actions.length; index++) ...[
            if (index > 0) const SizedBox(width: 12),
            Expanded(child: actions[index]),
          ],
        ],
      ),
    );
  }
}
