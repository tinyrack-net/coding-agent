import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';

/// Semantic icon names from Paseo's frozen tool-call presentation contract.
///
/// [tinyrack] replaces the upstream Paseo logo while preserving the internal
/// wire-name recognition required for protocol compatibility.
enum ToolCallIconName {
  wrench('wrench'),
  squareTerminal('square_terminal'),
  eye('eye'),
  pencil('pencil'),
  search('search'),
  bot('bot'),
  sparkles('sparkles'),
  brain('brain'),
  micVocal('mic_vocal'),
  tinyrack('tinyrack');

  const ToolCallIconName(this.wireName);

  final String wireName;

  static ToolCallIconName? fromWireName(String? value) {
    if (value == null) return null;
    for (final icon in values) {
      if (icon.wireName == value) return icon;
    }
    return null;
  }
}

ToolCallIconName resolveToolCallIconName(
  String toolName,
  ToolCallDetail? detail,
) {
  final lowerName = toolName.trim().toLowerCase();

  if (detail case PlainTextDetail(:final icon)) {
    final customIcon = ToolCallIconName.fromWireName(icon);
    if (customIcon != null && customIcon != ToolCallIconName.tinyrack) {
      return customIcon;
    }
  }

  if (lowerName == 'thinking' && (detail == null || detail is GenericDetail)) {
    return ToolCallIconName.brain;
  }
  if (lowerName == 'speak') return ToolCallIconName.micVocal;
  if (isPaseoToolName(lowerName)) return ToolCallIconName.tinyrack;
  if (lowerName == 'task') return ToolCallIconName.bot;

  return switch (detail) {
    ShellDetail() ||
    WorktreeSetupToolDetail() => ToolCallIconName.squareTerminal,
    ReadDetail() => ToolCallIconName.eye,
    EditDetail() || WriteDetail() => ToolCallIconName.pencil,
    SearchDetail() || FetchDetail() => ToolCallIconName.search,
    SubAgentDetail() => ToolCallIconName.bot,
    PlanDetail() => ToolCallIconName.brain,
    PlainTextDetail() || GenericDetail() || null => ToolCallIconName.wrench,
  };
}

IconData? iconDataForToolCallIcon(ToolCallIconName name) => switch (name) {
  ToolCallIconName.wrench => FluentIcons.build,
  ToolCallIconName.squareTerminal => FluentIcons.command_prompt,
  ToolCallIconName.eye => FluentIcons.view,
  ToolCallIconName.pencil => FluentIcons.edit,
  ToolCallIconName.search => FluentIcons.search,
  ToolCallIconName.bot => FluentIcons.robot,
  ToolCallIconName.sparkles => FluentIcons.starburst,
  ToolCallIconName.brain => FluentIcons.processing,
  ToolCallIconName.micVocal => FluentIcons.microphone,
  ToolCallIconName.tinyrack => null,
};

final class ToolCallIconView extends StatelessWidget {
  const ToolCallIconView({
    required this.name,
    this.size = 20,
    this.color,
    super.key,
  });

  final ToolCallIconName name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final icon = iconDataForToolCallIcon(name);
    if (icon != null) return Icon(icon, size: size, color: color);
    return Image.asset(
      'assets/tray/tray_icon.png',
      width: size,
      height: size,
      color: color,
      semanticLabel: 'Tinyrack',
      filterQuality: FilterQuality.medium,
    );
  }
}
