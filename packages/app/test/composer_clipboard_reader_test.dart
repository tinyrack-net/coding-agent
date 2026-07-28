import 'dart:io';
import 'package:coding_agent_app/composer/composer_clipboard_reader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('pasteboard'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test(
    'system reader reads text and normalizes the native image channel',
    () async {
      final source = image.Image(width: 1, height: 1)
        ..setPixelRgba(0, 0, 12, 34, 56, 255);
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'tinyrack-clipboard-reader.bmp',
      );
      await file.writeAsBytes(image.encodeBmp(source));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('pasteboard'), (
            call,
          ) async {
            return switch (call.method) {
              'image' => file.path,
              _ => null,
            };
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return {'text': 'clipboard text'};
            }
            return null;
          });
      const reader = SystemComposerClipboardReader();

      expect(await reader.readText(), 'clipboard text');
      expect((await reader.readPngImage())!.take(8), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
    },
  );

  test('system reader returns null when no native image exists', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('pasteboard'),
          (_) async => null,
        );

    expect(await const SystemComposerClipboardReader().readPngImage(), isNull);
  });

  test('normalizes native BMP clipboard bytes to PNG', () {
    final source = image.Image(width: 1, height: 1)
      ..setPixelRgba(0, 0, 12, 34, 56, 255);

    final png = normalizeClipboardImageToPng(
      Uint8List.fromList(image.encodeBmp(source)),
    );

    expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final decoded = image.decodePng(png)!;
    expect(decoded.getPixel(0, 0).r, 12);
    expect(decoded.getPixel(0, 0).g, 34);
    expect(decoded.getPixel(0, 0).b, 56);
  });

  test('rejects undecodable clipboard bytes', () {
    expect(
      () => normalizeClipboardImageToPng(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
