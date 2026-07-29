import 'package:coding_agent_app/core/path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isAbsolutePath', () {
    test('returns true for Unix absolute paths', () {
      expect(isAbsolutePath('/'), isTrue);
      expect(isAbsolutePath('/home/user'), isTrue);
      expect(isAbsolutePath('/tmp/file.txt'), isTrue);
    });

    test('returns true for Windows drive letter paths', () {
      expect(isAbsolutePath(r'C:\Users'), isTrue);
      expect(isAbsolutePath('C:/Users'), isTrue);
      expect(isAbsolutePath(r'd:\projects'), isTrue);
    });

    test('returns true for UNC paths', () {
      expect(isAbsolutePath(r'\\server\share'), isTrue);
      expect(isAbsolutePath(r'\\\\host\path'), isTrue);
    });

    test('returns false for relative paths', () {
      expect(isAbsolutePath('foo/bar'), isFalse);
      expect(isAbsolutePath('./relative'), isFalse);
      expect(isAbsolutePath('../parent'), isFalse);
      expect(isAbsolutePath(''), isFalse);
      expect(isAbsolutePath('file.txt'), isFalse);
    });

    test('returns false for edge cases that are not absolute paths', () {
      expect(isAbsolutePath(''), isFalse);
      expect(isAbsolutePath('C:'), isFalse);
    });

    test('handles mixed separators in absolute paths', () {
      expect(isAbsolutePath(r'C:/Users\mixed/path'), isTrue);
      expect(isAbsolutePath(r'/tmp\mixed/path'), isTrue);
    });
  });
}
