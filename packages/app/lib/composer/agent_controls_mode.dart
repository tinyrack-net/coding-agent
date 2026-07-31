/// Port of Paseo 0.2.0's `composer/agent-controls/mode.ts` and
/// `composer/agent-controls/model-loading.ts`.
library;

import 'package:agent_protocol/agent_protocol.dart';

/// Which surface the composer's agent controls are rendering for.
///
/// A draft composer owns its provider/model/mode selection, so it renders
/// the full control set; a ready composer targets an existing agent whose
/// configuration is already fixed.
enum AgentControlsMode { draft, ready }

/// Draft controls are present only on a draft composer.
AgentControlsMode resolveAgentControlsMode({required bool hasAgentControls}) =>
    hasAgentControls ? AgentControlsMode.draft : AgentControlsMode.ready;

/// Returns the mode the cycle shortcut should select next, or null when
/// there is nothing to cycle through.
///
/// An empty or stale selection is treated as the visible first mode, so the
/// first cycle lands on the second option rather than appearing to do
/// nothing.
String? resolveNextAgentModeId({
  required List<ProviderMode> modeOptions,
  String? selectedMode,
}) {
  if (modeOptions.length < 2) return null;

  final selectedIndex = modeOptions.indexWhere(
    (mode) => mode.id == selectedMode,
  );
  final currentIndex = selectedIndex >= 0 ? selectedIndex : 0;
  final nextIndex = (currentIndex + 1) % modeOptions.length;
  return modeOptions[nextIndex].id;
}

/// The model list counts as loading while either an initial load or a
/// background refetch is in flight, so the picker does not flash a stale
/// list mid-refresh.
bool isProviderModelsQueryLoading({
  required bool isLoading,
  required bool isFetching,
}) => isLoading || isFetching;
