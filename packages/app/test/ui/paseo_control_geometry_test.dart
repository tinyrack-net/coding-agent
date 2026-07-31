import 'package:coding_agent_app/ui/paseo_control_geometry.dart';
import 'package:flutter/widgets.dart' show Color, MainAxisAlignment;
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the fake theme in upstream `control-geometry.test.ts`. Every numeric
/// token there is already the [ControlGeometryTheme] default, so only the two
/// colors need stating.
const theme = ControlGeometryTheme(
  accent: Color(0xFF20744A),
  borderAccent: Color(0xFF2F3534),
);

const transparent = Color(0x00000000);

void main() {
  group('orderAutocompleteOptions', () {
    const options = ['alpha', 'beta', 'gamma'];

    test('keeps first logical option closest to the input by default', () {
      expect(orderAutocompleteOptions(options), ['gamma', 'beta', 'alpha']);
    });

    test('keeps normal top-down order when below-input is selected', () {
      expect(
        orderAutocompleteOptions(
          options,
          position: AutocompleteOptionsPosition.belowInput,
        ),
        ['alpha', 'beta', 'gamma'],
      );
    });

    test('returns a fresh list rather than aliasing the input', () {
      final source = ['alpha', 'beta'];
      final below = orderAutocompleteOptions(
        source,
        position: AutocompleteOptionsPosition.belowInput,
      );
      source.add('gamma');
      expect(below, ['alpha', 'beta']);
    });

    test('handles empty and single-element lists in both positions', () {
      expect(orderAutocompleteOptions(<String>[]), isEmpty);
      expect(
        orderAutocompleteOptions(
          <String>[],
          position: AutocompleteOptionsPosition.belowInput,
        ),
        isEmpty,
      );
      expect(orderAutocompleteOptions(['only']), ['only']);
    });
  });

  group('getAutocompleteFallbackIndex', () {
    test('picks the option nearest the input by default', () {
      expect(getAutocompleteFallbackIndex(3), 2);
      expect(getAutocompleteFallbackIndex(0), -1);
    });

    test('picks top item when below-input ordering is used', () {
      expect(
        getAutocompleteFallbackIndex(
          3,
          position: AutocompleteOptionsPosition.belowInput,
        ),
        0,
      );
    });

    test('collapses to the only item when there is exactly one', () {
      expect(getAutocompleteFallbackIndex(1), 0);
      expect(
        getAutocompleteFallbackIndex(
          1,
          position: AutocompleteOptionsPosition.belowInput,
        ),
        0,
      );
    });

    test('treats a negative count as empty', () {
      expect(getAutocompleteFallbackIndex(-4), -1);
      expect(
        getAutocompleteFallbackIndex(
          -4,
          position: AutocompleteOptionsPosition.belowInput,
        ),
        -1,
      );
    });
  });

  group('getAutocompleteNextIndex', () {
    test('delegates to the shared combobox wrap rule', () {
      expect(
        getAutocompleteNextIndex(
          currentIndex: 0,
          itemCount: 3,
          key: ComboboxArrowKey.down,
        ),
        1,
      );
      expect(
        getAutocompleteNextIndex(
          currentIndex: 2,
          itemCount: 3,
          key: ComboboxArrowKey.down,
        ),
        0,
      );
      expect(
        getAutocompleteNextIndex(
          currentIndex: 0,
          itemCount: 3,
          key: ComboboxArrowKey.up,
        ),
        2,
      );
    });

    test('enters from the matching edge when nothing is active yet', () {
      expect(
        getAutocompleteNextIndex(
          currentIndex: -1,
          itemCount: 3,
          key: ComboboxArrowKey.down,
        ),
        0,
      );
      expect(
        getAutocompleteNextIndex(
          currentIndex: -1,
          itemCount: 3,
          key: ComboboxArrowKey.up,
        ),
        2,
      );
    });

    test('has nowhere to go in an empty list', () {
      expect(
        getAutocompleteNextIndex(
          currentIndex: 0,
          itemCount: 0,
          key: ComboboxArrowKey.down,
        ),
        -1,
      );
    });

    test('normalizes an index left over from a longer list', () {
      expect(
        getAutocompleteNextIndex(
          currentIndex: 7,
          itemCount: 3,
          key: ComboboxArrowKey.down,
        ),
        2,
      );
    });
  });

  group('getAutocompleteScrollOffset', () {
    test('scrolls up when the active item is above the viewport', () {
      expect(
        getAutocompleteScrollOffset(
          currentOffset: 120,
          viewportHeight: 80,
          itemTop: 90,
          itemHeight: 20,
        ),
        90,
      );
    });

    test('scrolls down when the active item is below the viewport', () {
      expect(
        getAutocompleteScrollOffset(
          currentOffset: 0,
          viewportHeight: 100,
          itemTop: 150,
          itemHeight: 24,
        ),
        74,
      );
    });

    test('leaves the offset alone when the item is already visible', () {
      expect(
        getAutocompleteScrollOffset(
          currentOffset: 40,
          viewportHeight: 100,
          itemTop: 50,
          itemHeight: 20,
        ),
        40,
      );
    });

    test('treats an item flush with either edge as already visible', () {
      expect(
        getAutocompleteScrollOffset(
          currentOffset: 40,
          viewportHeight: 100,
          itemTop: 40,
          itemHeight: 20,
        ),
        40,
      );
      expect(
        getAutocompleteScrollOffset(
          currentOffset: 40,
          viewportHeight: 100,
          itemTop: 120,
          itemHeight: 20,
        ),
        40,
      );
    });

    test('never scrolls past the top of the list', () {
      expect(
        getAutocompleteScrollOffset(
          currentOffset: 10,
          viewportHeight: 100,
          itemTop: -30,
          itemHeight: 20,
        ),
        0,
      );
    });

    test('leaves an out-of-range offset alone when the item is inside it', () {
      // Only the two corrective branches clamp at 0; an already-negative offset
      // whose viewport still contains the item is returned untouched, exactly
      // as upstream does.
      expect(
        getAutocompleteScrollOffset(
          currentOffset: -50,
          viewportHeight: 100,
          itemTop: -40,
          itemHeight: 20,
        ),
        -50,
      );
    });

    test('holds the offset while the viewport is unmeasured', () {
      expect(
        getAutocompleteScrollOffset(
          currentOffset: 33,
          viewportHeight: 0,
          itemTop: 999,
          itemHeight: 20,
        ),
        33,
      );
      expect(
        getAutocompleteScrollOffset(
          currentOffset: 33,
          viewportHeight: -5,
          itemTop: 999,
          itemHeight: 20,
        ),
        33,
      );
    });
  });

  group('buildDesktopFrameStyle', () {
    DesktopFrameStyle widthStyle({
      double? desktopMinWidth,
      required double? referenceWidth,
    }) {
      return buildDesktopFrameStyle(
        desktopMinWidth: desktopMinWidth,
        referenceWidth: referenceWidth,
        desktopFixedHeight: null,
        desktopPositionStyle: const DesktopFramePositionStyle(left: 0, top: 0),
        shouldHideDesktopContent: false,
        availableHeight: null,
      );
    }

    test('lets a narrow trigger grow to the default desktop ceiling', () {
      final style = widthStyle(referenceWidth: 120);
      expect(style.width, isNull);
      expect(style.minWidth, 120);
      expect(style.maxWidth, 400);
    });

    test('keeps a wide trigger from being capped below its own width', () {
      final style = widthStyle(referenceWidth: 470);
      expect(style.width, isNull);
      expect(style.minWidth, 470);
      expect(style.maxWidth, 470);
    });

    test('uses desktopMinWidth as an explicit floor raiser', () {
      final style = widthStyle(desktopMinWidth: 360, referenceWidth: 120);
      expect(style.width, isNull);
      expect(style.minWidth, 360);
      expect(style.maxWidth, 400);
    });

    test('keeps the trigger as the floor when it is wider than '
        'desktopMinWidth', () {
      final style = widthStyle(desktopMinWidth: 240, referenceWidth: 300);
      expect(style.width, isNull);
      expect(style.minWidth, 300);
      expect(style.maxWidth, 400);
    });

    test('falls back to 200 while the trigger is unmeasured', () {
      final style = widthStyle(referenceWidth: null);
      expect(style.minWidth, 200);
      expect(style.maxWidth, 400);
    });

    test('still honours desktopMinWidth while the trigger is unmeasured', () {
      final style = widthStyle(desktopMinWidth: 520, referenceWidth: null);
      expect(style.minWidth, 520);
      expect(style.maxWidth, 520);
    });

    test('leaves height unconstrained when nothing pins it', () {
      final style = widthStyle(referenceWidth: 120);
      expect(style.minHeight, isNull);
      expect(style.maxHeight, isNull);
      expect(style.opacity, isNull);
    });

    test('pins both height bounds to a caller-supplied fixed height', () {
      final style = buildDesktopFrameStyle(
        referenceWidth: 300,
        desktopFixedHeight: 260,
        desktopPositionStyle: const DesktopFramePositionStyle(),
        shouldHideDesktopContent: false,
      );
      expect(style.minHeight, 260);
      expect(style.maxHeight, 260);
    });

    test('lets the measured available height lower the fixed ceiling but not '
        'the floor', () {
      final style = buildDesktopFrameStyle(
        referenceWidth: 300,
        desktopFixedHeight: 260,
        desktopPositionStyle: const DesktopFramePositionStyle(),
        shouldHideDesktopContent: false,
        availableHeight: 180,
      );
      expect(style.minHeight, 260);
      expect(style.maxHeight, 180);
    });

    test('never lets the available height raise the fixed ceiling', () {
      final style = buildDesktopFrameStyle(
        referenceWidth: 300,
        desktopFixedHeight: 260,
        desktopPositionStyle: const DesktopFramePositionStyle(),
        shouldHideDesktopContent: false,
        availableHeight: 900,
      );
      expect(style.maxHeight, 260);
    });

    test('caps an unpinned popover at 400 once space is measured', () {
      final tall = buildDesktopFrameStyle(
        referenceWidth: 300,
        desktopPositionStyle: const DesktopFramePositionStyle(),
        shouldHideDesktopContent: false,
        availableHeight: 900,
      );
      expect(tall.minHeight, isNull);
      expect(tall.maxHeight, 400);

      final cramped = buildDesktopFrameStyle(
        referenceWidth: 300,
        desktopPositionStyle: const DesktopFramePositionStyle(),
        shouldHideDesktopContent: false,
        availableHeight: 150,
      );
      expect(cramped.maxHeight, 150);
    });

    test('hides the frame while its position is still being resolved', () {
      final style = buildDesktopFrameStyle(
        referenceWidth: null,
        desktopPositionStyle: const DesktopFramePositionStyle(),
        shouldHideDesktopContent: true,
      );
      expect(style.opacity, 0);
    });

    test('passes the position layer through untouched', () {
      final style = buildDesktopFrameStyle(
        referenceWidth: 300,
        desktopPositionStyle: const DesktopFramePositionStyle(
          left: 12,
          bottom: 34,
        ),
        shouldHideDesktopContent: false,
      );
      expect(style.left, 12);
      expect(style.bottom, 34);
      expect(style.top, isNull);
      expect(style.right, isNull);
    });

    test('is a value type', () {
      final a = buildDesktopFrameStyle(
        referenceWidth: 300,
        desktopPositionStyle: const DesktopFramePositionStyle(left: 1),
        shouldHideDesktopContent: false,
      );
      final b = buildDesktopFrameStyle(
        referenceWidth: 300,
        desktopPositionStyle: const DesktopFramePositionStyle(left: 1),
        shouldHideDesktopContent: false,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        const DesktopFramePositionStyle(left: 1),
        const DesktopFramePositionStyle(left: 1),
      );
      expect(
        const DesktopFramePositionStyle(left: 1),
        isNot(const DesktopFramePositionStyle(left: 2)),
      );
    });
  });

  group('buildVisibleComboboxOptions', () {
    const options = [
      ComboboxOptionModel(
        id: '/Users/me/project-a',
        label: '/Users/me/project-a',
        kind: ComboboxOptionKind.directory,
      ),
      ComboboxOptionModel(
        id: '/Users/me/project-b',
        label: '/Users/me/project-b',
        kind: ComboboxOptionKind.directory,
      ),
    ];

    test('keeps a custom row visible while searching with no matches', () {
      final visible = buildVisibleComboboxOptions(
        options: options,
        searchQuery: '/tmp/new-project',
        searchable: true,
        allowCustomValue: true,
        customValuePrefix: '',
        customValueKind: ComboboxOptionKind.directory,
      );

      expect(visible, hasLength(1));
      expect(
        visible[0],
        const ComboboxOptionModel(
          id: '/tmp/new-project',
          label: '/tmp/new-project',
          kind: ComboboxOptionKind.directory,
        ),
      );
      expect(visible[0].description, isNull);
    });

    test('does not duplicate a row when search exactly matches an existing '
        'option', () {
      final visible = buildVisibleComboboxOptions(
        options: options,
        searchQuery: '/Users/me/project-a',
        searchable: true,
        allowCustomValue: true,
        customValuePrefix: '',
        customValueKind: ComboboxOptionKind.directory,
      );

      expect(visible, [
        const ComboboxOptionModel(
          id: '/Users/me/project-a',
          label: '/Users/me/project-a',
          kind: ComboboxOptionKind.directory,
        ),
      ]);
    });

    test('wraps the typed value with a non-empty prefix', () {
      final visible = buildVisibleComboboxOptions(
        options: options,
        searchQuery: '  /tmp/fresh  ',
        searchable: true,
        allowCustomValue: true,
        customValuePrefix: '  Use  ',
        customValueDescription: 'not on disk yet',
      );

      expect(visible.first.id, '/tmp/fresh');
      expect(visible.first.label, 'Use "/tmp/fresh"');
      expect(visible.first.description, 'not on disk yet');
      expect(visible.first.kind, isNull);
    });

    test('shows every option and no custom row when not searchable', () {
      final visible = buildVisibleComboboxOptions(
        options: options,
        searchQuery: '/tmp/new-project',
        searchable: false,
        allowCustomValue: true,
        customValuePrefix: '',
      );

      expect(visible.map((o) => o.id), [
        '/Users/me/project-a',
        '/Users/me/project-b',
      ]);
    });

    test('omits the custom row when custom values are not allowed', () {
      final visible = buildVisibleComboboxOptions(
        options: options,
        searchQuery: '/tmp/new-project',
        searchable: true,
        allowCustomValue: false,
        customValuePrefix: '',
      );

      expect(visible, isEmpty);
    });

    test('omits the custom row for a whitespace-only query', () {
      final visible = buildVisibleComboboxOptions(
        options: options,
        searchQuery: '   ',
        searchable: true,
        allowCustomValue: true,
        customValuePrefix: '',
      );

      expect(visible.map((o) => o.id), [
        '/Users/me/project-a',
        '/Users/me/project-b',
      ]);
    });
  });

  group('shouldShowCustomComboboxOption', () {
    const options = [ComboboxOptionModel(id: 'main', label: 'Main branch')];

    test('suppresses the row for a case-insensitive id or label hit', () {
      for (final query in ['MAIN', 'main branch', '  Main  ']) {
        expect(
          shouldShowCustomComboboxOption(
            options: options,
            searchQuery: query,
            searchable: true,
            allowCustomValue: true,
          ),
          isFalse,
          reason: query,
        );
      }
    });

    test('offers the row for a value no option carries', () {
      expect(
        shouldShowCustomComboboxOption(
          options: options,
          searchQuery: 'mainline',
          searchable: true,
          allowCustomValue: true,
        ),
        isTrue,
      );
    });

    test('requires both searchable and allowCustomValue', () {
      expect(
        shouldShowCustomComboboxOption(
          options: options,
          searchQuery: 'mainline',
          searchable: false,
          allowCustomValue: true,
        ),
        isFalse,
      );
      expect(
        shouldShowCustomComboboxOption(
          options: options,
          searchQuery: 'mainline',
          searchable: true,
          allowCustomValue: false,
        ),
        isFalse,
      );
    });
  });

  group('filterAndRankComboboxOptions', () {
    const options = [
      ComboboxOptionModel(id: 'feat/login', label: 'feat/login'),
      ComboboxOptionModel(id: 'main', label: 'main'),
      ComboboxOptionModel(id: 'feat/main-nav', label: 'feat/main-nav'),
      ComboboxOptionModel(
        id: 'fix/logout',
        label: 'fix/logout',
        description: 'fixes main logout bug',
      ),
    ];

    test('returns all options when search is empty', () {
      expect(filterAndRankComboboxOptions(options, ''), options);
    });

    test('filters by label substring', () {
      final result = filterAndRankComboboxOptions(options, 'login');
      expect(result.map((o) => o.id), ['feat/login']);
    });

    test('filters by id substring', () {
      final result = filterAndRankComboboxOptions(options, 'fix/');
      expect(result.map((o) => o.id), ['fix/logout']);
    });

    test('filters by description substring', () {
      final result = filterAndRankComboboxOptions(options, 'logout bug');
      expect(result.map((o) => o.id), ['fix/logout']);
    });

    test('ranks prefix matches above substring matches', () {
      final result = filterAndRankComboboxOptions(options, 'main');
      expect(result.map((o) => o.id), ['main', 'feat/main-nav', 'fix/logout']);
    });

    test('is case-insensitive', () {
      const items = [ComboboxOptionModel(id: 'Alpha', label: 'Alpha')];
      expect(filterAndRankComboboxOptions(items, 'alpha'), hasLength(1));
    });

    test('returns empty when nothing matches', () {
      expect(filterAndRankComboboxOptions(options, 'zzz'), isEmpty);
    });

    test('ranks word-boundary matches above mid-word substring matches', () {
      const items = [
        ComboboxOptionModel(id: 'happy', label: 'happy'),
        ComboboxOptionModel(id: 'a/py', label: 'a/py'),
      ];
      final result = filterAndRankComboboxOptions(items, 'py');
      expect(result.map((o) => o.id), ['a/py', 'happy']);
    });

    test('interleaves mixed branches and PRs by match quality', () {
      const items = [
        ComboboxOptionModel(
          id: 'branch:feat/api-login',
          label: 'feat/api-login',
        ),
        ComboboxOptionModel(
          id: 'branch:feat/pi-direct-sdk',
          label: 'feat/pi-direct-sdk',
        ),
        ComboboxOptionModel(
          id: 'github-pr:202',
          label: '#202 feat(server): replace Pi ACP with direct SDK provider',
        ),
        ComboboxOptionModel(
          id: 'github-pr:355',
          label: '#355 feat: add LaTeX math formula rendering',
        ),
      ];
      final result = filterAndRankComboboxOptions(items, 'pi');
      expect(result.map((o) => o.id), [
        'branch:feat/pi-direct-sdk',
        'github-pr:202',
        'branch:feat/api-login',
      ]);
    });

    test('ranks PR-number matches via word-boundary on #', () {
      const items = [
        ComboboxOptionModel(id: 'github-pr:202', label: '#202 some title'),
        ComboboxOptionModel(id: 'github-pr:1202', label: '#1202 another title'),
      ];
      final result = filterAndRankComboboxOptions(items, '202');
      expect(result.map((o) => o.id), ['github-pr:202', 'github-pr:1202']);
    });

    test('matches fuzzy character sequences after stronger substring '
        'matches', () {
      const items = [
        ComboboxOptionModel(id: 'gpt-5.4', label: 'GPT-5.4'),
        ComboboxOptionModel(id: 'gpt-4.1', label: 'GPT-4.1'),
        ComboboxOptionModel(id: 'gemini', label: 'Gemini'),
      ];
      final result = filterAndRankComboboxOptions(items, 'gpt54');
      expect(result.map((o) => o.id), ['gpt-5.4']);
    });

    test('returns the input list itself for an empty query', () {
      expect(filterAndRankComboboxOptions(options, ''), same(options));
    });

    test('requires every whitespace-separated token to match somewhere', () {
      const items = [
        ComboboxOptionModel(id: 'feat/login', label: 'feat/login'),
      ];
      expect(filterAndRankComboboxOptions(items, 'feat login'), hasLength(1));
      expect(filterAndRankComboboxOptions(items, 'feat zzz'), isEmpty);
    });

    test('never lets a description match outrank a label match', () {
      const items = [
        ComboboxOptionModel(
          id: 'a',
          label: 'zzz-alpha',
          description: 'alpha alpha alpha',
        ),
        ComboboxOptionModel(id: 'b', label: 'not-a-match-at-all'),
        ComboboxOptionModel(
          id: 'c',
          label: 'nothing',
          description: 'alpha first word',
        ),
      ];
      final result = filterAndRankComboboxOptions(items, 'alpha');
      expect(result.map((o) => o.id), ['a', 'c']);
    });

    test('treats an empty description like a missing one', () {
      const items = [ComboboxOptionModel(id: 'x', label: 'x', description: '')];
      expect(filterAndRankComboboxOptions(items, 'zzz'), isEmpty);
    });

    test('breaks score ties by label, then by input order', () {
      const items = [
        ComboboxOptionModel(id: 'second', label: 'beta'),
        ComboboxOptionModel(id: 'first', label: 'Alpha'),
        ComboboxOptionModel(id: 'dup-b', label: 'beta'),
      ];
      // All three score identically (whole-word match at offset 0), so the
      // case-insensitive label comparison orders "Alpha" first and the
      // original-index tie-break keeps the two "beta" rows in input order.
      final result = filterAndRankComboboxOptions(items, 'a');
      expect(result.map((o) => o.id), ['first', 'second', 'dup-b']);
    });
  });

  group('combobox above-search ordering', () {
    const visible = [
      ComboboxOptionModel(
        id: '/tmp/new-project',
        label: '/tmp/new-project',
        kind: ComboboxOptionKind.directory,
      ),
      ComboboxOptionModel(
        id: '/Users/me/project-a',
        label: '/Users/me/project-a',
        kind: ComboboxOptionKind.directory,
      ),
      ComboboxOptionModel(
        id: '/Users/me/project-b',
        label: '/Users/me/project-b',
        kind: ComboboxOptionKind.directory,
      ),
    ];

    test('renders first logical option closest to the search box in '
        'above-search mode', () {
      final ordered = orderVisibleComboboxOptions(
        visible,
        ComboboxOptionsPosition.aboveSearch,
      );
      expect(ordered.map((option) => option.id), [
        '/Users/me/project-b',
        '/Users/me/project-a',
        '/tmp/new-project',
      ]);
      expect(
        getComboboxFallbackIndex(
          ordered.length,
          ComboboxOptionsPosition.aboveSearch,
        ),
        2,
      );
    });

    test('keeps normal top-down order in below-search mode', () {
      final ordered = orderVisibleComboboxOptions(
        visible,
        ComboboxOptionsPosition.belowSearch,
      );
      expect(ordered.map((option) => option.id), [
        '/tmp/new-project',
        '/Users/me/project-a',
        '/Users/me/project-b',
      ]);
      expect(
        getComboboxFallbackIndex(
          ordered.length,
          ComboboxOptionsPosition.belowSearch,
        ),
        0,
      );
    });

    test('below-search ordering is the identity case', () {
      expect(
        orderVisibleComboboxOptions(
          visible,
          ComboboxOptionsPosition.belowSearch,
        ),
        same(visible),
      );
    });

    test('reports no fallback for an empty list in either position', () {
      expect(
        getComboboxFallbackIndex(0, ComboboxOptionsPosition.aboveSearch),
        -1,
      );
      expect(
        getComboboxFallbackIndex(0, ComboboxOptionsPosition.belowSearch),
        -1,
      );
      expect(
        getComboboxFallbackIndex(-2, ComboboxOptionsPosition.aboveSearch),
        -1,
      );
    });
  });

  group('ComboboxOptionModel', () {
    test('is a value type', () {
      const a = ComboboxOptionModel(id: 'a', label: 'A');
      const b = ComboboxOptionModel(id: 'a', label: 'A');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const ComboboxOptionModel(id: 'a', label: 'B')));
      expect(
        a,
        isNot(
          const ComboboxOptionModel(
            id: 'a',
            label: 'A',
            kind: ComboboxOptionKind.file,
          ),
        ),
      );
    });
  });

  group('control geometry', () {
    test('keeps resting control borders transparent while preserving border '
        'geometry', () {
      final geometry = createControlGeometry(theme);

      expect(
        geometry.controlRest,
        const ControlSurfaceStyle(
          borderWidth: 1,
          borderColor: transparent,
          outlineColor: transparent,
          outlineWidth: 0,
        ),
      );
    });

    test('uses the shared hover border and active focus ring values', () {
      final geometry = createControlGeometry(theme);

      expect(
        geometry.controlHover,
        const ControlSurfaceStyle(borderColor: Color(0xFF2F3534)),
      );
      expect(
        geometry.controlActive,
        const ControlSurfaceStyle(
          borderColor: Color(0xFF2F3534),
          outlineColor: Color(0xFF20744A),
          outlineOffset: 1,
          outlineStyle: ControlOutlineStyle.solid,
          outlineWidth: 2,
        ),
      );
    });

    test('resolves disabled, focus, open, pressed, and hover into one '
        'interaction phase', () {
      expect(
        getControlInteractionPhase(
          const ControlInteractionState(disabled: true, focused: true),
        ),
        ControlInteractionPhase.rest,
      );
      expect(
        getControlInteractionPhase(
          const ControlInteractionState(focused: true),
        ),
        ControlInteractionPhase.active,
      );
      expect(
        getControlInteractionPhase(const ControlInteractionState(open: true)),
        ControlInteractionPhase.active,
      );
      expect(
        getControlInteractionPhase(
          const ControlInteractionState(pressed: true),
        ),
        ControlInteractionPhase.active,
      );
      expect(
        getControlInteractionPhase(
          const ControlInteractionState(hovered: true),
        ),
        ControlInteractionPhase.hover,
      );
      expect(
        getControlInteractionPhase(const ControlInteractionState()),
        ControlInteractionPhase.rest,
      );
    });

    test('treats selected as engaged and lets active outrank hover', () {
      expect(
        getControlInteractionPhase(const ControlInteractionState(active: true)),
        ControlInteractionPhase.active,
      );
      expect(
        getControlInteractionPhase(
          const ControlInteractionState(hovered: true, pressed: true),
        ),
        ControlInteractionPhase.active,
      );
      expect(
        getControlInteractionPhase(
          const ControlInteractionState(hovered: true, disabled: true),
        ),
        ControlInteractionPhase.rest,
      );
    });

    test('keeps field text sizing tied to control size', () {
      final geometry = createControlGeometry(theme);

      expect(geometry.fieldTextSm.fontSize, 14);
      expect(geometry.fieldTextSm.lineHeight, 20);
      expect(geometry.fieldTextMd.fontSize, 16);
      expect(geometry.fieldTextMd.lineHeight, 22);
      expect(geometry.formTextInputSm.fontSize, 14);
      expect(geometry.formTextInputSm.lineHeight, 20);
      expect(geometry.formTextInputMd.fontSize, 16);
      expect(geometry.formTextInputMd.lineHeight, 22);
    });

    test('derives field padding from line height without changing the control '
        'height', () {
      final geometry = createControlGeometry(theme);

      expect(geometry.fieldControlSm.minHeight, 32);
      expect(geometry.fieldControlSm.paddingVertical, 6);
      expect(
        geometry.fieldTextSm.lineHeight! +
            geometry.fieldControlSm.paddingVertical! * 2,
        geometry.fieldControlSm.minHeight,
      );

      expect(geometry.fieldControlMd.minHeight, 44);
      expect(geometry.fieldControlMd.paddingVertical, 11);
      expect(
        geometry.fieldTextMd.lineHeight! +
            geometry.fieldControlMd.paddingVertical! * 2,
        geometry.fieldControlMd.minHeight,
      );

      expect(geometry.formTextInputSm.paddingVertical, 6);
      expect(geometry.formTextInputMd.paddingVertical, 11);
    });

    test('keeps segmented controls ghost with fully rounded segments in a '
        'button-sized track', () {
      final geometry = createControlGeometry(theme);

      expect(geometry.segmentedContainerXs.padding, 0);
      expect(geometry.segmentedContainerSm.padding, 0);
      expect(geometry.segmentedContainerMd.padding, 0);
      expect(geometry.segmentedSegmentXs.borderRadius, 9999);
      expect(geometry.segmentedSegmentSm.borderRadius, 9999);
      expect(geometry.segmentedSegmentMd.borderRadius, 9999);
      expect(
        geometry.segmentedContainerXs.minHeight,
        geometry.buttonXs.minHeight,
      );
      expect(
        geometry.segmentedContainerSm.minHeight,
        geometry.buttonSm.minHeight,
      );
      expect(
        geometry.segmentedContainerMd.minHeight,
        geometry.buttonMd.minHeight,
      );
      expect(geometry.segmentedSegmentXs.minHeight, 24);
      expect(geometry.segmentedSegmentSm.minHeight, 28);
      expect(geometry.segmentedSegmentMd.minHeight, 38);
    });

    test('keeps one size contract across buttons and segmented controls', () {
      final geometry = createControlGeometry(theme);

      // xs is a genuinely smaller tier, not sm with a different font.
      expect(geometry.buttonXs.minHeight, 28);
      expect(geometry.buttonSm.minHeight, 32);
      expect(geometry.buttonMd.minHeight, 44);

      // Same size name means the same label size on every control kind.
      expect(geometry.segmentedLabelXs.fontSize, 12);
      expect(
        geometry.segmentedLabelXs.fontSize,
        geometry.buttonTextXs.fontSize,
      );
      expect(geometry.segmentedLabelSm.fontSize, 14);
      expect(geometry.segmentedLabelSm.fontSize, geometry.buttonText.fontSize);
      expect(geometry.segmentedLabelMd.fontSize, geometry.buttonText.fontSize);

      // Same size name means the same horizontal padding on every control kind.
      expect(
        geometry.segmentedSegmentXs.paddingHorizontal,
        geometry.buttonXs.paddingHorizontal,
      );
      expect(
        geometry.segmentedSegmentSm.paddingHorizontal,
        geometry.buttonSm.paddingHorizontal,
      );
      expect(
        geometry.segmentedSegmentMd.paddingHorizontal,
        geometry.buttonMd.paddingHorizontal,
      );
    });

    test('gives lg the md height with wider padding and a larger radius', () {
      final geometry = createControlGeometry(theme);

      expect(geometry.buttonLg.minHeight, geometry.buttonMd.minHeight);
      expect(geometry.buttonLg.paddingHorizontal, 24);
      expect(geometry.buttonLg.borderRadius, 12);
      expect(geometry.buttonMd.borderRadius, 8);
      expect(geometry.buttonXs.borderRadius, 6);
      expect(geometry.buttonSm.borderRadius, 6);
    });

    test('aliases the default text input to the medium tier', () {
      final geometry = createControlGeometry(theme);

      expect(geometry.formTextInput, geometry.formTextInputMd);
      expect(geometry.formTextInput.box, geometry.fieldControlMd);
      expect(geometry.formTextInput.text, geometry.fieldTextMd);
      expect(geometry.formTextInput.borderRadius, 8);
      expect(geometry.formTextInput.paddingHorizontal, 16);
    });

    test('centres the switch row in a compact-height track', () {
      final geometry = createControlGeometry(theme);

      expect(geometry.switchControl.minHeight, 32);
      expect(geometry.switchControl.justifyContent, MainAxisAlignment.center);
    });

    test(
      'exposes the focus ring color on its own and the disabled dimming',
      () {
        final geometry = createControlGeometry(theme);

        expect(
          geometry.controlFocusRingColor,
          const ControlSurfaceStyle(outlineColor: Color(0xFF20744A)),
        );
        expect(
          geometry.controlDisabled,
          const ControlSurfaceStyle(opacity: 0.5),
        );
      },
    );

    test('re-derives every size from the theme it is handed', () {
      final geometry = createControlGeometry(
        const ControlGeometryTheme(
          accent: Color(0xFF000001),
          borderAccent: Color(0xFF000002),
          fontSizeSm: 10,
          fontSizeBase: 20,
          spacing3: 3,
          spacing4: 4,
          spacing6: 6,
          borderRadiusMd: 1,
        ),
      );

      // round(10 * 1.4) == 14, round(20 * 1.4) == 28.
      expect(geometry.fieldTextSm.lineHeight, 14);
      expect(geometry.fieldTextMd.lineHeight, 28);
      expect(geometry.fieldControlSm.paddingVertical, 9);
      expect(geometry.fieldControlMd.paddingVertical, 8);
      expect(geometry.buttonXs.paddingHorizontal, 3);
      expect(geometry.buttonMd.paddingHorizontal, 4);
      expect(geometry.buttonLg.paddingHorizontal, 6);
      expect(geometry.buttonXs.borderRadius, 1);
      expect(geometry.controlActive.outlineColor, const Color(0xFF000001));
      expect(geometry.controlHover.borderColor, const Color(0xFF000002));
    });
  });

  group('resolveControlInteractionStyles', () {
    const styles = ControlInteractionStyleMap<String>(
      controlRest: 'rest',
      controlHover: 'hover',
      controlActive: 'active',
      controlDisabled: 'disabled',
    );

    test('always emits four slots so layer positions stay meaningful', () {
      expect(
        resolveControlInteractionStyles(
          styles,
          const ControlInteractionState(),
        ),
        ['rest', null, null, null],
      );
      expect(
        resolveControlInteractionStyles(
          styles,
          const ControlInteractionState(hovered: true),
        ),
        ['rest', 'hover', null, null],
      );
      expect(
        resolveControlInteractionStyles(
          styles,
          const ControlInteractionState(open: true),
        ),
        ['rest', null, 'active', null],
      );
    });

    test('drops the engaged layer but keeps the dimming when disabled', () {
      expect(
        resolveControlInteractionStyles(
          styles,
          const ControlInteractionState(disabled: true, focused: true),
        ),
        ['rest', null, null, 'disabled'],
      );
    });

    test('leaves the disabled slot null when no dimming style is supplied', () {
      const withoutDisabled = ControlInteractionStyleMap<String>(
        controlRest: 'rest',
        controlHover: 'hover',
        controlActive: 'active',
      );
      expect(
        resolveControlInteractionStyles(
          withoutDisabled,
          const ControlInteractionState(disabled: true),
        ),
        ['rest', null, null, null],
      );
    });

    test('layers the geometry own styles through the same rule', () {
      final geometry = createControlGeometry(theme);
      final layers = resolveControlInteractionStyles(
        geometry.interactionStyles,
        const ControlInteractionState(hovered: true),
      );

      expect(layers, [geometry.controlRest, geometry.controlHover, null, null]);
    });
  });

  group('control size tables', () {
    test('maps every button and segmented size to an icon size', () {
      expect(buttonIconSize, {
        ButtonControlSize.xs: 12.0,
        ButtonControlSize.sm: 14.0,
        ButtonControlSize.md: 16.0,
        ButtonControlSize.lg: 20.0,
      });
      expect(segmentedIconSize, {
        SegmentedControlSize.xs: 12.0,
        SegmentedControlSize.sm: 14.0,
        SegmentedControlSize.md: 16.0,
      });
      for (final size in SegmentedControlSize.values) {
        expect(
          segmentedIconSize[size],
          buttonIconSize[ButtonControlSize.values.byName(size.name)],
        );
      }
    });

    test(
      'gives the switch thumb an equal inset at both ends of its travel',
      () {
        expect(SwitchGeometry.trackWidth, 34);
        expect(SwitchGeometry.trackHeight, 20);
        expect(SwitchGeometry.thumbSize, 16);
        expect(SwitchGeometry.thumbTravel, 14);

        final inset =
            (SwitchGeometry.trackHeight - SwitchGeometry.thumbSize) / 2;
        expect(
          inset + SwitchGeometry.thumbSize + SwitchGeometry.thumbTravel + inset,
          SwitchGeometry.trackWidth,
        );
      },
    );

    test('field control sizes cover exactly the two field heights', () {
      expect(FieldControlSize.values, [
        FieldControlSize.sm,
        FieldControlSize.md,
      ]);
    });
  });
}
