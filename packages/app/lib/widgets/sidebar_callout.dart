import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';
import '../state/sidebar_callout_state.dart';

class SidebarCallout extends StatelessWidget {
  const SidebarCallout({
    super.key,
    this.title,
    this.description,
    this.icon,
    this.variant = SidebarCalloutVariant.defaultVariant,
    this.actions = const [],
    this.onDismiss,
    this.testId,
  }) : assert(
         description == null || description is String || description is Widget,
       );

  final String? title;
  final Object? description;
  final Widget? icon;
  final SidebarCalloutVariant variant;
  final List<SidebarCalloutAction> actions;
  final VoidCallback? onDismiss;
  final String? testId;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    final visibleActions = actions.take(2).toList(growable: false);
    final hasHeader = title != null || icon != null;
    final hasDescription = description != null && description != '';
    final body = <Widget>[];
    final dismissRenderKey = onDismiss == null ? null : GlobalKey();

    if (hasHeader || onDismiss != null) {
      body.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasHeader)
              Expanded(
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Center(child: icon),
                      const SizedBox(width: 8),
                    ],
                    if (title != null)
                      Flexible(
                        child: Text(
                          title!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.foreground,
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (hasHeader && onDismiss != null) const SizedBox(width: 8),
            if (onDismiss != null)
              KeyedSubtree(
                key: testId == null ? null : ValueKey('$testId-dismiss'),
                child: _DismissButton(
                  key: dismissRenderKey,
                  onPressed: onDismiss!,
                ),
              ),
          ],
        ),
      );
    }

    if (hasDescription) {
      if (body.isNotEmpty) body.add(const SizedBox(height: 8));
      body.add(
        description is String
            ? Text(
                description! as String,
                style: TextStyle(color: palette.foregroundMuted, fontSize: 12),
              )
            : description! as Widget,
      );
    }

    if (visibleActions.isNotEmpty) {
      if (body.isNotEmpty) body.add(const SizedBox(height: 8));
      body.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            key: testId == null ? null : ValueKey('$testId-actions'),
            children: [
              for (var index = 0; index < visibleActions.length; index++) ...[
                if (index > 0) const SizedBox(width: 8),
                Expanded(
                  child: _SidebarCalloutActionButton(
                    key: ValueKey(
                      visibleActions[index].testId ??
                          (testId == null
                              ? 'sidebar-callout-action-$index'
                              : '$testId-action-$index'),
                    ),
                    action: visibleActions[index],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final borderColor = variant == SidebarCalloutVariant.error
        ? context.statusColors.danger
        : palette.border;
    final callout = Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: testId == null ? null : ValueKey(testId!),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: borderColor)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: body,
        ),
      ),
    );
    if (onDismiss == null) return callout;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (details) {
        final renderBox =
            dismissRenderKey?.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox == null) return;
        final bounds = renderBox.localToGlobal(Offset.zero) & renderBox.size;
        if (bounds.inflate(8).contains(details.globalPosition)) onDismiss!();
      },
      child: callout,
    );
  }
}

class SidebarCalloutDescriptionText extends StatelessWidget {
  const SidebarCalloutDescriptionText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(color: context.paseoPalette.foregroundMuted, fontSize: 12),
  );
}

class _DismissButton extends StatelessWidget {
  const _DismissButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Dismiss',
    child: HoverButton(
      onPressed: onPressed,
      builder: (context, states) => SizedBox.square(
        dimension: 14,
        child: Icon(
          FluentIcons.chrome_close,
          size: 14,
          color: states.contains(WidgetState.hovered)
              ? context.paseoPalette.foreground
              : context.paseoPalette.foregroundMuted,
        ),
      ),
    ),
  );
}

class _SidebarCalloutActionButton extends StatelessWidget {
  const _SidebarCalloutActionButton({super.key, required this.action});

  final SidebarCalloutAction action;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    final primary = action.variant == SidebarCalloutActionVariant.primary;
    return Semantics(
      button: true,
      enabled: !action.disabled,
      child: HoverButton(
        onPressed: action.disabled ? null : action.onPressed,
        builder: (context, states) {
          final pressed = states.contains(WidgetState.pressed);
          return Opacity(
            opacity: action.disabled ? 0.5 : (pressed ? 0.8 : 1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: primary ? palette.foreground : Colors.transparent,
                border: Border.all(
                  color: primary ? palette.foreground : palette.border,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                action.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: primary ? palette.surface0 : palette.foreground,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
