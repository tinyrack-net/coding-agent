import 'package:coding_agent_app/terminal/terminal_file_drop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('terminal file drop', () {
    test('prepares POSIX paths with conservative escaping', () {
      expect(
        prepareDroppedPathForTerminal(
          '/tmp/my image.png',
          TerminalHostPlatform.nonWindows,
        ),
        "'/tmp/my image.png'",
      );
      expect(
        prepareDroppedPathForTerminal(
          r'/tmp/a$(touch bad).png',
          TerminalHostPlatform.nonWindows,
        ),
        "'/tmp/a(touch bad).png'",
      );
      expect(
        prepareDroppedPathForTerminal(
          "/tmp/it's.png",
          TerminalHostPlatform.nonWindows,
        ),
        r"'/tmp/it\'s.png'",
      );
      expect(
        prepareDroppedPathForTerminal(
          '/tmp/a"b\'c.png',
          TerminalHostPlatform.nonWindows,
        ),
        "\$'/tmp/a\"b\\'c.png'",
      );
      expect(
        prepareDroppedPathForTerminal(
          r'/tmp/a\b.png',
          TerminalHostPlatform.nonWindows,
        ),
        r"'/tmp/a\\b.png'",
      );
    });

    test('prepares Windows paths with space quoting', () {
      expect(
        prepareDroppedPathForTerminal(
          r'C:\Users\me\photo.png',
          TerminalHostPlatform.windows,
        ),
        r'C:\Users\me\photo.png',
      );
      expect(
        prepareDroppedPathForTerminal(
          r'C:\Users\me\photo one.png',
          TerminalHostPlatform.windows,
        ),
        r'"C:\Users\me\photo one.png"',
      );
    });

    test('joins multiple paths for one terminal input', () {
      expect(
        prepareDroppedPathsForTerminal([
          '/tmp/a.png',
          '/tmp/b c.png',
        ], TerminalHostPlatform.nonWindows),
        "'/tmp/a.png' '/tmp/b c.png'",
      );
      expect(
        prepareDroppedPathsForTerminal([], TerminalHostPlatform.windows),
        isEmpty,
      );
    });
  });
}
