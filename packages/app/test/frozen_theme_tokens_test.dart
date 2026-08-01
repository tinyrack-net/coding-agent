// Drift guard: the palette tokens must match the frozen Paseo 0.2.0 theme.
//
// Sibling of `frozen_icon_paths_test.dart`, and written for the same reason.
// Two icons had silently drifted from the frozen artwork while passing every
// test they had; colours are the other half of that surface and are just as
// easy to "tidy" by a shade without anything noticing.
//
// Values are lifted from `packages/app/src/styles/theme.ts` —
// `lightSemanticColors` + `lightStatusColors`, and the `paseoDarkColors`
// config + `darkStatusColors`. Only the tokens `PaseoPalette` declares are
// compared; the frozen file carries many more (terminal ANSI, shadcn
// aliases) that this app does not model.
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const frozenLight = <String, int>{
  'surface0': 0xFFFFFFFF,
  'surface1': 0xFFFAFAFA,
  'surface2': 0xFFF4F4F5,
  'surface3': 0xFFE4E4E7,
  'surfaceSidebar': 0xFFF4F4F5,
  'surfaceSidebarHover': 0xFFE9E9EC,
  'foreground': 0xFF1A1A1E,
  'foregroundMuted': 0xFF71717A,
  'border': 0xFFE4E4E7,
  'borderAccent': 0xFFECECF1,
  'accent': 0xFF20744A,
  'accentBright': 0xFF239956,
  'statusSuccess': 0xFF15803D,
  'statusDanger': 0xFFB91C1C,
  'statusWarning': 0xFFD97706,
  'statusMerged': 0xFF7C3AED,
};

const frozenDark = <String, int>{
  'surface0': 0xFF181B1A,
  'surface1': 0xFF1E2120,
  'surface2': 0xFF272A29,
  'surface3': 0xFF434645,
  'surfaceSidebar': 0xFF141716,
  'surfaceSidebarHover': 0xFF1C1F1E,
  'foregroundMuted': 0xFFA1A5A4,
  'border': 0xFF252B2A,
  'borderAccent': 0xFF2F3534,
  'accent': 0xFF20744A,
  'accentBright': 0xFF7CCBA0,
  'statusSuccess': 0xFF16A34A,
  'statusDanger': 0xFFDC2626,
  'statusWarning': 0xFFF59E0B,
  'statusMerged': 0xFF9333EA,
};

Map<String, Color> tokensOf(PaseoPalette p) => {
  'surface0': p.surface0,
  'surface1': p.surface1,
  'surface2': p.surface2,
  'surface3': p.surface3,
  'surfaceSidebar': p.surfaceSidebar,
  'surfaceSidebarHover': p.surfaceSidebarHover,
  'foreground': p.foreground,
  'foregroundMuted': p.foregroundMuted,
  'border': p.border,
  'borderAccent': p.borderAccent,
  'accent': p.accent,
  'accentBright': p.accentBright,
  'statusSuccess': p.statusSuccess,
  'statusDanger': p.statusDanger,
  'statusWarning': p.statusWarning,
  'statusMerged': p.statusMerged,
};

void expectPalette(PaseoPalette palette, Map<String, int> frozen) {
  final actual = tokensOf(palette);
  for (final entry in frozen.entries) {
    expect(
      actual[entry.key]!.toARGB32(),
      entry.value,
      reason: '${entry.key} drifted from the frozen theme',
    );
  }
}

void main() {
  test('the light palette matches the frozen theme', () {
    expectPalette(paseoPaletteFor(AppThemeName.light), frozenLight);
  });

  test('the dark palette matches the frozen theme', () {
    expectPalette(paseoPaletteFor(AppThemeName.dark), frozenDark);
  });

  test('auto resolves to the frozen palette for each brightness', () {
    expectPalette(
      paseoPaletteFor(AppThemeName.auto, Brightness.light),
      frozenLight,
    );
    expectPalette(
      paseoPaletteFor(AppThemeName.auto, Brightness.dark),
      frozenDark,
    );
  });

  test('the spacing scale matches the frozen SPACING', () {
    // packages/app/src/styles/theme.ts SPACING
    expect(
      [
        PaseoSpacing.s0,
        PaseoSpacing.s1,
        PaseoSpacing.s1x5,
        PaseoSpacing.s2,
        PaseoSpacing.s3,
        PaseoSpacing.s4,
        PaseoSpacing.s6,
        PaseoSpacing.s8,
        PaseoSpacing.s12,
        PaseoSpacing.s16,
        PaseoSpacing.s20,
        PaseoSpacing.s24,
        PaseoSpacing.s32,
      ],
      [0, 4, 6, 8, 12, 16, 24, 32, 48, 64, 80, 96, 128],
    );
  });
}
