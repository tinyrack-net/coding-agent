import 'dart:convert';
import 'dart:typed_data';

import 'package:coding_agent_app/file_explorer/file_explorer_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Port of Paseo's `file-explorer/visibility.test.ts`,
/// `file-explorer/read-result.test.ts` and
/// `components/file-pane-enabled.test.ts`.

ExplorerEntry makeEntry(String name, ExplorerEntryKind kind) => ExplorerEntry(
  name: name,
  path: name,
  kind: kind,
  size: 0,
  modifiedAt: '2026-01-01T00:00:00.000Z',
);

FileReadResult textRead(List<int> bytes) => FileReadResult(
  bytes: Uint8List.fromList(bytes),
  mime: 'text/plain',
  size: bytes.length,
  path: 'notes.txt',
  kind: ExplorerFileKind.text,
  modifiedAt: '2026-07-21T00:00:00.000Z',
);

void main() {
  group('file explorer visibility', () {
    test('keeps dot-prefixed entries when hidden files are shown', () {
      final entries = [
        makeEntry('.env', ExplorerEntryKind.file),
        makeEntry('src', ExplorerEntryKind.directory),
      ];

      expect(
        filterVisibleExplorerEntries(entries, showHiddenFiles: true),
        equals(entries),
      );
    });

    test('hides dot-prefixed files and directories when hidden files are not '
        'shown', () {
      final entries = [
        makeEntry('.env', ExplorerEntryKind.file),
        makeEntry('.git', ExplorerEntryKind.directory),
        makeEntry('README.md', ExplorerEntryKind.file),
        makeEntry('src', ExplorerEntryKind.directory),
      ];

      expect(
        filterVisibleExplorerEntries(
          entries,
          showHiddenFiles: false,
        ).map((entry) => entry.name),
        equals(['README.md', 'src']),
      );
    });

    test('detects paths nested under dot-prefixed directories', () {
      expect(isHiddenExplorerPath('.'), isFalse);
      expect(isHiddenExplorerPath('..'), isFalse);
      expect(isHiddenExplorerPath('../sibling'), isFalse);
      expect(isHiddenExplorerPath('src/components'), isFalse);
      expect(isHiddenExplorerPath('.git'), isTrue);
      expect(isHiddenExplorerPath('src/.cache/output.json'), isTrue);
    });

    test('treats an empty path and empty segments as visible', () {
      expect(isHiddenExplorerPath(''), isFalse);
      expect(isHiddenExplorerPath('src//nested'), isFalse);
    });

    test('a dot-prefixed leaf under a visible directory is hidden', () {
      expect(isHiddenExplorerPath('src/.env'), isTrue);
      expect(isHiddenExplorerPath('./.env'), isTrue);
      expect(isHiddenExplorerPath('../.ssh/config'), isTrue);
    });

    test('a mid-name dot does not hide a path', () {
      expect(isHiddenExplorerPath('src/app.config.json'), isFalse);
    });

    test('returns the input list unchanged when hidden files are shown', () {
      final entries = <ExplorerEntry>[];

      expect(
        identical(
          filterVisibleExplorerEntries(entries, showHiddenFiles: true),
          entries,
        ),
        isTrue,
      );
    });

    test('filtering ignores the entry path and only inspects its name', () {
      // Listings are already scoped to one directory, so an entry inside a
      // hidden directory the user navigated into stays visible.
      const entry = ExplorerEntry(
        name: 'config',
        path: '.ssh/config',
        kind: ExplorerEntryKind.file,
        size: 0,
        modifiedAt: '2026-01-01T00:00:00.000Z',
      );

      expect(
        filterVisibleExplorerEntries([entry], showHiddenFiles: false),
        equals([entry]),
      );
    });
  });

  group('explorerFileFromReadResult', () {
    test('records and hides a leading UTF-8 BOM', () {
      final file = explorerFileFromReadResult(
        textRead([0xef, 0xbb, 0xbf, 0x68, 0x69]),
      );

      expect(file.content, 'hi');
      expect(file.hasBom, isTrue);
    });

    test('does not mark BOM-free text or non-leading U+FEFF as BOM files', () {
      final plain = explorerFileFromReadResult(textRead(utf8.encode('hi')));
      final embedded = explorerFileFromReadResult(
        textRead([0x68, 0x69, 0xef, 0xbb, 0xbf]),
      );

      expect(plain.hasBom, isFalse);
      expect(embedded.hasBom, isFalse);
      // A non-leading BOM stays in the decoded content.
      expect(embedded.content, 'hi\u{feff}');
    });

    test('carries the daemon metadata through unchanged', () {
      final file = explorerFileFromReadResult(textRead(utf8.encode('hi')));

      expect(file.path, 'notes.txt');
      expect(file.kind, ExplorerFileKind.text);
      expect(file.encoding, ExplorerEncoding.utf8);
      expect(file.mimeType, 'text/plain');
      expect(file.size, 2);
      expect(file.modifiedAt, '2026-07-21T00:00:00.000Z');
    });

    test('leaves image and binary reads undecoded', () {
      for (final kind in [ExplorerFileKind.image, ExplorerFileKind.binary]) {
        final file = explorerFileFromReadResult(
          FileReadResult(
            bytes: Uint8List.fromList([0xef, 0xbb, 0xbf, 0x00]),
            mime: 'application/octet-stream',
            size: 4,
            path: 'blob.bin',
            kind: kind,
            modifiedAt: '2026-07-21T00:00:00.000Z',
          ),
        );

        expect(file.encoding, ExplorerEncoding.none);
        expect(file.content, isNull);
        // The BOM bit is only meaningful for decoded text.
        expect(file.hasBom, isFalse);
      }
    });

    test('a short file that only prefixes the BOM is not a BOM file', () {
      final file = explorerFileFromReadResult(textRead([0xef, 0xbb]));

      expect(file.hasBom, isFalse);
    });

    test('an empty text read decodes to an empty string', () {
      final file = explorerFileFromReadResult(textRead(const []));

      expect(file.content, '');
      expect(file.hasBom, isFalse);
    });

    test('a bare BOM decodes to an empty string', () {
      final file = explorerFileFromReadResult(textRead([0xef, 0xbb, 0xbf]));

      expect(file.content, '');
      expect(file.hasBom, isTrue);
    });

    test('malformed bytes are substituted rather than throwing', () {
      // Browser TextDecoder is lenient; the port must not throw where upstream
      // would have produced U+FFFD.
      final file = explorerFileFromReadResult(textRead([0x68, 0xff, 0x69]));

      expect(file.content, 'h\u{fffd}i');
    });

    test('decodes multi-byte text after a BOM', () {
      final file = explorerFileFromReadResult(
        textRead([0xef, 0xbb, 0xbf, ...utf8.encode('안녕')]),
      );

      expect(file.content, '안녕');
      expect(file.hasBom, isTrue);
    });
  });

  group('isFileQueryEnabled', () {
    test('reads when there is a target, the tab is active, and the app is '
        'visible', () {
      expect(
        isFileQueryEnabled(
          hasReadTarget: true,
          isTabActive: true,
          isAppVisible: true,
        ),
        isTrue,
      );
    });

    test('does not read while the tab is hidden', () {
      expect(
        isFileQueryEnabled(
          hasReadTarget: true,
          isTabActive: false,
          isAppVisible: true,
        ),
        isFalse,
      );
    });

    test('does not read while the app is backgrounded', () {
      expect(
        isFileQueryEnabled(
          hasReadTarget: true,
          isTabActive: true,
          isAppVisible: false,
        ),
        isFalse,
      );
    });

    test('does not read without a resolved file target', () {
      expect(
        isFileQueryEnabled(
          hasReadTarget: false,
          isTabActive: true,
          isAppVisible: true,
        ),
        isFalse,
      );
    });

    test('stays disabled when every input is false', () {
      expect(
        isFileQueryEnabled(
          hasReadTarget: false,
          isTabActive: false,
          isAppVisible: false,
        ),
        isFalse,
      );
    });
  });
}
