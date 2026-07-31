import 'package:agent_daemon/src/providers/paseo/paseo_omp_runtime.dart';
import 'package:agent_daemon/src/providers/paseo/paseo_provider_mappers.dart';
import 'package:agent_daemon/src/providers/paseo/provider_launch_config.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

/// Upstream's fixture, kept byte-identical so the sha1-derived call id and the
/// first-line label are exercised against the same input.
final _completedNotice = [
  '<system-notice>',
  'Background job DocsSmokeTwo has completed. Resume your work using the '
      'result below.',
  '<task-result id="DocsSmokeTwo" agent="explore" status="completed" '
      'duration="21.6s">',
  '<meta lines="22" size="2.5KB" />',
  '<output>',
  '{"summary":"docs smoke check done"}',
  '</output>',
  '</task-result>',
  '</system-notice>',
  'DocsSmokeTwo is now idle — transcript at history://DocsSmokeTwo',
].join('\n');

Map<String, Object?>? _detail(ToolCallDetail? detail) => detail?.toPaseoJson();

/// Projects a subagent upsert onto a comparable map. Dart value classes have no
/// structural equality, so every assertion goes through JSON-ish shapes.
Map<String, Object?> _upsert(ProviderEvent event) {
  final upserted = event as ProviderSubagentUpserted;
  return {
    'id': upserted.subagentId,
    'title': upserted.title,
    'description': upserted.description,
    'status': upserted.status.name,
    'toolCallId': upserted.toolCallId,
  };
}

Map<String, Object?> _timelineItem(ProviderEvent event) {
  final changed = event as ProviderSubagentTimelineChanged;
  return {
    'id': changed.subagentId,
    'timestamp': changed.timestamp,
    'item': changed.item.toJson(),
  };
}

/// A minimal parent handle. [Expando] rejects strings and numbers, so tests
/// need a real object exactly as upstream's `WeakMap` does.
final class _Parent {}

void main() {
  group('OMP tool argument parsing', () {
    test('parses each simple tool and strips undeclared keys', () {
      final bash = parseOmpToolArgs('bash', {
        'command': 'echo hi',
        'timeout': 30,
        'nope': true,
      });
      expect(bash, isA<OmpBashToolCall>());
      expect((bash as OmpBashToolCall).command, 'echo hi');
      expect(bash.timeout, 30);
      expect(bash.args, {'command': 'echo hi', 'timeout': 30});

      final read = parseOmpToolArgs('read', {
        'path': 'a.txt',
        'offset': 3,
        'limit': 10,
      });
      expect((read as OmpReadToolCall).path, 'a.txt');
      expect(read.offset, 3);
      expect(read.limit, 10);

      final write = parseOmpToolArgs('write', {'path': 'a', 'content': 'b'});
      expect((write as OmpWriteToolCall).content, 'b');

      final find = parseOmpToolArgs('find', {'pattern': '*.dart', 'limit': 5});
      expect((find as OmpFindToolCall).pattern, '*.dart');
      expect(find.path, isNull);

      final grep = parseOmpToolArgs('grep', {
        'pattern': 'todo',
        'glob': '*.md',
        'ignoreCase': true,
        'literal': false,
        'context': 2,
      });
      expect((grep as OmpGrepToolCall).ignoreCase, isTrue);
      expect(grep.literal, isFalse);
      expect(grep.context, 2);

      final ls = parseOmpToolArgs('ls', {'path': 'src'});
      expect((ls as OmpLsToolCall).path, 'src');
    });

    test('falls back to unknown when a declared field has the wrong type', () {
      // `command` is required and must be a string.
      expect(
        parseOmpToolArgs('bash', {'timeout': 1}),
        isA<OmpUnknownToolCall>(),
      );
      // Optional numbers reject an explicit null, matching Zod.
      expect(
        parseOmpToolArgs('read', {'path': 'a', 'offset': null}),
        isA<OmpUnknownToolCall>(),
      );
      expect(
        parseOmpToolArgs('grep', {'pattern': 'x', 'ignoreCase': 'yes'}),
        isA<OmpUnknownToolCall>(),
      );
      // A non-object payload cannot satisfy any object schema.
      final scalar = parseOmpToolArgs('ls', 'nope');
      expect(scalar, isA<OmpUnknownToolCall>());
      expect(scalar.args, 'nope');
      // `ls` has no required fields, so an empty object still parses.
      expect(parseOmpToolArgs('ls', <String, Object?>{}), isA<OmpLsToolCall>());
    });

    test('keeps the raw payload for tools with no schema', () {
      final call = parseOmpToolArgs('task', {'agent': 'explore'});
      expect(call, isA<OmpUnknownToolCall>());
      expect(call.toolName, 'task');
      expect(call.args, {'agent': 'explore'});
      expect(parseOmpToolArgs('lsp', null).args, isNull);
    });

    test('parses the current edit shape and rebuilds its stripped args', () {
      final call = parseOmpToolArgs('edit', {
        'path': 'a.txt',
        'edits': [
          {'oldText': 'one', 'newText': 'two'},
          {'oldText': 'three', 'newText': 'four'},
        ],
        'extra': 1,
      });
      expect(call, isA<OmpEditToolCall>());
      expect((call as OmpEditToolCall).edits, hasLength(2));
      expect(call.args, {
        'path': 'a.txt',
        'edits': [
          {'oldText': 'one', 'newText': 'two'},
          {'oldText': 'three', 'newText': 'four'},
        ],
      });
    });

    test('accepts both legacy edit spellings and normalizes them', () {
      final snake = parseOmpToolArgs('edit', {
        'path': 'a.txt',
        'old_string': 'alpha',
        'new_string': 'beta',
      });
      expect((snake as OmpEditToolCall).edits.single.oldText, 'alpha');
      expect(snake.edits.single.newText, 'beta');

      final camel = parseOmpToolArgs('edit', {
        'path': 'a.txt',
        'oldString': 'alpha',
        'newString': 'beta',
      });
      expect((camel as OmpEditToolCall).edits.single.newText, 'beta');

      // snake_case wins when both spellings are present.
      final both = parseOmpToolArgs('edit', {
        'path': 'a.txt',
        'old_string': 'snake',
        'oldString': 'camel',
        'new_string': 'snake-new',
        'newString': 'camel-new',
      });
      expect((both as OmpEditToolCall).edits.single.oldText, 'snake');
      expect(both.edits.single.newText, 'snake-new');
    });

    test(
      'legacy edit rejects an empty oldText but allows an empty newText',
      () {
        expect(
          parseOmpToolArgs('edit', {
            'path': 'a.txt',
            'old_string': '',
            'new_string': 'x',
          }),
          isA<OmpUnknownToolCall>(),
        );
        final deletion = parseOmpToolArgs('edit', {
          'path': 'a.txt',
          'old_string': 'gone',
          'new_string': '',
        });
        expect((deletion as OmpEditToolCall).edits.single.newText, '');
      },
    );

    test('an unparseable edit keeps the raw args under the edit name', () {
      final call = parseOmpToolArgs('edit', {'input': '*** Begin Patch'});
      expect(call, isA<OmpUnknownToolCall>());
      expect(call.toolName, 'edit');
      expect(call.args, {'input': '*** Begin Patch'});
    });
  });

  group('OMP tool result text extraction', () {
    test('prefers direct fields in output, stdout, text order', () {
      expect(extractOmpToolResultText('raw'), 'raw');
      expect(
        extractOmpToolResultText({'output': 'o', 'stdout': 's', 'text': 't'}),
        'o',
      );
      expect(extractOmpToolResultText({'stdout': 's', 'text': 't'}), 's');
      expect(extractOmpToolResultText({'text': 't'}), 't');
    });

    test('an empty direct field falls through to the content blocks', () {
      expect(
        extractOmpToolResultText({
          'output': '',
          'content': [
            {'type': 'text', 'text': 'from-content'},
          ],
        }),
        'from-content',
      );
    });

    test('joins text blocks with a newline and skips non-text ones', () {
      expect(
        extractOmpToolResultText({
          'content': [
            {'type': 'text', 'text': 'one'},
            {'type': 'image', 'data': 'ignored'},
            {'type': 'text', 'text': 'two'},
          ],
        }),
        'one\ntwo',
      );
    });

    test('reports nothing when there is no text at all', () {
      expect(extractOmpToolResultText(null), isNull);
      expect(extractOmpToolResultText(<String, Object?>{}), isNull);
      expect(extractOmpToolResultText({'content': <Object?>[]}), isNull);
      expect(
        extractOmpToolResultText({
          'content': [
            {'type': 'image'},
          ],
        }),
        isNull,
      );
    });
  });

  group('OMP core tool detail', () {
    test('resolves the shell exit code through exitCode then code', () {
      expect(
        _detail(
          mapOmpCoreToolDetail(parseOmpToolArgs('bash', {'command': 'x'}), {
            'output': 'out',
            'exitCode': 2,
          }),
        ),
        {'type': 'shell', 'command': 'x', 'output': 'out', 'exitCode': 2},
      );
      expect(
        _detail(
          mapOmpCoreToolDetail(parseOmpToolArgs('bash', {'command': 'x'}), {
            'output': 'out',
            'code': 7,
          }),
        ),
        {'type': 'shell', 'command': 'x', 'output': 'out', 'exitCode': 7},
      );
      // A bare string result carries no exit code at all.
      final stringResult =
          mapOmpCoreToolDetail(
                parseOmpToolArgs('bash', {'command': 'x'}),
                'plain',
              )
              as ShellDetail;
      expect(stringResult.output, 'plain');
      expect(stringResult.exitCode, isNull);
    });

    test('maps searches, keeping the ls query fallback and tool labels', () {
      expect(
        _detail(
          mapOmpCoreToolDetail(
            parseOmpToolArgs('find', {'pattern': '*.dart'}),
            'hits',
          ),
        ),
        {
          'type': 'search',
          'query': '*.dart',
          'toolName': 'search',
          'content': 'hits',
        },
      );
      expect(
        _detail(
          mapOmpCoreToolDetail(parseOmpToolArgs('grep', {'pattern': 'todo'})),
        ),
        {'type': 'search', 'query': 'todo', 'toolName': 'grep'},
      );
      // `ls` gets no toolName upstream, and an absent path renders as "ls".
      expect(
        _detail(
          mapOmpCoreToolDetail(parseOmpToolArgs('ls', <String, Object?>{})),
        ),
        {'type': 'search', 'query': 'ls'},
      );
      // Only string results reach a search card; object results are dropped.
      expect(
        _detail(
          mapOmpCoreToolDetail(parseOmpToolArgs('grep', {'pattern': 'todo'}), {
            'output': 'ignored',
          }),
        ),
        {'type': 'search', 'query': 'todo', 'toolName': 'grep'},
      );
    });

    test('uses only the first edit operation on the card', () {
      expect(
        _detail(
          mapOmpCoreToolDetail(
            parseOmpToolArgs('edit', {
              'path': 'a.txt',
              'edits': [
                {'oldText': 'one', 'newText': 'two'},
                {'oldText': 'three', 'newText': 'four'},
              ],
            }),
            {
              'details': <String, Object?>{'diff': '-one\n+two'},
            },
          ),
        ),
        {
          'type': 'edit',
          'filePath': 'a.txt',
          'oldString': 'one',
          'newString': 'two',
          'unifiedDiff': '-one\n+two',
        },
      );
    });

    test('unwraps an xdev execute envelope on a write result', () {
      final result = {
        'output': 'ok',
        'details': {
          'xdev': {
            'tool': '  proxied-tool  ',
            'mode': 'execute',
            'args': {'q': 1},
            'inner': {'rows': 2},
          },
        },
      };
      final call = parseOmpToolArgs('write', {'path': 'a', 'content': 'b'});

      expect(_detail(mapOmpCoreToolDetail(call, result)), {
        'type': 'unknown',
        'input': {'q': 1},
        'output': {
          'output': 'ok',
          'details': {'rows': 2},
        },
      });
      // The card is titled with the proxied tool, trimmed by the schema.
      expect(resolveOmpToolCallName(call, result), 'proxied-tool');
    });

    test('a malformed xdev envelope still suppresses the write card', () {
      final result = {
        'details': {
          'xdev': {'tool': '   ', 'mode': 'execute'},
        },
      };
      final call = parseOmpToolArgs('write', {'path': 'a', 'content': 'b'});

      expect(_detail(mapOmpCoreToolDetail(call, result)), {
        'type': 'unknown',
        'input': {'path': 'a', 'content': 'b'},
        'output': result,
      });
      expect(resolveOmpToolCallName(call, result), 'write');
      expect(resolveOmpToolCallName(call), 'write');
    });

    test('a non-map xdev args payload is wrapped for the generic detail', () {
      final detail =
          mapOmpCoreToolDetail(
                parseOmpToolArgs('write', {'path': 'a', 'content': 'b'}),
                {
                  'details': {
                    'xdev': {'tool': 't', 'mode': 'execute', 'args': 'scalar'},
                  },
                },
              )
              as GenericDetail;
      expect(detail.input, {'value': 'scalar'});
    });
  });

  group('OMP tool call mapper', () {
    test('maps OMP bash, read, hashline edit, and write calls', () {
      final bash = mapOmpToolDetail(
        parseOmpToolArgs('bash', {'command': 'echo hi'}),
        parseOmpToolResult({
          'content': [
            {'type': 'text', 'text': 'hi\n\n\nWall time: 0.02 seconds'},
          ],
        }),
      );
      expect(_detail(bash), {
        'type': 'shell',
        'command': 'echo hi',
        'output': 'hi\n\n\nWall time: 0.02 seconds',
      });
      expect((bash as ShellDetail).exitCode, isNull);

      expect(
        _detail(
          mapOmpToolDetail(
            parseOmpToolArgs('read', {'path': 'fixture.txt'}),
            parseOmpToolResult({
              'content': [
                {
                  'type': 'text',
                  'text': '[fixture.txt#0063]\n1:alpha\n2:beta\n3:',
                },
              ],
              'details': {
                'displayContent': {'text': 'alpha\nbeta\n'},
              },
            }),
          ),
        ),
        {'type': 'read', 'filePath': 'fixture.txt', 'content': 'alpha\nbeta\n'},
      );

      expect(
        _detail(
          mapOmpToolDetail(
            parseOmpToolArgs('edit', {
              'input':
                  '*** Begin Patch\n[fixture.txt#0063]\nSWAP 2.=2:\n+gamma\n'
                  '*** End Patch\n',
            }),
            parseOmpToolResult({
              'content': <Object?>[],
              'details': {
                'path': 'fixture.txt',
                'oldText': 'alpha\nbeta\n',
                'newText': 'alpha\ngamma\n',
                'diff': ' 1|alpha\n-2|beta\n+2|gamma',
              },
            }),
          ),
        ),
        {
          'type': 'edit',
          'filePath': 'fixture.txt',
          'oldString': 'alpha\nbeta\n',
          'newString': 'alpha\ngamma\n',
          'unifiedDiff': ' 1|alpha\n-2|beta\n+2|gamma',
        },
      );

      expect(
        _detail(
          mapOmpToolDetail(
            parseOmpToolArgs('write', {
              'path': 'created.txt',
              'content': 'hello write',
            }),
            null,
          ),
        ),
        {'type': 'write', 'filePath': 'created.txt', 'content': 'hello write'},
      );
    });

    test('maps task to sub-agent detail and suppresses todo raw cards', () {
      expect(
        _detail(
          mapOmpToolDetail(
            parseOmpToolArgs('task', {
              'agent': 'explore',
              'description': 'Inspect the target files',
            }),
            null,
          ),
        ),
        {
          'type': 'sub_agent',
          'subAgentType': 'explore',
          'description': 'Inspect the target files',
          'log': '',
        },
      );
      expect(
        mapOmpToolDetail(parseOmpToolArgs('todo', {'op': 'view'}), null),
        isNull,
      );
    });

    test('uses task result text and transcript path as the best static replay '
        'detail', () {
      expect(
        _detail(
          mapOmpToolDetail(
            parseOmpToolArgs('task', {
              'agent': 'explore',
              'description': 'Inspect the target files',
            }),
            parseOmpToolResult({
              'content': [
                {
                  'type': 'text',
                  'text':
                      'done\ntranscript: /tmp/omp-task-static/Explore.jsonl',
                },
              ],
            }),
          ),
        ),
        {
          'type': 'sub_agent',
          'subAgentType': 'explore',
          'description': 'Inspect the target files',
          'childSessionId': '/tmp/omp-task-static/Explore.jsonl',
          'log': 'done\ntranscript: /tmp/omp-task-static/Explore.jsonl',
        },
      );
    });

    test('falls back to shared unknown detail for unmapped tools', () {
      expect(
        _detail(
          mapOmpToolDetail(parseOmpToolArgs('lsp', {'op': 'hover'}), null),
        ),
        {
          'type': 'unknown',
          'input': {'op': 'hover'},
          'output': null,
        },
      );
    });

    test(
      'task detail walks every alias for the agent type and description',
      () {
        final detail =
            mapOmpToolDetail(
                  parseOmpToolArgs('task', {
                    'agent': '   ',
                    'subAgentType': '',
                    'agentType': 'fallback-agent',
                    'task': 'fallback task',
                  }),
                  null,
                )
                as SubAgentDetail;
        expect(detail.subAgentType, 'fallback-agent');
        expect(detail.description, 'fallback task');

        final none =
            mapOmpToolDetail(parseOmpToolArgs('task', 'not-an-object'), null)
                as SubAgentDetail;
        expect(none.subAgentType, isNull);
        expect(none.description, isNull);
        expect(none.log, '');
      },
    );

    test('task detail prefers the declared session file over the transcript '
        'regex', () {
      final detail =
          mapOmpToolDetail(parseOmpToolArgs('task', {'agent': 'explore'}), {
                'output': 'transcript: /tmp/from-text.jsonl',
                'details': {'sessionFile': '/tmp/from-details.jsonl'},
              })
              as SubAgentDetail;
      expect(detail.childSessionId, '/tmp/from-details.jsonl');

      final snake =
          mapOmpToolDetail(parseOmpToolArgs('task', {'agent': 'explore'}), {
                'details': {'session_file': '/tmp/snake.jsonl'},
              })
              as SubAgentDetail;
      expect(snake.childSessionId, '/tmp/snake.jsonl');
    });

    test('the transcript regex only accepts an absolute .jsonl path', () {
      SubAgentDetail detailFor(String text) =>
          mapOmpToolDetail(parseOmpToolArgs('task', {'agent': 'a'}), {
                'output': text,
              })
              as SubAgentDetail;

      expect(
        detailFor('Session File: /tmp/Case.jsonl').childSessionId,
        '/tmp/Case.jsonl',
      );
      expect(detailFor('session: relative/path.jsonl').childSessionId, isNull);
      expect(detailFor('session: /tmp/path.txt').childSessionId, isNull);
      expect(detailFor('no transcript here').childSessionId, isNull);
    });

    test('the subagent hook may replace the task card', () {
      const replacement = PlainTextDetail(label: 'live', text: 'child running');
      final detail = mapOmpToolDetail(
        parseOmpToolArgs('task', {'agent': 'explore'}),
        null,
        context: OmpToolDetailContext(
          toolCallId: 'call-1',
          mapSubagentDetail: (base) {
            expect(base, isA<SubAgentDetail>());
            return replacement;
          },
        ),
      );
      expect(identical(detail, replacement), isTrue);
    });

    test('the subagent hook is never consulted for non-task tools', () {
      var invoked = false;
      mapOmpToolDetail(
        parseOmpToolArgs('bash', {'command': 'x'}),
        null,
        context: OmpToolDetailContext(
          toolCallId: 'call-1',
          mapSubagentDetail: (base) {
            invoked = true;
            return base;
          },
        ),
      );
      expect(invoked, isFalse);
    });

    test('edit recovers the path from the patch header when the result has '
        'none', () {
      expect(
        _detail(
          mapOmpToolDetail(
            parseOmpToolArgs('edit', {
              'input': '*** Begin Patch\n[from-header.txt#0063]\nSWAP 1.=1:\n',
            }),
            parseOmpToolResult({'details': <String, Object?>{}}),
          ),
        ),
        {'type': 'edit', 'filePath': 'from-header.txt'},
      );
    });

    test(
      'edit falls back to the shared card when no path can be recovered',
      () {
        // A parsed edit exposes only `{path, edits}`, so the patch-header
        // recovery cannot fire and the shared card wins.
        expect(
          _detail(
            mapOmpToolDetail(
              parseOmpToolArgs('edit', {
                'path': 'schema.txt',
                'edits': [
                  {'oldText': 'a', 'newText': 'b'},
                ],
              }),
              null,
            ),
          ),
          {
            'type': 'edit',
            'filePath': 'schema.txt',
            'oldString': 'a',
            'newString': 'b',
          },
        );
        // An unparseable edit with no header at all keeps the generic card.
        expect(
          _detail(
            mapOmpToolDetail(
              parseOmpToolArgs('edit', {'input': 'no header here'}),
              null,
            ),
          ),
          {
            'type': 'unknown',
            'input': {'input': 'no header here'},
            'output': null,
          },
        );
      },
    );

    test('edit prefers details.path over details.filePath', () {
      final detail =
          mapOmpToolDetail(parseOmpToolArgs('edit', {'input': 'x'}), {
                'details': {'path': 'primary.txt', 'filePath': 'secondary.txt'},
              })
              as EditDetail;
      expect(detail.path, 'primary.txt');

      final camel =
          mapOmpToolDetail(parseOmpToolArgs('edit', {'input': 'x'}), {
                'details': {
                  'filePath': 'secondary.txt',
                  'old_string': 'legacy-old',
                  'new_string': 'legacy-new',
                },
              })
              as EditDetail;
      expect(camel.path, 'secondary.txt');
      expect(camel.oldString, 'legacy-old');
      expect(camel.newString, 'legacy-new');
    });

    test('read keeps the raw card when displayContent is missing or blank', () {
      expect(
        _detail(
          mapOmpToolDetail(
            parseOmpToolArgs('read', {
              'path': 'a.txt',
              'offset': 5,
              'limit': 9,
            }),
            parseOmpToolResult({'output': '1:alpha'}),
          ),
        ),
        {
          'type': 'read',
          'filePath': 'a.txt',
          'content': '1:alpha',
          'offset': 5,
          'limit': 9,
        },
      );
      expect(
        _detail(
          mapOmpToolDetail(parseOmpToolArgs('read', {'path': 'a.txt'}), {
            'output': '1:alpha',
            'details': {
              'displayContent': {'text': '   '},
            },
          }),
        ),
        {'type': 'read', 'filePath': 'a.txt', 'content': '1:alpha'},
      );
    });

    test('read that failed argument validation never reaches the read '
        'override', () {
      // Without a `path` the call is unknown, so `fallback.type !== "read"`
      // short-circuits and the display content is ignored.
      expect(
        _detail(
          mapOmpToolDetail(parseOmpToolArgs('read', {'paths': 'a.txt'}), {
            'details': {
              'displayContent': {'text': 'ignored'},
            },
          }),
        ),
        {
          'type': 'unknown',
          'input': {'paths': 'a.txt'},
          'output': {
            'details': {
              'displayContent': {'text': 'ignored'},
            },
          },
        },
      );
    });
  });

  group('OMP system notice detection', () {
    test('detects messages that start with the system-notice tag', () {
      expect(isOmpSystemNotice(_completedNotice), isTrue);
      expect(
        isOmpSystemNotice('  \n<system-notice>plain</system-notice>'),
        isTrue,
      );
    });

    test('ignores regular prompts, including ones that mention the tag '
        'mid-message', () {
      expect(isOmpSystemNotice('please fix the bug'), isFalse);
      expect(
        isOmpSystemNotice('what does <system-notice> mean in omp?'),
        isFalse,
      );
      expect(
        mapOmpSystemNoticeToToolCall('what does <system-notice> mean in omp?'),
        isNull,
      );
    });
  });

  group('OMP system notice tool call mapping', () {
    test('maps a completed task-result notice to a synthetic completed tool '
        'call', () {
      final item = mapOmpSystemNoticeToToolCall(_completedNotice)!;
      expect(item.id, 'omp-notice:DocsSmokeTwo');
      expect(item.toolName, 'task_notification');
      expect(item.status, ToolCallStatus.success);
      expect(item.errorMessage, isNull);
      expect(_detail(item.detail), {
        'type': 'plain_text',
        'label': 'Background job DocsSmokeTwo completed',
        'text': _completedNotice,
        'icon': 'wrench',
      });
      expect(item.metadata, {
        'synthetic': true,
        'source': 'omp_system_notice',
        'taskId': 'DocsSmokeTwo',
        'subagentType': 'explore',
        'status': 'completed',
      });
    });

    test('maps a failed task-result notice to a failed tool call', () {
      final notice = [
        '<system-notice>',
        'Background job RepoSmokeOne has failed.',
        '<task-result id="RepoSmokeOne" agent="explore" status="failed" '
            'duration="3s">',
        '<output>boom</output>',
        '</task-result>',
        '</system-notice>',
      ].join('\n');

      final item = mapOmpSystemNoticeToToolCall(notice)!;
      expect(item.id, 'omp-notice:RepoSmokeOne');
      expect(item.status, ToolCallStatus.error);
      expect(item.errorMessage, 'Background job RepoSmokeOne failed');
    });

    test('maps a canceled task-result notice without an error message', () {
      final notice = [
        '<system-notice>',
        'Background job StoppedOne was stopped.',
        '<task-result id="StoppedOne" agent="explore" status="stopped">',
        '</task-result>',
        '</system-notice>',
      ].join('\n');

      final item = mapOmpSystemNoticeToToolCall(notice)!;
      expect(item.status, ToolCallStatus.canceled);
      expect(item.errorMessage, isNull);
      expect(item.metadata['status'], 'stopped');
    });

    test('parses task-result attributes with typographic quotes', () {
      final notice = [
        '<system-notice>',
        'Background job DocsSmokeTwo has completed.',
        '<task-result id=“DocsSmokeTwo” agent=“explore” '
            'status=“completed” duration=“21.6s”>',
        '<output>ok</output>',
        '</task-result>',
        '</system-notice>',
      ].join('\n');

      final item = mapOmpSystemNoticeToToolCall(notice)!;
      expect(item.id, 'omp-notice:DocsSmokeTwo');
      expect(item.status, ToolCallStatus.success);
      expect(item.metadata['taskId'], 'DocsSmokeTwo');
      expect(item.metadata['subagentType'], 'explore');
    });

    test('maps a notice without a task-result using its first line and a '
        'stable hash id', () {
      const notice =
          '<system-notice>\nThe daemon rotated its logs.\n</system-notice>';

      final first = mapOmpSystemNoticeToToolCall(notice)!;
      final second = mapOmpSystemNoticeToToolCall(notice)!;
      expect(first.id, second.id);
      expect(first.status, ToolCallStatus.success);
      expect(_detail(first.detail), {
        'type': 'plain_text',
        'label': 'The daemon rotated its logs.',
        'text': notice,
        'icon': 'wrench',
      });
      expect(first.id, matches(RegExp(r'^omp-notice:[0-9a-f]{12}$')));
      // No task-result means no task metadata to carry.
      expect(first.metadata, {
        'synthetic': true,
        'source': 'omp_system_notice',
      });
    });

    test('a notice whose body is all tags falls back to the generic label', () {
      const notice = '<system-notice>\n<meta lines="0" />\n</system-notice>';
      expect(
        (mapOmpSystemNoticeToToolCall(notice)!.detail as PlainTextDetail).label,
        'System notice',
      );
    });
  });

  group('buildOmpLaunch', () {
    test('appends the default rpc mode to the provider command', () {
      final launch = buildOmpLaunch(
        command: const ['omp'],
        session: const OmpStartSessionInput(cwd: '/work'),
      );
      expect(launch.cwd, '/work');
      expect(launch.argv, ['omp', '--mode', 'rpc']);
      expect(launch.protocolMode, OmpProtocolMode.rpc);
      expect(launch.env, isNull);
      expect(launch.systemPrompt, isNull);
    });

    test('emits every flag in upstream order', () {
      final launch = buildOmpLaunch(
        command: const ['omp', '--color'],
        session: const OmpStartSessionInput(
          cwd: '/work',
          protocolMode: OmpProtocolMode.rpcUi,
          extraArgs: ['--raw', 'value'],
          model: 'gpt-5.5',
          thinkingOptionId: 'high',
          session: 'sess-1',
          systemPrompt: '  be terse  ',
        ),
      );
      expect(launch.argv, [
        'omp',
        '--color',
        '--mode',
        'rpc-ui',
        '--raw',
        'value',
        '--model',
        'gpt-5.5',
        '--thinking',
        'high',
        '--session',
        'sess-1',
        '--append-system-prompt',
        'be terse',
      ]);
      expect(launch.protocolMode, OmpProtocolMode.rpcUi);
      expect(launch.systemPrompt, 'be terse');
      expect(launch.extraArgs, ['--raw', 'value']);
    });

    test('noSession wins over a resumable session id', () {
      final launch = buildOmpLaunch(
        command: const ['omp'],
        session: const OmpStartSessionInput(
          cwd: '/work',
          session: 'sess-1',
          noSession: true,
        ),
      );
      expect(launch.argv, ['omp', '--mode', 'rpc', '--no-session']);
      expect(launch.noSession, isTrue);
      expect(launch.session, 'sess-1');
    });

    test('skips flags whose value is blank', () {
      final launch = buildOmpLaunch(
        command: const ['omp'],
        session: const OmpStartSessionInput(
          cwd: '/work',
          model: '',
          thinkingOptionId: '',
          session: '',
          systemPrompt: '   ',
          extraArgs: [],
          noSession: false,
        ),
      );
      expect(launch.argv, ['omp', '--mode', 'rpc']);
      // The trimmed prompt is still recorded, it just produces no flag.
      expect(launch.systemPrompt, '');
    });

    test('respects a mode flag the caller already pinned', () {
      expect(
        buildOmpLaunch(
          command: const ['omp', '--mode', 'rpc-ui'],
          session: const OmpStartSessionInput(cwd: '/work'),
        ).argv,
        ['omp', '--mode', 'rpc-ui'],
      );
      expect(
        buildOmpLaunch(
          command: const ['omp', '--mode=rpc-ui'],
          session: const OmpStartSessionInput(
            cwd: '/work',
            protocolMode: OmpProtocolMode.rpc,
          ),
        ).argv,
        ['omp', '--mode=rpc-ui'],
      );
      // A pinned mode does not rewrite the reported protocol mode.
      expect(
        buildOmpLaunch(
          command: const ['omp', '--mode', 'rpc-ui'],
          session: const OmpStartSessionInput(cwd: '/work'),
        ).protocolMode,
        OmpProtocolMode.rpc,
      );
      // `extraArgs` are appended after the mode check has already run, so a
      // mode pinned there is additive rather than suppressing.
      expect(
        buildOmpLaunch(
          command: const ['omp'],
          session: const OmpStartSessionInput(
            cwd: '/work',
            extraArgs: ['--mode', 'rpc-ui'],
          ),
        ).argv,
        ['omp', '--mode', 'rpc', '--mode', 'rpc-ui'],
      );
    });

    test('a replace override takes over the executable', () {
      expect(
        buildOmpLaunch(
          command: const ['omp'],
          runtimeSettings: const ProviderRuntimeSettings(
            command: ProviderCommand.replace(['custom-omp', '--dev']),
          ),
          session: const OmpStartSessionInput(cwd: '/work'),
        ).argv,
        ['custom-omp', '--dev', '--mode', 'rpc'],
      );
    });

    test('a replace override without a usable executable is discarded', () {
      expect(
        buildOmpLaunch(
          command: const ['omp'],
          runtimeSettings: const ProviderRuntimeSettings(
            command: ProviderCommand.replace(['']),
          ),
          session: const OmpStartSessionInput(cwd: '/work'),
        ).argv,
        ['omp', '--mode', 'rpc'],
      );
      expect(
        buildOmpLaunch(
          command: const ['omp'],
          runtimeSettings: const ProviderRuntimeSettings(
            command: ProviderCommand.replace([]),
          ),
          session: const OmpStartSessionInput(cwd: '/work'),
        ).argv,
        ['omp', '--mode', 'rpc'],
      );
    });

    test('non-replace override modes leave the default command alone', () {
      expect(
        buildOmpLaunch(
          command: const ['omp'],
          runtimeSettings: const ProviderRuntimeSettings(
            command: ProviderCommand.append(['--verbose']),
          ),
          session: const OmpStartSessionInput(cwd: '/work'),
        ).argv,
        ['omp', '--mode', 'rpc'],
      );
    });

    test('merges the override environment under the session environment', () {
      expect(
        buildOmpLaunch(
          command: const ['omp'],
          runtimeSettings: const ProviderRuntimeSettings(
            environment: {'SHARED': 'from-settings', 'ONLY_SETTINGS': '1'},
          ),
          session: const OmpStartSessionInput(
            cwd: '/work',
            env: {'SHARED': 'from-session', 'ONLY_SESSION': '2'},
          ),
        ).env,
        {'SHARED': 'from-session', 'ONLY_SETTINGS': '1', 'ONLY_SESSION': '2'},
      );
      // An explicitly empty session environment is still an environment.
      expect(
        buildOmpLaunch(
          command: const ['omp'],
          session: const OmpStartSessionInput(cwd: '/work', env: {}),
        ).env,
        isEmpty,
      );
      expect(
        buildOmpLaunch(
          command: const ['omp'],
          runtimeSettings: const ProviderRuntimeSettings(),
          session: const OmpStartSessionInput(cwd: '/work'),
        ).env,
        isNull,
      );
    });

    test('echoes the fields that are applied over RPC rather than argv', () {
      final launch = buildOmpLaunch(
        command: const ['omp'],
        session: const OmpStartSessionInput(cwd: '/work', modeId: 'plan'),
      );
      expect(launch.modeId, 'plan');
      expect(launch.argv, ['omp', '--mode', 'rpc']);
    });
  });

  group('subscribeOmpSubagentEvents', () {
    test('stops at the events level when the provider accepts it', () async {
      final requested = <OmpSubagentSubscriptionLevel>[];
      final attempted = await subscribeOmpSubagentEvents(
        setLevel: (level) async => requested.add(level),
      );
      expect(attempted, [OmpSubagentSubscriptionLevel.events]);
      expect(requested, [OmpSubagentSubscriptionLevel.events]);
    });

    test('falls back to progress when the event subscription is '
        'unavailable', () async {
      final failures = <String>[];
      final attempted = await subscribeOmpSubagentEvents(
        setLevel: (level) async {
          if (level == OmpSubagentSubscriptionLevel.events) {
            throw StateError('events unsupported');
          }
        },
        onError: (level, error) => failures.add('${level.wireName}: $error'),
      );
      expect(attempted.map((level) => level.wireName), ['events', 'progress']);
      expect(failures, hasLength(1));
      expect(failures.single, contains('events: '));
    });

    test('swallows a failing progress downgrade too', () async {
      final failures = <OmpSubagentSubscriptionLevel>[];
      final attempted = await subscribeOmpSubagentEvents(
        setLevel: (level) async => throw StateError('nope'),
        onError: (level, error) => failures.add(level),
      );
      expect(attempted, [
        OmpSubagentSubscriptionLevel.events,
        OmpSubagentSubscriptionLevel.progress,
      ]);
      expect(failures, [
        OmpSubagentSubscriptionLevel.events,
        OmpSubagentSubscriptionLevel.progress,
      ]);
    });
  });

  group('OMP subagent title', () {
    test('flips provider/model and falls back for unusable inputs', () {
      expect(formatOmpSubagentTitle('explore'), 'explore');
      expect(formatOmpSubagentTitle('  '), 'OMP subagent');
      expect(
        formatOmpSubagentTitle('explore', 'anthropic/claude-sonnet-5'),
        'explore · claude-sonnet-5 (anthropic)',
      );
      expect(formatOmpSubagentTitle('explore', '  '), 'explore');
      // No slash, leading slash, or trailing slash: appended verbatim.
      expect(formatOmpSubagentTitle('explore', 'gpt-5.5'), 'explore · gpt-5.5');
      expect(formatOmpSubagentTitle('explore', '/model'), 'explore · /model');
      expect(
        formatOmpSubagentTitle('explore', 'provider/'),
        'explore · provider/',
      );
      // Only the first slash separates; the rest belongs to the model name.
      expect(formatOmpSubagentTitle('explore', 'a/b/c'), 'explore · b/c (a)');
    });
  });

  group('OMP provider subagent mapper', () {
    test('maps lifecycle and progress frames to stable provider_subagent '
        'descriptors', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();

      expect(
        index
            .handleLifecycle(
              parent,
              const OmpSubagentLifecyclePayload(
                id: 'child-1',
                agent: 'explore',
                description: 'Inspect files',
                status: OmpSubagentLifecycleStatus.started,
                parentToolCallId: 'task-1',
              ),
            )
            .map(_upsert),
        [
          {
            'id': 'child-1',
            'title': 'explore',
            'description': 'Inspect files',
            'status': 'running',
            'toolCallId': 'task-1',
          },
        ],
      );

      expect(
        _upsert(
          index
              .handleProgress(
                parent,
                const OmpSubagentProgressPayload(
                  agent: 'explore',
                  parentToolCallId: 'task-1',
                  progress: OmpSubagentProgress(
                    id: 'child-1',
                    status: OmpSubagentProgressStatus.running,
                    resolvedModel: 'openai-codex/gpt-5.5',
                  ),
                ),
              )
              .single,
        ),
        {
          'id': 'child-1',
          'title': 'explore · gpt-5.5 (openai-codex)',
          // Carried over from the lifecycle frame.
          'description': 'Inspect files',
          'status': 'running',
          'toolCallId': 'task-1',
        },
      );

      expect(
        _upsert(
          index
              .handleProgress(
                parent,
                const OmpSubagentProgressPayload(
                  agent: 'explore',
                  parentToolCallId: 'task-1',
                  progress: OmpSubagentProgress(
                    id: 'child-1',
                    status: OmpSubagentProgressStatus.completed,
                    resolvedModel: 'anthropic/claude-sonnet-5',
                  ),
                ),
              )
              .single,
        ),
        {
          'id': 'child-1',
          'title': 'explore · claude-sonnet-5 (anthropic)',
          'description': 'Inspect files',
          'status': 'completed',
          'toolCallId': 'task-1',
        },
      );
    });

    test('maps child message events onto the descriptor timeline', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();

      expect(
        index
            .handleEvent(
              parent,
              const OmpSubagentEventPayload(
                id: 'child-1',
                event: {
                  'type': 'message_end',
                  'message': {
                    'role': 'assistant',
                    'content': [
                      {'type': 'text', 'text': 'Child answer'},
                    ],
                  },
                },
              ),
            )
            .map(_timelineItem),
        [
          {
            'id': 'child-1',
            'timestamp': null,
            'item': {
              'id': 'omp-history-assistant-1',
              'kind': 'assistant_message',
              'text': 'Child answer',
              'complete': true,
            },
          },
        ],
      );
    });

    test('maps aborted lifecycle status to canceled', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();
      expect(
        _upsert(
          index
              .handleLifecycle(
                parent,
                const OmpSubagentLifecyclePayload(
                  id: 'child-1',
                  agent: 'task',
                  status: OmpSubagentLifecycleStatus.aborted,
                ),
              )
              .single,
        ),
        {
          'id': 'child-1',
          'title': 'task',
          'description': null,
          'status': 'canceled',
          'toolCallId': null,
        },
      );
    });

    test('maps the remaining lifecycle and progress statuses', () {
      ProviderSubagentStatus lifecycle(OmpSubagentLifecycleStatus status) =>
          (OmpSubagentIndex()
                      .handleLifecycle(
                        _Parent(),
                        OmpSubagentLifecyclePayload(
                          id: 'c',
                          agent: 'a',
                          status: status,
                        ),
                      )
                      .single
                  as ProviderSubagentUpserted)
              .status;
      expect(
        lifecycle(OmpSubagentLifecycleStatus.completed),
        ProviderSubagentStatus.completed,
      );
      expect(
        lifecycle(OmpSubagentLifecycleStatus.failed),
        ProviderSubagentStatus.failed,
      );

      ProviderSubagentStatus progress(OmpSubagentProgressStatus status) =>
          (OmpSubagentIndex()
                      .handleProgress(
                        _Parent(),
                        OmpSubagentProgressPayload(
                          agent: 'a',
                          progress: OmpSubagentProgress(
                            id: 'c',
                            status: status,
                          ),
                        ),
                      )
                      .single
                  as ProviderSubagentUpserted)
              .status;
      expect(
        progress(OmpSubagentProgressStatus.pending),
        ProviderSubagentStatus.running,
      );
      expect(
        progress(OmpSubagentProgressStatus.failed),
        ProviderSubagentStatus.failed,
      );
      expect(
        progress(OmpSubagentProgressStatus.aborted),
        ProviderSubagentStatus.canceled,
      );
    });

    test('a blank agent keeps the previously known title', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();
      index.handleLifecycle(
        parent,
        const OmpSubagentLifecyclePayload(
          id: 'child-1',
          agent: 'explore',
          status: OmpSubagentLifecycleStatus.started,
        ),
      );
      expect(
        _upsert(
          index
              .handleLifecycle(
                parent,
                const OmpSubagentLifecyclePayload(
                  id: 'child-1',
                  agent: '',
                  status: OmpSubagentLifecycleStatus.completed,
                ),
              )
              .single,
        )['title'],
        'explore',
      );
    });

    test('a blank resolvedModel never clears one already resolved', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();
      index.handleProgress(
        parent,
        const OmpSubagentProgressPayload(
          agent: 'explore',
          progress: OmpSubagentProgress(
            id: 'child-1',
            status: OmpSubagentProgressStatus.running,
            resolvedModel: 'anthropic/claude-sonnet-5',
          ),
        ),
      );
      expect(
        _upsert(
          index
              .handleProgress(
                parent,
                const OmpSubagentProgressPayload(
                  agent: 'explore',
                  progress: OmpSubagentProgress(
                    id: 'child-1',
                    status: OmpSubagentProgressStatus.running,
                    resolvedModel: '   ',
                  ),
                ),
              )
              .single,
        )['title'],
        'explore · claude-sonnet-5 (anthropic)',
      );
    });

    test('the description falls through progress, assignment, then memory', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();

      expect(
        _upsert(
          index
              .handleProgress(
                parent,
                const OmpSubagentProgressPayload(
                  agent: 'explore',
                  assignment: 'from assignment',
                  progress: OmpSubagentProgress(
                    id: 'child-1',
                    status: OmpSubagentProgressStatus.running,
                  ),
                ),
              )
              .single,
        )['description'],
        'from assignment',
      );
      expect(
        _upsert(
          index
              .handleProgress(
                parent,
                const OmpSubagentProgressPayload(
                  agent: 'explore',
                  assignment: 'ignored',
                  progress: OmpSubagentProgress(
                    id: 'child-1',
                    status: OmpSubagentProgressStatus.running,
                    description: 'from progress',
                  ),
                ),
              )
              .single,
        )['description'],
        'from progress',
      );
      // Neither source present: the remembered description survives.
      expect(
        _upsert(
          index
              .handleProgress(
                parent,
                const OmpSubagentProgressPayload(
                  agent: 'explore',
                  progress: OmpSubagentProgress(
                    id: 'child-1',
                    status: OmpSubagentProgressStatus.completed,
                  ),
                ),
              )
              .single,
        )['description'],
        'from progress',
      );
    });

    test('ignores every child session event other than message_end', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();
      for (final event in const [
        <String, Object?>{'type': 'turn_start'},
        {
          'type': 'message_start',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'partial'},
            ],
          },
        },
        {'type': 'message_end'},
        {'type': 'message_end', 'message': 'not-an-object'},
      ]) {
        expect(
          index.handleEvent(
            parent,
            OmpSubagentEventPayload(id: 'child-1', event: event),
          ),
          isEmpty,
        );
      }
    });

    test('the default mapper numbers assistant messages per child and honours '
        'responseId', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();

      List<Map<String, Object?>> emit(
        String id,
        Map<String, Object?> message,
      ) => index
          .handleEvent(
            parent,
            OmpSubagentEventPayload(
              id: id,
              event: {'type': 'message_end', 'message': message},
            ),
          )
          .map((event) => _timelineItem(event)['item']!)
          .cast<Map<String, Object?>>()
          .toList();

      expect(
        emit('child-1', {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'first'},
          ],
        }).single['id'],
        'omp-history-assistant-1',
      );
      expect(
        emit('child-1', {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'second'},
          ],
        }).single['id'],
        'omp-history-assistant-2',
      );
      // A sibling child gets its own mapper, so numbering restarts.
      expect(
        emit('child-2', {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'sibling'},
          ],
        }).single['id'],
        'omp-history-assistant-1',
      );
      // A provider-supplied response id wins over the synthetic one.
      expect(
        emit('child-2', {
          'role': 'assistant',
          'responseId': 'resp-9',
          'content': [
            {'type': 'text', 'text': 'named'},
          ],
        }).single['id'],
        'resp-9',
      );
    });

    test('the default mapper emits reasoning items and drops empty blocks', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();
      final items = index
          .handleEvent(
            parent,
            const OmpSubagentEventPayload(
              id: 'child-1',
              event: {
                'type': 'message_end',
                'message': {
                  'role': 'assistant',
                  'content': [
                    {'type': 'thinking', 'thinking': 'pondering'},
                    {'type': 'text', 'text': ''},
                    {'type': 'text', 'text': 'answer'},
                    {'type': 'toolCall', 'name': 'bash', 'id': 'call-1'},
                  ],
                },
              },
            ),
          )
          .map((event) => _timelineItem(event)['item']!)
          .cast<Map<String, Object?>>()
          .toList();

      expect(items, [
        {
          'id': 'omp-history-assistant-1-thinking-1',
          'kind': 'reasoning',
          'text': 'pondering',
          'complete': true,
        },
        {
          'id': 'omp-history-assistant-1',
          'kind': 'assistant_message',
          'text': 'answer',
          'complete': true,
        },
      ]);
    });

    test('the default mapper ignores non-assistant roles', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();
      expect(
        index.handleEvent(
          parent,
          const OmpSubagentEventPayload(
            id: 'child-1',
            event: {
              'type': 'message_end',
              'message': {'role': 'user', 'content': 'hello'},
            },
          ),
        ),
        isEmpty,
      );
    });

    test('an injected mapper replaces the default entirely', () {
      final index = OmpSubagentIndex(
        timelineMapperFactory: _CountingTimelineMapper.new,
      );
      final parent = _Parent();
      final items = index
          .handleEvent(
            parent,
            const OmpSubagentEventPayload(
              id: 'child-1',
              event: {
                'type': 'message_end',
                'message': {'role': 'user', 'content': 'hello'},
              },
            ),
          )
          .map((event) => _timelineItem(event)['item']!)
          .cast<Map<String, Object?>>()
          .toList();
      expect(items.single['id'], 'injected-1');
    });

    test('terminalizes only the running children, in announcement order', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();
      index.handleLifecycle(
        parent,
        const OmpSubagentLifecyclePayload(
          id: 'child-1',
          agent: 'explore',
          status: OmpSubagentLifecycleStatus.started,
        ),
      );
      index.handleLifecycle(
        parent,
        const OmpSubagentLifecyclePayload(
          id: 'child-2',
          agent: 'plan',
          status: OmpSubagentLifecycleStatus.completed,
        ),
      );
      index.handleLifecycle(
        parent,
        const OmpSubagentLifecyclePayload(
          id: 'child-3',
          agent: 'review',
          status: OmpSubagentLifecycleStatus.started,
        ),
      );

      expect(
        index.terminalizeRunning(parent).map((event) => _upsert(event)['id']),
        ['child-1', 'child-3'],
      );
      // Idempotent: the children are no longer running.
      expect(index.terminalizeRunning(parent), isEmpty);
      // An unknown parent has nothing to terminalize.
      expect(index.terminalizeRunning(_Parent()), isEmpty);
    });

    test('clear drops the parent state without emitting anything', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();
      index.handleLifecycle(
        parent,
        const OmpSubagentLifecyclePayload(
          id: 'child-1',
          agent: 'explore',
          status: OmpSubagentLifecycleStatus.started,
        ),
      );
      index.clear(parent);
      expect(index.terminalizeRunning(parent), isEmpty);

      // A fresh lifecycle frame for the same id starts from scratch: the
      // description that was never re-sent is gone.
      expect(
        _upsert(
          index
              .handleLifecycle(
                parent,
                const OmpSubagentLifecyclePayload(
                  id: 'child-1',
                  agent: 'explore',
                  status: OmpSubagentLifecycleStatus.started,
                ),
              )
              .single,
        )['description'],
        isNull,
      );
    });

    test('keeps each parent session isolated', () {
      final index = OmpSubagentIndex();
      final first = _Parent();
      final second = _Parent();

      index.handleLifecycle(
        first,
        const OmpSubagentLifecyclePayload(
          id: 'child-1',
          agent: 'explore',
          description: 'first parent',
          status: OmpSubagentLifecycleStatus.started,
        ),
      );
      expect(
        _upsert(
          index
              .handleLifecycle(
                second,
                const OmpSubagentLifecyclePayload(
                  id: 'child-1',
                  agent: 'plan',
                  status: OmpSubagentLifecycleStatus.started,
                ),
              )
              .single,
        ),
        {
          'id': 'child-1',
          'title': 'plan',
          'description': null,
          'status': 'running',
          'toolCallId': null,
        },
      );
      index.clear(second);
      expect(index.terminalizeRunning(first), hasLength(1));
    });

    test('an event frame alone never publishes a descriptor', () {
      final index = OmpSubagentIndex();
      final parent = _Parent();
      index.handleEvent(
        parent,
        const OmpSubagentEventPayload(
          id: 'child-1',
          event: {'type': 'turn_start'},
        ),
      );
      // The state exists but has never been upserted, so terminalizing is the
      // first descriptor anyone sees — under the placeholder title.
      expect(_upsert(index.terminalizeRunning(parent).single), {
        'id': 'child-1',
        'title': 'OMP subagent',
        'description': null,
        'status': 'canceled',
        'toolCallId': null,
      });
    });
  });
}

/// Proves the mapper seam is honoured: it maps every role, unlike the default.
final class _CountingTimelineMapper implements OmpSubagentTimelineMapper {
  int _index = 0;

  @override
  List<TimelineItem> mapMessage(Map<String, Object?> message) {
    _index += 1;
    return [
      AssistantMessageItem(
        id: 'injected-$_index',
        text: '${message['role']}',
        complete: true,
      ),
    ];
  }
}
