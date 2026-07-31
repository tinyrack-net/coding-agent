// Ports of the upstream test suites for Paseo's admission rules:
// client-slash-commands, browser/new-tab-requests, question-form-card-core, and
// isolated-bottom-sheet-modal/visibility-tracker.
//
// Every upstream case is reproduced, plus the edges those suites leave
// unpinned: alias/whitespace handling in the slash-command resolver, the
// WHATWG-URL emulation behind the new-tab allowlist, the empty-string
// truthiness quirks in the question form, and the tracker's disabled and
// controller-less transitions.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/paseo_command_rules.dart';
import 'package:coding_agent_app/widgets/composer.dart'
    show ComposerClientSlashCommand;
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:flutter_test/flutter_test.dart';

DraftAgentSnapshot _createAgent({
  String provider = 'codex',
  String cwd = '/repo',
  String? currentModeId = 'mode-current',
  String? model = 'agent-model',
  String? thinkingOptionId = 'think-hard',
  DraftAgentRuntimeInfo? runtimeInfo = const DraftAgentRuntimeInfo(
    model: 'runtime-model',
    modeId: 'runtime-mode',
    thinkingOptionId: 'runtime-thinking',
  ),
  List<AgentFeature>? features = const [
    AgentFeatureToggle(id: 'web-search', label: 'Web search', value: true),
    AgentFeatureSelect(
      id: 'effort',
      label: 'Effort',
      value: 'high',
      options: [ProviderSelectOption(id: 'high', label: 'High')],
    ),
  ],
}) => DraftAgentSnapshot(
  provider: provider,
  cwd: cwd,
  currentModeId: currentModeId,
  model: model,
  thinkingOptionId: thinkingOptionId,
  runtimeInfo: runtimeInfo,
  features: features,
);

List<WorkspaceTab> _layoutWithBrowser(String browserId) => [
  WorkspaceTab(
    tabId: 'browser_$browserId',
    target: WorkspaceBrowserTabTarget(browserId: browserId),
    createdAt: 1,
  ),
];

final class _FakeBottomSheet implements BottomSheetController {
  final List<String> events = [];

  @override
  void present() => events.add('present');

  @override
  void dismiss() => events.add('dismiss');
}

final class _TrackerHarness {
  _TrackerHarness() {
    tracker = BottomSheetVisibilityTracker(onClose: () => closeCount += 1);
  }

  final _FakeBottomSheet sheet = _FakeBottomSheet();
  late final BottomSheetVisibilityTracker tracker;
  int closeCount = 0;
}

void main() {
  group('resolveClientSlashCommand', () {
    test('declares the exact canonical client commands with their aliases', () {
      expect(
        [
          for (final command in clientSlashCommands)
            [command.name, command.aliases, command.execution],
        ],
        [
          [
            'exit',
            ['quit', 'q'],
            ClientSlashCommandExecution.immediate,
          ],
          [
            'clear',
            ['new'],
            ClientSlashCommandExecution.immediate,
          ],
        ],
      );
    });

    test('carries upstream descriptions, hints and i18n keys', () {
      final exit = clientSlashCommands[0];
      final clear = clientSlashCommands[1];

      expect(exit.description, 'Archive the current agent');
      expect(exit.argumentHint, '');
      expect(
        exit.descriptionKey,
        ClientSlashCommandDescriptionKey.archiveAgent,
      );
      expect(
        exit.descriptionKey.translationKey,
        'composer.clientCommands.archiveAgent',
      );
      expect(clear.description, 'Archive this agent and start a fresh draft');
      expect(clear.argumentHint, '');
      expect(clear.descriptionKey, ClientSlashCommandDescriptionKey.freshDraft);
      expect(
        clear.descriptionKey.translationKey,
        'composer.clientCommands.freshDraft',
      );
    });

    test('exposes commands as client autocomplete entries', () {
      for (final command in clientSlashCommands) {
        expect(command.entry.isClient, isTrue);
        expect(command.entry.command.name, command.name);
        expect(command.entry.aliases, command.aliases);
      }
    });

    test('resolves canonical names and aliases after trimming', () {
      final quit = resolveClientSlashCommand(
        text: ' /quit ',
        hasAttachments: false,
      );
      expect(quit?.name, 'exit');
      expect(quit?.kind, ComposerClientSlashCommand.exit);
      expect(quit?.execution, ClientSlashCommandExecution.immediate);

      for (final text in ['/exit', '/q']) {
        final command = resolveClientSlashCommand(
          text: text,
          hasAttachments: false,
        );
        expect(command?.name, 'exit', reason: text);
        expect(command?.kind, ComposerClientSlashCommand.exit, reason: text);
      }

      for (final text in ['/clear', '/new']) {
        final command = resolveClientSlashCommand(
          text: text,
          hasAttachments: false,
        );
        expect(command?.name, 'clear', reason: text);
        expect(command?.kind, ComposerClientSlashCommand.clear, reason: text);
      }
    });

    test(
      'leaves provider commands, arguments, ordinary messages, and attachment '
      'submits alone',
      () {
        for (final text in [
          '/clear now',
          '/quit now',
          '/provider-command',
          'hello /quit',
        ]) {
          expect(
            resolveClientSlashCommand(text: text, hasAttachments: false),
            isNull,
            reason: text,
          );
        }
        expect(
          resolveClientSlashCommand(text: '/quit', hasAttachments: true),
          isNull,
        );
      },
    );

    test('ignores a bare slash and an empty submission', () {
      expect(
        resolveClientSlashCommand(text: '/', hasAttachments: false),
        isNull,
      );
      expect(
        resolveClientSlashCommand(text: '   /   ', hasAttachments: false),
        isNull,
      );
      expect(
        resolveClientSlashCommand(text: '', hasAttachments: false),
        isNull,
      );
      expect(
        resolveClientSlashCommand(text: '   ', hasAttachments: false),
        isNull,
      );
    });

    test('rejects trailing whitespace inside the command name', () {
      // The name is taken after trimming, so only interior whitespace can
      // survive to hit the `\s` guard.
      expect(
        resolveClientSlashCommand(text: '/exit\tnow', hasAttachments: false),
        isNull,
      );
      expect(
        resolveClientSlashCommand(text: '/exit\nnow', hasAttachments: false),
        isNull,
      );
    });

    test('is case sensitive and rejects a doubled slash', () {
      expect(
        resolveClientSlashCommand(text: '/EXIT', hasAttachments: false),
        isNull,
      );
      expect(
        resolveClientSlashCommand(text: '//exit', hasAttachments: false),
        isNull,
      );
    });

    test('rejects attachment submits even for unknown text', () {
      expect(
        resolveClientSlashCommand(text: 'anything', hasAttachments: true),
        isNull,
      );
    });
  });

  group('buildDraftAgentSetup', () {
    test('builds draft setup from the active agent snapshot', () {
      final setup = buildDraftAgentSetup(_createAgent());

      expect(setup.provider, 'codex');
      expect(setup.cwd, '/repo');
      expect(setup.modeId, 'mode-current');
      expect(setup.model, 'agent-model');
      expect(setup.thinkingOptionId, 'think-hard');
      expect(setup.featureValues, {'web-search': true, 'effort': 'high'});
    });

    test(
      'falls back to runtime model setup when top-level fields are absent',
      () {
        final setup = buildDraftAgentSetup(
          _createAgent(
            currentModeId: null,
            model: null,
            thinkingOptionId: null,
          ),
        );

        expect(setup.modeId, 'runtime-mode');
        expect(setup.model, 'runtime-model');
        expect(setup.thinkingOptionId, 'runtime-thinking');
      },
    );

    test('leaves every optional field null when nothing supplies one', () {
      final setup = buildDraftAgentSetup(
        _createAgent(
          currentModeId: null,
          model: null,
          thinkingOptionId: null,
          runtimeInfo: null,
          features: null,
        ),
      );

      expect(setup.modeId, isNull);
      expect(setup.model, isNull);
      expect(setup.thinkingOptionId, isNull);
      expect(setup.featureValues, isEmpty);
    });

    test('keeps an explicit empty string rather than falling back', () {
      // Upstream coalesces with `??`, not truthiness, so "" is a real value.
      final setup = buildDraftAgentSetup(
        _createAgent(currentModeId: '', model: '', thinkingOptionId: ''),
      );

      expect(setup.modeId, '');
      expect(setup.model, '');
      expect(setup.thinkingOptionId, '');
    });

    test('preserves feature declaration order and lets a repeat id win', () {
      final setup = buildDraftAgentSetup(
        _createAgent(
          features: const [
            AgentFeatureToggle(id: 'a', label: 'A', value: true),
            AgentFeatureSelect(
              id: 'b',
              label: 'B',
              value: 'first',
              options: [],
            ),
            AgentFeatureSelect(
              id: 'b',
              label: 'B again',
              value: 'second',
              options: [],
            ),
          ],
        ),
      );

      expect(setup.featureValues.keys.toList(), ['a', 'b']);
      expect(setup.featureValues['b'], 'second');
    });

    test('carries a null select feature value through', () {
      final setup = buildDraftAgentSetup(
        _createAgent(
          features: const [
            AgentFeatureSelect(
              id: 'effort',
              label: 'Effort',
              value: null,
              options: [],
            ),
          ],
        ),
      );

      expect(setup.featureValues, {'effort': null});
      expect(setup.featureValues.containsKey('effort'), isTrue);
    });
  });

  group('browser new-tab requests', () {
    test(
      'accepts desktop requests from browser tabs in the current workspace',
      () {
        final request = resolveBrowserNewTabRequest(
          payload: {
            'sourceBrowserId': 'browser-1',
            'url': 'https://example.com/target',
          },
          workspaceTabs: _layoutWithBrowser('browser-1'),
        );

        expect(
          request,
          const BrowserNewTabRequest(
            sourceBrowserId: 'browser-1',
            url: 'https://example.com/target',
          ),
        );
      },
    );

    test('ignores desktop requests from another workspace', () {
      expect(
        resolveBrowserNewTabRequest(
          payload: {
            'sourceBrowserId': 'browser-from-other-workspace',
            'url': 'https://example.com/target',
          },
          workspaceTabs: _layoutWithBrowser('browser-1'),
        ),
        isNull,
      );
    });

    test('rejects unsupported desktop request URLs', () {
      expect(
        resolveBrowserNewTabRequest(
          payload: {
            'sourceBrowserId': 'browser-1',
            'url': 'file:///etc/passwd',
          },
          workspaceTabs: _layoutWithBrowser('browser-1'),
        ),
        isNull,
      );
    });

    test('ignores requests when there is no workspace layout at all', () {
      expect(
        resolveBrowserNewTabRequest(
          payload: {
            'sourceBrowserId': 'browser-1',
            'url': 'https://example.com',
          },
          workspaceTabs: null,
        ),
        isNull,
      );
    });

    test('only matches browser tabs, not other tab kinds sharing the id', () {
      expect(
        resolveBrowserNewTabRequest(
          payload: {
            'sourceBrowserId': 'browser-1',
            'url': 'https://example.com',
          },
          workspaceTabs: const [
            WorkspaceTab(
              tabId: 'terminal_browser-1',
              target: WorkspaceTerminalTabTarget(terminalId: 'browser-1'),
              createdAt: 1,
            ),
            WorkspaceTab(
              tabId: 'agent_browser-1',
              target: WorkspaceAgentTabTarget(agentId: 'browser-1'),
              createdAt: 2,
            ),
          ],
        ),
        isNull,
      );
    });

    test('finds a browser tab anywhere in the flattened tab list', () {
      final request = resolveBrowserNewTabRequest(
        payload: {'sourceBrowserId': 'browser-2', 'url': 'https://example.com'},
        workspaceTabs: const [
          WorkspaceTab(
            tabId: 'working_diff',
            target: WorkspaceWorkingDiffTabTarget(),
            createdAt: 1,
          ),
          WorkspaceTab(
            tabId: 'browser_browser-1',
            target: WorkspaceBrowserTabTarget(browserId: 'browser-1'),
            createdAt: 2,
          ),
          WorkspaceTab(
            tabId: 'browser_browser-2',
            target: WorkspaceBrowserTabTarget(browserId: 'browser-2'),
            createdAt: 3,
          ),
        ],
      );

      expect(request?.sourceBrowserId, 'browser-2');
    });

    test(
      'carries the source id through untrimmed, so padding never matches',
      () {
        // The emptiness guard trims but the value does not, exactly as upstream:
        // a padded id survives validation and then fails workspace membership.
        expect(
          readDesktopBrowserNewTabRequest({
            'sourceBrowserId': ' browser-1 ',
            'url': 'https://example.com',
          })?.sourceBrowserId,
          ' browser-1 ',
        );
        expect(
          resolveBrowserNewTabRequest(
            payload: {
              'sourceBrowserId': ' browser-1 ',
              'url': 'https://example.com',
            },
            workspaceTabs: _layoutWithBrowser('browser-1'),
          ),
          isNull,
        );
      },
    );

    test('rejects payloads that are not well-formed request objects', () {
      for (final payload in <Object?>[
        null,
        'not-an-object',
        42,
        <Object?>[],
        <String, Object?>{},
        {'url': 'https://example.com'},
        {'sourceBrowserId': 'browser-1'},
        {'sourceBrowserId': '', 'url': 'https://example.com'},
        {'sourceBrowserId': '   ', 'url': 'https://example.com'},
        {'sourceBrowserId': 7, 'url': 'https://example.com'},
        {'sourceBrowserId': 'browser-1', 'url': 7},
        {'sourceBrowserId': 'browser-1', 'url': null},
      ]) {
        expect(
          readDesktopBrowserNewTabRequest(payload),
          isNull,
          reason: '$payload',
        );
      }
    });

    test('passes the url through byte for byte, without normalizing it', () {
      expect(
        readDesktopBrowserNewTabRequest({
          'sourceBrowserId': 'browser-1',
          'url': 'HTTPS://Example.com',
        })?.url,
        'HTTPS://Example.com',
      );
    });

    test('BrowserNewTabRequest compares by value', () {
      const left = BrowserNewTabRequest(sourceBrowserId: 'a', url: 'b');
      const right = BrowserNewTabRequest(sourceBrowserId: 'a', url: 'b');
      const other = BrowserNewTabRequest(sourceBrowserId: 'a', url: 'c');

      expect(left, right);
      expect(left.hashCode, right.hashCode);
      expect(left, isNot(other));
      expect(left.toString(), contains('sourceBrowserId: a'));
    });
  });

  group('isAllowedBrowserNewTabUrl', () {
    test('allows http and https, including the forms new URL() normalizes', () {
      for (final url in [
        'https://example.com/target',
        'http://a.b',
        'HTTPS://Example.com',
        'http:example.com',
        'http:/a.b',
        r'http:\\a.b',
        'http:///x',
        'https://example.com?q=1#frag',
        'https://user:pass@example.com',
        ' https://example.com ',
      ]) {
        expect(isAllowedBrowserNewTabUrl(url), isTrue, reason: url);
      }
    });

    test(
      'rejects http and https without a host, as new URL() throws on them',
      () {
        for (final url in [
          'https:',
          'http://',
          'http:///',
          r'http:\\',
          'http://@',
        ]) {
          expect(isAllowedBrowserNewTabUrl(url), isFalse, reason: url);
        }
      },
    );

    test('allows exactly about:blank and nothing else in that scheme', () {
      expect(isAllowedBrowserNewTabUrl('about:blank'), isTrue);
      expect(isAllowedBrowserNewTabUrl(' about:blank '), isTrue);
      expect(isAllowedBrowserNewTabUrl('\tabout:blank'), isTrue);
      expect(isAllowedBrowserNewTabUrl('about:bl\tank'), isTrue);

      for (final url in [
        'ABOUT:BLANK',
        'about:Blank',
        'about:blank#x',
        'about:blank?',
        'about://blank',
        'about:',
        'about:srcdoc',
      ]) {
        expect(isAllowedBrowserNewTabUrl(url), isFalse, reason: url);
      }
    });

    test('rejects every other scheme', () {
      for (final url in [
        'file:///etc/passwd',
        'javascript:alert(1)',
        'data:text/html,x',
        'ws://x',
        'chrome://settings',
      ]) {
        expect(isAllowedBrowserNewTabUrl(url), isFalse, reason: url);
      }
    });

    test('rejects strings new URL() cannot parse at all', () {
      for (final url in [
        '',
        '   ',
        'not a url',
        '//example.com',
        '/relative',
        'example.com',
        '1http://x',
        ':nohost',
      ]) {
        expect(isAllowedBrowserNewTabUrl(url), isFalse, reason: url);
      }
    });
  });

  group('parseQuestionFormQuestions', () {
    test('parses a full question payload', () {
      final questions = parseQuestionFormQuestions({
        'questions': [
          {
            'question': 'Pick or type',
            'header': 'Response',
            'options': [
              {'label': 'A', 'description': 'first'},
              {'label': 'B'},
            ],
            'multiSelect': true,
            'allowOther': true,
            'allowEmpty': true,
            'placeholder': 'Type here',
            'dismissLabel': 'Skip',
          },
        ],
      });

      expect(questions, isNotNull);
      final question = questions!.single;
      expect(question.question, 'Pick or type');
      expect(question.header, 'Response');
      expect(question.options.map((o) => o.label), ['A', 'B']);
      expect(question.options[0].description, 'first');
      expect(question.options[1].description, isNull);
      expect(question.multiSelect, isTrue);
      expect(question.allowOther, isTrue);
      expect(question.allowEmpty, isTrue);
      expect(question.placeholder, 'Type here');
      expect(question.dismissLabel, 'Skip');
    });

    test('defaults every boolean flag to false when absent', () {
      final questions = parseQuestionFormQuestions({
        'questions': [
          {'question': 'Q', 'header': 'H', 'options': <Object?>[]},
        ],
      });

      final question = questions!.single;
      expect(question.multiSelect, isFalse);
      expect(question.allowOther, isFalse);
      expect(question.allowEmpty, isFalse);
      expect(question.placeholder, isNull);
      expect(question.dismissLabel, isNull);
    });

    test('treats truthy non-booleans as false, matching strict equality', () {
      final questions = parseQuestionFormQuestions({
        'questions': [
          {
            'question': 'Q',
            'header': 'H',
            'options': <Object?>[],
            'multiSelect': 1,
            'allowOther': 'yes',
            'allowEmpty': 'true',
          },
        ],
      });

      final question = questions!.single;
      expect(question.multiSelect, isFalse);
      expect(question.allowOther, isFalse);
      expect(question.allowEmpty, isFalse);
    });

    test('folds the legacy isOther spelling into allowOther', () {
      final questions = parseQuestionFormQuestions({
        'questions': [
          {
            'question': 'Q',
            'header': 'H',
            'options': [
              {'label': 'A'},
            ],
            'isOther': true,
          },
        ],
      });

      expect(questions!.single.allowOther, isTrue);
    });

    test('drops non-string optional fields rather than failing', () {
      final questions = parseQuestionFormQuestions({
        'questions': [
          {
            'question': 'Q',
            'header': 'H',
            'options': [
              {'label': 'A', 'description': 7},
            ],
            'placeholder': 7,
            'dismissLabel': false,
          },
        ],
      });

      final question = questions!.single;
      expect(question.options.single.description, isNull);
      expect(question.placeholder, isNull);
      expect(question.dismissLabel, isNull);
    });

    test('keeps an empty-string dismiss label verbatim', () {
      final questions = parseQuestionFormQuestions({
        'questions': [
          {
            'question': 'Q',
            'header': 'H',
            'options': <Object?>[],
            'dismissLabel': '',
          },
        ],
      });

      expect(questions!.single.dismissLabel, '');
    });

    test('rejects payloads that are not usable question forms', () {
      for (final payload in <Object?>[
        null,
        'nope',
        42,
        <Object?>[],
        <String, Object?>{},
        {'questions': null},
        {'questions': 'nope'},
        {'questions': <Object?>[]},
        {
          'questions': ['nope'],
        },
        {
          'questions': [null],
        },
      ]) {
        expect(parseQuestionFormQuestions(payload), isNull, reason: '$payload');
      }
    });

    test('voids the whole form when any single question is malformed', () {
      for (final question in <Object?>[
        {'header': 'H', 'options': <Object?>[]},
        {'question': 'Q', 'options': <Object?>[]},
        {'question': 7, 'header': 'H', 'options': <Object?>[]},
        {'question': 'Q', 'header': 7, 'options': <Object?>[]},
        {'question': 'Q', 'header': 'H'},
        {'question': 'Q', 'header': 'H', 'options': 'nope'},
        {
          'question': 'Q',
          'header': 'H',
          'options': ['nope'],
        },
        {
          'question': 'Q',
          'header': 'H',
          'options': [
            {'description': 'no label'},
          ],
        },
      ]) {
        expect(
          parseQuestionFormQuestions({
            'questions': [
              {'question': 'Good', 'header': 'Good', 'options': <Object?>[]},
              question,
            ],
          }),
          isNull,
          reason: '$question',
        );
      }
    });
  });

  group('question answering', () {
    test('treats optional input prompts as skippable empty answers', () {
      final questions = parseQuestionFormQuestions({
        'questions': [
          {
            'question': 'Optional comment?',
            'header': 'Response',
            'options': <Object?>[],
            'multiSelect': false,
            'placeholder': 'Optional comment (press Enter to skip)...',
            'allowEmpty': true,
            'dismissLabel': 'Skip',
          },
        ],
      });

      expect(questions, isNotNull, reason: 'questions did not parse');
      expect(areQuestionsAnswered(questions, {}, {}), isTrue);
      expect(buildQuestionFormAnswers(questions!, {}, {}), {'Response': ''});
      expect(shouldSubmitEmptyOnDismiss(questions), isTrue);
      expect(resolveDismissLabel(questions), 'Skip');
    });

    test('requires a selection for option-only questions', () {
      final questions = parseQuestionFormQuestions({
        'questions': [
          {
            'question': 'Pick one',
            'header': 'Response',
            'options': [
              {'label': 'A'},
              {'label': 'B'},
            ],
            'multiSelect': false,
          },
        ],
      });

      expect(questions, isNotNull, reason: 'questions did not parse');
      final question = questions!.first;
      expect(questionShowsTextInput(question), isFalse);
      expect(areQuestionsAnswered(questions, {}, {0: 'freeform'}), isFalse);
      expect(
        areQuestionsAnswered(questions, {
          0: {1},
        }, {}),
        isTrue,
      );
      expect(
        buildQuestionFormAnswers(questions, {
          0: {1},
        }, {}),
        {'Response': 'B'},
      );
    });

    test('shows text input for explicit other questions', () {
      final questions = parseQuestionFormQuestions({
        'questions': [
          {
            'question': 'Pick or type',
            'header': 'Response',
            'options': [
              {'label': 'A'},
            ],
            'isOther': true,
            'multiSelect': false,
          },
        ],
      });

      expect(questions, isNotNull, reason: 'questions did not parse');
      final question = questions!.first;
      expect(questionShowsTextInput(question), isTrue);
      expect(areQuestionsAnswered(questions, {}, {0: 'custom'}), isTrue);
      expect(buildQuestionFormAnswers(questions, {}, {0: 'custom'}), {
        'Response': 'custom',
      });
    });

    test('shows text input for questions that allow other answers', () {
      final questions = parseQuestionFormQuestions({
        'questions': [
          {
            'question': 'Pick or type',
            'header': 'Response',
            'options': [
              {'label': 'A'},
            ],
            'allowOther': true,
            'multiSelect': false,
          },
        ],
      });

      expect(questions, isNotNull, reason: 'questions did not parse');
      final question = questions!.first;
      expect(questionShowsTextInput(question), isTrue);
      expect(areQuestionsAnswered(questions, {}, {0: 'custom'}), isTrue);
      expect(buildQuestionFormAnswers(questions, {}, {0: 'custom'}), {
        'Response': 'custom',
      });
    });

    test('does not count whitespace-only free text as an answer', () {
      const question = QuestionFormQuestion(
        question: 'Q',
        header: 'Response',
        options: [],
        multiSelect: false,
        allowOther: false,
        allowEmpty: false,
      );

      expect(isQuestionAnswered(question, 0, {}, {0: '   '}), isFalse);
      expect(isQuestionAnswered(question, 0, {}, {0: ''}), isFalse);
      expect(isQuestionAnswered(question, 0, {}, {0: ' hi '}), isTrue);
    });

    test('ignores an empty selection set exactly like a missing one', () {
      const question = QuestionFormQuestion(
        question: 'Q',
        header: 'Response',
        options: [QuestionOption(label: 'A')],
        multiSelect: false,
        allowOther: false,
        allowEmpty: false,
      );

      expect(isQuestionAnswered(question, 0, {0: <int>{}}, {}), isFalse);
      expect(isQuestionAnswered(question, 0, {}, {}), isFalse);
    });

    test('keys selections and texts by question index', () {
      const question = QuestionFormQuestion(
        question: 'Q',
        header: 'Response',
        options: [QuestionOption(label: 'A')],
        multiSelect: false,
        allowOther: false,
        allowEmpty: false,
      );

      expect(
        isQuestionAnswered(question, 1, {
          0: {0},
        }, {}),
        isFalse,
      );
      expect(
        isQuestionAnswered(question, 1, {
          1: {0},
        }, {}),
        isTrue,
      );
    });

    test(
      'answers an option-only question that allows empty only by picking',
      () {
        // allowEmpty cannot rescue a question that shows no text input.
        const question = QuestionFormQuestion(
          question: 'Q',
          header: 'Response',
          options: [QuestionOption(label: 'A')],
          multiSelect: false,
          allowOther: false,
          allowEmpty: true,
        );

        expect(isQuestionAnswered(question, 0, {}, {}), isFalse);
        expect(
          isQuestionAnswered(question, 0, {
            0: {0},
          }, {}),
          isTrue,
        );
      },
    );

    test('a null question list is never answered, an empty one always is', () {
      expect(areQuestionsAnswered(null, {}, {}), isFalse);
      expect(areQuestionsAnswered(const [], {}, {}), isTrue);
    });

    test('requires every question to be answered', () {
      const questions = [
        QuestionFormQuestion(
          question: 'Q1',
          header: 'One',
          options: [QuestionOption(label: 'A')],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
        ),
        QuestionFormQuestion(
          question: 'Q2',
          header: 'Two',
          options: [QuestionOption(label: 'B')],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
        ),
      ];

      expect(
        areQuestionsAnswered(questions, {
          0: {0},
        }, {}),
        isFalse,
      );
      expect(
        areQuestionsAnswered(questions, {
          0: {0},
          1: {0},
        }, {}),
        isTrue,
      );
    });
  });

  group('buildQuestionFormAnswers', () {
    test('joins a multi-select answer in selection order', () {
      const questions = [
        QuestionFormQuestion(
          question: 'Q',
          header: 'Response',
          options: [
            QuestionOption(label: 'A'),
            QuestionOption(label: 'B'),
            QuestionOption(label: 'C'),
          ],
          multiSelect: true,
          allowOther: false,
          allowEmpty: false,
        ),
      ];

      expect(
        buildQuestionFormAnswers(questions, {
          0: {2, 0},
        }, {}),
        {'Response': 'C, A'},
      );
    });

    test('prefers typed text over a selection when text input is shown', () {
      const questions = [
        QuestionFormQuestion(
          question: 'Q',
          header: 'Response',
          options: [QuestionOption(label: 'A')],
          multiSelect: false,
          allowOther: true,
          allowEmpty: false,
        ),
      ];

      expect(
        buildQuestionFormAnswers(
          questions,
          {
            0: {0},
          },
          {0: '  typed  '},
        ),
        {'Response': 'typed'},
      );
    });

    test('falls back to the selection when the typed text is blank', () {
      const questions = [
        QuestionFormQuestion(
          question: 'Q',
          header: 'Response',
          options: [QuestionOption(label: 'A')],
          multiSelect: false,
          allowOther: true,
          allowEmpty: false,
        ),
      ];

      expect(
        buildQuestionFormAnswers(
          questions,
          {
            0: {0},
          },
          {0: '   '},
        ),
        {'Response': 'A'},
      );
    });

    test('never emits the empty-string answer for a question with options', () {
      const questions = [
        QuestionFormQuestion(
          question: 'Q',
          header: 'Response',
          options: [QuestionOption(label: 'A')],
          multiSelect: false,
          allowOther: true,
          allowEmpty: true,
        ),
      ];

      expect(buildQuestionFormAnswers(questions, {}, {}), isEmpty);
    });

    test('omits unanswered questions entirely', () {
      const questions = [
        QuestionFormQuestion(
          question: 'Q1',
          header: 'One',
          options: [QuestionOption(label: 'A')],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
        ),
        QuestionFormQuestion(
          question: 'Q2',
          header: 'Two',
          options: [QuestionOption(label: 'B')],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
        ),
      ];

      expect(
        buildQuestionFormAnswers(questions, {
          1: {0},
        }, {}),
        {'Two': 'B'},
      );
    });

    test('lets a later question overwrite an earlier one sharing a header', () {
      const questions = [
        QuestionFormQuestion(
          question: 'Q1',
          header: 'Same',
          options: [QuestionOption(label: 'A')],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
        ),
        QuestionFormQuestion(
          question: 'Q2',
          header: 'Same',
          options: [QuestionOption(label: 'B')],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
        ),
      ];

      expect(
        buildQuestionFormAnswers(questions, {
          0: {0},
          1: {0},
        }, {}),
        {'Same': 'B'},
      );
    });

    test('throws on a selection index outside the question options', () {
      // Upstream throws a TypeError reading `.label` of undefined; Dart throws
      // a RangeError. Both fail loudly on the same corrupt state.
      const questions = [
        QuestionFormQuestion(
          question: 'Q',
          header: 'Response',
          options: [QuestionOption(label: 'A')],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
        ),
      ];

      expect(
        () => buildQuestionFormAnswers(questions, {
          0: {5},
        }, {}),
        throwsA(isA<RangeError>()),
      );
    });

    test('returns an empty record for an empty question list', () {
      expect(buildQuestionFormAnswers(const [], {}, {}), isEmpty);
    });
  });

  group('shouldSubmitEmptyOnDismiss', () {
    test('is false for an empty question list', () {
      expect(shouldSubmitEmptyOnDismiss(const []), isFalse);
    });

    test('requires every question to be optional and option-free', () {
      const optional = QuestionFormQuestion(
        question: 'Q',
        header: 'H',
        options: [],
        multiSelect: false,
        allowOther: false,
        allowEmpty: true,
      );
      const withOptions = QuestionFormQuestion(
        question: 'Q',
        header: 'H',
        options: [QuestionOption(label: 'A')],
        multiSelect: false,
        allowOther: false,
        allowEmpty: true,
      );
      const required = QuestionFormQuestion(
        question: 'Q',
        header: 'H',
        options: [],
        multiSelect: false,
        allowOther: false,
        allowEmpty: false,
      );

      expect(shouldSubmitEmptyOnDismiss(const [optional, optional]), isTrue);
      expect(
        shouldSubmitEmptyOnDismiss(const [optional, withOptions]),
        isFalse,
      );
      expect(shouldSubmitEmptyOnDismiss(const [optional, required]), isFalse);
    });
  });

  group('resolveDismissLabel', () {
    test('falls back to Dismiss, or to a caller-supplied label', () {
      const question = QuestionFormQuestion(
        question: 'Q',
        header: 'H',
        options: [],
        multiSelect: false,
        allowOther: false,
        allowEmpty: false,
      );

      expect(resolveDismissLabel(const [question]), 'Dismiss');
      expect(resolveDismissLabel(const [question], 'Cancel'), 'Cancel');
      expect(resolveDismissLabel(const []), 'Dismiss');
    });

    test('takes the first question that supplies a label', () {
      const questions = [
        QuestionFormQuestion(
          question: 'Q1',
          header: 'One',
          options: [],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
        ),
        QuestionFormQuestion(
          question: 'Q2',
          header: 'Two',
          options: [],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
          dismissLabel: 'Skip',
        ),
        QuestionFormQuestion(
          question: 'Q3',
          header: 'Three',
          options: [],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
          dismissLabel: 'Later',
        ),
      ];

      expect(resolveDismissLabel(questions), 'Skip');
    });

    test('skips an empty-string label, reproducing the truthiness search', () {
      const questions = [
        QuestionFormQuestion(
          question: 'Q1',
          header: 'One',
          options: [],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
          dismissLabel: '',
        ),
        QuestionFormQuestion(
          question: 'Q2',
          header: 'Two',
          options: [],
          multiSelect: false,
          allowOther: false,
          allowEmpty: false,
          dismissLabel: 'Skip',
        ),
      ];

      expect(resolveDismissLabel(questions), 'Skip');
      expect(resolveDismissLabel([questions.first]), 'Dismiss');
    });
  });

  group('bottom sheet visibility tracker', () {
    test(
      'presents once when the sheet becomes visible and dismisses when it goes '
      'back to hidden',
      () {
        final harness = _TrackerHarness();
        harness.tracker.attachController(harness.sheet);

        harness.tracker.syncDesired(visible: false);
        expect(harness.sheet.events, isEmpty);

        harness.tracker.syncDesired(visible: true);
        expect(harness.sheet.events, ['present']);

        harness.tracker.syncDesired(visible: true);
        expect(harness.sheet.events, ['present']);

        harness.tracker.syncDesired(visible: false);
        expect(harness.sheet.events, ['present', 'dismiss']);
      },
    );

    test('waits to present until the sheet controller becomes available', () {
      final harness = _TrackerHarness();
      harness.tracker.syncDesired(visible: true);
      expect(harness.sheet.events, isEmpty);

      harness.tracker.attachController(harness.sheet);
      expect(harness.sheet.events, ['present']);
    });

    test('does not present while disabled', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);

      harness.tracker.syncDesired(visible: true, isEnabled: false);
      expect(harness.sheet.events, isEmpty);
    });

    test('an unset isEnabled behaves like true, not like false', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);

      harness.tracker.syncDesired(visible: true, isEnabled: true);
      expect(harness.sheet.events, ['present']);

      final other = _TrackerHarness();
      other.tracker.attachController(other.sheet);
      other.tracker.syncDesired(visible: true);
      expect(other.sheet.events, ['present']);
    });

    test('does not dismiss while disabled either', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);
      harness.tracker.syncDesired(visible: true);
      expect(harness.sheet.events, ['present']);

      harness.tracker.syncDesired(visible: false, isEnabled: false);
      expect(harness.sheet.events, ['present']);
    });

    test('a disabled attach does not present, and re-enabling does', () {
      final harness = _TrackerHarness();
      harness.tracker.syncDesired(visible: true, isEnabled: false);
      harness.tracker.attachController(harness.sheet);
      expect(harness.sheet.events, isEmpty);

      harness.tracker.syncDesired(visible: true);
      expect(harness.sheet.events, ['present']);
    });

    test(
      'does not treat index -1 as a close because stacked sheets can be hidden '
      'without dismissing',
      () {
        final harness = _TrackerHarness();
        harness.tracker.attachController(harness.sheet);
        harness.tracker.syncDesired(visible: true);

        harness.tracker.handleSheetIndexChange(-1);
        expect(harness.closeCount, 0);

        harness.tracker.syncDesired(visible: false);
        harness.tracker.handleSheetIndexChange(-1);
        expect(harness.closeCount, 0);
      },
    );

    test('reports a dismiss while visible as a close request', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);
      harness.tracker.syncDesired(visible: true);

      harness.tracker.handleSheetDismiss();

      expect(harness.closeCount, 1);
    });

    test('reports close once when a hidden sheet is actually dismissed', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);
      harness.tracker.syncDesired(visible: true);

      harness.tracker.handleSheetIndexChange(-1);
      harness.tracker.handleSheetDismiss();

      expect(harness.closeCount, 1);
    });

    test('reports close only once for repeated dismisses in one cycle', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);
      harness.tracker.syncDesired(visible: true);

      harness.tracker.handleSheetDismiss();
      harness.tracker.handleSheetDismiss();
      harness.tracker.handleSheetDismiss();

      expect(harness.closeCount, 1);
    });

    test('allows a new close notification after re-presenting the sheet', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);
      harness.tracker.syncDesired(visible: true);

      harness.tracker.handleSheetIndexChange(-1);
      harness.tracker.handleSheetDismiss();
      expect(harness.closeCount, 1);

      harness.tracker.syncDesired(visible: false);
      harness.tracker.syncDesired(visible: true);

      harness.tracker.handleSheetIndexChange(-1);
      harness.tracker.handleSheetDismiss();
      expect(harness.closeCount, 2);
    });

    test(
      'does not re-present when the controller reattaches before parent state '
      'acknowledges a user dismiss',
      () {
        final harness = _TrackerHarness();
        harness.tracker.attachController(harness.sheet);
        harness.tracker.syncDesired(visible: true);

        harness.tracker.handleSheetIndexChange(-1);
        harness.tracker.attachController(null);
        harness.tracker.attachController(harness.sheet);

        expect(harness.closeCount, 0);
        expect(harness.sheet.events, ['present']);
      },
    );

    test(
      'does not re-present when dismiss fires before parent state acknowledges '
      'a user dismiss',
      () {
        final harness = _TrackerHarness();
        harness.tracker.attachController(harness.sheet);
        harness.tracker.syncDesired(visible: true);

        harness.tracker.handleSheetDismiss();
        harness.tracker.attachController(null);
        harness.tracker.attachController(harness.sheet);

        expect(harness.closeCount, 1);
        expect(harness.sheet.events, ['present']);
      },
    );

    test(
      'allows a fresh open after parent state acknowledges a dismissed sheet',
      () {
        final harness = _TrackerHarness();
        harness.tracker.attachController(harness.sheet);
        harness.tracker.syncDesired(visible: true);

        harness.tracker.handleSheetIndexChange(-1);
        harness.tracker.attachController(null);
        harness.tracker.attachController(harness.sheet);
        harness.tracker.syncDesired(visible: false);
        harness.tracker.syncDesired(visible: true);

        expect(harness.sheet.events, ['present', 'present']);
      },
    );

    test('a settled index promotes presenting to presented', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);
      harness.tracker.syncDesired(visible: true);
      harness.tracker.handleSheetIndexChange(0);

      // Still presented, so a hide really does dismiss.
      harness.tracker.syncDesired(visible: false);
      expect(harness.sheet.events, ['present', 'dismiss']);
    });

    test('a non -1 index rescues a sheet mid-dismiss back to presented', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);
      harness.tracker.syncDesired(visible: true);
      harness.tracker.handleSheetIndexChange(-1);
      harness.tracker.handleSheetIndexChange(0);

      // Back to presented, so hiding issues a real dismiss rather than only
      // resetting the phase.
      harness.tracker.syncDesired(visible: false);
      expect(harness.sheet.events, ['present', 'dismiss']);
    });

    test('never dismisses a sheet that was never presented', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);

      harness.tracker.syncDesired(visible: false);
      harness.tracker.syncDesired(visible: false);
      harness.tracker.handleSheetIndexChange(-1);

      expect(harness.sheet.events, isEmpty);
      expect(harness.closeCount, 0);
    });

    test('does nothing at all without a controller attached', () {
      final harness = _TrackerHarness();

      harness.tracker.syncDesired(visible: true);
      harness.tracker.syncDesired(visible: false);
      harness.tracker.handleSheetIndexChange(-1);

      expect(harness.sheet.events, isEmpty);
      expect(harness.closeCount, 0);
    });

    test('a detached controller stops receiving present and dismiss calls', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);
      harness.tracker.syncDesired(visible: true);
      harness.tracker.attachController(null);
      harness.tracker.syncDesired(visible: false);

      expect(harness.sheet.events, ['present']);
    });

    test('a dismiss while hidden clears the latch without notifying', () {
      final harness = _TrackerHarness();
      harness.tracker.attachController(harness.sheet);

      harness.tracker.handleSheetDismiss();

      expect(harness.closeCount, 0);
      harness.tracker.syncDesired(visible: true);
      expect(harness.sheet.events, ['present']);
    });
  });
}
