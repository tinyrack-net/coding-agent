import 'package:agent_daemon/src/server/pairing_qr.dart';
import 'package:test/test.dart';

void main() {
  test('renders Paseo UTF-8 blocks with margin and per-line ANSI colors', () {
    final rendered = renderPairingQr('https://app.tinyrack.dev/#offer=test');
    final lines = rendered.split('\n');

    expect(lines.length, greaterThan(10));
    expect(
      lines,
      everyElement(
        allOf(startsWith('\u001b[47m\u001b[30m'), endsWith('\u001b[0m')),
      ),
    );
    final plain = lines
        .map(
          (line) => line
              .replaceFirst('\u001b[47m\u001b[30m', '')
              .replaceFirst('\u001b[0m', ''),
        )
        .toList();
    expect(plain.map((line) => line.length).toSet(), hasLength(1));
    expect(plain.take(2), everyElement(matches(RegExp(r'^ +$'))));
    expect(plain.skip(2).take(plain.length - 4).join(), contains('█'));
    expect(
      plain.skip(plain.length - 2),
      everyElement(matches(RegExp(r'^ +$'))),
    );
  });
}
