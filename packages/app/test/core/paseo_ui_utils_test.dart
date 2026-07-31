// Ports of the upstream test suites for Paseo 0.2.0's `utils/score-match.ts`,
// `utils/web-focus.ts`, `utils/app-visibility.ts`, `utils/format-shortcut.ts`,
// `utils/rich-clipboard.ts` and `utils/assistant-image-source.ts` — plus the
// edge cases those suites leave unpinned (fuzzy tier 5 and its spread, empty
// and over-long queries, multi-token field scoring, focus timeout and throwing
// focus targets, native app state, modifier re-ordering and duplicates, the
// no-rich-writer clipboard path, UNC and tilde image paths).
//
// Unicode glyphs are written as escapes so the expectations survive any
// re-encoding of this file; the comment beside each one names it.
import 'package:coding_agent_app/core/paseo_ui_utils.dart';
import 'package:flutter_test/flutter_test.dart';

const String _cmd = '\u2318'; // COMMAND KEY
const String _opt = '\u2325'; // OPTION KEY
const String _ctl = '\u2303'; // CONTROL KEY
const String _backspace = '\u232B'; // ERASE TO THE LEFT
const String _enter = '\u23CE'; // RETURN SYMBOL
const String _space = '\u2423'; // OPEN BOX
const String _left = '\u2190';
const String _right = '\u2192';
const String _up = '\u2191';
const String _down = '\u2193';

void main() {
  // -------------------------------------------------------------------------
  // utils/score-match.ts
  // -------------------------------------------------------------------------

  group('scoreMatch', () {
    test('returns tier 0 for empty query', () {
      expect(scoreMatch('', 'anything'), const MatchScore(tier: 0, offset: 0));
    });

    test('returns tier 0 for an empty query against empty text', () {
      expect(scoreMatch('', ''), const MatchScore(tier: 0, offset: 0));
    });

    test('returns tier 0 for exact match ignoring case', () {
      expect(scoreMatch('pi', 'pi'), const MatchScore(tier: 0, offset: 0));
      expect(scoreMatch('PI', 'pi'), const MatchScore(tier: 0, offset: 0));
      expect(scoreMatch('Pi', 'pI'), const MatchScore(tier: 0, offset: 0));
    });

    test('returns tier 1 for whole-word match at start', () {
      expect(
        scoreMatch('feat', 'feat/pi-direct-sdk'),
        const MatchScore(tier: 1, offset: 0),
      );
    });

    test('returns tier 1 for whole-word match in middle', () {
      expect(
        scoreMatch('pi', 'feat/pi-direct-sdk'),
        const MatchScore(tier: 1, offset: 5),
      );
      expect(
        scoreMatch('pi', 'a b pi c d'),
        const MatchScore(tier: 1, offset: 4),
      );
    });

    test(
      'returns tier 2 for a string prefix that does not complete a word',
      () {
        expect(
          scoreMatch('par', 'party'),
          const MatchScore(tier: 2, offset: 0),
        );
      },
    );

    test('returns tier 3 for a word-boundary start inside a longer word', () {
      expect(
        scoreMatch('par', 'a/party'),
        const MatchScore(tier: 3, offset: 2),
      );
    });

    test('returns tier 4 for a substring buried inside a word', () {
      expect(scoreMatch('art', 'party'), const MatchScore(tier: 4, offset: 1));
    });

    test('returns null when the query is not found', () {
      expect(scoreMatch('xyz', 'feat/pi-direct-sdk'), isNull);
    });

    test('returns null when the query is longer than the text', () {
      expect(scoreMatch('abc', 'ab'), isNull);
    });

    test('returns null for a non-empty query against empty text', () {
      expect(scoreMatch('a', ''), isNull);
    });

    test('picks the best tier across multiple occurrences', () {
      expect(
        scoreMatch('ab', 'xabxab-yy'),
        const MatchScore(tier: 4, offset: 1),
      );
      expect(
        scoreMatch('ab', 'xxab x-ab-y'),
        const MatchScore(tier: 1, offset: 7),
      );
    });

    test('prefers earlier offset when tiers are equal', () {
      expect(
        scoreMatch('pi', 'pi-a pi-b'),
        const MatchScore(tier: 1, offset: 0),
      );
    });

    test('treats common separators as word boundaries', () {
      for (final text in ['x/pi', 'x-pi', 'x_pi', 'x pi', 'x.pi', 'x:pi']) {
        expect(
          scoreMatch('pi', text),
          const MatchScore(tier: 1, offset: 2),
          reason: text,
        );
      }
      expect(
        scoreMatch('202', '#202 feat'),
        const MatchScore(tier: 1, offset: 1),
      );
    });

    test('treats digits as word characters, not boundaries', () {
      // '1' is a word character, so the match does not start at a boundary.
      expect(scoreMatch('pi', 'x1pi'), const MatchScore(tier: 4, offset: 2));
    });

    test('treats non-ASCII characters as word boundaries', () {
      // Upstream's boundary test is `/[a-z0-9]/`, so anything outside ASCII
      // word characters — including CJK — counts as a boundary.
      expect(
        scoreMatch('pi', '\uAC00pi'),
        const MatchScore(tier: 1, offset: 1),
      );
    });

    test(
      'a trailing word character downgrades a zero-offset match to tier 2',
      () {
        expect(scoreMatch('pi', 'pix'), const MatchScore(tier: 2, offset: 0));
      },
    );

    test('lowercases the text before boundary testing', () {
      expect(scoreMatch('pi', 'XPI'), const MatchScore(tier: 4, offset: 1));
    });

    test('scores PR-title-shaped text realistically', () {
      const pr202 =
          '#202 feat(server): replace Pi ACP with direct SDK provider';
      expect(scoreMatch('pi', pr202)?.tier, 1);
      expect(scoreMatch('202', pr202), const MatchScore(tier: 1, offset: 1));
      expect(scoreMatch('replace', pr202)?.tier, 1);
    });

    test('falls back to a tier 5 subsequence with a spread', () {
      expect(
        scoreMatch('ac', 'abc'),
        const MatchScore(tier: 5, offset: 0, spread: 3),
      );
      expect(
        scoreMatch('ad', 'a-b-c-d'),
        const MatchScore(tier: 5, offset: 0, spread: 7),
      );
    });

    test('subsequence matching is greedy, not optimal', () {
      // The tight match is 'a' at 4 and 'b' at 6 (spread 3), but the walk
      // consumes the first viable 'a' at 0 and reports spread 7.
      expect(
        scoreMatch('ab', 'a-x-a b'),
        const MatchScore(tier: 5, offset: 0, spread: 7),
      );
    });

    test('subsequence matching is case-insensitive', () {
      expect(
        scoreMatch('AC', 'AbC'),
        const MatchScore(tier: 5, offset: 0, spread: 3),
      );
    });

    test('leaves spread null for every non-fuzzy tier', () {
      expect(scoreMatch('', 'party')?.spread, isNull);
      expect(scoreMatch('party', 'party')?.spread, isNull);
      expect(scoreMatch('par', 'party')?.spread, isNull);
      expect(scoreMatch('art', 'party')?.spread, isNull);
    });

    test('a substring hit always beats an available subsequence', () {
      // 'ab' is both a substring of 'xxab' and a subsequence of it; the
      // substring branch runs first and wins.
      expect(scoreMatch('ab', 'xxab'), const MatchScore(tier: 4, offset: 2));
    });
  });

  group('compareMatchScores', () {
    test('sorts by tier ascending', () {
      expect(
        compareMatchScores(
          const MatchScore(tier: 1, offset: 10),
          const MatchScore(tier: 2, offset: 0),
        ),
        lessThan(0),
      );
      expect(
        compareMatchScores(
          const MatchScore(tier: 3, offset: 0),
          const MatchScore(tier: 1, offset: 99),
        ),
        greaterThan(0),
      );
    });

    test('tie-breaks by offset ascending at the same tier', () {
      expect(
        compareMatchScores(
          const MatchScore(tier: 1, offset: 0),
          const MatchScore(tier: 1, offset: 5),
        ),
        lessThan(0),
      );
      expect(
        compareMatchScores(
          const MatchScore(tier: 1, offset: 5),
          const MatchScore(tier: 1, offset: 5),
        ),
        0,
      );
    });

    test('tie-breaks by spread ascending when tier and offset match', () {
      expect(
        compareMatchScores(
          const MatchScore(tier: 5, offset: 0, spread: 3),
          const MatchScore(tier: 5, offset: 0, spread: 5),
        ),
        lessThan(0),
      );
    });

    test('treats a null spread as zero', () {
      expect(
        compareMatchScores(
          const MatchScore(tier: 5, offset: 0),
          const MatchScore(tier: 5, offset: 0, spread: 0),
        ),
        0,
      );
      expect(
        compareMatchScores(
          const MatchScore(tier: 5, offset: 0),
          const MatchScore(tier: 5, offset: 0, spread: 2),
        ),
        lessThan(0),
      );
    });

    test('sorts a list best-first', () {
      final scores = <MatchScore>[
        const MatchScore(tier: 5, offset: 0, spread: 9),
        const MatchScore(tier: 1, offset: 7),
        const MatchScore(tier: 0, offset: 0),
        const MatchScore(tier: 1, offset: 2),
      ]..sort(compareMatchScores);
      expect(scores, [
        const MatchScore(tier: 0, offset: 0),
        const MatchScore(tier: 1, offset: 2),
        const MatchScore(tier: 1, offset: 7),
        const MatchScore(tier: 5, offset: 0, spread: 9),
      ]);
    });
  });

  group('scoreTextFields', () {
    test('returns an all-zero score for an empty query', () {
      expect(
        scoreTextFields('', ['anything']),
        const MatchScore(tier: 0, offset: 0, spread: 0),
      );
    });

    test('returns an all-zero score for a whitespace-only query', () {
      expect(
        scoreTextFields('  \t\n ', ['anything']),
        const MatchScore(tier: 0, offset: 0, spread: 0),
      );
    });

    test('sums tier and offset across tokens', () {
      expect(
        scoreTextFields('feat pi', ['feat/pi-direct-sdk']),
        const MatchScore(tier: 2, offset: 5, spread: 6),
      );
    });

    test('charges a non-fuzzy match the token length as its spread', () {
      expect(
        scoreTextFields('par', ['party']),
        const MatchScore(tier: 2, offset: 0, spread: 3),
      );
    });

    test('uses the real spread for a fuzzy match', () {
      expect(
        scoreTextFields('ac', ['abc']),
        const MatchScore(tier: 5, offset: 0, spread: 3),
      );
    });

    test('lets each token pick its own best field', () {
      expect(
        scoreTextFields('pi', ['xxpi', 'pi']),
        const MatchScore(tier: 0, offset: 0, spread: 2),
      );
      expect(
        scoreTextFields('feat pi', ['feat', 'pi']),
        const MatchScore(tier: 0, offset: 0, spread: 6),
      );
    });

    test('returns null when any single token matches nothing', () {
      expect(scoreTextFields('feat zzz', ['feat/pi']), isNull);
      expect(scoreTextFields('zz', ['abc', 'def']), isNull);
    });

    test('returns null for a non-empty query with no fields to search', () {
      expect(scoreTextFields('a', const []), isNull);
    });

    test('lowercases and trims the query before tokenizing', () {
      expect(
        scoreTextFields('  PI  ', ['pi']),
        const MatchScore(tier: 0, offset: 0, spread: 2),
      );
    });

    test('splits on runs of any whitespace', () {
      expect(
        scoreTextFields('feat\t\n  pi', ['feat/pi']),
        const MatchScore(tier: 2, offset: 5, spread: 6),
      );
    });

    test('a multi-word query narrows rather than widens', () {
      // 'feat' alone matches, but adding an absent token rejects the row.
      expect(scoreTextFields('feat', ['feat/pi']), isNotNull);
      expect(scoreTextFields('feat nope', ['feat/pi']), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // utils/web-focus.ts
  // -------------------------------------------------------------------------

  group('focusWithRetries', () {
    test('tries to focus immediately before waiting for animation frames', () {
      final frames = _FrameQueue();
      var focused = false;
      var focusCalls = 0;
      var successCalls = 0;

      focusWithRetries(
        focus: () {
          focusCalls += 1;
          focused = true;
        },
        isFocused: () => focused,
        scheduleFrame: frames.schedule,
        onSuccess: () => successCalls += 1,
      );

      expect(focusCalls, 1);
      expect(successCalls, 1);
      expect(frames.pendingCount, 0);
    });

    test('keeps retrying on later animation frames until focus succeeds', () {
      final frames = _FrameQueue();
      var focused = false;
      var focusCalls = 0;
      var successCalls = 0;

      focusWithRetries(
        focus: () {
          focusCalls += 1;
          if (focusCalls >= 3) focused = true;
        },
        isFocused: () => focused,
        scheduleFrame: frames.schedule,
        onSuccess: () => successCalls += 1,
      );

      expect(focusCalls, 1);
      expect(successCalls, 0);

      // Two frames per retry: a frame scheduled from inside a frame.
      frames.flush(2);
      expect(focusCalls, 2);
      expect(successCalls, 0);

      frames.flush(2);
      expect(focusCalls, 3);
      expect(successCalls, 1);
    });

    test('one flushed frame is not enough to trigger a retry', () {
      final frames = _FrameQueue();
      var focusCalls = 0;

      focusWithRetries(
        focus: () => focusCalls += 1,
        isFocused: () => false,
        scheduleFrame: frames.schedule,
      );

      frames.flush(1);
      expect(focusCalls, 1);
      frames.flush(1);
      expect(focusCalls, 2);
    });

    test('stops retrying after cancellation', () {
      final frames = _FrameQueue();
      var focusCalls = 0;

      final cancel = focusWithRetries(
        focus: () => focusCalls += 1,
        isFocused: () => false,
        scheduleFrame: frames.schedule,
      );

      expect(focusCalls, 1);

      cancel();
      frames.flush(4);

      expect(focusCalls, 1);
    });

    test('cancellation suppresses the timeout callback too', () {
      final frames = _FrameQueue();
      final clock = _FakeClock(DateTime.utc(2026));
      var timeoutCalls = 0;

      final cancel = focusWithRetries(
        focus: () {},
        isFocused: () => false,
        scheduleFrame: frames.schedule,
        now: clock.now,
        timeout: const Duration(milliseconds: 10),
        onTimeout: () => timeoutCalls += 1,
      );

      cancel();
      clock.advance(const Duration(seconds: 1));
      frames.flush(4);

      expect(timeoutCalls, 0);
    });

    test('cancelling twice is harmless', () {
      final frames = _FrameQueue();
      final cancel = focusWithRetries(
        focus: () {},
        isFocused: () => false,
        scheduleFrame: frames.schedule,
      );

      expect(cancel, returnsNormally);
      cancel();
      cancel();
      frames.flush(2);
    });

    test('reports a timeout without scheduling a frame when already due', () {
      final frames = _FrameQueue();
      final clock = _FakeClock(DateTime.utc(2026));
      var focusCalls = 0;
      var timeoutCalls = 0;
      var successCalls = 0;

      focusWithRetries(
        focus: () => focusCalls += 1,
        isFocused: () => false,
        scheduleFrame: frames.schedule,
        now: clock.now,
        timeout: Duration.zero,
        onSuccess: () => successCalls += 1,
        onTimeout: () => timeoutCalls += 1,
      );

      // Landing exactly on the deadline is a timeout, not another attempt.
      expect(focusCalls, 1);
      expect(timeoutCalls, 1);
      expect(successCalls, 0);
      expect(frames.pendingCount, 0);
    });

    test('reports a timeout once the deadline passes between retries', () {
      final frames = _FrameQueue();
      final clock = _FakeClock(DateTime.utc(2026));
      var focusCalls = 0;
      var timeoutCalls = 0;

      focusWithRetries(
        focus: () => focusCalls += 1,
        isFocused: () => false,
        scheduleFrame: frames.schedule,
        now: clock.now,
        timeout: const Duration(milliseconds: 10),
        onTimeout: () => timeoutCalls += 1,
      );

      expect(focusCalls, 1);
      expect(timeoutCalls, 0);

      clock.advance(const Duration(milliseconds: 20));
      frames.flush(2);

      expect(focusCalls, 2);
      expect(timeoutCalls, 1);
      expect(frames.pendingCount, 0);
    });

    test('keeps retrying inside the default 1500ms budget', () {
      final frames = _FrameQueue();
      final clock = _FakeClock(DateTime.utc(2026));
      var focusCalls = 0;
      var timeoutCalls = 0;

      focusWithRetries(
        focus: () => focusCalls += 1,
        isFocused: () => false,
        scheduleFrame: frames.schedule,
        now: clock.now,
        onTimeout: () => timeoutCalls += 1,
      );

      clock.advance(const Duration(milliseconds: 1400));
      frames.flush(2);
      expect(focusCalls, 2);
      expect(timeoutCalls, 0);

      clock.advance(const Duration(milliseconds: 200));
      frames.flush(2);
      expect(focusCalls, 3);
      expect(timeoutCalls, 1);
    });

    test('swallows exceptions thrown by the focus target and retries', () {
      final frames = _FrameQueue();
      var focusCalls = 0;

      focusWithRetries(
        focus: () {
          focusCalls += 1;
          throw StateError('not attached');
        },
        isFocused: () => false,
        scheduleFrame: frames.schedule,
      );

      expect(focusCalls, 1);
      frames.flush(2);
      expect(focusCalls, 2);
    });

    test(
      'a throwing focus target still succeeds when focus actually landed',
      () {
        final frames = _FrameQueue();
        var successCalls = 0;

        focusWithRetries(
          focus: () => throw StateError('reported failure'),
          isFocused: () => true,
          scheduleFrame: frames.schedule,
          onSuccess: () => successCalls += 1,
        );

        expect(successCalls, 1);
      },
    );

    test(
      'omitted callbacks are safe on both the success and timeout paths',
      () {
        final frames = _FrameQueue();
        final clock = _FakeClock(DateTime.utc(2026));

        expect(
          () => focusWithRetries(
            focus: () {},
            isFocused: () => true,
            scheduleFrame: frames.schedule,
          ),
          returnsNormally,
        );
        expect(
          () => focusWithRetries(
            focus: () {},
            isFocused: () => false,
            scheduleFrame: frames.schedule,
            now: clock.now,
            timeout: Duration.zero,
          ),
          returnsNormally,
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // utils/app-visibility.ts
  // -------------------------------------------------------------------------

  group('isAppVisible / isAppActivelyVisible', () {
    test(
      'a visible desktop app stays visible when another window has focus',
      () {
        const input = ActiveAppVisibilityInput(
          appState: 'active',
          native: false,
          documentVisible: true,
          windowFocused: false,
        );

        expect(isAppVisible(input), isTrue);
        expect(isAppActivelyVisible(input), isFalse);
      },
    );

    test('a hidden desktop page is neither visible nor actively visible', () {
      const input = ActiveAppVisibilityInput(
        appState: 'active',
        native: false,
        documentVisible: false,
        windowFocused: true,
      );

      expect(isAppVisible(input), isFalse);
      expect(isAppActivelyVisible(input), isFalse);
    });

    test('a focused, visible desktop app is both', () {
      const input = ActiveAppVisibilityInput(
        appState: 'active',
        native: false,
        documentVisible: true,
        windowFocused: true,
      );

      expect(isAppVisible(input), isTrue);
      expect(isAppActivelyVisible(input), isTrue);
    });

    test('native ignores the document and focus signals entirely', () {
      const input = ActiveAppVisibilityInput(
        appState: 'active',
        native: true,
        documentVisible: false,
        windowFocused: false,
      );

      expect(isAppVisible(input), isTrue);
      expect(isAppActivelyVisible(input), isTrue);
    });

    test('a non-active app state loses on every other signal', () {
      for (final state in ['background', 'inactive', 'unknown', '']) {
        final input = ActiveAppVisibilityInput(
          appState: state,
          native: true,
          documentVisible: true,
          windowFocused: true,
        );
        expect(isAppVisible(input), isFalse, reason: state);
        expect(isAppActivelyVisible(input), isFalse, reason: state);
      }
    });

    test('the active state constant is the wire value upstream compares', () {
      expect(activeAppState, 'active');
    });
  });

  group('getIsAppVisible / getIsAppActivelyVisible', () {
    test('a host with no document is treated as visible and focused', () {
      final host = AppVisibilityHost(
        native: true,
        currentAppState: () => 'active',
      );

      expect(getIsAppVisible(host), isTrue);
      expect(getIsAppActivelyVisible(host), isTrue);
    });

    test('a web host with no reportable focus is treated as focused', () {
      final host = AppVisibilityHost(
        native: false,
        currentAppState: () => 'active',
        documentVisible: () => true,
      );

      expect(getIsAppVisible(host), isTrue);
      expect(getIsAppActivelyVisible(host), isTrue);
    });

    test('a web host reads its document and focus signals', () {
      final host = AppVisibilityHost(
        native: false,
        currentAppState: () => 'active',
        documentVisible: () => true,
        windowFocused: () => false,
      );

      expect(getIsAppVisible(host), isTrue);
      expect(getIsAppActivelyVisible(host), isFalse);
    });

    test('a hidden web document loses both answers', () {
      final host = AppVisibilityHost(
        native: false,
        currentAppState: () => 'active',
        documentVisible: () => false,
        windowFocused: () => true,
      );

      expect(getIsAppVisible(host), isFalse);
      expect(getIsAppActivelyVisible(host), isFalse);
    });

    test('the host app state is read lazily on every call', () {
      var state = 'background';
      final host = AppVisibilityHost(
        native: true,
        currentAppState: () => state,
      );

      expect(getIsAppVisible(host), isFalse);
      state = 'active';
      expect(getIsAppVisible(host), isTrue);
    });

    test('an explicit app state overrides whatever the host reports', () {
      final host = AppVisibilityHost(
        native: true,
        currentAppState: () => 'background',
      );

      expect(getIsAppVisible(host, 'active'), isTrue);
      expect(getIsAppActivelyVisible(host, 'active'), isTrue);
      expect(getIsAppVisible(host, 'inactive'), isFalse);
      expect(getIsAppActivelyVisible(host, 'inactive'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // utils/format-shortcut.ts
  // -------------------------------------------------------------------------

  group('formatShortcut', () {
    test('uses symbols on macOS', () {
      expect(formatShortcut(['mod', 'B'], ShortcutOs.mac), '${_cmd}B');
      expect(formatShortcut(['mod', 'E'], ShortcutOs.mac), '${_cmd}E');
    });

    test('spells out Shift in shortcut labels', () {
      expect(formatShortcut(['shift', 'Tab'], ShortcutOs.mac), 'Shift+Tab');
      expect(
        formatShortcut(['mod', 'shift', 'P'], ShortcutOs.mac),
        'Shift+$_cmd+P',
      );
      expect(formatShortcut(['shift', 'Tab'], ShortcutOs.nonMac), 'Shift+Tab');
    });

    test('uses Ctrl+ on non-mac platforms', () {
      expect(formatShortcut(['mod', 'B'], ShortcutOs.nonMac), 'Ctrl+B');
      expect(formatShortcut(['mod', 'E'], ShortcutOs.nonMac), 'Ctrl+E');
    });

    test('re-orders macOS modifiers into platform order', () {
      expect(
        formatShortcut(['shift', 'mod', 'P'], ShortcutOs.mac),
        formatShortcut(['mod', 'shift', 'P'], ShortcutOs.mac),
      );
      expect(
        formatShortcut(['mod', 'alt', 'ctrl', 'K'], ShortcutOs.mac),
        '$_ctl$_opt${_cmd}K',
      );
    });

    test('preserves the caller order on non-mac platforms', () {
      expect(
        formatShortcut(['mod', 'alt', 'ctrl', 'K'], ShortcutOs.nonMac),
        'Ctrl+Alt+Ctrl+K',
      );
    });

    test('renders every macOS modifier, with Shift forcing separators', () {
      expect(
        formatShortcut([
          'ctrl',
          'alt',
          'shift',
          'mod',
          'meta',
          'K',
        ], ShortcutOs.mac),
        '$_ctl+$_opt+Shift+$_cmd+$_cmd+K',
      );
    });

    test('maps meta to the command glyph on mac and to Win elsewhere', () {
      expect(formatShortcut(['meta', 'B'], ShortcutOs.mac), '${_cmd}B');
      expect(formatShortcut(['meta', 'B'], ShortcutOs.nonMac), 'Win+B');
    });

    test('collapses duplicate modifiers on mac but not on non-mac', () {
      // Upstream builds a Set for the mac branch only; the non-mac branch maps
      // element-wise. Frozen, not fixed.
      expect(formatShortcut(['mod', 'mod', 'B'], ShortcutOs.mac), '${_cmd}B');
      expect(
        formatShortcut(['mod', 'mod', 'B'], ShortcutOs.nonMac),
        'Ctrl+Ctrl+B',
      );
    });

    test('uppercases single-character keys', () {
      expect(formatShortcut(['mod', 'b'], ShortcutOs.mac), '${_cmd}B');
      expect(formatShortcut(['mod', 'b'], ShortcutOs.nonMac), 'Ctrl+B');
      expect(formatShortcut(['1'], ShortcutOs.nonMac), '1');
    });

    test('passes unknown multi-character key names through unchanged', () {
      expect(formatShortcut(['mod', 'Tab'], ShortcutOs.mac), '${_cmd}Tab');
      expect(formatShortcut(['F12'], ShortcutOs.nonMac), 'F12');
    });

    test('renders display glyphs for named keys', () {
      expect(formatShortcut(['Backspace'], ShortcutOs.mac), _backspace);
      expect(formatShortcut(['Enter'], ShortcutOs.mac), _enter);
      expect(formatShortcut(['Space'], ShortcutOs.mac), _space);
      expect(formatShortcut(['Esc'], ShortcutOs.mac), 'Esc');
      expect(
        formatShortcut(['Left', 'Right', 'Up', 'Down'], ShortcutOs.mac),
        '$_left$_right$_up$_down',
      );
      expect(formatShortcut(['alt', 'Left'], ShortcutOs.nonMac), 'Alt+$_left');
    });

    test('concatenates multiple main keys on mac and joins them elsewhere', () {
      expect(formatShortcut(['mod', 'K', 'P'], ShortcutOs.mac), '${_cmd}KP');
      expect(formatShortcut(['mod', 'K', 'P'], ShortcutOs.nonMac), 'Ctrl+K+P');
    });

    test('renders modifier-only shortcuts', () {
      expect(formatShortcut(['mod'], ShortcutOs.mac), _cmd);
      expect(formatShortcut(['mod'], ShortcutOs.nonMac), 'Ctrl');
      expect(formatShortcut(['shift'], ShortcutOs.mac), 'Shift');
      expect(formatShortcut(['shift', 'mod'], ShortcutOs.mac), 'Shift+$_cmd');
      expect(formatShortcut(['ctrl'], ShortcutOs.mac), _ctl);
    });

    test('drops empty key names on both platforms', () {
      expect(formatShortcut(['mod', ''], ShortcutOs.mac), _cmd);
      expect(formatShortcut(['mod', ''], ShortcutOs.nonMac), 'Ctrl');
      expect(formatShortcut(['shift', ''], ShortcutOs.mac), 'Shift');
    });

    test('renders an empty shortcut as an empty string', () {
      expect(formatShortcut(const [], ShortcutOs.mac), '');
      expect(formatShortcut(const [], ShortcutOs.nonMac), '');
    });

    test('ctrl stays Ctrl on non-mac and becomes a glyph on mac', () {
      expect(formatShortcut(['ctrl', 'B'], ShortcutOs.nonMac), 'Ctrl+B');
      expect(formatShortcut(['ctrl', 'B'], ShortcutOs.mac), '${_ctl}B');
    });
  });

  // -------------------------------------------------------------------------
  // utils/rich-clipboard.ts
  // -------------------------------------------------------------------------

  group('createMarkdownClipboardContent', () {
    test('keeps the markdown source as the plain-text flavour', () {
      final content = createMarkdownClipboardContent(
        '# Heading',
        _fakeMarkdownHtml,
      );
      expect(content.plainText, '# Heading');
    });

    test('prefixes the rendered html with a utf-8 meta tag', () {
      final content = createMarkdownClipboardContent(
        '# Heading',
        _fakeMarkdownHtml,
      );
      expect(content.html, startsWith('<meta charset="utf-8">'));
      expect(content.html, contains('<h1>Heading</h1>'));
    });

    test('passes the markdown through to the injected renderer verbatim', () {
      String? seen;
      createMarkdownClipboardContent('- Parent\n  - Child', (markdown) {
        seen = markdown;
        return '';
      });
      expect(seen, '- Parent\n  - Child');
    });

    test('renders list and code structures through the injected renderer', () {
      final content = createMarkdownClipboardContent(
        '- item\n\n```ts\nconst value = 1;\n```',
        _fakeMarkdownHtml,
      );
      expect(content.html, contains('<li>item</li>'));
      expect(content.html, contains('class="language-ts"'));
    });

    test('an empty document still carries the charset prefix', () {
      final content = createMarkdownClipboardContent('', _fakeMarkdownHtml);
      expect(content.plainText, '');
      expect(content.html, '<meta charset="utf-8">');
    });
  });

  group('writeMarkdownToRichClipboard', () {
    test(
      'writes plain text and html when a rich writer is available',
      () async {
        final clipboard = _RecordingClipboard();

        await writeMarkdownToRichClipboard('- item', clipboard.environment);

        expect(clipboard.richWrites, hasLength(1));
        final written = clipboard.richWrites.single;
        expect(
          written[ClipboardMimeType.plainText],
          const ClipboardBlob(
            mimeType: ClipboardMimeType.plainText,
            text: '- item',
          ),
        );
        expect(
          written[ClipboardMimeType.html]!.text,
          contains('<li>item</li>'),
        );
        expect(
          written[ClipboardMimeType.html]!.text,
          startsWith('<meta charset="utf-8">'),
        );
        expect(
          written[ClipboardMimeType.html]!.mimeType,
          ClipboardMimeType.html,
        );
        expect(clipboard.plainTexts, isEmpty);
        expect(clipboard.renderCalls, 1);
      },
    );

    test(
      'falls back to plain text when rich clipboard writing fails',
      () async {
        final clipboard = _RecordingClipboard(richWriteFails: true);

        await writeMarkdownToRichClipboard('**bold**', clipboard.environment);

        expect(clipboard.plainTexts, ['**bold**']);
        expect(clipboard.richWrites, isEmpty);
      },
    );

    test('skips the rich path entirely when html is unsupported', () async {
      final clipboard = _RecordingClipboard(supportsHtml: false);

      await writeMarkdownToRichClipboard('**bold**', clipboard.environment);

      expect(clipboard.plainTexts, ['**bold**']);
      expect(clipboard.richWrites, isEmpty);
      // No markdown is rendered for a path that cannot use it.
      expect(clipboard.renderCalls, 0);
    });

    test('skips the rich path when the host has no rich writer', () async {
      final clipboard = _RecordingClipboard(hasRichWriter: false);

      await writeMarkdownToRichClipboard('**bold**', clipboard.environment);

      expect(clipboard.plainTexts, ['**bold**']);
      expect(clipboard.renderCalls, 0);
    });

    test('does not double-write plain text on the rich path', () async {
      final clipboard = _RecordingClipboard();

      await writeMarkdownToRichClipboard('a', clipboard.environment);
      await writeMarkdownToRichClipboard('b', clipboard.environment);

      expect(clipboard.richWrites, hasLength(2));
      expect(clipboard.plainTexts, isEmpty);
    });

    test('the mime enum carries the wire strings the clipboard keys off', () {
      expect(ClipboardMimeType.plainText.wireValue, 'text/plain');
      expect(ClipboardMimeType.html.wireValue, 'text/html');
    });
  });

  // -------------------------------------------------------------------------
  // utils/assistant-image-source.ts
  // -------------------------------------------------------------------------

  group('resolveAssistantImageSource', () {
    test('passes through direct image URIs', () {
      expect(
        resolveAssistantImageSource(source: 'https://example.com/image.png'),
        const AssistantImageDirectSource(uri: 'https://example.com/image.png'),
      );
      expect(
        resolveAssistantImageSource(source: 'data:image/png;base64,abc'),
        const AssistantImageDirectSource(uri: 'data:image/png;base64,abc'),
      );
    });

    test('passes through http and blob URIs, case-insensitively', () {
      expect(
        resolveAssistantImageSource(source: 'http://example.com/a.png'),
        const AssistantImageDirectSource(uri: 'http://example.com/a.png'),
      );
      expect(
        resolveAssistantImageSource(source: 'blob:https://example.com/abc'),
        const AssistantImageDirectSource(uri: 'blob:https://example.com/abc'),
      );
      expect(
        resolveAssistantImageSource(source: 'HTTPS://example.com/a.png'),
        const AssistantImageDirectSource(uri: 'HTTPS://example.com/a.png'),
      );
      expect(
        resolveAssistantImageSource(source: 'DATA:image/png;base64,abc'),
        const AssistantImageDirectSource(uri: 'DATA:image/png;base64,abc'),
      );
    });

    test('trims surrounding whitespace before resolving', () {
      expect(
        resolveAssistantImageSource(source: '  https://example.com/a.png \n'),
        const AssistantImageDirectSource(uri: 'https://example.com/a.png'),
      );
    });

    test('returns null for an empty or whitespace-only source', () {
      expect(resolveAssistantImageSource(source: ''), isNull);
      expect(resolveAssistantImageSource(source: '   \n\t '), isNull);
    });

    test('uses the workspace root for relative paths', () {
      expect(
        resolveAssistantImageSource(
          source: 'screenshots/output.png',
          workspaceRoot: '/Users/test/project',
        ),
        const AssistantImageFileRpcSource(
          cwd: '/Users/test/project',
          path: 'screenshots/output.png',
        ),
      );
    });

    test('uses the workspace root for absolute paths inside the workspace', () {
      expect(
        resolveAssistantImageSource(
          source: '/Users/test/project/screenshots/output.png',
          workspaceRoot: '/Users/test/project',
        ),
        const AssistantImageFileRpcSource(
          cwd: '/Users/test/project',
          path: '/Users/test/project/screenshots/output.png',
        ),
      );
    });

    test('falls back to filesystem root for absolute paths outside it', () {
      expect(
        resolveAssistantImageSource(
          source: '/tmp/paseo-codex-screenshot.png',
          workspaceRoot: '/Users/test/project',
        ),
        const AssistantImageFileRpcSource(
          cwd: '/',
          path: '/tmp/paseo-codex-screenshot.png',
        ),
      );
    });

    test('uses the same home-root target as file previews for tilde paths', () {
      expect(
        resolveAssistantImageSource(
          source: '~/.paseo/screenshots/output.png',
          workspaceRoot: '/Users/test/project',
        ),
        const AssistantImageFileRpcSource(
          cwd: '~',
          path: '~/.paseo/screenshots/output.png',
        ),
      );
    });

    test('recognises bare and backslashed tilde paths as home-relative', () {
      expect(
        resolveAssistantImageSource(source: '~'),
        const AssistantImageFileRpcSource(cwd: '~', path: '~'),
      );
      expect(
        resolveAssistantImageSource(source: r'~\pics\a.png'),
        const AssistantImageFileRpcSource(cwd: '~', path: r'~\pics\a.png'),
      );
    });

    test('normalizes file URIs into file RPC requests', () {
      expect(
        resolveAssistantImageSource(
          source: 'file:///tmp/paseo-codex-screenshot.png',
          workspaceRoot: '/Users/test/project',
        ),
        const AssistantImageFileRpcSource(
          cwd: '/',
          path: '/tmp/paseo-codex-screenshot.png',
        ),
      );
    });

    test('normalizes a Windows file URI down to a drive path', () {
      expect(
        resolveAssistantImageSource(
          source: 'file:///C:/Users/test/a.png',
          workspaceRoot: 'D:/repo',
        ),
        const AssistantImageFileRpcSource(
          cwd: 'C:/',
          path: 'C:/Users/test/a.png',
        ),
      );
    });

    test('normalizes markdown-encoded Windows paths into file RPC requests', () {
      expect(
        resolveAssistantImageSource(
          source:
              'C:%5CUsers%5Chanse%5CAppData%5CLocal%5CTemp%5Cpaseo-attachments%5Cimage.png',
          workspaceRoot: 'C:/Users/hanse/eatingkat',
        ),
        const AssistantImageFileRpcSource(
          cwd: 'C:/',
          path: 'C:/Users/hanse/AppData/Local/Temp/paseo-attachments/image.png',
        ),
      );
    });

    test('falls back to the drive root for Windows absolute paths', () {
      expect(
        resolveAssistantImageSource(
          source: 'C:/Users/test/Desktop/screenshot.png',
          workspaceRoot: 'D:/repo',
        ),
        const AssistantImageFileRpcSource(
          cwd: 'C:/',
          path: 'C:/Users/test/Desktop/screenshot.png',
        ),
      );
    });

    test(
      'compares Windows drive letters case-insensitively for containment',
      () {
        expect(
          resolveAssistantImageSource(
            source: 'c:/repo/pics/a.png',
            workspaceRoot: r'C:\repo',
          ),
          const AssistantImageFileRpcSource(
            cwd: r'C:\repo',
            path: 'c:/repo/pics/a.png',
          ),
        );
      },
    );

    test(
      'a trailing separator on the workspace root still contains a path',
      () {
        expect(
          resolveAssistantImageSource(
            source: '/Users/test/project/a.png',
            workspaceRoot: '/Users/test/project/',
          ),
          // The root is reported exactly as given; only the comparison is
          // normalized.
          const AssistantImageFileRpcSource(
            cwd: '/Users/test/project/',
            path: '/Users/test/project/a.png',
          ),
        );
      },
    );

    test('a sibling directory is not inside the workspace', () {
      expect(
        resolveAssistantImageSource(
          source: '/Users/test/project-backup/a.png',
          workspaceRoot: '/Users/test/project',
        ),
        const AssistantImageFileRpcSource(
          cwd: '/',
          path: '/Users/test/project-backup/a.png',
        ),
      );
    });

    test('the workspace root itself counts as inside the workspace', () {
      expect(
        resolveAssistantImageSource(
          source: '/Users/test/project',
          workspaceRoot: '/Users/test/project',
        ),
        const AssistantImageFileRpcSource(
          cwd: '/Users/test/project',
          path: '/Users/test/project',
        ),
      );
    });

    test('scopes a UNC path to its share, not its server', () {
      expect(
        resolveAssistantImageSource(
          source: r'\\server\share\pics\a.png',
          workspaceRoot: 'C:/repo',
        ),
        const AssistantImageFileRpcSource(
          cwd: r'\\server\share',
          path: r'\\server\share\pics\a.png',
        ),
      );
    });

    test('returns null for an absolute path with no derivable root', () {
      // A UNC prefix with no share is absolute by the path check but has no
      // mountable root to scope a read to.
      expect(resolveAssistantImageSource(source: r'\\server'), isNull);
    });

    test('returns null for a relative path with no usable workspace root', () {
      expect(resolveAssistantImageSource(source: 'pics/a.png'), isNull);
      expect(
        resolveAssistantImageSource(source: 'pics/a.png', workspaceRoot: ''),
        isNull,
      );
      expect(
        resolveAssistantImageSource(source: 'pics/a.png', workspaceRoot: '   '),
        isNull,
      );
      expect(
        resolveAssistantImageSource(
          source: 'pics/a.png',
          workspaceRoot: 'relative/root',
        ),
        isNull,
      );
    });

    test(
      'a relative workspace root does not scope an absolute path either',
      () {
        expect(
          resolveAssistantImageSource(
            source: '/tmp/a.png',
            workspaceRoot: 'relative/root',
          ),
          const AssistantImageFileRpcSource(cwd: '/', path: '/tmp/a.png'),
        );
      },
    );

    test('a file URI is never treated as a direct source', () {
      final resolved = resolveAssistantImageSource(source: 'file:///tmp/a.png');
      expect(resolved, isA<AssistantImageFileRpcSource>());
    });
  });
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// Stands in for the browser frame queue upstream's suite fakes out.
///
/// [flush] mirrors the upstream helper exactly: each iteration drains the queue
/// as it stands and runs those callbacks, so callbacks scheduled *during* an
/// iteration wait for the next one.
final class _FrameQueue {
  List<void Function()> _pending = <void Function()>[];

  int get pendingCount => _pending.length;

  void schedule(void Function() callback) => _pending.add(callback);

  void flush(int count) {
    for (var index = 0; index < count; index += 1) {
      final callbacks = _pending;
      _pending = <void Function()>[];
      for (final callback in callbacks) {
        callback();
      }
    }
  }
}

final class _FakeClock {
  _FakeClock(this._now);

  DateTime _now;

  DateTime now() => _now;

  void advance(Duration delta) => _now = _now.add(delta);
}

/// A deliberately tiny markdown-to-HTML stand-in.
///
/// The real renderer is injected (see [MarkdownHtmlRenderer]), so these tests
/// pin the clipboard plumbing — the charset prefix, the flavour map, the
/// degrade-to-plain-text path — rather than markdown-it's output, which no
/// longer lives inside the module under test.
String _fakeMarkdownHtml(String markdown) {
  final buffer = StringBuffer();
  for (final line in markdown.split('\n')) {
    if (line.startsWith('# ')) {
      buffer.write('<h1>${line.substring(2)}</h1>');
    } else if (line.startsWith('- ')) {
      buffer.write('<ul><li>${line.substring(2).trim()}</li></ul>');
    } else if (line.startsWith('```') && line.length > 3) {
      buffer.write('<pre><code class="language-${line.substring(3)}">');
    }
  }
  return buffer.toString();
}

final class _RecordingClipboard {
  _RecordingClipboard({
    bool supportsHtml = true,
    bool richWriteFails = false,
    bool hasRichWriter = true,
  }) {
    environment = MarkdownClipboardEnvironment(
      renderMarkdownHtml: (markdown) {
        renderCalls += 1;
        return _fakeMarkdownHtml(markdown);
      },
      writePlainText: (text) async => plainTexts.add(text),
      richWriter: hasRichWriter
          ? RichClipboardWriter(
              supportsHtml: () => supportsHtml,
              write: (data) async {
                if (richWriteFails) {
                  throw StateError('clipboard denied');
                }
                richWrites.add(data);
              },
            )
          : null,
    );
  }

  late final MarkdownClipboardEnvironment environment;
  final List<Map<ClipboardMimeType, ClipboardBlob>> richWrites = [];
  final List<String> plainTexts = [];
  int renderCalls = 0;
}
