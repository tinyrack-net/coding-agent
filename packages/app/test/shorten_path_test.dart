import 'package:coding_agent_app/core/shorten_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shortens macOS and Linux home prefixes only', () {
    expect(shortenPath('/Users/alice/src/paseo'), '~/src/paseo');
    expect(shortenPath('/home/alice/src/paseo'), '~/src/paseo');
    expect(shortenPath('/srv/paseo'), '/srv/paseo');
    expect(shortenPath(r'C:\Users\alice\src'), r'C:\Users\alice\src');
    expect(shortenPath(null), '');
    expect(shortenPath(''), '');
  });
}
