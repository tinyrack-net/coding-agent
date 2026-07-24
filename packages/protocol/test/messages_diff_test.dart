import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('DiffLine', () {
    test('round-trips with all fields', () {
      const line = DiffLine(
        type: DiffLineType.add,
        text: '+ hello',
        oldLineNo: 3,
        newLineNo: 4,
      );
      final decoded = DiffLine.fromJson(roundTrip(line.toJson()));
      expect(decoded.type, DiffLineType.add);
      expect(decoded.text, '+ hello');
      expect(decoded.oldLineNo, 3);
      expect(decoded.newLineNo, 4);
    });

    test('omits null line numbers from json', () {
      const line = DiffLine(type: DiffLineType.context, text: 'x');
      final json = line.toJson();
      expect(json.containsKey('oldLineNo'), isFalse);
      expect(json.containsKey('newLineNo'), isFalse);
    });

    test('fromJson applies defaults for missing fields', () {
      final decoded = DiffLine.fromJson(const {});
      expect(decoded.type, DiffLineType.context);
      expect(decoded.text, '');
      expect(decoded.oldLineNo, isNull);
      expect(decoded.newLineNo, isNull);
    });

    test('fromJson throws on unknown enum value', () {
      expect(
        () => DiffLine.fromJson(const {'type': 'bogus'}),
        throwsArgumentError,
      );
    });
  });

  group('DiffHunk', () {
    test('round-trips with lines', () {
      const hunk = DiffHunk(
        header: '@@ -1,2 +1,2 @@',
        lines: [
          DiffLine(type: DiffLineType.del, text: 'old'),
          DiffLine(type: DiffLineType.add, text: 'new'),
        ],
      );
      final decoded = DiffHunk.fromJson(roundTrip(hunk.toJson()));
      expect(decoded.header, '@@ -1,2 +1,2 @@');
      expect(decoded.lines, hasLength(2));
      expect(decoded.lines[0].type, DiffLineType.del);
      expect(decoded.lines[1].type, DiffLineType.add);
    });

    test('fromJson defaults to empty header/lines', () {
      final decoded = DiffHunk.fromJson(const {});
      expect(decoded.header, '');
      expect(decoded.lines, isEmpty);
    });
  });

  group('DiffFile', () {
    test('round-trips with hunks', () {
      const file = DiffFile(
        path: 'lib/main.dart',
        status: DiffFileStatus.renamed,
        oldPath: 'lib/old_main.dart',
        binary: false,
        additions: 5,
        deletions: 2,
        hunks: [
          DiffHunk(
            header: '@@ -1 +1 @@',
            lines: [DiffLine(type: DiffLineType.context, text: 'same')],
          ),
        ],
      );
      final decoded = DiffFile.fromJson(roundTrip(file.toJson()));
      expect(decoded.path, 'lib/main.dart');
      expect(decoded.status, DiffFileStatus.renamed);
      expect(decoded.oldPath, 'lib/old_main.dart');
      expect(decoded.binary, isFalse);
      expect(decoded.additions, 5);
      expect(decoded.deletions, 2);
      expect(decoded.hunks, hasLength(1));
    });

    test('defaults applied for optional fields', () {
      final decoded = DiffFile.fromJson({'path': 'a.txt'});
      expect(decoded.status, DiffFileStatus.modified);
      expect(decoded.oldPath, isNull);
      expect(decoded.binary, isFalse);
      expect(decoded.additions, 0);
      expect(decoded.deletions, 0);
      expect(decoded.hunks, isEmpty);
    });

    test('fromJson throws when path missing', () {
      expect(() => DiffFile.fromJson(const {}), throwsA(anything));
    });

    test('binary file with no hunks round-trips', () {
      const file = DiffFile(
        path: 'image.png',
        status: DiffFileStatus.added,
        binary: true,
      );
      final decoded = DiffFile.fromJson(roundTrip(file.toJson()));
      expect(decoded.binary, isTrue);
      expect(decoded.hunks, isEmpty);
    });
  });

  group('DiffResponse', () {
    test('round-trips with multiple files', () {
      const response = DiffResponse(
        files: [
          DiffFile(path: 'a.dart', status: DiffFileStatus.added),
          DiffFile(path: 'b.dart', status: DiffFileStatus.deleted),
        ],
      );
      final decoded = DiffResponse.fromJson(roundTrip(response.toJson()));
      expect(decoded.files, hasLength(2));
      expect(decoded.files[0].status, DiffFileStatus.added);
      expect(decoded.files[1].status, DiffFileStatus.deleted);
    });

    test('fromJson defaults to empty list when files missing', () {
      final decoded = DiffResponse.fromJson(const {});
      expect(decoded.files, isEmpty);
    });
  });
}
