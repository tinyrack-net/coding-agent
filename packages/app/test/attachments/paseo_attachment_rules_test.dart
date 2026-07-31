// Ports of the upstream test suites for Paseo's frozen attachment rules:
// `attachments/file-types.test.ts`, `attachments/utils.test.ts`,
// `attachments/workspace-attachment-utils.test.ts`, and
// `hooks/picked-image-normalizer.test.ts`, plus the edge cases those suites
// leave unpinned.
//
// The hash-derived expectations (`data-image:...`, `preview_..._...`) were
// computed by running upstream's `hashString` under Node, so the Dart FNV-1a
// port is pinned to the exact JavaScript digits.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/attachments/paseo_attachment_rules.dart';
import 'package:coding_agent_app/state/workspace_attachments_provider.dart';
import 'package:flutter_test/flutter_test.dart';

WorkspaceContextAttachment _contextAttachment({
  String kind = 'github.pull_request_comment',
}) => WorkspaceContextAttachment(
  kind: kind,
  id: 'comment-1',
  title: 'Comment · octocat',
  subtitle: 'Fix flaky build',
  text: 'GitHub pull request comment\n\nLooks good.',
  url: 'https://github.com/getpaseo/paseo/pull/42#issuecomment-1',
);

final class _FakePngExporter {
  final List<String> recordedUris = [];

  Future<String> call(String uri) async {
    recordedUris.add(uri);
    return 'file:///cache/ImageManipulator/safe-picked.png';
  }
}

void main() {
  group('attachment file types', () {
    test('keeps SVG as a file while treating raster image files as images', () {
      expect(getMimeTypeFromPath('/tmp/logo.svg'), 'application/octet-stream');
      expect(isRasterImagePath('/tmp/logo.svg'), isFalse);
      expect(isRasterImageMimeType('image/svg+xml'), isFalse);
      expect(
        isRasterImageFile(name: 'logo.svg', type: 'image/svg+xml'),
        isFalse,
      );

      expect(
        getRasterImageMimeTypeFromPath('/tmp/screenshot.PNG?cache=1'),
        'image/png',
      );
      expect(getMimeTypeFromPath('/tmp/screenshot.PNG?cache=1'), 'image/png');
      expect(isRasterImagePath('/tmp/screenshot.PNG?cache=1'), isTrue);
      expect(isRasterImageMimeType('image/png; charset=binary'), isTrue);
      expect(isRasterImageFile(name: 'screenshot.png'), isTrue);
    });

    test(
      'does not require MIME table entries for generic file attachments',
      () {
        for (final path in const [
          '/tmp/notes.md',
          '/tmp/archive.zip',
          '/tmp/report.docx',
          '/tmp/runtime.log',
          '/tmp/export.anything',
        ]) {
          expect(getMimeTypeFromPath(path), 'application/octet-stream');
        }
      },
    );

    test('does not offer SVG in the image picker extension list', () {
      expect(rasterImageFileExtensions.toSet(), {
        'png',
        'jpg',
        'jpeg',
        'gif',
        'webp',
        'bmp',
        'heic',
        'heif',
        'avif',
        'tif',
        'tiff',
      });
    });

    test('uses explicit raster MIME metadata before the filename', () {
      expect(
        resolveRasterImageMimeType(
          mimeType: 'image/jpeg',
          path: '/tmp/screenshot.png',
        ),
        'image/jpeg',
      );
      expect(
        resolveRasterImageMimeType(
          mimeType: 'image/png; charset=binary',
          path: '/tmp/screenshot.jpg',
        ),
        'image/png',
      );
    });

    test('uses the filename only when MIME metadata is absent', () {
      expect(
        resolveRasterImageMimeType(mimeType: '', path: '/tmp/screenshot.png'),
        'image/png',
      );
      expect(
        resolveRasterImageMimeType(
          mimeType: 'application/octet-stream',
          path: '/tmp/screenshot.png',
        ),
        isNull,
      );
    });

    test('normalizes the non-standard image/jpg spelling', () {
      expect(resolveRasterImageMimeType(mimeType: 'IMAGE/JPG'), 'image/jpeg');
      expect(isRasterImageMimeType('image/jpg'), isTrue);
      expect(isRasterImageMimeType(null), isFalse);
      expect(isRasterImageMimeType('   '), isFalse);
    });

    test('getFileExtension strips fragments and query strings', () {
      expect(getFileExtension('/tmp/a.PNG'), '.png');
      expect(getFileExtension('/tmp/a.png?v=2#frag'), '.png');
      expect(getFileExtension('/tmp/a.png#frag?v=2'), '.png');
      expect(getFileExtension('/tmp/noextension'), '');
      expect(getFileExtension(''), '');
      expect(getFileExtension('/tmp/archive.tar.gz'), '.gz');
      // Upstream takes everything after the last dot without checking for a
      // separator, so a dot in a directory segment yields a nonsense
      // "extension" that simply misses the MIME table.
      expect(getFileExtension('/tmp/a.png/inner'), '.png/inner');
      expect(getRasterImageMimeTypeFromPath('/tmp/a.png/inner'), isNull);
    });

    test('getFileTypeLabel badges the extension, or nothing at all', () {
      expect(getFileTypeLabel('/tmp/report.pdf'), 'PDF');
      expect(getFileTypeLabel('/tmp/screenshot.PNG?cache=1'), 'PNG');
      expect(getFileTypeLabel('/tmp/Makefile'), isNull);
      // A dotfile has an extension-shaped tail and upstream badges it.
      expect(getFileTypeLabel('/tmp/.env'), 'ENV');
    });

    test('isRasterImageFile falls back to the name for an unknown type', () {
      expect(isRasterImageFile(name: 'shot.HEIC'), isTrue);
      expect(isRasterImageFile(name: 'notes.md'), isFalse);
      expect(isRasterImageFile(name: 'notes.md', type: 'image/png'), isTrue);
    });

    test(
      'DEVIATION: a MIME string with an empty type falls through to the path',
      () {
        // Upstream returns null here: `";base64".trim()` is truthy, so the
        // filename branch is never reached and the empty media type fails the
        // raster check. The reused `composer_image_attachments.dart` port
        // splits on `;` before testing emptiness, so it falls back to the path
        // instead. Only a malformed MIME string paired with a path can observe
        // the difference; pinned here so the divergence stays deliberate.
        expect(
          resolveRasterImageMimeType(
            mimeType: ';base64',
            path: '/tmp/shot.png',
          ),
          'image/png',
        );
      },
    );
  });

  group('generateAttachmentId', () {
    test('keeps the frozen att_msg_<millis>_<suffix> shape', () {
      final id = generateAttachmentId(
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
        random: Random(7),
      );
      expect(id, startsWith('att_msg_1700000000000_'));
      expect(id.substring('att_msg_1700000000000_'.length), hasLength(9));
      expect(RegExp(r'^att_msg_\d+_[a-z0-9]{9}$').hasMatch(id), isTrue);
    });

    test('produces distinct ids within the same millisecond', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final ids = {
        for (var index = 0; index < 50; index += 1)
          generateAttachmentId(now: now),
      };
      expect(ids.length, greaterThan(40));
    });
  });

  group('normalizeMimeType', () {
    test('falls back to JPEG for absent or blank metadata', () {
      expect(normalizeMimeType(null), 'image/jpeg');
      expect(normalizeMimeType(''), 'image/jpeg');
      expect(normalizeMimeType('   '), 'image/jpeg');
    });

    test('trims but does not otherwise rewrite a supplied type', () {
      expect(normalizeMimeType('  image/png  '), 'image/png');
      expect(normalizeMimeType('IMAGE/PNG'), 'IMAGE/PNG');
      expect(normalizeMimeType('application/pdf'), 'application/pdf');
    });
  });

  group('pathToFileUri', () {
    test('converts POSIX absolute paths to file URIs', () {
      expect(
        pathToFileUri('/home/user/file.txt'),
        'file:///home/user/file.txt',
      );
    });

    test('converts Windows drive-letter paths to file URIs', () {
      expect(pathToFileUri(r'C:\Users\file.txt'), 'file:///C:/Users/file.txt');
    });

    test('converts UNC paths to host-based file URIs', () {
      expect(pathToFileUri(r'\\server\share\dir'), 'file://server/share/dir');
    });

    test('passes through file URIs unchanged', () {
      expect(pathToFileUri('file:///already/uri'), 'file:///already/uri');
    });

    test('passes through relative paths unchanged', () {
      expect(pathToFileUri('relative/path'), 'relative/path');
      expect(pathToFileUri('./relative'), './relative');
      expect(pathToFileUri(''), '');
      // `C:` without a separator is not an absolute path.
      expect(pathToFileUri('C:file.txt'), 'C:file.txt');
    });

    test('accepts a drive path already spelled with forward slashes', () {
      expect(pathToFileUri('C:/Users/file.txt'), 'file:///C:/Users/file.txt');
    });
  });

  group('fileUriToPath', () {
    test('converts Windows drive-letter file URIs back to paths', () {
      expect(fileUriToPath('file:///C:/Users/file.txt'), 'C:/Users/file.txt');
    });

    test('converts host-based file URIs back to UNC paths', () {
      expect(
        fileUriToPath('file://server/share/shot%231.png'),
        r'\\server\share\shot#1.png',
      );
    });

    test('leaves POSIX paths alone and passes non-file URIs through', () {
      expect(fileUriToPath('file:///home/user/a.txt'), '/home/user/a.txt');
      expect(
        fileUriToPath('https://example.test/a.png'),
        'https://example.test/a.png',
      );
      expect(fileUriToPath('/already/a/path'), '/already/a/path');
    });

    test('keeps a malformed percent escape verbatim', () {
      // `%zz` is not a valid escape; upstream swallows the decode error and
      // uses the raw text rather than dropping the path.
      expect(fileUriToPath('file:///tmp/100%zz.png'), '/tmp/100%zz.png');
    });

    test('round-trips a drive path through pathToFileUri', () {
      expect(
        fileUriToPath(pathToFileUri(r'C:\Users\file.txt')),
        'C:/Users/file.txt',
      );
    });
  });

  group('localFileSourceToPath', () {
    test('decodes markdown-encoded Windows drive-letter paths', () {
      expect(
        localFileSourceToPath(r'C:%5CUsers%5Cfile.txt'),
        'C:/Users/file.txt',
      );
      expect(
        localFileSourceToPath('C:%2fUsers%2ffile.txt'),
        'C:/Users/file.txt',
      );
    });

    test('preserves literal percent sequences in plain local paths', () {
      expect(
        localFileSourceToPath('/tmp/image%20with%20literal%20percent.png'),
        '/tmp/image%20with%20literal%20percent.png',
      );
    });

    test('routes file URIs through fileUriToPath', () {
      expect(
        localFileSourceToPath('file:///C:/Users/file.txt'),
        'C:/Users/file.txt',
      );
    });

    test('normalizes backslashes only for drive-letter paths', () {
      expect(localFileSourceToPath(r'C:\Users\file.txt'), 'C:/Users/file.txt');
      // A relative Windows-ish path has no drive letter, so it is left alone.
      expect(localFileSourceToPath(r'src\main.dart'), r'src\main.dart');
    });
  });

  group('parseDataUrl', () {
    test('accepts base64 data URLs with media-type parameters', () {
      expect(
        parseDataUrl(
          'data:image/png;charset=utf-8;name=preview;base64,AAECAw==',
        ),
        const AttachmentDataUrl(mimeType: 'image/png', base64: 'AAECAw=='),
      );
    });

    test('rejects non-base64 data URLs', () {
      expect(
        () => parseDataUrl('data:image/png,not-base64'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Attachment data URL is not base64 encoded.',
          ),
        ),
      );
    });

    test('rejects strings that are not data URLs at all', () {
      for (final input in const [
        '',
        'https://example.test/a.png',
        'data:image/png;base64,',
      ]) {
        expect(
          () => parseDataUrl(input),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Malformed data URL for attachment.',
            ),
          ),
          reason: input,
        );
      }
    });

    test('rejects a base64 URL whose payload is only whitespace', () {
      // The whole URL is trimmed before matching, so a whitespace-only payload
      // never reaches the "missing base64 payload" branch — it fails the
      // pattern outright. Pinned because upstream's dead branch is easy to
      // "fix" into a behaviour change.
      expect(
        () => parseDataUrl('data:image/png;base64,   \n  '),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Malformed data URL for attachment.',
          ),
        ),
      );
    });

    test('strips whitespace inside a wrapped payload', () {
      expect(
        parseDataUrl('  data:image/png;base64,AAEC\n  Aw==  ').base64,
        'AAECAw==',
      );
    });

    test('falls back to JPEG when the media type is omitted', () {
      expect(parseDataUrl('data:;base64,AAECAw==').mimeType, 'image/jpeg');
      expect(parseDataUrl('DATA:;BASE64,AAECAw==').mimeType, 'image/jpeg');
    });

    test('keeps commas that belong to the payload', () {
      expect(parseDataUrl('data:image/png;base64,AA,BB').base64, 'AA,BB');
    });
  });

  group('parseImageDataUrl', () {
    test('returns a compact cache key for image data URLs', () {
      final payload = 'a' * 512;
      final dataUrl = 'data:image/png;base64,$payload';
      final parsed = parseImageDataUrl(dataUrl);

      expect(parsed, isNotNull);
      expect(parsed!.mimeType, 'image/png');
      expect(parsed.base64, payload);
      expect(
        createImageSourceCacheKey(dataUrl),
        startsWith('data-image:image/png:512:'),
      );
      expect(createImageSourceCacheKey(dataUrl), isNot(contains('a' * 128)));
      expect(
        createImageSourceCacheKey(dataUrl),
        'data-image:image/png:512:qrlgk6',
      );
    });

    test('ignores non-image data URLs', () {
      expect(parseImageDataUrl('data:text/plain;base64,SGVsbG8='), isNull);
    });

    test('ignores SVG data URLs', () {
      expect(
        parseImageDataUrl('data:image/svg+xml;base64,PHN2ZyAvPg=='),
        isNull,
      );
    });

    test('ignores malformed image data URLs instead of throwing', () {
      expect(parseImageDataUrl('data:image/png,not-base64'), isNull);
      expect(parseImageDataUrl('data:image/png;base64,'), isNull);
      expect(parseImageDataUrl('not a data url'), isNull);
    });

    test('handles a payload shorter than the fingerprint window', () {
      expect(
        parseImageDataUrl('  data:image/png;base64,AAECAw==  ')?.cacheKey,
        'data-image:image/png:8:1li4j4y',
      );
    });

    test('keeps the media type verbatim, including its case', () {
      // `normalizeMimeType` only trims, so an upper-case declaration flows into
      // the cache key unchanged even though the raster check is case-insensitive.
      final parsed = parseImageDataUrl('DATA:IMAGE/PNG;BASE64,AAECAw==');
      expect(parsed?.mimeType, 'IMAGE/PNG');
      expect(parsed?.cacheKey, startsWith('data-image:IMAGE/PNG:8:'));
    });

    test('createImageSourceCacheKey passes ordinary sources through', () {
      expect(createImageSourceCacheKey('/tmp/a.png'), '/tmp/a.png');
      expect(
        createImageSourceCacheKey('https://example.test/a.png'),
        'https://example.test/a.png',
      );
    });

    test('distinct payloads of equal length get distinct cache keys', () {
      final first = createImageSourceCacheKey(
        'data:image/png;base64,${'a' * 512}',
      );
      final second = createImageSourceCacheKey(
        'data:image/png;base64,${'b' * 512}',
      );
      expect(first, isNot(second));
    });
  });

  group('getFileNameFromPath', () {
    test('returns the last segment of either separator style', () {
      expect(getFileNameFromPath('/tmp/dir/shot.png'), 'shot.png');
      expect(getFileNameFromPath(r'C:\Users\me\shot.png'), 'shot.png');
      expect(getFileNameFromPath('shot.png'), 'shot.png');
    });

    test('ignores trailing separators', () {
      expect(getFileNameFromPath('/tmp/dir/'), 'dir');
      expect(getFileNameFromPath('/tmp/dir///'), 'dir');
    });

    test('returns null when there is nothing nameable', () {
      expect(getFileNameFromPath(null), isNull);
      expect(getFileNameFromPath(''), isNull);
      expect(getFileNameFromPath('   '), isNull);
      expect(getFileNameFromPath('/'), isNull);
    });
  });

  group('createPreviewAttachmentId', () {
    test('labels the id with the byte size when one is known', () {
      expect(
        createPreviewAttachmentId(
          mimeType: 'image/png',
          path: '/tmp/a.png',
          size: 1024,
        ),
        'preview_1024_18azsro',
      );
    });

    test('falls back to content length, then to unknown', () {
      expect(
        createPreviewAttachmentId(
          mimeType: 'image/png',
          path: '/tmp/a.png',
          contentLength: 77,
        ),
        'preview_77_5wfcy9',
      );
      expect(
        createPreviewAttachmentId(mimeType: 'application/octet-stream'),
        'preview_unknown_11c3exc',
      );
    });

    test('hashes non-BMP path characters by UTF-16 code unit', () {
      expect(
        createPreviewAttachmentId(
          mimeType: 'image/png',
          // Written as escapes so the expectation is pinned to the exact code
          // units upstream hashed, not to this file's encoding.
          path: '/tmp/café\u{1F600}.png',
          size: 12,
        ),
        'preview_12_14u160v',
      );
    });

    test('is stable for the same inputs and sensitive to each of them', () {
      String id({
        String mimeType = 'image/png',
        String? path = '/tmp/a.png',
        num? size = 10,
        String? modifiedAt,
        num? contentLength,
      }) => createPreviewAttachmentId(
        mimeType: mimeType,
        path: path,
        size: size,
        modifiedAt: modifiedAt,
        contentLength: contentLength,
      );

      expect(id(), id());
      expect(id(mimeType: 'image/jpeg'), isNot(id()));
      expect(id(path: '/tmp/b.png'), isNot(id()));
      expect(id(size: 11), isNot(id()));
      expect(id(modifiedAt: '2026-01-01T00:00:00Z'), isNot(id()));
      expect(id(contentLength: 3), isNot(id()));
    });

    test('trims path and timestamp, and drops non-finite sizes', () {
      expect(
        createPreviewAttachmentId(
          mimeType: 'image/png',
          path: '  /tmp/a.png  ',
          size: 1024,
        ),
        createPreviewAttachmentId(
          mimeType: 'image/png',
          path: '/tmp/a.png',
          size: 1024,
        ),
      );
      expect(
        createPreviewAttachmentId(
          mimeType: 'application/octet-stream',
          size: double.nan,
          contentLength: double.infinity,
        ),
        'preview_unknown_11c3exc',
      );
    });

    test('an integral double keys the same preview as an int', () {
      expect(
        createPreviewAttachmentId(
          mimeType: 'image/png',
          path: '/tmp/a.png',
          size: 1024.0,
        ),
        'preview_1024_18azsro',
      );
    });

    test('a zero size still labels the id rather than reading as unknown', () {
      expect(
        createPreviewAttachmentId(
          mimeType: 'image/png',
          size: 0,
          contentLength: 9,
        ),
        startsWith('preview_0_'),
      );
    });
  });

  group('attachmentBytesToBase64', () {
    test('encodes attachment bytes', () async {
      expect(
        await attachmentBytesToBase64(Uint8List.fromList([0, 1, 2, 3])),
        'AAECAw==',
      );
      expect(
        base64Decode(
          await attachmentBytesToBase64(Uint8List.fromList([255, 0, 128])),
        ),
        [255, 0, 128],
      );
    });

    test('rejects an empty payload the way an empty Blob does', () async {
      await expectLater(
        attachmentBytesToBase64(Uint8List(0)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Attachment FileReader result did not contain base64 payload.',
          ),
        ),
      );
    });
  });

  group('getFileExtensionFromName', () {
    test('keeps the dot and the original case', () {
      expect(getFileExtensionFromName('Report.PDF'), '.PDF');
      expect(getFileExtensionFromName('archive.tar.gz'), '.gz');
    });

    test('returns empty for names with no usable extension', () {
      expect(getFileExtensionFromName(null), '');
      expect(getFileExtensionFromName(''), '');
      expect(getFileExtensionFromName('Makefile'), '');
      // A dotfile is a name, not an extension.
      expect(getFileExtensionFromName('.env'), '');
      // A trailing dot has nothing after it.
      expect(getFileExtensionFromName('archive.'), '');
    });
  });

  group('workspace attachment utilities', () {
    test('treats pull request context as a workspace attachment', () {
      expect(isWorkspaceAttachmentKind(_contextAttachment().kind), isTrue);
      expect(
        isPullRequestContextAttachmentKind(_contextAttachment().kind),
        isTrue,
      );
    });

    test('recognises both the forge and the legacy github kind spellings', () {
      for (final kind in const [
        'forge.change_request_comment',
        'forge.change_request_review',
        'forge.change_request_check',
        'github.pull_request_comment',
        'github.pull_request_review',
        'github.pull_request_check',
      ]) {
        expect(isPullRequestContextAttachmentKind(kind), isTrue, reason: kind);
        expect(isWorkspaceAttachmentKind(kind), isTrue, reason: kind);
      }
    });

    test('review, browser element and chat history are workspace-owned', () {
      for (final kind in const ['review', 'browser_element', 'chat_history']) {
        expect(isWorkspaceAttachmentKind(kind), isTrue, reason: kind);
        expect(isPullRequestContextAttachmentKind(kind), isFalse, reason: kind);
      }
    });

    test(
      'user attachment kinds and a missing attachment are not workspace-owned',
      () {
        for (final kind in const [
          'image',
          'file',
          'workspace_file',
          'forge_issue',
          'forge_change_request',
          'github_issue',
          'github_pr',
        ]) {
          expect(isWorkspaceAttachmentKind(kind), isFalse, reason: kind);
        }
        expect(isWorkspaceAttachmentKind(null), isFalse);
        expect(isPullRequestContextAttachmentKind(null), isFalse);
      },
    );

    test('strips context attachments from user draft attachments', () {
      const normalAttachment = (kind: 'github_issue', id: 'issue-12');
      final contextEntry = (
        kind: _contextAttachment().kind,
        id: _contextAttachment().id,
      );

      expect(
        userAttachmentsOnly([
          normalAttachment,
          contextEntry,
        ], kindOf: (attachment) => attachment.kind),
        [normalAttachment],
      );
    });

    test(
      'userAttachmentsOnly keeps order and returns an unmodifiable list',
      () {
        final kept = userAttachmentsOnly([
          _contextAttachment(),
          _contextAttachment(kind: 'workspace_file'),
          _contextAttachment(kind: 'review'),
          _contextAttachment(kind: 'image'),
        ], kindOf: (attachment) => attachment.kind);

        expect(kept.map((attachment) => attachment.kind), [
          'workspace_file',
          'image',
        ]);
        expect(() => kept.add(_contextAttachment()), throwsUnsupportedError);
      },
    );

    test('serializes context attachments as protocol text attachments', () {
      // `workspaceAttachmentToSubmitAttachment` is already ported as
      // `WorkspaceContextAttachment.toAgentAttachment()`; this pins the frozen
      // upstream expectation against that existing implementation rather than
      // declaring a second one.
      expect(_contextAttachment().toAgentAttachment().toJson(), {
        'type': 'text',
        'mimeType': 'text/plain',
        'title': 'Comment · octocat',
        'text': 'GitHub pull request comment\n\nLooks good.',
      });
    });

    test(
      'a workspace attachment with a semantic payload submits that payload',
      () {
        const review = ReviewAgentAttachment(
          cwd: '/repo',
          mode: ReviewAttachmentMode.uncommitted,
          comments: [],
        );
        final attachment = WorkspaceContextAttachment(
          kind: 'review',
          id: 'review-1',
          title: 'Review',
          subtitle: '1 comment',
          text: 'ignored',
          url: null,
          semanticAttachment: review,
        );

        expect(attachment.toAgentAttachment(), same(review));
      },
    );
  });

  group('native image attachment picker', () {
    test('preserves native picked JPEG and PNG attachment inputs', () async {
      final exporter = _FakePngExporter();

      final result = await normalizePickedImageAssetsWith(const [
        PickedImageAsset(
          uri: 'file:///photos/IMG_0001.JPG',
          mimeType: 'image/jpeg',
          fileName: 'picked.jpeg',
        ),
        PickedImageAsset(
          uri: 'file:///photos/screenshot.png',
          mimeType: 'image/png',
          fileName: 'screenshot.png',
        ),
      ], exporter.call);

      expect(result, const [
        PickedImageAttachmentInput(
          source: FileUriPickedImageSource('file:///photos/IMG_0001.JPG'),
          mimeType: 'image/jpeg',
          fileName: 'picked.jpg',
        ),
        PickedImageAttachmentInput(
          source: FileUriPickedImageSource('file:///photos/screenshot.png'),
          mimeType: 'image/png',
          fileName: 'screenshot.png',
        ),
      ]);
      expect(exporter.recordedUris, isEmpty);
    });

    test(
      'uses explicit native MIME metadata before the URI extension',
      () async {
        final exporter = _FakePngExporter();

        final result = await normalizePickedImageAssetsWith(const [
          PickedImageAsset(
            uri: 'file:///photos/screenshot.jpg',
            mimeType: 'image/png',
            fileName: 'screenshot.png',
          ),
        ], exporter.call);

        expect(result, const [
          PickedImageAttachmentInput(
            source: FileUriPickedImageSource('file:///photos/screenshot.jpg'),
            mimeType: 'image/png',
            fileName: 'screenshot.png',
          ),
        ]);
        expect(exporter.recordedUris, isEmpty);
      },
    );

    test(
      'turns a native picked HEIC-like asset into a PNG attachment input',
      () async {
        final exporter = _FakePngExporter();

        final result = await normalizePickedImageAssetsWith(const [
          PickedImageAsset(
            uri: 'file:///photos/IMG_0001.HEIC',
            mimeType: 'image/png',
            fileName: 'picked.png',
          ),
        ], exporter.call);

        expect(result, const [
          PickedImageAttachmentInput(
            source: FileUriPickedImageSource(
              'file:///cache/ImageManipulator/safe-picked.png',
            ),
            mimeType: 'image/png',
            fileName: 'picked.png',
          ),
        ]);
        expect(exporter.recordedUris, ['file:///photos/IMG_0001.HEIC']);
      },
    );

    test('an extensionless URI trusts the reported MIME type', () async {
      final exporter = _FakePngExporter();

      final result = await normalizePickedImageAssetsWith(const [
        PickedImageAsset(
          uri: 'content://media/external/images/1',
          mimeType: 'image/jpg',
        ),
      ], exporter.call);

      expect(result.single.mimeType, 'image/jpeg');
      expect(
        result.single.source,
        const FileUriPickedImageSource('content://media/external/images/1'),
      );
      // No file name means nothing to rewrite, not an invented one.
      expect(result.single.fileName, isNull);
      expect(exporter.recordedUris, isEmpty);
    });

    test(
      'falls back to the URI extension when no other metadata is present',
      () async {
        final exporter = _FakePngExporter();

        final result = await normalizePickedImageAssetsWith(const [
          PickedImageAsset(uri: 'file:///photos/a.PNG?ts=1'),
        ], exporter.call);

        expect(result.single.mimeType, 'image/png');
        expect(exporter.recordedUris, isEmpty);
      },
    );

    test(
      'falls back to the file name extension when the MIME type is unusable',
      () async {
        final exporter = _FakePngExporter();

        final result = await normalizePickedImageAssetsWith(const [
          PickedImageAsset(
            uri: 'content://media/external/images/2',
            mimeType: 'application/octet-stream',
            fileName: 'photo.JPEG',
          ),
        ], exporter.call);

        expect(result.single.mimeType, 'image/jpeg');
        expect(result.single.fileName, 'photo.jpg');
        expect(exporter.recordedUris, isEmpty);
      },
    );

    test('converts an unsupported container and renames the file', () async {
      final exporter = _FakePngExporter();

      final result = await normalizePickedImageAssetsWith(const [
        PickedImageAsset(
          uri: 'file:///photos/animation.webp',
          mimeType: 'image/webp',
          fileName: 'animation.webp',
        ),
      ], exporter.call);

      expect(result.single.mimeType, 'image/png');
      expect(result.single.fileName, 'animation.png');
      expect(
        result.single.source,
        const FileUriPickedImageSource(
          'file:///cache/ImageManipulator/safe-picked.png',
        ),
      );
      expect(exporter.recordedUris, ['file:///photos/animation.webp']);
    });

    test(
      'keeps assets in order and converts only the ones that need it',
      () async {
        final exporter = _FakePngExporter();

        final result = await normalizePickedImageAssetsWith(const [
          PickedImageAsset(uri: 'file:///photos/a.heic', fileName: 'a.heic'),
          PickedImageAsset(uri: 'file:///photos/b.png', fileName: 'b.png'),
          PickedImageAsset(uri: 'file:///photos/c.gif', fileName: 'c.gif'),
        ], exporter.call);

        expect(result.map((input) => input.mimeType), [
          'image/png',
          'image/png',
          'image/png',
        ]);
        expect(result.map((input) => input.fileName), [
          'a.png',
          'b.png',
          'c.png',
        ]);
        expect(exporter.recordedUris, [
          'file:///photos/a.heic',
          'file:///photos/c.gif',
        ]);
      },
    );

    test('a file name without an extension gains one', () async {
      final exporter = _FakePngExporter();

      final result = await normalizePickedImageAssetsWith(const [
        PickedImageAsset(
          uri: 'file:///photos/x.png',
          mimeType: 'image/png',
          fileName: 'no-extension',
        ),
      ], exporter.call);

      expect(result.single.fileName, 'no-extension.png');
    });

    test('normalizes an empty selection to an empty list', () async {
      final exporter = _FakePngExporter();
      expect(
        await normalizePickedImageAssetsWith(const [], exporter.call),
        isEmpty,
      );
    });
  });
}
