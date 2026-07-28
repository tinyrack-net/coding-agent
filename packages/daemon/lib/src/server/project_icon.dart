import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

const iconPatterns = [
  'favicon.ico',
  'favicon.png',
  'favicon.svg',
  'favico.ico',
  'favico.png',
  'favico.svg',
  'icon.png',
  'icon.svg',
  'app-icon.png',
  'app-icon.svg',
  'apple-touch-icon.png',
  'icon-*.png',
  'logo.png',
  'logo.svg',
];
const priorityIconDirectories = [
  'public',
  'static',
  'priv/static',
  'assets',
  'images',
  'img',
];
const monorepoPackageDirectories = ['packages', 'apps'];
const ignoredIconDirectories = {
  '.git',
  'node_modules',
  'dist',
  'build',
  '.next',
  '.nuxt',
  '.output',
  'coverage',
  '.cache',
  'vendor',
  'src',
  'lib',
  'test',
  'tests',
  '__tests__',
};
const maxProjectIconBytes = 32 * 1024;

Future<String?> findProjectIcon(String projectDir, {int maxDepth = 3}) async {
  final priority = await _searchPriorityDirectories(projectDir, maxDepth - 1);
  if (priority != null) return priority;

  for (final monorepoDirectory in monorepoPackageDirectories) {
    final root = Directory(p.join(projectDir, monorepoDirectory));
    final packages = await _listNames(root);
    if (packages == null) continue;
    for (final packageName in packages) {
      final packagePath = p.join(root.path, packageName);
      if (!await Directory(packagePath).exists()) continue;
      final nested = await _searchPriorityDirectories(
        packagePath,
        maxDepth - 1,
      );
      if (nested != null) return nested;
      final direct = await _findIconInDirectory(packagePath);
      if (direct != null) return direct;
    }
  }

  return _findIconInDirectory(projectDir);
}

Future<Map<String, String>?> getProjectIcon(String projectDir) async {
  final iconPath = await findProjectIcon(projectDir);
  if (iconPath == null) return null;
  try {
    final file = File(iconPath);
    final stat = await file.stat();
    if (stat.size > maxProjectIconBytes) return null;
    final bytes = await file.readAsBytes();
    final mimeType = projectIconMimeType(iconPath);
    if (!isSquareProjectIcon(bytes, mimeType)) return null;
    return {'data': base64Encode(bytes), 'mimeType': mimeType};
  } on FileSystemException {
    return null;
  }
}

Future<String?> _searchPriorityDirectories(
  String basePath,
  int remainingDepth,
) async {
  for (final relative in priorityIconDirectories) {
    final path = p.join(basePath, relative);
    if (!await Directory(path).exists()) continue;
    final result = await _searchDirectory(path, remainingDepth);
    if (result != null) return result;
  }
  return null;
}

Future<String?> _searchDirectory(
  String directory,
  int maxDepth, [
  int currentDepth = 0,
]) async {
  if (currentDepth > maxDepth) return null;
  final direct = await _findIconInDirectory(directory);
  if (direct != null) return direct;
  final entries = await _listNames(Directory(directory));
  if (entries == null) return null;
  for (final entry in entries) {
    if (ignoredIconDirectories.contains(entry)) continue;
    final child = p.join(directory, entry);
    if (!await Directory(child).exists()) continue;
    final result = await _searchDirectory(child, maxDepth, currentDepth + 1);
    if (result != null) return result;
  }
  return null;
}

Future<String?> _findIconInDirectory(String directory) async {
  final entries = await _listNames(Directory(directory));
  if (entries == null) return null;
  for (final pattern in iconPatterns) {
    for (final entry in entries) {
      if (!_matchesIconPattern(entry, pattern)) continue;
      final candidate = File(p.join(directory, entry));
      if (await candidate.exists()) return candidate.path;
    }
  }
  return null;
}

Future<List<String>?> _listNames(Directory directory) async {
  try {
    return [
      await for (final entity in directory.list(followLinks: false))
        p.basename(entity.path),
    ];
  } on FileSystemException {
    return null;
  }
}

bool _matchesIconPattern(String fileName, String pattern) {
  if (!pattern.contains('*')) return fileName == pattern;
  final expression = '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$';
  return RegExp(expression).hasMatch(fileName);
}

String projectIconMimeType(String path) =>
    switch (p.extension(path).toLowerCase()) {
      '.ico' => 'image/x-icon',
      '.png' => 'image/png',
      '.svg' => 'image/svg+xml',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      _ => 'application/octet-stream',
    };

bool isSquareProjectIcon(Uint8List bytes, String mimeType) {
  final dimensions = switch (mimeType) {
    'image/png' => _pngDimensions(bytes),
    'image/jpeg' => _jpegDimensions(bytes),
    'image/gif' => _gifDimensions(bytes),
    'image/webp' => _webpDimensions(bytes),
    'image/x-icon' || 'image/svg+xml' => const (1, 1),
    _ => null,
  };
  return dimensions != null && dimensions.$1 == dimensions.$2;
}

(int, int)? _pngDimensions(Uint8List bytes) {
  if (bytes.length < 24 ||
      bytes[0] != 0x89 ||
      bytes[1] != 0x50 ||
      bytes[2] != 0x4e ||
      bytes[3] != 0x47) {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  return (data.getUint32(16, Endian.big), data.getUint32(20, Endian.big));
}

(int, int)? _jpegDimensions(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return null;
  final data = ByteData.sublistView(bytes);
  var offset = 2;
  while (offset < bytes.length - 8) {
    if (bytes[offset] != 0xff) {
      offset++;
      continue;
    }
    final marker = bytes[offset + 1];
    if (marker >= 0xc0 && marker <= 0xc2) {
      return (
        data.getUint16(offset + 7, Endian.big),
        data.getUint16(offset + 5, Endian.big),
      );
    }
    final length = data.getUint16(offset + 2, Endian.big);
    if (length == 0) return null;
    offset += 2 + length;
  }
  return null;
}

(int, int)? _gifDimensions(Uint8List bytes) {
  if (bytes.length < 10 ||
      bytes[0] != 0x47 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46) {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  return (data.getUint16(6, Endian.little), data.getUint16(8, Endian.little));
}

(int, int)? _webpDimensions(Uint8List bytes) {
  if (bytes.length < 30 ||
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WEBP') {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  final type = ascii.decode(bytes.sublist(12, 16), allowInvalid: true);
  if (type == 'VP8 ') {
    return (
      data.getUint16(26, Endian.little) & 0x3fff,
      data.getUint16(28, Endian.little) & 0x3fff,
    );
  }
  if (type == 'VP8L') {
    final bits = data.getUint32(21, Endian.little);
    return ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
  }
  return null;
}
