import 'package:qr/qr.dart';

const _blackOnWhite = '\u001b[47m\u001b[30m';
const _resetColors = '\u001b[0m';

/// Renders the same compact UTF-8 block QR representation used by Paseo.
String renderPairingQr(String url) {
  final code = QrCode(
    payload: QrPayload.fromString(url),
    errorCorrectLevel: QrErrorCorrectLevel.medium,
  );
  final image = QrImage(code);
  const margin = 4;
  final width = image.moduleCount + margin * 2;
  final blankLine = ''.padLeft(width);
  final lines = <String>[
    for (var index = 0; index < margin ~/ 2; index++) blankLine,
  ];
  for (var row = 0; row < image.moduleCount; row += 2) {
    final line = StringBuffer(''.padLeft(margin));
    for (var column = 0; column < image.moduleCount; column++) {
      final top = image.isDark(row, column);
      final bottom =
          row + 1 < image.moduleCount && image.isDark(row + 1, column);
      line.write(switch ((top, bottom)) {
        (false, false) => ' ',
        (false, true) => '▄',
        (true, false) => '▀',
        (true, true) => '█',
      });
    }
    line.write(''.padLeft(margin));
    lines.add(line.toString());
  }
  for (var index = 0; index < margin ~/ 2; index++) {
    lines.add(blankLine);
  }
  return lines.map((line) => '$_blackOnWhite$line$_resetColors').join('\n');
}
