import '../provider_icon_names.dart';

final class TerminalProfile {
  const TerminalProfile({
    required this.id,
    required this.name,
    required this.command,
    this.args,
    this.icon,
    this.extra = const {},
  });

  final String id;
  final String name;
  final String command;
  final List<String>? args;
  final String? icon;
  final Map<String, Object?> extra;

  factory TerminalProfile.fromJson(Map<String, Object?> json) {
    final args = json['args'];
    if (args != null &&
        (args is! List || args.any((argument) => argument is! String))) {
      throw const FormatException('terminal profile args must be strings');
    }
    final id = json['id'];
    final name = json['name'];
    final command = json['command'];
    final icon = json['icon'];
    if (id is! String || name is! String || command is! String) {
      throw const FormatException(
        'terminal profile id, name, and command must be strings',
      );
    }
    if (icon != null && icon is! String) {
      throw const FormatException('terminal profile icon must be a string');
    }
    return TerminalProfile(
      id: id,
      name: name,
      command: command,
      args: args == null
          ? null
          : List.unmodifiable((args as List).cast<String>()),
      icon: icon as String?,
      extra: Map.unmodifiable({
        for (final entry in json.entries)
          if (!const {
            'id',
            'name',
            'command',
            'args',
            'icon',
          }.contains(entry.key))
            entry.key: entry.value,
      }),
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'id': id,
    'name': name,
    'command': command,
    if (args != null) 'args': args,
    if (icon != null) 'icon': icon,
  };
}

const defaultTerminalProfiles = <TerminalProfile>[
  TerminalProfile(
    id: 'claude',
    name: 'Claude Code',
    command: 'claude',
    icon: 'claude',
  ),
  TerminalProfile(id: 'codex', name: 'Codex', command: 'codex', icon: 'codex'),
  TerminalProfile(
    id: 'opencode',
    name: 'OpenCode',
    command: 'opencode',
    icon: 'opencode',
  ),
];

String? guessTerminalProfileIcon(String command) {
  final lastSlash = command.lastIndexOf('/');
  final lastBackslash = command.lastIndexOf(r'\');
  final start = (lastSlash > lastBackslash ? lastSlash : lastBackslash) + 1;
  final base = command.substring(start).toLowerCase();
  final dot = base.indexOf('.');
  final name = dot > 0 ? base.substring(0, dot) : base;
  return knownProviderIconNames.contains(name) ? name : null;
}

String? getTerminalProfileIcon(TerminalProfile profile) =>
    profile.icon ?? guessTerminalProfileIcon(profile.command);

List<TerminalProfile> resolveTerminalProfiles(
  List<TerminalProfile>? terminalProfiles,
) => terminalProfiles ?? defaultTerminalProfiles;

String terminalSubscriptionKey(String cwd, String? workspaceId) =>
    workspaceId == null ? cwd : '$workspaceId::$cwd';
