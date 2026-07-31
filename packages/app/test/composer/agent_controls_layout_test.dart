// Port of Paseo's `composer/agent-controls/layout.test.ts`.
import 'package:coding_agent_app/composer/agent_controls_layout.dart';
import 'package:flutter_test/flutter_test.dart';

const _controls = ComposerControlPresence(
  hasModel: true,
  hasThinking: true,
  hasMode: true,
  features: [ComposerFeatureToggle()],
);

void main() {
  test('removes labels in priority order as the toolbar narrows', () {
    expect(
      resolveComposerControlPresentation(ComposerControlDensity.full),
      const ComposerControlPresentation(
        showCarets: true,
        showThinkingLabel: true,
        showModeLabel: true,
        aggregateFeatures: false,
      ),
    );
    expect(
      resolveComposerControlPresentation(ComposerControlDensity.condensed),
      const ComposerControlPresentation(
        showCarets: false,
        showThinkingLabel: false,
        showModeLabel: true,
        aggregateFeatures: true,
      ),
    );
    expect(
      resolveComposerControlPresentation(ComposerControlDensity.tight),
      const ComposerControlPresentation(
        showCarets: false,
        showThinkingLabel: false,
        showModeLabel: false,
        aggregateFeatures: true,
      ),
    );
  });

  test('uses local available width and hysteresis to avoid density churn', () {
    expect(
      resolveComposerControlDensity(
        availableWidth: 420,
        currentDensity: ComposerControlDensity.full,
        controls: _controls,
      ),
      ComposerControlDensity.full,
    );
    expect(
      resolveComposerControlDensity(
        availableWidth: 380,
        currentDensity: ComposerControlDensity.full,
        controls: _controls,
      ),
      ComposerControlDensity.condensed,
    );
    expect(
      resolveComposerControlDensity(
        availableWidth: 290,
        currentDensity: ComposerControlDensity.condensed,
        controls: _controls,
      ),
      ComposerControlDensity.condensed,
    );
    expect(
      resolveComposerControlDensity(
        availableWidth: 280,
        currentDensity: ComposerControlDensity.condensed,
        controls: _controls,
      ),
      ComposerControlDensity.tight,
    );
    expect(
      resolveComposerControlDensity(
        availableWidth: 300,
        currentDensity: ComposerControlDensity.tight,
        controls: _controls,
      ),
      ComposerControlDensity.tight,
    );
    expect(
      resolveComposerControlDensity(
        availableWidth: 312,
        currentDensity: ComposerControlDensity.tight,
        controls: _controls,
      ),
      ComposerControlDensity.condensed,
    );
  });

  test('budgets extra features and larger text before restoring full '
      'labels', () {
    expect(
      resolveComposerControlDensity(
        availableWidth: 430,
        currentDensity: ComposerControlDensity.condensed,
        controls: _controls,
      ),
      ComposerControlDensity.full,
    );
    expect(
      resolveComposerControlDensity(
        availableWidth: 430,
        currentDensity: ComposerControlDensity.condensed,
        controls: const ComposerControlPresence(
          hasModel: true,
          hasThinking: true,
          hasMode: true,
          features: [ComposerFeatureToggle(), ComposerFeatureSelect('Tools')],
        ),
      ),
      ComposerControlDensity.condensed,
    );
    expect(
      resolveComposerControlDensity(
        availableWidth: 430,
        currentDensity: ComposerControlDensity.condensed,
        controls: const ComposerControlPresence(
          hasModel: true,
          hasThinking: true,
          hasMode: true,
          features: [ComposerFeatureToggle()],
          fontScale: 1.25,
        ),
      ),
      ComposerControlDensity.condensed,
    );
  });

  test('condenses before a labeled feature would overflow', () {
    expect(
      resolveComposerControlDensity(
        availableWidth: 430,
        currentDensity: ComposerControlDensity.full,
        controls: _controls,
      ),
      ComposerControlDensity.full,
    );
    expect(
      resolveComposerControlDensity(
        availableWidth: 430,
        currentDensity: ComposerControlDensity.full,
        controls: const ComposerControlPresence(
          hasModel: true,
          hasThinking: true,
          hasMode: true,
          features: [
            ComposerFeatureSelect('A much longer localized feature label'),
          ],
        ),
      ),
      ComposerControlDensity.condensed,
    );
  });

  test('gives every toolbar control one shell and one platform glyph '
      'envelope', () {
    expect(ComposerToolbarGeometry.controlSize, 28);
    expect(ComposerToolbarGeometry.controlGap, 4);
    expect(ComposerToolbarGeometry.iconLabelGap, 4);
    expect(ComposerToolbarGeometry.labelPadding, 8);
    expect(ComposerToolbarGeometry.caretSize, 14);
    expect(resolveComposerToolbarGlyphSize(isNative: false), 16);
    expect(resolveComposerToolbarGlyphSize(isNative: true), 20);
  });

  test('an empty toolbar still clears hysteresis before promoting', () {
    // Both floors are zero, but promoting out of tight still requires the
    // hysteresis band, so a zero-width toolbar stays tight.
    expect(
      resolveComposerControlDensity(
        availableWidth: 0,
        currentDensity: ComposerControlDensity.tight,
        controls: const ComposerControlPresence(),
      ),
      ComposerControlDensity.tight,
    );
    expect(
      resolveComposerControlDensity(
        availableWidth: 12,
        currentDensity: ComposerControlDensity.tight,
        controls: const ComposerControlPresence(),
      ),
      ComposerControlDensity.full,
    );
  });

  test('a non-finite or sub-unit font scale is clamped to 1', () {
    for (final scale in const [double.nan, 0.5, -3.0]) {
      expect(
        resolveComposerControlDensity(
          availableWidth: 430,
          currentDensity: ComposerControlDensity.condensed,
          controls: ComposerControlPresence(
            hasModel: true,
            hasThinking: true,
            hasMode: true,
            features: const [ComposerFeatureToggle()],
            fontScale: scale,
          ),
        ),
        ComposerControlDensity.full,
        reason: 'font scale $scale should behave as 1',
      );
    }
  });
}
