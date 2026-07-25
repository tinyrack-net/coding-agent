/// Terminal session messages.
library;

final class TerminalInfo {
  const TerminalInfo({
    required this.terminalId,
    required this.cwd,
    required this.shell,
  });

  final String terminalId;
  final String cwd;
  final String shell;

  static TerminalInfo fromJson(Map<String, Object?> json) => TerminalInfo(
        terminalId: json['terminalId'] as String,
        cwd: (json['cwd'] as String?) ?? '',
        shell: (json['shell'] as String?) ?? '',
      );

  Map<String, Object?> toJson() =>
      {'terminalId': terminalId, 'cwd': cwd, 'shell': shell};
}
