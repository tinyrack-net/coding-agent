import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../core/theme.dart';
import 'host_picker.dart';

class HostFilter extends StatelessWidget {
  const HostFilter({
    super.key,
    required this.hosts,
    required this.selectedHost,
    required this.onSelectHost,
    this.localServerId,
    this.triggerKey,
  });

  final List<HostProfile> hosts;
  final String selectedHost;
  final ValueChanged<String> onSelectHost;
  final String? localServerId;
  final Key? triggerKey;

  @override
  Widget build(BuildContext context) {
    final label = getHostPickerLabel(hosts, selectedHost, includeAllHost: true);
    return HostPicker(
      hosts: hosts,
      value: selectedHost,
      onSelect: onSelectHost,
      localServerId: localServerId,
      includeAllHost: true,
      title: 'Filter by host',
      triggerKey: triggerKey,
      triggerBuilder: (context, onOpen, open) => Semantics(
        button: true,
        label: 'Filter: $label',
        excludeSemantics: true,
        onTap: onOpen,
        child: HoverButton(
          onPressed: onOpen,
          builder: (context, states) {
            final palette = context.paseoPalette;
            final hovered = states.contains(WidgetState.hovered);
            final pressed = states.contains(WidgetState.pressed);
            return Container(
              key: triggerKey,
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: pressed
                    ? palette.surface3
                    : hovered
                    ? palette.surface2
                    : palette.surface1,
                border: Border.all(color: palette.border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selectedHost == allHostsOptionId)
                    SizedBox.square(
                      dimension: 16,
                      child: Icon(
                        FluentIcons.server,
                        size: 14,
                        color: palette.foregroundMuted,
                      ),
                    )
                  else
                    HostStatusDotSlot(serverId: selectedHost),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.foreground,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    FluentIcons.chevron_down,
                    size: 14,
                    color: palette.foregroundMuted,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
