import 'package:agent_protocol/agent_protocol.dart';

const _shellFileCommands = {
  'cat',
  'bat',
  'less',
  'more',
  'head',
  'tail',
  'wc',
  'nl',
  'tac',
  'od',
  'xxd',
  'file',
  'stat',
  'column',
  'md5',
  'md5sum',
  'sha1sum',
  'sha256sum',
  'shasum',
};
final _shellOperatorPattern = RegExp(r'[|><&;`$()]');
final _shortFlagPattern = RegExp(r'^-[a-zA-Z]$');

String? extractToolCallFilePath(ToolCallDetail? detail) => switch (detail) {
  ReadDetail(:final path) ||
  EditDetail(path: final path) ||
  WriteDetail(path: final path) => path.isEmpty ? null : path,
  ShellDetail(:final command) => _extractFromShellCommand(command),
  _ => null,
};

String? _extractFromShellCommand(String command) {
  final trimmed = command.trim();
  if (trimmed.isEmpty || _shellOperatorPattern.hasMatch(trimmed)) return null;
  final tokens = trimmed.split(RegExp(r'\s+'));
  if (tokens.length < 2 || !_shellFileCommands.contains(tokens.first)) {
    return null;
  }
  final last = tokens.last;
  if (last.startsWith('-')) return null;
  if (tokens.length > 2) {
    final previous = tokens[tokens.length - 2];
    if (!previous.startsWith('-')) {
      final beforePrevious = tokens.length >= 3
          ? tokens[tokens.length - 3]
          : null;
      if (beforePrevious == null ||
          !_shortFlagPattern.hasMatch(beforePrevious)) {
        return null;
      }
    }
  }
  return last;
}
