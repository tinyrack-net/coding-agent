import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('strips only an exact normalized cwd prefix', () {
    expect(
      stripCwdPrefix('/tmp/repo/src/main.dart', '/tmp/repo'),
      'src/main.dart',
    );
    expect(
      stripCwdPrefix(r'C:\repo\lib\main.dart', r'C:\repo'),
      'lib/main.dart',
    );
    expect(stripCwdPrefix('/tmp/repo', '/tmp/repo/'), '.');
    expect(
      stripCwdPrefix('/tmp/repository/main.dart', '/tmp/repo'),
      '/tmp/repository/main.dart',
    );
    expect(stripCwdPrefix('/tmp/repo/main.dart'), '/tmp/repo/main.dart');
    expect(stripCwdPrefix('', '/tmp/repo'), '');
  });
}
