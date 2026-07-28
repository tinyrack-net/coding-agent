import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

final class ClaudeToolResultContent {
  const ClaudeToolResultContent({
    required this.textContent,
    required this.imageMarkdown,
  });

  final Object? textContent;
  final List<String> imageMarkdown;
}

ClaudeToolResultContent splitClaudeToolResultContent(Object? content) {
  if (content is! List) {
    return ClaudeToolResultContent(
      textContent: content,
      imageMarkdown: const [],
    );
  }
  final images = <String>[];
  final text = <Object?>[];
  for (final value in content) {
    final image = _materializeClaudeImage(value);
    if (image == null) {
      text.add(value);
    } else {
      images.add('![](${Uri.file(image).toString()})');
      text.add(const {'type': 'text', 'text': '[image]'});
    }
  }
  return ClaudeToolResultContent(
    textContent: text,
    imageMarkdown: List.unmodifiable(images),
  );
}

String? _materializeClaudeImage(Object? value) {
  final block = _record(value);
  final source = _record(block?['source']);
  if (block?['type'] != 'image' ||
      source?['type'] != 'base64' ||
      source?['data'] is! String) {
    return null;
  }
  late final List<int> bytes;
  try {
    bytes = base64Decode(source!['data']! as String);
  } on FormatException {
    return null;
  }
  final mimeType = source['media_type'] as String?;
  final extension = switch (mimeType) {
    'image/jpeg' => '.jpg',
    'image/png' => '.png',
    'image/gif' => '.gif',
    'image/webp' => '.webp',
    _ => '.bin',
  };
  final directory = Directory(
    p.join(Directory.systemTemp.path, 'tinyrack-agent-attachments'),
  )..createSync(recursive: true);
  final file = File(
    p.join(directory.path, '${sha256.convert(bytes)}$extension'),
  );
  if (!file.existsSync()) file.writeAsBytesSync(bytes, flush: true);
  return file.path;
}

Map<String, Object?>? _record(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}
