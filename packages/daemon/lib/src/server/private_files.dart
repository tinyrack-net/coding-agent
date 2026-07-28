import 'dart:io';

import 'package:path/path.dart' as p;

void ensurePrivateFile(File file) {
  // coverage:ignore-start
  if (!Platform.isWindows && file.existsSync()) {
    Process.runSync('chmod', ['600', file.path]);
  }
  // coverage:ignore-end
}

void writePrivateFileAtomic(File file, String contents) {
  file.parent.createSync(recursive: true);
  final temporary = File(
    p.join(
      file.parent.path,
      '.${p.basename(file.path)}.${pid}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    ),
  );
  temporary.writeAsStringSync(contents, flush: true);
  ensurePrivateFile(temporary);
  if (file.existsSync()) file.deleteSync();
  temporary.renameSync(file.path);
}
