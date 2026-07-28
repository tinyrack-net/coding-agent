/// Filesystem-aware path identity used by Paseo import and placement flows.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

bool Function(String) realpathAwarePathMatcher(String target) {
  final targets = _pathVariants(target);
  return (candidate) {
    final candidates = _pathVariants(candidate);
    return candidates.any(
      (candidate) => targets.any((target) => _samePath(target, candidate)),
    );
  };
}

Set<String> _pathVariants(String value) {
  final result = <String>{value};
  try {
    result.add(Directory(value).resolveSymbolicLinksSync());
  } on FileSystemException {
    // Lexical comparison remains available for paths that do not exist.
  }
  return result;
}

bool _samePath(String left, String right) {
  final normalizedLeft = p.normalize(p.absolute(left));
  final normalizedRight = p.normalize(p.absolute(right));
  if (Platform.isWindows ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(left) ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(right)) {
    return normalizedLeft.toLowerCase() == normalizedRight.toLowerCase();
  }
  return normalizedLeft == normalizedRight;
}
