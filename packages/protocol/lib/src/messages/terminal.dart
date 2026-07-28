/// Terminal session messages.
library;

import '../terminal/terminal_activity.dart';

final class TerminalInfo {
  const TerminalInfo({
    required this.terminalId,
    required this.cwd,
    required this.shell,
    this.workspaceId,
    this.activity,
  });

  final String terminalId;
  final String cwd;
  final String shell;
  final String? workspaceId;
  final TerminalActivity? activity;

  static TerminalInfo fromJson(Map<String, Object?> json) => TerminalInfo(
    terminalId: json['terminalId'] as String,
    cwd: (json['cwd'] as String?) ?? '',
    shell: (json['shell'] as String?) ?? '',
    workspaceId: json['workspaceId'] as String?,
    activity: switch (json['activity']) {
      Map<String, Object?> value => TerminalActivity.fromJson(value),
      Map value => TerminalActivity.fromJson(value.cast<String, Object?>()),
      _ => null,
    },
  );

  Map<String, Object?> toJson() => {
    'terminalId': terminalId,
    'cwd': cwd,
    'shell': shell,
    if (workspaceId != null) 'workspaceId': workspaceId,
    'activity': activity?.toJson(),
  };
}

final class TerminalAttentionRequired {
  const TerminalAttentionRequired({
    required this.terminalId,
    required this.cwd,
    required this.reason,
    required this.title,
    required this.body,
    required this.shouldNotify,
    this.serverId,
    this.workspaceId,
  });

  final String? serverId;
  final String terminalId;
  final String cwd;
  final String? workspaceId;
  final TerminalActivityAttentionReason reason;
  final String title;
  final String body;
  final bool shouldNotify;

  factory TerminalAttentionRequired.fromJson(Map<String, Object?> json) {
    if (json['type'] != 'terminal_attention_required') {
      throw const FormatException('wrong terminal attention message type');
    }
    final payload = json['payload'];
    if (payload is! Map) {
      throw const FormatException('terminal attention payload is required');
    }
    final values = payload.cast<String, Object?>();
    final reason = TerminalActivityAttentionReason.fromWire(values['reason']);
    if (reason == null) {
      throw const FormatException('unknown terminal attention reason');
    }
    return TerminalAttentionRequired(
      serverId: values['serverId'] as String?,
      terminalId: values['terminalId'] as String,
      cwd: values['cwd'] as String,
      workspaceId: values['workspaceId'] as String?,
      reason: reason,
      title: values['title'] as String,
      body: values['body'] as String,
      shouldNotify: values['shouldNotify'] as bool,
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'terminal_attention_required',
    'payload': {
      if (serverId != null) 'serverId': serverId,
      'terminalId': terminalId,
      'cwd': cwd,
      if (workspaceId != null) 'workspaceId': workspaceId,
      'reason': reason.wireValue,
      'title': title,
      'body': body,
      'shouldNotify': shouldNotify,
    },
  };
}
