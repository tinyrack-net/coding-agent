import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('request round-trips the frozen optional search controls', () {
    const request = DirectorySuggestionsRequest(
      query: 'src/com',
      cwd: 'C:/repo',
      includeFiles: true,
      includeDirectories: false,
      matchMode: DirectorySuggestionMatchMode.suffix,
      limit: 50,
      requestId: 'request-1',
    );

    expect(DirectorySuggestionsRequest.fromJson(request.toJson()).toJson(), {
      'type': 'directory_suggestions_request',
      'query': 'src/com',
      'cwd': 'C:/repo',
      'includeFiles': true,
      'includeDirectories': false,
      'matchMode': 'suffix',
      'limit': 50,
      'requestId': 'request-1',
    });
  });

  test('response defaults missing entries for old-client compatibility', () {
    final response = DirectorySuggestionsResponse.fromJson({
      'type': 'directory_suggestions_response',
      'payload': {
        'directories': ['C:/repo/src'],
        'error': null,
        'requestId': 'request-2',
      },
    });

    expect(response.entries, isEmpty);
    expect(response.directories, ['C:/repo/src']);
    expect(
      DirectorySuggestionsResponse(
        directories: const ['src'],
        entries: const [
          DirectorySuggestionEntry(
            path: 'src/main.dart',
            kind: DirectorySuggestionKind.file,
          ),
        ],
        requestId: 'request-3',
      ).toJson(),
      {
        'type': 'directory_suggestions_response',
        'payload': {
          'directories': ['src'],
          'entries': [
            {'path': 'src/main.dart', 'kind': 'file'},
          ],
          'error': null,
          'requestId': 'request-3',
        },
      },
    );
  });

  test('schemas reject malformed boundaries', () {
    for (final limit in [0, 101, 1.5]) {
      expect(
        () => DirectorySuggestionsRequest.fromJson({
          'type': 'directory_suggestions_request',
          'query': '',
          'limit': limit,
          'requestId': 'r',
        }),
        throwsFormatException,
      );
    }
    expect(
      () => DirectorySuggestionsRequest.fromJson({
        'type': 'directory_suggestions_request',
        'query': '',
        'matchMode': 'future',
        'requestId': 'r',
      }),
      throwsFormatException,
    );
    expect(
      () => DirectorySuggestionsResponse.fromJson({
        'type': 'directory_suggestions_response',
        'payload': {
          'directories': [false],
          'entries': const [],
          'error': null,
          'requestId': 'r',
        },
      }),
      throwsFormatException,
    );
  });
}
