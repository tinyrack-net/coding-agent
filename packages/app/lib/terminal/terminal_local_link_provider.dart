/*
 * Adapted from MIT-licensed upstream terminal link provider behavior.
 * Copyright (c) Microsoft Corporation.
 */

import 'dart:async';

import 'package:xterm/xterm.dart';

import 'terminal_local_link_parsing.dart';

const terminalLocalLinkMaxLineLength = 2000;
const terminalLocalLinkMaxLength = 500;
const terminalLocalLinkMaxResolvedPerLine = 10;

final class TerminalLocalFileLinkSource {
  const TerminalLocalFileLinkSource({
    required this.text,
    required this.path,
    this.lineStart,
    this.lineEnd,
  });

  final String text;
  final String path;
  final int? lineStart;
  final int? lineEnd;
}

final class TerminalLocalFileLinkTarget {
  const TerminalLocalFileLinkTarget({
    required this.path,
    this.lineStart,
    this.lineEnd,
  });

  final String path;
  final int? lineStart;
  final int? lineEnd;
}

final class TerminalBufferPoint {
  const TerminalBufferPoint({required this.x, required this.y});

  /// One-based terminal cell coordinate, matching xterm.js link ranges.
  final int x;
  final int y;
}

final class TerminalBufferRange {
  const TerminalBufferRange({required this.start, required this.end});

  final TerminalBufferPoint start;
  final TerminalBufferPoint end;

  bool containsCell({required int x, required int y}) {
    final oneBasedX = x + 1;
    final oneBasedY = y + 1;
    if (oneBasedY < start.y || oneBasedY > end.y) return false;
    if (start.y == end.y) {
      return oneBasedX >= start.x && oneBasedX <= end.x;
    }
    if (oneBasedY == start.y) return oneBasedX >= start.x;
    if (oneBasedY == end.y) return oneBasedX <= end.x;
    return true;
  }
}

final class TerminalLocalFileLink {
  const TerminalLocalFileLink({
    required this.range,
    required this.source,
    required this.target,
  });

  final TerminalBufferRange range;
  final TerminalLocalFileLinkSource source;
  final TerminalLocalFileLinkTarget target;
}

typedef TerminalLocalLinkResolver =
    Future<TerminalLocalFileLinkTarget?> Function(
      TerminalLocalFileLinkSource source,
    );

/// Resolves candidates before exposing them, coalescing concurrent requests
/// for the same buffer line exactly like Paseo's xterm.js link provider.
final class TerminalLocalFileLinkProvider {
  TerminalLocalFileLinkProvider(this.terminal, {required this.resolveLink});

  final Terminal terminal;
  final TerminalLocalLinkResolver resolveLink;
  final Map<int, Future<List<TerminalLocalFileLink>>> _activeRequests = {};

  Future<List<TerminalLocalFileLink>> provideLinks(int bufferLineNumber) async {
    final active = _activeRequests[bufferLineNumber];
    if (active != null) return active;
    final request = _provideLinksForLine(bufferLineNumber);
    _activeRequests[bufferLineNumber] = request;
    try {
      return await request;
    } finally {
      _activeRequests.remove(bufferLineNumber);
    }
  }

  Future<TerminalLocalFileLink?> linkAtCell({
    required int x,
    required int y,
  }) async {
    final links = await provideLinks(y + 1);
    for (final link in links) {
      if (link.range.containsCell(x: x, y: y)) return link;
    }
    return null;
  }

  Future<List<TerminalLocalFileLink>> _provideLinksForLine(
    int bufferLineNumber,
  ) async {
    final windowed = _getWindowedLineContent(terminal, bufferLineNumber - 1);
    if (windowed == null ||
        windowed.text.isEmpty ||
        windowed.text.length > terminalLocalLinkMaxLineLength) {
      return const [];
    }

    final links = <TerminalLocalFileLink>[];
    for (final parsed in detectTerminalLocalLinks(windowed.text)) {
      if (parsed.path.text.length > terminalLocalLinkMaxLength) continue;
      final source = _toLinkSource(windowed.text, parsed);
      if (source == null) continue;
      final target = await resolveLink(source);
      if (target == null) continue;
      final range = _toBufferRange(
        terminal: terminal,
        startLine: windowed.startLine,
        startIndex: parsed.prefix?.index ?? parsed.path.index,
        endIndex: _getParsedLinkEndIndex(parsed),
      );
      if (range == null) continue;
      links.add(
        TerminalLocalFileLink(range: range, source: source, target: target),
      );
      if (links.length >= terminalLocalLinkMaxResolvedPerLine) break;
    }
    return links;
  }
}

TerminalLocalFileLinkSource? _toLinkSource(
  String lineText,
  TerminalParsedLink parsed,
) {
  final path = parsed.path.text.replaceFirst(RegExp(r'''[\]\[["'.]+$'''), '');
  if (path.isEmpty || path.length != parsed.path.text.length) return null;
  final lineStart = parsed.suffix?.row;
  final lineEnd = parsed.suffix?.rowEnd;
  var text = path;
  if (lineStart != null && lineStart > 0) {
    text = '$text:$lineStart';
    final col = parsed.suffix?.col;
    if (col != null && col > 0) text = '$text:$col';
    if (lineEnd != null && lineEnd > 0) {
      text = '$text-$lineEnd';
      final colEnd = parsed.suffix?.colEnd;
      if (colEnd != null && colEnd > 0) text = '$text:$colEnd';
    }
  }
  final rawText = lineText.substring(
    parsed.prefix?.index ?? parsed.path.index,
    _getParsedLinkEndIndex(parsed),
  );
  if (rawText.trim().isEmpty) return null;
  return TerminalLocalFileLinkSource(
    text: text,
    path: path,
    lineStart: lineStart,
    lineEnd: lineEnd != null && lineStart != null && lineEnd >= lineStart
        ? lineEnd
        : null,
  );
}

int _getParsedLinkEndIndex(TerminalParsedLink parsed) => parsed.suffix == null
    ? parsed.path.index + parsed.path.text.length
    : parsed.suffix!.suffix.index + parsed.suffix!.suffix.text.length;

final class _WindowedLine {
  const _WindowedLine({required this.text, required this.startLine});

  final String text;
  final int startLine;
}

_WindowedLine? _getWindowedLineContent(Terminal terminal, int requestedLine) {
  final lines = terminal.buffer.lines;
  if (requestedLine < 0 || requestedLine >= lines.length) return null;
  var startLine = requestedLine;
  var endLine = requestedLine;
  var contextLength = 0;
  while (startLine > 0 &&
      lines[startLine].isWrapped &&
      contextLength < terminalLocalLinkMaxLength) {
    startLine -= 1;
    contextLength += lines[startLine].getText().trimRight().length;
  }

  final parts = <String>[];
  for (var y = startLine; y <= endLine; y += 1) {
    parts.add(lines[y].getText().trimRight());
  }
  contextLength = 0;
  while (endLine + 1 < lines.length &&
      lines[endLine + 1].isWrapped &&
      contextLength < terminalLocalLinkMaxLength) {
    endLine += 1;
    final next = lines[endLine].getText().trimRight();
    contextLength += next.length;
    parts.add(next);
  }
  return _WindowedLine(text: parts.join(), startLine: startLine);
}

TerminalBufferRange? _toBufferRange({
  required Terminal terminal,
  required int startLine,
  required int startIndex,
  required int endIndex,
}) {
  final start = _mapStringOffsetToBuffer(terminal, startLine, startIndex);
  final end = _mapStringOffsetToBuffer(terminal, startLine, endIndex);
  if (start == null || end == null) return null;
  return TerminalBufferRange(
    start: TerminalBufferPoint(x: start.x + 1, y: start.y + 1),
    end: TerminalBufferPoint(x: end.x, y: end.y + 1),
  );
}

({int x, int y})? _mapStringOffsetToBuffer(
  Terminal terminal,
  int startLine,
  int offset,
) {
  final lines = terminal.buffer.lines;
  var y = startLine;
  var remaining = offset;
  while (true) {
    if (y < 0 || y >= lines.length) return null;
    final line = lines[y];
    for (var column = 0; column < line.length; column += 1) {
      if (remaining <= 0) return (x: column, y: y);
      final codePoint = line.getCodePoint(column);
      final width = line.getWidth(column);
      if (width != 0) {
        final chars = codePoint == 0 ? '' : String.fromCharCode(codePoint);
        remaining -= chars.isEmpty ? 1 : chars.length;
        if (column == line.length - 1 &&
            chars.isEmpty &&
            y + 1 < lines.length &&
            lines[y + 1].isWrapped &&
            lines[y + 1].getWidth(0) == 2) {
          remaining += 1;
        }
      }
      if (remaining <= 0) return (x: column + width, y: y);
    }
    if (remaining <= 0) return (x: line.length, y: y);
    y += 1;
  }
}
