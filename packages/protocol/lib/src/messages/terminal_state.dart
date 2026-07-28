/// Paseo 0.2.0 terminal snapshot and subscription contracts.
library;

final class TerminalCell {
  const TerminalCell({
    required this.char,
    this.fg,
    this.bg,
    this.fgMode,
    this.bgMode,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.dim = false,
    this.inverse = false,
    this.strikethrough = false,
  });

  final String char;
  final int? fg;
  final int? bg;
  final int? fgMode;
  final int? bgMode;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool dim;
  final bool inverse;
  final bool strikethrough;

  factory TerminalCell.fromJson(Map<String, Object?> json) => TerminalCell(
    char: _string(json, 'char'),
    fg: _optionalInt(json, 'fg'),
    bg: _optionalInt(json, 'bg'),
    fgMode: _optionalInt(json, 'fgMode'),
    bgMode: _optionalInt(json, 'bgMode'),
    bold: _optionalBool(json, 'bold'),
    italic: _optionalBool(json, 'italic'),
    underline: _optionalBool(json, 'underline'),
    dim: _optionalBool(json, 'dim'),
    inverse: _optionalBool(json, 'inverse'),
    strikethrough: _optionalBool(json, 'strikethrough'),
  );

  Map<String, Object?> toJson() => {
    'char': char,
    if (fg != null) 'fg': fg,
    if (bg != null) 'bg': bg,
    if (fgMode != null) 'fgMode': fgMode,
    if (bgMode != null) 'bgMode': bgMode,
    'bold': bold,
    'italic': italic,
    'underline': underline,
    'dim': dim,
    'inverse': inverse,
    'strikethrough': strikethrough,
  };
}

enum TerminalCursorStyle {
  block,
  underline,
  bar;

  static TerminalCursorStyle fromWire(Object? value) => switch (value) {
    'block' => block,
    'underline' => underline,
    'bar' => bar,
    _ => throw const FormatException('invalid terminal cursor style'),
  };
}

final class TerminalCursor {
  const TerminalCursor({
    required this.row,
    required this.col,
    this.hidden,
    this.style,
    this.blink,
  });

  final int row;
  final int col;
  final bool? hidden;
  final TerminalCursorStyle? style;
  final bool? blink;

  factory TerminalCursor.fromJson(Map<String, Object?> json) => TerminalCursor(
    row: _int(json, 'row'),
    col: _int(json, 'col'),
    hidden: _nullableBool(json, 'hidden'),
    style: json['style'] == null
        ? null
        : TerminalCursorStyle.fromWire(json['style']),
    blink: _nullableBool(json, 'blink'),
  );

  Map<String, Object?> toJson() => {
    'row': row,
    'col': col,
    if (hidden != null) 'hidden': hidden,
    if (style != null) 'style': style!.name,
    if (blink != null) 'blink': blink,
  };
}

final class TerminalState {
  const TerminalState({
    required this.rows,
    required this.cols,
    required this.grid,
    required this.scrollback,
    required this.cursor,
    this.title,
    this.gridWrapped,
    this.scrollbackWrapped,
  });

  final int rows;
  final int cols;
  final List<List<TerminalCell>> grid;
  final List<List<TerminalCell>> scrollback;
  final TerminalCursor cursor;
  final String? title;
  final List<bool>? gridWrapped;
  final List<bool>? scrollbackWrapped;

  factory TerminalState.fromJson(Map<String, Object?> json) => TerminalState(
    rows: _int(json, 'rows'),
    cols: _int(json, 'cols'),
    grid: _cellRows(json, 'grid'),
    scrollback: _cellRows(json, 'scrollback'),
    cursor: switch (json['cursor']) {
      Map value => TerminalCursor.fromJson(value.cast<String, Object?>()),
      _ => throw const FormatException('cursor must be an object'),
    },
    title: _optionalString(json, 'title'),
    gridWrapped: _optionalBoolList(json, 'gridWrapped'),
    scrollbackWrapped: _optionalBoolList(json, 'scrollbackWrapped'),
  );

  Map<String, Object?> toJson() => {
    'rows': rows,
    'cols': cols,
    'grid': [
      for (final row in grid) [for (final cell in row) cell.toJson()],
    ],
    'scrollback': [
      for (final row in scrollback) [for (final cell in row) cell.toJson()],
    ],
    'cursor': cursor.toJson(),
    if (title != null) 'title': title,
    if (gridWrapped != null) 'gridWrapped': gridWrapped,
    if (scrollbackWrapped != null) 'scrollbackWrapped': scrollbackWrapped,
  };
}

enum TerminalRestoreMode {
  live('live'),
  visibleSnapshot('visible-snapshot'),
  fullSnapshot('full-snapshot');

  const TerminalRestoreMode(this.wire);
  final String wire;

  static TerminalRestoreMode fromWire(Object? value) => switch (value) {
    'live' => live,
    'visible-snapshot' => visibleSnapshot,
    'full-snapshot' => fullSnapshot,
    _ => throw const FormatException('invalid terminal restore mode'),
  };
}

final class TerminalRestoreOptions {
  const TerminalRestoreOptions({
    required this.mode,
    this.scrollbackLines,
    this.size,
  });

  final TerminalRestoreMode mode;
  final int? scrollbackLines;
  final ({int rows, int cols})? size;

  factory TerminalRestoreOptions.fromJson(Map<String, Object?> json) {
    final scrollbackLines = _optionalInt(json, 'scrollbackLines');
    if (scrollbackLines != null && scrollbackLines < 0) {
      throw const FormatException('scrollbackLines must be non-negative');
    }
    final size = json['size'];
    if (size != null && size is! Map) {
      throw const FormatException('size must be an object');
    }
    final parsedSize = size is Map ? size.cast<String, Object?>() : null;
    final rows = parsedSize == null ? null : _int(parsedSize, 'rows');
    final cols = parsedSize == null ? null : _int(parsedSize, 'cols');
    if ((rows != null && rows <= 0) || (cols != null && cols <= 0)) {
      throw const FormatException('terminal size must be positive');
    }
    return TerminalRestoreOptions(
      mode: TerminalRestoreMode.fromWire(json['mode']),
      scrollbackLines: scrollbackLines,
      size: rows == null || cols == null ? null : (rows: rows, cols: cols),
    );
  }

  Map<String, Object?> toJson() => {
    'mode': mode.wire,
    if (scrollbackLines != null) 'scrollbackLines': scrollbackLines,
    if (size != null) 'size': {'rows': size!.rows, 'cols': size!.cols},
  };
}

final class SubscribeTerminalRequest {
  const SubscribeTerminalRequest({
    required this.terminalId,
    required this.requestId,
    this.restore,
  });

  static const type = 'subscribe_terminal_request';
  final String terminalId;
  final String requestId;
  final TerminalRestoreOptions? restore;

  factory SubscribeTerminalRequest.fromJson(Map<String, Object?> json) {
    _type(json, type);
    final restore = json['restore'];
    if (restore != null && restore is! Map) {
      throw const FormatException('restore must be an object');
    }
    return SubscribeTerminalRequest(
      terminalId: _string(json, 'terminalId'),
      requestId: _string(json, 'requestId'),
      restore: restore is Map
          ? TerminalRestoreOptions.fromJson(restore.cast<String, Object?>())
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'terminalId': terminalId,
    'requestId': requestId,
    if (restore != null) 'restore': restore!.toJson(),
  };
}

final class UnsubscribeTerminalRequest {
  const UnsubscribeTerminalRequest({required this.terminalId});

  static const type = 'unsubscribe_terminal_request';
  final String terminalId;

  factory UnsubscribeTerminalRequest.fromJson(Map<String, Object?> json) {
    _type(json, type);
    return UnsubscribeTerminalRequest(terminalId: _string(json, 'terminalId'));
  }

  Map<String, Object?> toJson() => {'type': type, 'terminalId': terminalId};
}

final class TerminalStreamExit {
  const TerminalStreamExit({required this.terminalId});

  static const type = 'terminal_stream_exit';
  final String terminalId;

  factory TerminalStreamExit.fromJson(Map<String, Object?> json) {
    _type(json, type);
    final payload = json['payload'];
    if (payload is! Map) {
      throw const FormatException('payload must be an object');
    }
    return TerminalStreamExit(
      terminalId: _string(payload.cast<String, Object?>(), 'terminalId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'terminalId': terminalId},
  };
}

final class SubscribeTerminalsRequest {
  const SubscribeTerminalsRequest({required this.cwd, this.workspaceId});

  static const type = 'subscribe_terminals_request';
  final String cwd;
  final String? workspaceId;

  factory SubscribeTerminalsRequest.fromJson(Map<String, Object?> json) {
    _type(json, type);
    return SubscribeTerminalsRequest(
      cwd: _string(json, 'cwd'),
      workspaceId: _optionalString(json, 'workspaceId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    if (workspaceId != null) 'workspaceId': workspaceId,
  };
}

final class UnsubscribeTerminalsRequest {
  const UnsubscribeTerminalsRequest({required this.cwd, this.workspaceId});

  static const type = 'unsubscribe_terminals_request';
  final String cwd;
  final String? workspaceId;

  factory UnsubscribeTerminalsRequest.fromJson(Map<String, Object?> json) {
    _type(json, type);
    return UnsubscribeTerminalsRequest(
      cwd: _string(json, 'cwd'),
      workspaceId: _optionalString(json, 'workspaceId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    if (workspaceId != null) 'workspaceId': workspaceId,
  };
}

List<List<TerminalCell>> _cellRows(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! List) throw FormatException('$field must be an array');
  return [
    for (final row in value)
      if (row is List)
        [
          for (final cell in row)
            if (cell is Map)
              TerminalCell.fromJson(cell.cast<String, Object?>())
            else
              throw FormatException('$field cells must be objects'),
        ]
      else
        throw FormatException('$field rows must be arrays'),
  ];
}

List<bool>? _optionalBoolList(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! List || value.any((element) => element is! bool)) {
    throw FormatException('$field must be a boolean array');
  }
  return List<bool>.from(value);
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

bool _optionalBool(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return false;
  if (value is! bool) throw FormatException('$field must be a boolean');
  return value;
}

bool? _nullableBool(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$field must be a boolean');
  return value;
}
