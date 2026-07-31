// Ports of the upstream test suites for Paseo 0.2.0's render-time rules:
// markdown/part-groups, markdown-text-style, root-error-details and
// worktree-setup-callout-policy. Every upstream case is carried over verbatim;
// the extra cases pin edges the frozen suites leave unspecified (paragraph
// boundary shapes, style-prop flattening, JSON pretty-printing details,
// nullish coalescing) so a future refactor cannot drift on them silently.
import 'package:coding_agent_app/core/paseo_render_rules.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// markdown/part-groups.ts
// ---------------------------------------------------------------------------

const flowImage = MarkdownInlineImagePart(
  alt: 'Priority',
  src: 'https://example.com/priority.svg',
  flowsWithText: true,
);

const secondFlowImage = MarkdownInlineImagePart(
  alt: 'Severity',
  src: 'https://example.com/severity.svg',
  flowsWithText: true,
);

/// Mirrors the upstream style of asserting on whole group lists rather than
/// poking at individual fields.
void expectGroups(
  List<MarkdownDisplayPart> parts,
  List<MarkdownPartGroup> expected,
) {
  expect(groupMarkdownParts(parts), expected);
}

// ---------------------------------------------------------------------------
// markdown-text-style.ts
// ---------------------------------------------------------------------------

/// A style carrying Unistyles' private tracking key, as a themed style does.
Map<String, Object?> unistylesStyle(String id, Map<String, Object?> style) => {
  ...style,
  'unistyles_$id': <String, Object?>{'id': id},
};

/// `react-native-uitextview/src/util.ts:8` flattens `[rootStyle, style]` before
/// passing the result to its native View-backed components.
Map<String, Object?> uiTextViewFlatten(
  Map<String, Object?> rootStyle,
  Map<String, Object?> style,
) => flattenTextStyleProp([rootStyle, style]);

List<String> unistylesMetadataKeys(Map<String, Object?> style) =>
    style.keys.where((key) => key.startsWith('unistyles_')).toList();

// ---------------------------------------------------------------------------
// root-error-details.ts
// ---------------------------------------------------------------------------

/// Stands in for `Object.defineProperty(error, "cause", { value: error })`.
class SelfCausedError extends CaughtError {
  SelfCausedError()
    : super(name: 'Error', message: 'self cause', hasCause: true);

  @override
  Object? get cause => this;
}

/// Stands in for a `message` getter that throws, which is what makes the
/// crash formatter fall back instead of crashing the crash screen.
class ThrowingMessageError extends CaughtError {
  ThrowingMessageError() : super(name: 'Error', message: 'fallback');

  @override
  Object? get message =>
      throw CaughtError(name: 'Error', message: 'bad message getter');
}

/// A Dart object with no JSON representation, used to pin the documented
/// unrecognised-value behaviour.
class OpaqueValue {
  const OpaqueValue();

  @override
  String toString() => 'opaque';
}

// ---------------------------------------------------------------------------
// worktree-setup-callout-policy.ts
// ---------------------------------------------------------------------------

WorktreeSetupWorkspaceInput gitWorkspace({
  String projectId = 'project-1',
  String projectKind = 'git',
  String projectRootPath = '/repo/project-1',
  String? projectCheckoutMainRepoRoot = '/repo/main-project-1',
}) => WorktreeSetupWorkspaceInput(
  projectId: projectId,
  projectKind: projectKind,
  projectRootPath: projectRootPath,
  projectCheckoutMainRepoRoot: projectCheckoutMainRepoRoot,
);

/// The English resource values upstream's suite asserts against, keyed exactly
/// as `i18n.t` is called.
String enTranslate(String key) => switch (key) {
  'sidebar.worktreeSetup.title' => 'Set up worktree scripts',
  'sidebar.worktreeSetup.description' =>
    'Add setup commands so new worktrees can install dependencies and '
        'prepare themselves automatically.',
  'sidebar.worktreeSetup.openProjectSettings' => 'Open project settings',
  _ => key,
};

void main() {
  group('groupMarkdownParts', () {
    test(
      'flows an image with the lead paragraph and keeps later paragraphs full width',
      () {
        expectGroups(
          [
            flowImage,
            const MarkdownTextPart(' **Title line**\n\nSecond paragraph.'),
          ],
          [
            const MarkdownImageTextGroup(
              images: [flowImage],
              lead: '**Title line**',
              rest: 'Second paragraph.',
            ),
          ],
        );
      },
    );

    test('flows an image with a single-paragraph text', () {
      expectGroups(
        [flowImage, const MarkdownTextPart(' Only line')],
        [
          const MarkdownImageTextGroup(
            images: [flowImage],
            lead: 'Only line',
            rest: '',
          ),
        ],
      );
    });

    test('groups two consecutive flowing images with the lead paragraph', () {
      expectGroups(
        [
          flowImage,
          const MarkdownTextPart(' '),
          secondFlowImage,
          const MarkdownTextPart(' **Title text here**\n\nBody paragraph.'),
        ],
        [
          const MarkdownImageTextGroup(
            images: [flowImage, secondFlowImage],
            lead: '**Title text here**',
            rest: 'Body paragraph.',
          ),
        ],
      );
    });

    test('keeps standalone images as plain parts', () {
      const image = MarkdownInlineImagePart(
        alt: 'Shot',
        src: 'https://example.com/shot.png',
      );

      expectGroups(
        [image, const MarkdownTextPart('\n\nCaption')],
        [
          const MarkdownSinglePartGroup(image),
          const MarkdownSinglePartGroup(MarkdownTextPart('\n\nCaption')),
        ],
      );
    });

    test('keeps a flowing image alone when no markdown follows', () {
      expectGroups([flowImage], [const MarkdownSinglePartGroup(flowImage)]);
    });

    test(
      'keeps a flowing image alone when the following markdown starts with a blank line',
      () {
        expectGroups(
          [flowImage, const MarkdownTextPart('\n\nBelow')],
          [
            const MarkdownSinglePartGroup(flowImage),
            const MarkdownSinglePartGroup(MarkdownTextPart('\n\nBelow')),
          ],
        );
      },
    );

    test('passes other part kinds through unchanged', () {
      const details = MarkdownDetailsPart(summary: 'More', body: 'Body');

      expectGroups(
        [const MarkdownTextPart('Intro'), details],
        [
          const MarkdownSinglePartGroup(MarkdownTextPart('Intro')),
          const MarkdownSinglePartGroup(details),
        ],
      );
    });

    // --- edges the upstream suite leaves unpinned ---

    test('returns no groups for no parts', () {
      expect(groupMarkdownParts(const []), isEmpty);
    });

    test('re-emits swallowed whitespace parts when the run has no lead', () {
      expectGroups(
        [flowImage, const MarkdownTextPart('  '), secondFlowImage],
        [
          const MarkdownSinglePartGroup(flowImage),
          const MarkdownSinglePartGroup(MarkdownTextPart('  ')),
          const MarkdownSinglePartGroup(secondFlowImage),
        ],
      );
    });

    test('leaves a non-markdown trailing part for the next iteration', () {
      const details = MarkdownDetailsPart(summary: 'More', body: 'Body');

      expectGroups(
        [flowImage, details],
        [
          const MarkdownSinglePartGroup(flowImage),
          const MarkdownSinglePartGroup(details),
        ],
      );
    });

    test('does not flow an image whose flowsWithText is unset', () {
      const image = MarkdownInlineImagePart(
        alt: 'Badge',
        src: 'https://example.com/badge.svg',
      );

      expectGroups(
        [image, const MarkdownTextPart(' Title')],
        [
          const MarkdownSinglePartGroup(image),
          const MarkdownSinglePartGroup(MarkdownTextPart(' Title')),
        ],
      );
    });

    test('treats a spaces-then-newline first line as a blank lead', () {
      expectGroups(
        [flowImage, const MarkdownTextPart('   \nBelow')],
        [
          const MarkdownSinglePartGroup(flowImage),
          const MarkdownSinglePartGroup(MarkdownTextPart('   \nBelow')),
        ],
      );
    });

    test('splits on a CRLF paragraph boundary', () {
      expectGroups(
        [flowImage, const MarkdownTextPart(' Lead\r\n\r\nRest')],
        [
          const MarkdownImageTextGroup(
            images: [flowImage],
            lead: 'Lead',
            rest: 'Rest',
          ),
        ],
      );
    });

    test('accepts horizontal whitespace inside the paragraph boundary', () {
      expectGroups(
        [flowImage, const MarkdownTextPart(' Lead\n \t\nRest')],
        [
          const MarkdownImageTextGroup(
            images: [flowImage],
            lead: 'Lead',
            rest: 'Rest',
          ),
        ],
      );
    });

    test('splits only on the first boundary and leaves the rest untrimmed', () {
      expectGroups(
        [flowImage, const MarkdownTextPart(' Lead\n\n  Second\n\nThird ')],
        [
          const MarkdownImageTextGroup(
            images: [flowImage],
            lead: 'Lead',
            rest: '  Second\n\nThird ',
          ),
        ],
      );
    });

    test('falls back when the trailing markdown is only whitespace', () {
      // The whitespace part is swallowed by the image run, so the run ends
      // with nothing to pair against.
      expectGroups(
        [flowImage, const MarkdownTextPart('   ')],
        [
          const MarkdownSinglePartGroup(flowImage),
          const MarkdownSinglePartGroup(MarkdownTextPart('   ')),
        ],
      );
    });

    test('starts a fresh run after a consumed group', () {
      expectGroups(
        [
          flowImage,
          const MarkdownTextPart(' First'),
          secondFlowImage,
          const MarkdownTextPart(' Second'),
        ],
        [
          const MarkdownImageTextGroup(
            images: [flowImage],
            lead: 'First',
            rest: '',
          ),
          const MarkdownImageTextGroup(
            images: [secondFlowImage],
            lead: 'Second',
            rest: '',
          ),
        ],
      );
    });
  });

  group('resolvePlainMarkdownTextStyle', () {
    test(
      'keeps UITextView from collapsing parent and child Unistyles styles into one native View style object',
      () {
        final merged = uiTextViewFlatten(
          resolvePlainMarkdownTextStyle(
            unistylesStyle('paragraph', {'color': '#111'}),
          ),
          resolvePlainMarkdownTextStyle(
            unistylesStyle('text', {'fontWeight': '600'}),
          ),
        );

        expect(unistylesMetadataKeys(merged), isEmpty);
        expect(merged['color'], '#111');
        expect(merged['fontWeight'], '600');
      },
    );

    // --- edges the upstream suite leaves unpinned ---

    test('resolves an absent style prop to an empty style', () {
      expect(resolvePlainMarkdownTextStyle(null), isEmpty);
    });

    test('keeps every key that is not Unistyles tracking metadata', () {
      expect(
        resolvePlainMarkdownTextStyle({
          'fontSize': 14.0,
          'unistylesColor': '#222',
          'unistyles_1': {'id': 1},
        }),
        {'fontSize': 14.0, 'unistylesColor': '#222'},
      );
    });

    test('strips a bare metadata prefix key', () {
      expect(resolvePlainMarkdownTextStyle({'unistyles_': 1}), isEmpty);
    });

    test('flattens nested lists with later entries winning', () {
      expect(
        flattenTextStyleProp([
          {'color': '#111', 'fontSize': 14.0},
          [
            {'color': '#222'},
            {'fontWeight': '600'},
          ],
        ]),
        {'color': '#222', 'fontSize': 14.0, 'fontWeight': '600'},
      );
    });

    test('skips null and false entries the way a conditional style yields', () {
      expect(
        flattenTextStyleProp([
          null,
          false,
          {'color': '#111'},
          null,
        ]),
        {'color': '#111'},
      );
    });

    test('does not mutate the style map it was given', () {
      final source = unistylesStyle('paragraph', {'color': '#111'});

      resolvePlainMarkdownTextStyle(source);

      expect(source.containsKey('unistyles_paragraph'), isTrue);
    });
  });

  group('formatCaughtValue', () {
    test('preserves details for Error values', () {
      final details = formatCaughtValue(
        CaughtError(
          name: 'RouteRenderError',
          message: 'route render exploded',
          stack:
              'RouteRenderError: route render exploded\n'
              '    at WorkspaceRoute',
          hasCause: true,
          cause: 'workspace route',
          fields: const {'code': 'E_ROUTE_RENDER'},
        ),
      );

      expect(details, contains('Name: RouteRenderError'));
      expect(details, contains('Message: route render exploded'));
      expect(details, contains('Stack:'));
      expect(details, contains('RouteRenderError: route render exploded'));
      expect(details, contains('Cause:'));
      expect(details, contains('workspace route'));
      expect(details, contains('E_ROUTE_RENDER'));
    });

    test('does not duplicate aggregate errors as custom fields', () {
      final details = formatCaughtValue(
        CaughtError(
          name: 'AggregateError',
          message: 'multiple failures',
          hasErrors: true,
          errors: [CaughtError(name: 'Error', message: 'first failure')],
        ),
      );

      expect(details, contains('Errors:'));
      expect(details, contains('first failure'));
      expect(details, isNot(contains('Fields:')));
    });

    test('preserves null aggregate error values', () {
      final details = formatCaughtValue(
        CaughtError(name: 'Error', message: 'nullable errors', hasErrors: true),
      );

      expect(details, contains('Errors:\nnull'));
      expect(details, isNot(contains('Fields:')));
    });

    test('does not throw for malformed Error text fields', () {
      final details = formatCaughtValue(
        CaughtError(
          name: null,
          message: 42,
          stack: const {'frame': 'bad stack'},
        ),
      );

      expect(details, contains('Name: null'));
      expect(details, contains('Message: 42'));
      expect(details, contains('"frame": "bad stack"'));
    });

    test('marks recursive Error causes', () {
      expect(
        formatCaughtValue(SelfCausedError()),
        contains('Cause:\n[Circular Error]'),
      );
    });

    test('returns fallback details when Error properties throw', () {
      final details = formatCaughtValue(ThrowingMessageError());

      expect(details, contains('[Unserializable value]'));
      expect(details, contains('Details unavailable:'));
      expect(details, contains('Error: bad message getter'));
    });

    test('renders string thrown values as the string', () {
      expect(formatCaughtValue('plain failure'), 'plain failure');
    });

    test('preserves empty string thrown values', () {
      expect(formatCaughtValue(''), '');
    });

    test('renders numeric thrown values without extra category text', () {
      final details = formatCaughtValue(42);

      expect(details, '42');
      expect(details, isNot(contains('non-Error')));
    });

    test('renders circular objects as JSON with circular markers', () {
      final value = <String, Object?>{'label': 'loop'};
      value['self'] = value;

      expect(
        formatCaughtValue(value),
        '{\n  "label": "loop",\n  "self": "[Circular]"\n}',
      );
    });

    // --- edges the upstream suite leaves unpinned ---

    test('renders nullish thrown values as their JavaScript spelling', () {
      expect(formatCaughtValue(null), 'null');
      expect(formatCaughtValue(jsUndefined), 'undefined');
    });

    test('renders booleans and integral doubles the way JavaScript does', () {
      expect(formatCaughtValue(true), 'true');
      expect(formatCaughtValue(42.0), '42');
      expect(formatCaughtValue(1.5), '1.5');
      expect(formatCaughtValue(double.infinity), 'Infinity');
      expect(formatCaughtValue(BigInt.from(9)), '9');
    });

    test('pretty-prints nested containers with two-space indentation', () {
      expect(
        formatCaughtValue({
          'a': {
            'b': [1],
          },
        }),
        '{\n  "a": {\n    "b": [\n      1\n    ]\n  }\n}',
      );
      expect(formatCaughtValue(<String, Object?>{}), '{}');
      expect(formatCaughtValue(<Object?>[]), '[]');
    });

    test('omits undefined properties but keeps undefined array slots', () {
      expect(formatCaughtValue({'a': jsUndefined, 'b': 1}), '{\n  "b": 1\n}');
      expect(formatCaughtValue({'a': jsUndefined}), '{}');
      expect(formatCaughtValue([jsUndefined]), '[\n  null\n]');
    });

    test('renders non-finite numbers inside JSON as null', () {
      expect(formatCaughtValue([double.nan]), '[\n  null\n]');
    });

    test('renders big integers inside JSON as decimal strings', () {
      expect(formatCaughtValue([BigInt.from(9)]), '[\n  "9"\n]');
    });

    test('renders a nested error inside JSON as its formatted text', () {
      expect(
        formatCaughtValue([CaughtError(name: 'Error', message: 'inner')]),
        '[\n  "Name: Error\\n\\nMessage: inner"\n]',
      );
    });

    test('renders an unrecognised value as a property-less object', () {
      // Documented deviation: Dart cannot enumerate an arbitrary object's
      // fields, so it serializes the way JS serializes a class instance that
      // declares no enumerable properties.
      expect(formatCaughtValue([const OpaqueValue()]), '[\n  {}\n]');
    });

    test('falls back to Error.toString when no section has content', () {
      // Nothing is set, so there is no section to print and the formatter
      // falls through to `String(error)` — which is "Error" for a bare error.
      expect(formatCaughtValue(CaughtError()), 'Error');
      // A blank name is treated as absent, so only the message survives.
      expect(
        formatCaughtValue(CaughtError(name: '', message: 'lonely message')),
        'Message: lonely message',
      );
      // A name on its own is still a section, not a toString fallback.
      expect(formatCaughtValue(CaughtError(name: 'Boom')), 'Name: Boom');
    });

    test('drops whitespace-only Error text properties', () {
      expect(
        formatCaughtValue(CaughtError(name: 'Error', message: '   ')),
        'Name: Error',
      );
    });

    test('separates sections with a blank line in a fixed order', () {
      expect(
        formatCaughtValue(
          CaughtError(
            name: 'Error',
            message: 'boom',
            stack: 'at frame',
            hasCause: true,
            cause: 'root',
            hasErrors: true,
            errors: 'sub',
            fields: const {'code': 7},
          ),
        ),
        'Name: Error\n\n'
        'Message: boom\n\n'
        'Stack:\nat frame\n\n'
        'Cause:\nroot\n\n'
        'Errors:\nsub\n\n'
        'Fields:\n{\n  "code": 7\n}',
      );
    });

    test('omits a cause section when the error carries no cause property', () {
      expect(
        formatCaughtValue(CaughtError(name: 'Error', message: 'boom')),
        isNot(contains('Cause:')),
      );
    });

    test('never reports the reserved property names as custom fields', () {
      expect(
        formatCaughtValue(
          CaughtError(
            name: 'Error',
            message: 'boom',
            fields: const {
              'name': 'dupe',
              'message': 'dupe',
              'stack': 'dupe',
              'cause': 'dupe',
              'errors': 'dupe',
            },
          ),
        ),
        isNot(contains('Fields:')),
      );
    });

    test('renders the same error twice when it is not actually a cycle', () {
      final inner = CaughtError(name: 'Inner', message: 'boom');
      final details = formatCaughtValue(
        CaughtError(
          name: 'Outer',
          message: 'wrap',
          hasCause: true,
          cause: inner,
          hasErrors: true,
          errors: inner,
        ),
      );

      expect('Name: Inner'.allMatches(details).length, 2);
    });
  });

  group('selectActiveGitWorkspaceProject', () {
    test('selects the active git workspace project from checkout metadata', () {
      expect(
        selectActiveGitWorkspaceProject('server-1', gitWorkspace()),
        const ActiveGitWorkspaceProject(
          serverId: 'server-1',
          projectKey: 'project-1',
          repoRoot: '/repo/main-project-1',
        ),
      );
    });

    test(
      'falls back to the workspace project root when checkout metadata has no main root',
      () {
        expect(
          selectActiveGitWorkspaceProject(
            'server-1',
            gitWorkspace(projectCheckoutMainRepoRoot: null),
          ),
          const ActiveGitWorkspaceProject(
            serverId: 'server-1',
            projectKey: 'project-1',
            repoRoot: '/repo/project-1',
          ),
        );
      },
    );

    test('ignores non-git workspaces and blank project coordinates', () {
      expect(
        selectActiveGitWorkspaceProject(
          'server-1',
          gitWorkspace(projectKind: 'local'),
        ),
        isNull,
      );
      expect(
        selectActiveGitWorkspaceProject(
          'server-1',
          gitWorkspace(projectId: ' '),
        ),
        isNull,
      );
      expect(
        selectActiveGitWorkspaceProject(
          'server-1',
          gitWorkspace(projectRootPath: ' ', projectCheckoutMainRepoRoot: null),
        ),
        isNull,
      );
    });

    // --- edges the upstream suite leaves unpinned ---

    test('does not fall back when the main repo root is explicitly blank', () {
      // Upstream coalesces with `??`, so an empty-string main root wins over
      // the project root and then fails the blank check.
      expect(
        selectActiveGitWorkspaceProject(
          'server-1',
          gitWorkspace(projectCheckoutMainRepoRoot: '  '),
        ),
        isNull,
      );
    });

    test('trims both coordinates', () {
      expect(
        selectActiveGitWorkspaceProject(
          'server-1',
          gitWorkspace(
            projectId: '  project-1  ',
            projectCheckoutMainRepoRoot: '  /repo/main  ',
          ),
        ),
        const ActiveGitWorkspaceProject(
          serverId: 'server-1',
          projectKey: 'project-1',
          repoRoot: '/repo/main',
        ),
      );
    });

    test('passes the server id through untouched', () {
      expect(
        selectActiveGitWorkspaceProject('  ', gitWorkspace())?.serverId,
        '  ',
      );
    });
  });

  group('shouldShowWorktreeSetupCallout', () {
    test(
      'shows the callout when paseo config was read and setup commands are missing',
      () {
        expect(
          shouldShowWorktreeSetupCallout(
            const ReadProjectConfigResult(ok: true),
          ),
          isTrue,
        );
      },
    );

    test('does not show the callout when setup commands are present', () {
      expect(
        shouldShowWorktreeSetupCallout(
          const ReadProjectConfigResult(ok: true, worktreeSetup: 'npm install'),
        ),
        isFalse,
      );
      expect(
        shouldShowWorktreeSetupCallout(
          const ReadProjectConfigResult(
            ok: true,
            worktreeSetup: [' ', 'npm install'],
          ),
        ),
        isFalse,
      );
    });

    test(
      'does not show the callout when reading paseo config fails or has not completed',
      () {
        expect(shouldShowWorktreeSetupCallout(null), isFalse);
        expect(
          shouldShowWorktreeSetupCallout(
            const ReadProjectConfigResult(ok: false),
          ),
          isFalse,
        );
      },
    );

    // --- edges the upstream suite leaves unpinned ---

    test('treats blank and non-string setup entries as no setup at all', () {
      expect(
        shouldShowWorktreeSetupCallout(
          const ReadProjectConfigResult(ok: true, worktreeSetup: '   '),
        ),
        isTrue,
      );
      expect(
        shouldShowWorktreeSetupCallout(
          const ReadProjectConfigResult(ok: true, worktreeSetup: <Object?>[]),
        ),
        isTrue,
      );
      expect(
        shouldShowWorktreeSetupCallout(
          const ReadProjectConfigResult(
            ok: true,
            worktreeSetup: [' ', '', null, 7],
          ),
        ),
        isTrue,
      );
    });

    test('ignores an unexpected setup shape rather than guessing', () {
      expect(
        shouldShowWorktreeSetupCallout(
          const ReadProjectConfigResult(
            ok: true,
            worktreeSetup: {'run': 'npm install'},
          ),
        ),
        isTrue,
      );
    });

    test('still hides the callout when a failed read carries setup', () {
      expect(
        shouldShowWorktreeSetupCallout(
          const ReadProjectConfigResult(
            ok: false,
            worktreeSetup: 'npm install',
          ),
        ),
        isFalse,
      );
    });
  });

  group('buildWorktreeSetupCalloutPolicy', () {
    test('builds the stable sidebar callout identity and action route', () {
      expect(
        buildWorktreeSetupCalloutPolicy(
          const ActiveGitWorkspaceProject(
            serverId: 'server-1',
            projectKey: 'project-1',
            repoRoot: '/repo/project-1',
          ),
          t: enTranslate,
        ),
        const WorktreeSetupCalloutPolicy(
          id: 'worktree-setup-missing:project-1',
          dismissalKey: 'worktree-setup-missing:project-1',
          priority: 100,
          title: 'Set up worktree scripts',
          description:
              'Add setup commands so new worktrees can install dependencies '
              'and prepare themselves automatically.',
          actionLabel: 'Open project settings',
          projectSettingsRoute: '/settings/projects/project-1',
          testID: 'worktree-setup-callout-project-1',
        ),
      );
    });

    // --- edges the upstream suite leaves unpinned ---

    test('keys the callout by project so two projects never collide', () {
      final first = buildWorktreeSetupCalloutPolicy(
        const ActiveGitWorkspaceProject(
          serverId: 'server-1',
          projectKey: 'alpha',
          repoRoot: '/repo/alpha',
        ),
        t: enTranslate,
      );
      final second = buildWorktreeSetupCalloutPolicy(
        const ActiveGitWorkspaceProject(
          serverId: 'server-2',
          projectKey: 'beta',
          repoRoot: '/repo/beta',
        ),
        t: enTranslate,
      );

      expect(first.dismissalKey, isNot(second.dismissalKey));
      expect(first.testID, isNot(second.testID));
    });

    test('does not vary with the server the project was seen on', () {
      const project = ActiveGitWorkspaceProject(
        serverId: 'server-1',
        projectKey: 'alpha',
        repoRoot: '/repo/alpha',
      );
      const otherServer = ActiveGitWorkspaceProject(
        serverId: 'server-2',
        projectKey: 'alpha',
        repoRoot: '/repo/alpha',
      );

      expect(
        buildWorktreeSetupCalloutPolicy(project, t: enTranslate),
        buildWorktreeSetupCalloutPolicy(otherServer, t: enTranslate),
      );
    });

    test('percent-encodes a project key that is not route safe', () {
      expect(
        buildWorktreeSetupCalloutPolicy(
          const ActiveGitWorkspaceProject(
            serverId: 'server-1',
            projectKey: 'group/name',
            repoRoot: '/repo/name',
          ),
          t: enTranslate,
        ).projectSettingsRoute,
        '/settings/projects/group%2Fname',
      );
    });
  });
}
