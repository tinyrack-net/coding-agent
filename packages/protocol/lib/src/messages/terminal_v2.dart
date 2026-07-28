/// Paseo 0.2.0 compatible terminal session messages.
library;

import '../terminal/terminal_activity.dart';

final class TerminalSize {
  const TerminalSize({required this.rows, required this.cols});

  final int rows;
  final int cols;

  factory TerminalSize.fromJson(Map<String, Object?> json) {
    final rows = _positiveInt(json, 'rows');
    final cols = _positiveInt(json, 'cols');
    return TerminalSize(rows: rows, cols: cols);
  }

  Map<String, Object?> toJson() => {'rows': rows, 'cols': cols};
}

final class PaseoTerminalInfo {
  const PaseoTerminalInfo({
    required this.id,
    required this.name,
    required this.cwd,
    this.workspaceId,
    this.title,
    this.activity,
  });

  final String id;
  final String name;
  final String cwd;
  final String? workspaceId;
  final String? title;
  final TerminalActivity? activity;

  factory PaseoTerminalInfo.fromJson(Map<String, Object?> json) =>
      PaseoTerminalInfo(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        cwd: _string(json, 'cwd'),
        workspaceId: _optionalString(json, 'workspaceId'),
        title: _optionalString(json, 'title'),
        activity: switch (json['activity']) {
          Map value => TerminalActivity.fromJson(value.cast<String, Object?>()),
          null => null,
          _ => throw const FormatException('activity must be an object'),
        },
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'cwd': cwd,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (title != null) 'title': title,
    if (activity != null) 'activity': activity!.toJson(),
  };
}

final class ListTerminalsRequest {
  const ListTerminalsRequest({
    required this.requestId,
    this.cwd,
    this.workspaceId,
  });

  static const type = 'list_terminals_request';
  final String requestId;
  final String? cwd;
  final String? workspaceId;

  factory ListTerminalsRequest.fromJson(Map<String, Object?> json) {
    _type(json, type);
    return ListTerminalsRequest(
      requestId: _string(json, 'requestId'),
      cwd: _optionalString(json, 'cwd'),
      workspaceId: _optionalString(json, 'workspaceId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    if (cwd != null) 'cwd': cwd,
    if (workspaceId != null) 'workspaceId': workspaceId,
    'requestId': requestId,
  };
}

final class CreateTerminalRequest {
  const CreateTerminalRequest({
    required this.cwd,
    required this.requestId,
    this.workspaceId,
    this.name,
    this.agentId,
    this.command,
    this.args,
    this.size,
  });

  static const type = 'create_terminal_request';
  final String cwd;
  final String requestId;
  final String? workspaceId;
  final String? name;
  final String? agentId;
  final String? command;
  final List<String>? args;
  final TerminalSize? size;

  factory CreateTerminalRequest.fromJson(Map<String, Object?> json) {
    _type(json, type);
    final rawArgs = json['args'];
    if (rawArgs != null &&
        (rawArgs is! List || rawArgs.any((value) => value is! String))) {
      throw const FormatException('args must be a string array');
    }
    final rawSize = json['size'];
    if (rawSize != null && rawSize is! Map) {
      throw const FormatException('size must be an object');
    }
    return CreateTerminalRequest(
      cwd: _string(json, 'cwd'),
      requestId: _string(json, 'requestId'),
      workspaceId: _optionalString(json, 'workspaceId'),
      name: _optionalString(json, 'name'),
      agentId: _optionalString(json, 'agentId'),
      command: _optionalString(json, 'command'),
      args: rawArgs is List ? List<String>.from(rawArgs) : null,
      size: rawSize is Map
          ? TerminalSize.fromJson(rawSize.cast<String, Object?>())
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (name != null) 'name': name,
    if (agentId != null) 'agentId': agentId,
    if (command != null) 'command': command,
    if (args != null) 'args': args,
    if (size != null) 'size': size!.toJson(),
    'requestId': requestId,
  };
}

final class KillTerminalRequest {
  const KillTerminalRequest({
    required this.terminalId,
    required this.requestId,
  });

  static const type = 'kill_terminal_request';
  final String terminalId;
  final String requestId;

  factory KillTerminalRequest.fromJson(Map<String, Object?> json) {
    _type(json, type);
    return KillTerminalRequest(
      terminalId: _string(json, 'terminalId'),
      requestId: _string(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'terminalId': terminalId,
    'requestId': requestId,
  };
}

final class CaptureTerminalRequest {
  const CaptureTerminalRequest({
    required this.terminalId,
    required this.requestId,
    this.start,
    this.end,
    this.stripAnsi = true,
  });

  static const type = 'capture_terminal_request';
  final String terminalId;
  final String requestId;
  final int? start;
  final int? end;
  final bool stripAnsi;

  factory CaptureTerminalRequest.fromJson(Map<String, Object?> json) {
    _type(json, type);
    return CaptureTerminalRequest(
      terminalId: _string(json, 'terminalId'),
      requestId: _string(json, 'requestId'),
      start: _optionalInt(json, 'start'),
      end: _optionalInt(json, 'end'),
      stripAnsi: switch (json['stripAnsi']) {
        null => true,
        bool value => value,
        _ => throw const FormatException('stripAnsi must be a boolean'),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'terminalId': terminalId,
    if (start != null) 'start': start,
    if (end != null) 'end': end,
    'stripAnsi': stripAnsi,
    'requestId': requestId,
  };
}

sealed class TerminalClientMessage {
  const TerminalClientMessage();

  factory TerminalClientMessage.fromJson(Map<String, Object?> json) =>
      switch (json['type']) {
        'input' => TerminalInputMessage(data: _string(json, 'data')),
        'resize' => TerminalResizeMessage(
          rows: _int(json, 'rows'),
          cols: _int(json, 'cols'),
        ),
        'mouse' => TerminalMouseMessage(
          row: _int(json, 'row'),
          col: _int(json, 'col'),
          button: _int(json, 'button'),
          action: TerminalMouseAction.fromWire(json['action']),
        ),
        _ => throw const FormatException('unknown terminal client message'),
      };

  Map<String, Object?> toJson();
}

final class TerminalInputMessage extends TerminalClientMessage {
  const TerminalInputMessage({required this.data});
  final String data;
  @override
  Map<String, Object?> toJson() => {'type': 'input', 'data': data};
}

final class TerminalResizeMessage extends TerminalClientMessage {
  const TerminalResizeMessage({required this.rows, required this.cols});
  final int rows;
  final int cols;
  @override
  Map<String, Object?> toJson() => {
    'type': 'resize',
    'rows': rows,
    'cols': cols,
  };
}

enum TerminalMouseAction {
  down,
  up,
  move;

  static TerminalMouseAction fromWire(Object? value) => switch (value) {
    'down' => down,
    'up' => up,
    'move' => move,
    _ => throw const FormatException('invalid terminal mouse action'),
  };
}

final class TerminalMouseMessage extends TerminalClientMessage {
  const TerminalMouseMessage({
    required this.row,
    required this.col,
    required this.button,
    required this.action,
  });
  final int row;
  final int col;
  final int button;
  final TerminalMouseAction action;
  @override
  Map<String, Object?> toJson() => {
    'type': 'mouse',
    'row': row,
    'col': col,
    'button': button,
    'action': action.name,
  };
}

final class TerminalInputRequest {
  const TerminalInputRequest({required this.terminalId, required this.message});

  static const type = 'terminal_input';
  final String terminalId;
  final TerminalClientMessage message;

  factory TerminalInputRequest.fromJson(Map<String, Object?> json) {
    _type(json, type);
    final message = json['message'];
    if (message is! Map) {
      throw const FormatException('message must be an object');
    }
    return TerminalInputRequest(
      terminalId: _string(json, 'terminalId'),
      message: TerminalClientMessage.fromJson(message.cast<String, Object?>()),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'terminalId': terminalId,
    'message': message.toJson(),
  };
}

void _type(Map<String, Object?> json, String expected) {
  if (json['type'] != expected) {
    throw FormatException('expected message type $expected');
  }
}

String _string(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

int _int(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int) throw FormatException('$field must be an integer');
  return value;
}

int? _optionalInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! int) throw FormatException('$field must be an integer');
  return value;
}

int _positiveInt(Map<String, Object?> json, String field) {
  final value = _int(json, field);
  if (value <= 0) throw FormatException('$field must be positive');
  return value;
}
