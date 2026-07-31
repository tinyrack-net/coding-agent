/// Port of Paseo 0.2.0's `composer/agent-controls/layout.ts`.
///
/// The composer toolbar sheds detail as it narrows: full shows every label
/// and caret, condensed drops carets and the thinking label and aggregates
/// feature controls behind one button, and tight drops the mode label too.
/// Density is chosen by estimating how wide the controls would be at each
/// level, with hysteresis so a toolbar sitting near a threshold does not
/// flip back and forth while resizing.
library;

enum ComposerControlDensity { full, condensed, tight }

/// A feature control is either a bare toggle or a labelled select, which
/// differ in how much width they need.
sealed class ComposerFeatureControlPresence {
  const ComposerFeatureControlPresence();
}

final class ComposerFeatureToggle extends ComposerFeatureControlPresence {
  const ComposerFeatureToggle();
}

final class ComposerFeatureSelect extends ComposerFeatureControlPresence {
  const ComposerFeatureSelect(this.label);

  final String label;
}

final class ComposerControlPresence {
  const ComposerControlPresence({
    this.hasModel = false,
    this.hasThinking = false,
    this.hasMode = false,
    this.features = const [],
    this.fontScale = 1,
  });

  final bool hasModel;
  final bool hasThinking;
  final bool hasMode;
  final List<ComposerFeatureControlPresence> features;
  final double fontScale;
}

final class ComposerControlPresentation {
  const ComposerControlPresentation({
    required this.showCarets,
    required this.showThinkingLabel,
    required this.showModeLabel,
    required this.aggregateFeatures,
  });

  final bool showCarets;
  final bool showThinkingLabel;
  final bool showModeLabel;
  final bool aggregateFeatures;

  @override
  bool operator ==(Object other) =>
      other is ComposerControlPresentation &&
      other.showCarets == showCarets &&
      other.showThinkingLabel == showThinkingLabel &&
      other.showModeLabel == showModeLabel &&
      other.aggregateFeatures == aggregateFeatures;

  @override
  int get hashCode => Object.hash(
    showCarets,
    showThinkingLabel,
    showModeLabel,
    aggregateFeatures,
  );
}

/// The frozen toolbar metrics the width estimates are built from.
abstract final class ComposerToolbarGeometry {
  static const controlSize = 28.0;
  static const controlGap = 4.0;
  static const iconLabelGap = 4.0;
  static const labelPadding = 8.0;
  static const caretSize = 14.0;
}

/// Width band around each threshold that a density must be exceeded by
/// before switching, so resizing across a boundary does not oscillate.
const _densityHysteresis = 12.0;

double _normalizedFontScale(double fontScale) =>
    fontScale.isFinite ? (fontScale < 1 ? 1 : fontScale) : 1;

double _sumControlWidths(List<double> widths) {
  if (widths.isEmpty) return 0;
  return widths.reduce((total, width) => total + width) +
      (widths.length - 1) * ComposerToolbarGeometry.controlGap;
}

/// Upstream estimates label width at 7 logical pixels per character rather
/// than measuring, which keeps the density decision synchronous.
double _estimateLabelWidth(String label, double fontScale) =>
    label.runes.length * 7 * fontScale;

double _resolveFeatureControlWidth(
  ComposerFeatureControlPresence feature,
  double fontScale,
) => switch (feature) {
  ComposerFeatureToggle() => ComposerToolbarGeometry.controlSize,
  ComposerFeatureSelect(:final label) =>
    ComposerToolbarGeometry.controlSize +
        ComposerToolbarGeometry.iconLabelGap +
        ComposerToolbarGeometry.labelPadding * 2 +
        _estimateLabelWidth(label, fontScale),
};

/// Width needed at condensed density, where features collapse to one
/// aggregate control and thinking loses its label.
double _resolveCondensedFloor(ComposerControlPresence controls) {
  final fontScale = _normalizedFontScale(controls.fontScale);
  final widths = <double>[];
  if (controls.hasModel) widths.add(36 + 60 * fontScale);
  if (controls.hasThinking) widths.add(ComposerToolbarGeometry.controlSize);
  if (controls.hasMode) widths.add(36 + 96 * fontScale);
  if (controls.features.isNotEmpty) {
    widths.add(ComposerToolbarGeometry.controlSize);
  }
  return _sumControlWidths(widths);
}

/// Width needed at full density, where every control carries its label and
/// each feature renders separately.
double _resolveFullFloor(ComposerControlPresence controls) {
  final fontScale = _normalizedFontScale(controls.fontScale);
  final widths = <double>[];
  if (controls.hasModel) widths.add(50 + 70 * fontScale);
  if (controls.hasThinking) widths.add(54 + 48 * fontScale);
  if (controls.hasMode) widths.add(54 + 96 * fontScale);
  for (final feature in controls.features) {
    widths.add(_resolveFeatureControlWidth(feature, fontScale));
  }
  return _sumControlWidths(widths);
}

/// Chooses the density for [availableWidth], biased toward staying at
/// [currentDensity] within the hysteresis band.
ComposerControlDensity resolveComposerControlDensity({
  required double availableWidth,
  required ComposerControlDensity currentDensity,
  required ComposerControlPresence controls,
}) {
  final fullFloor = _resolveFullFloor(controls);
  final condensedFloor = _resolveCondensedFloor(controls);

  switch (currentDensity) {
    case ComposerControlDensity.full:
      // Already full: give up full only after dropping clearly below it.
      if (availableWidth >= fullFloor - _densityHysteresis) {
        return ComposerControlDensity.full;
      }
      return availableWidth >= condensedFloor
          ? ComposerControlDensity.condensed
          : ComposerControlDensity.tight;
    case ComposerControlDensity.condensed:
      if (availableWidth >= fullFloor + _densityHysteresis) {
        return ComposerControlDensity.full;
      }
      if (availableWidth < condensedFloor - _densityHysteresis) {
        return ComposerControlDensity.tight;
      }
      return ComposerControlDensity.condensed;
    case ComposerControlDensity.tight:
      if (availableWidth >= fullFloor + _densityHysteresis) {
        return ComposerControlDensity.full;
      }
      if (availableWidth >= condensedFloor + _densityHysteresis) {
        return ComposerControlDensity.condensed;
      }
      return ComposerControlDensity.tight;
  }
}

ComposerControlPresentation resolveComposerControlPresentation(
  ComposerControlDensity density,
) => switch (density) {
  ComposerControlDensity.full => const ComposerControlPresentation(
    showCarets: true,
    showThinkingLabel: true,
    showModeLabel: true,
    aggregateFeatures: false,
  ),
  ComposerControlDensity.condensed => const ComposerControlPresentation(
    showCarets: false,
    showThinkingLabel: false,
    showModeLabel: true,
    aggregateFeatures: true,
  ),
  ComposerControlDensity.tight => const ComposerControlPresentation(
    showCarets: false,
    showThinkingLabel: false,
    showModeLabel: false,
    aggregateFeatures: true,
  ),
};

/// Native surfaces use a larger toolbar glyph than web.
double resolveComposerToolbarGlyphSize({required bool isNative}) =>
    isNative ? 20 : 16;
