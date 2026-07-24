import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('ShellDetail', () {
    test('round-trips with all fields', () {
      const detail = ShellDetail(command: 'ls -la', output: 'file.txt', exitCode: 0);
      final decoded = ToolCallDetail.fromJson(roundTrip(detail.toJson()));
      expect(decoded, isA<ShellDetail>());
      final shell = decoded as ShellDetail;
      expect(shell.command, 'ls -la');
      expect(shell.output, 'file.txt');
      expect(shell.exitCode, 0);
    });

    test('omits null output/exitCode from json', () {
      const detail = ShellDetail(command: 'ls');
      final json = detail.toJson();
      expect(json.containsKey('output'), isFalse);
      expect(json.containsKey('exitCode'), isFalse);
      final decoded = ToolCallDetail.fromJson(json) as ShellDetail;
      expect(decoded.output, isNull);
      expect(decoded.exitCode, isNull);
    });
  });

  group('ReadDetail', () {
    test('round-trips', () {
      const detail = ReadDetail(path: 'lib/main.dart');
      final decoded = ToolCallDetail.fromJson(roundTrip(detail.toJson()));
      expect(decoded, isA<ReadDetail>());
      expect((decoded as ReadDetail).path, 'lib/main.dart');
    });

    test('fromJson defaults path to empty string', () {
      final decoded = ToolCallDetail.fromJson(const {'kind': 'read'});
      expect((decoded as ReadDetail).path, '');
    });
  });

  group('EditDetail', () {
    test('round-trips with diff', () {
      const detail = EditDetail(path: 'lib/a.dart', diff: '+add\n-remove');
      final decoded = ToolCallDetail.fromJson(roundTrip(detail.toJson()));
      expect(decoded, isA<EditDetail>());
      final edit = decoded as EditDetail;
      expect(edit.path, 'lib/a.dart');
      expect(edit.diff, '+add\n-remove');
    });

    test('omits null diff from json', () {
      const detail = EditDetail(path: 'lib/a.dart');
      expect(detail.toJson().containsKey('diff'), isFalse);
      final decoded = ToolCallDetail.fromJson(detail.toJson()) as EditDetail;
      expect(decoded.diff, isNull);
    });
  });

  group('WriteDetail', () {
    test('round-trips with contentPreview', () {
      const detail = WriteDetail(path: 'lib/b.dart', contentPreview: 'class B {}');
      final decoded = ToolCallDetail.fromJson(roundTrip(detail.toJson()));
      expect(decoded, isA<WriteDetail>());
      final write = decoded as WriteDetail;
      expect(write.path, 'lib/b.dart');
      expect(write.contentPreview, 'class B {}');
    });

    test('omits null contentPreview from json', () {
      const detail = WriteDetail(path: 'lib/b.dart');
      expect(detail.toJson().containsKey('contentPreview'), isFalse);
    });
  });

  group('SearchDetail', () {
    test('round-trips with path', () {
      const detail = SearchDetail(query: 'TODO', path: 'lib/');
      final decoded = ToolCallDetail.fromJson(roundTrip(detail.toJson()));
      expect(decoded, isA<SearchDetail>());
      final search = decoded as SearchDetail;
      expect(search.query, 'TODO');
      expect(search.path, 'lib/');
    });

    test('omits null path from json', () {
      const detail = SearchDetail(query: 'TODO');
      expect(detail.toJson().containsKey('path'), isFalse);
      final decoded = ToolCallDetail.fromJson(detail.toJson()) as SearchDetail;
      expect(decoded.path, isNull);
    });

    test('fromJson defaults query to empty string', () {
      final decoded = ToolCallDetail.fromJson(const {'kind': 'search'});
      expect((decoded as SearchDetail).query, '');
    });
  });

  group('GenericDetail', () {
    test('round-trips with arbitrary input map', () {
      const detail = GenericDetail(input: {'foo': 'bar', 'n': 1});
      final decoded = ToolCallDetail.fromJson(roundTrip(detail.toJson()));
      expect(decoded, isA<GenericDetail>());
      expect((decoded as GenericDetail).input, {'foo': 'bar', 'n': 1});
    });

    test('unknown kind falls back to GenericDetail', () {
      final decoded = ToolCallDetail.fromJson(
        const {'kind': 'mystery', 'input': {'x': 1}},
      );
      expect(decoded, isA<GenericDetail>());
      expect((decoded as GenericDetail).input, {'x': 1});
    });

    test('missing kind falls back to GenericDetail with empty input', () {
      final decoded = ToolCallDetail.fromJson(const {});
      expect(decoded, isA<GenericDetail>());
      expect((decoded as GenericDetail).input, isEmpty);
    });
  });
}
