import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test('majorOf parses common forms', () {
    expect(majorOf('0.2.0'), 0);
    expect(majorOf('v1.4.2'), 1);
    expect(majorOf('2'), 2);
    expect(majorOf('garbage'), -1);
  });

  test('majorCompatible gates on major only', () {
    expect(majorCompatible('1.0.0', '1.9.3'), isTrue);
    expect(majorCompatible('1.0.0', '2.0.0'), isFalse);
    expect(majorCompatible('bad', 'bad'), isFalse);
  });
}
