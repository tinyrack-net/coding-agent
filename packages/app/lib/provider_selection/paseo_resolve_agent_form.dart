/// Port of Paseo 0.2.0's `provider-selection/resolve-agent-form.ts`.
///
/// The create/edit-agent form has three competing sources of truth for its
/// provider, mode, model and thinking selection: values the caller passed in
/// (editing an existing agent, or a deep link), the user's saved preferences,
/// and whatever the user has since touched in the open form. On top of that the
/// provider catalog arrives asynchronously, so resolution runs again whenever a
/// snapshot lands.
///
/// This module is the pure decision layer for that: a reducer plus the
/// resolution helpers it calls. The invariants worth knowing before changing
/// anything here:
///
/// - **A field the user touched is never overwritten.** [UserModifiedFields]
///   latches per field, and every resolver returns the current value untouched
///   when its flag is set. The one exception is a user-picked provider that the
///   refreshed catalog no longer offers — that is cleared rather than kept.
/// - **Resolution runs at most once per open.** [AgentFormReducerState.resolution]
///   gates it, so a background snapshot refresh cannot re-derive a selection the
///   form already settled on.
/// - **Saved modes are user intent.** An unknown mode id survives resolution
///   even when the provider does not advertise it; the provider's create config
///   validates modes at submission time, so erasing it here would silently drop
///   a deliberate choice while the catalog is still loading.
///
/// Reused rather than redeclared: [ProviderModelDefinition],
/// [ProviderSelectOption], [ProviderMode], [ProviderSnapshotEntry] and
/// [ProviderCatalogStatus] from `package:agent_protocol`, and
/// [CreateAgentPreferences] / [ProviderCreateAgentPreferences] from
/// `composer/create_agent_preferences.dart` (upstream's `FormPreferences` /
/// `ProviderPreferences`). Upstream's `AgentProvider` is a bare `string`, so
/// provider ids stay `String` here as they do everywhere else in this app.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../composer/create_agent_preferences.dart';

// ---------------------------------------------------------------------------
// Provider definitions
// ---------------------------------------------------------------------------

/// Upstream `AgentProviderDefinition` from `@getpaseo/protocol/provider-manifest`.
///
/// Declared here because the provider manifest is not ported yet and this
/// module's resolvers need the provider's advertised modes and default mode.
/// Modes reuse the protocol's [ProviderMode] instead of upstream's
/// `AgentProviderModeDefinition`; the only structural difference is that
/// upstream makes `icon`/`colorTier` required, which [buildProviderDefinitions]
/// guarantees by filling in the same defaults upstream does.
///
/// Upstream's optional `voice` block is omitted: nothing in this cluster reads
/// it.
final class AgentProviderDefinition {
  const AgentProviderDefinition({
    required this.id,
    required this.label,
    required this.description,
    required this.defaultModeId,
    this.modes = const [],
    this.enabledByDefault,
  });

  final String id;
  final String label;
  final String description;

  /// Null when the provider advertises no default; empty string is treated as
  /// "no default" too, matching upstream's truthiness check.
  final String? defaultModeId;
  final List<ProviderMode> modes;
  final bool? enabledByDefault;
}

/// Port of `utils/provider-definitions.ts`'s `buildProviderDefinitions`.
///
/// Lives in this file because upstream's `resolve-agent-form.test.ts` exercises
/// it directly and `utils/provider-definitions.ts` has no port yet; move it out
/// when that module lands.
///
/// A snapshot entry carries only the raw provider metadata, so missing display
/// affordances are filled with the same defaults upstream uses: a mode without
/// an icon renders as `ShieldCheck`, and one without a color tier is treated as
/// `moderate` (visible caution rather than an accidental "safe" badge).
List<AgentProviderDefinition> buildProviderDefinitions(
  List<ProviderSnapshotEntry>? snapshotEntries,
) {
  if (snapshotEntries == null || snapshotEntries.isEmpty) return const [];
  return [
    for (final entry in snapshotEntries)
      AgentProviderDefinition(
        id: entry.provider,
        label: entry.label ?? entry.provider,
        description: entry.description ?? '',
        defaultModeId: entry.defaultModeId,
        modes: [
          for (final mode in entry.modes ?? const <ProviderMode>[])
            ProviderMode(
              id: mode.id,
              label: mode.label,
              description: mode.description,
              icon: mode.icon ?? 'ShieldCheck',
              colorTier: mode.colorTier ?? 'moderate',
            ),
        ],
      ),
  ];
}

// ---------------------------------------------------------------------------
// Form value types
// ---------------------------------------------------------------------------

/// Values the caller seeds the form with, e.g. when editing an existing agent.
///
/// Every field is optional in the upstream interface. Only `serverId` needs the
/// full JS tri-state (absent / explicitly `null` / a value): resolution treats
/// "absent" as "leave the current server alone" but an explicit `null` as
/// "clear it". Dart has no `undefined`, so absence is carried by [hasServerId]
/// and set through the [FormInitialValues.withServerId] constructor.
///
/// The remaining fields collapse `null` and absent into `null`, which is
/// faithful: upstream reads each of them through a trim-or-empty normalization
/// where both spellings already produce the same result.
final class FormInitialValues {
  /// Initial values with no server id override at all.
  const FormInitialValues({
    this.provider,
    this.modeId,
    this.model,
    this.thinkingOptionId,
    this.workingDir,
  }) : serverId = null,
       hasServerId = false;

  /// Initial values carrying an explicit server id, including an explicit
  /// `null` meaning "no server".
  const FormInitialValues.withServerId(
    this.serverId, {
    this.provider,
    this.modeId,
    this.model,
    this.thinkingOptionId,
    this.workingDir,
  }) : hasServerId = true;

  /// Whether `serverId` was supplied at all, i.e. upstream's
  /// `initialValues.serverId !== undefined`.
  final bool hasServerId;
  final String? serverId;
  final String? provider;
  final String? modeId;
  final String? model;
  final String? thinkingOptionId;
  final String? workingDir;

  /// Upstream's `{ ...initialValues, serverId: value }` spread.
  FormInitialValues withServerIdOverride(String? value) =>
      FormInitialValues.withServerId(
        value,
        provider: provider,
        modeId: modeId,
        model: model,
        thinkingOptionId: thinkingOptionId,
        workingDir: workingDir,
      );

  @override
  bool operator ==(Object other) =>
      other is FormInitialValues &&
      other.hasServerId == hasServerId &&
      other.serverId == serverId &&
      other.provider == provider &&
      other.modeId == modeId &&
      other.model == model &&
      other.thinkingOptionId == thinkingOptionId &&
      other.workingDir == workingDir;

  @override
  int get hashCode => Object.hash(
    hasServerId,
    serverId,
    provider,
    modeId,
    model,
    thinkingOptionId,
    workingDir,
  );

  @override
  String toString() =>
      'FormInitialValues(hasServerId: $hasServerId, serverId: $serverId, '
      'provider: $provider, modeId: $modeId, model: $model, '
      'thinkingOptionId: $thinkingOptionId, workingDir: $workingDir)';
}

const Object _unset = Object();

/// The form's live selection.
///
/// `provider` is nullable because "nothing selected yet" is a real state the
/// submit button gates on; the string fields use `''` for the same idea because
/// that is what upstream stores in its controlled inputs.
final class FormState {
  const FormState({
    this.serverId,
    this.provider,
    this.modeId = '',
    this.model = '',
    this.thinkingOptionId = '',
    this.workingDir = '',
  });

  final String? serverId;
  final String? provider;
  final String modeId;
  final String model;
  final String thinkingOptionId;
  final String workingDir;

  FormState copyWith({
    Object? serverId = _unset,
    Object? provider = _unset,
    String? modeId,
    String? model,
    String? thinkingOptionId,
    String? workingDir,
  }) => FormState(
    serverId: identical(serverId, _unset) ? this.serverId : serverId as String?,
    provider: identical(provider, _unset) ? this.provider : provider as String?,
    modeId: modeId ?? this.modeId,
    model: model ?? this.model,
    thinkingOptionId: thinkingOptionId ?? this.thinkingOptionId,
    workingDir: workingDir ?? this.workingDir,
  );

  @override
  bool operator ==(Object other) =>
      other is FormState &&
      other.serverId == serverId &&
      other.provider == provider &&
      other.modeId == modeId &&
      other.model == model &&
      other.thinkingOptionId == thinkingOptionId &&
      other.workingDir == workingDir;

  @override
  int get hashCode => Object.hash(
    serverId,
    provider,
    modeId,
    model,
    thinkingOptionId,
    workingDir,
  );

  @override
  String toString() =>
      'FormState(serverId: $serverId, provider: $provider, modeId: $modeId, '
      'model: $model, thinkingOptionId: $thinkingOptionId, '
      'workingDir: $workingDir)';
}

/// Which fields the user has touched since the form opened.
///
/// A latched field is authoritative: background resolution reads it and leaves
/// the corresponding form value alone.
final class UserModifiedFields {
  const UserModifiedFields({
    this.serverId = false,
    this.provider = false,
    this.modeId = false,
    this.model = false,
    this.thinkingOptionId = false,
    this.workingDir = false,
  });

  final bool serverId;
  final bool provider;
  final bool modeId;
  final bool model;
  final bool thinkingOptionId;
  final bool workingDir;

  UserModifiedFields copyWith({
    bool? serverId,
    bool? provider,
    bool? modeId,
    bool? model,
    bool? thinkingOptionId,
    bool? workingDir,
  }) => UserModifiedFields(
    serverId: serverId ?? this.serverId,
    provider: provider ?? this.provider,
    modeId: modeId ?? this.modeId,
    model: model ?? this.model,
    thinkingOptionId: thinkingOptionId ?? this.thinkingOptionId,
    workingDir: workingDir ?? this.workingDir,
  );

  @override
  bool operator ==(Object other) =>
      other is UserModifiedFields &&
      other.serverId == serverId &&
      other.provider == provider &&
      other.modeId == modeId &&
      other.model == model &&
      other.thinkingOptionId == thinkingOptionId &&
      other.workingDir == workingDir;

  @override
  int get hashCode => Object.hash(
    serverId,
    provider,
    modeId,
    model,
    thinkingOptionId,
    workingDir,
  );

  @override
  String toString() =>
      'UserModifiedFields(serverId: $serverId, provider: $provider, '
      'modeId: $modeId, model: $model, '
      'thinkingOptionId: $thinkingOptionId, workingDir: $workingDir)';
}

/// Models per provider, as the snapshot delivers them.
///
/// A `null` value means "this provider's catalog has not loaded", which is
/// distinct from an empty list ("loaded, offers nothing"): the resolvers keep a
/// preferred model verbatim in the former case and fall back to the provider
/// default in the latter. A missing key reads the same as `null`.
typedef ProviderModelsByProvider = Map<String, List<ProviderModelDefinition>?>;

/// Whether the form has already derived its selection for this open.
///
/// Upstream models this as `{ status: "pending" } | { status: "completed" }`;
/// the payload-free union collapses to an enum here.
enum AgentFormResolutionState { pending, completed }

/// A form open always starts unresolved.
const AgentFormResolutionState pendingAgentFormResolution =
    AgentFormResolutionState.pending;

/// Alias kept from upstream, where the two constants document different intents
/// (the pending sentinel vs. the reducer's initial value) despite being equal.
const AgentFormResolutionState initialAgentFormResolution =
    pendingAgentFormResolution;

/// Nothing touched yet.
const UserModifiedFields initialUserModified = UserModifiedFields();

/// The full reducer state: the selection, what the user touched, and whether
/// resolution has run.
final class AgentFormReducerState {
  const AgentFormReducerState({
    required this.form,
    this.userModified = initialUserModified,
    this.resolution = initialAgentFormResolution,
  });

  final FormState form;
  final UserModifiedFields userModified;
  final AgentFormResolutionState resolution;

  AgentFormReducerState copyWith({
    FormState? form,
    UserModifiedFields? userModified,
    AgentFormResolutionState? resolution,
  }) => AgentFormReducerState(
    form: form ?? this.form,
    userModified: userModified ?? this.userModified,
    resolution: resolution ?? this.resolution,
  );
}

/// Provider states whose selection may still be *resolved* against.
///
/// A provider that is merely reloading its catalog keeps the user's saved
/// selection instead of having it wiped mid-refresh.
const Set<ProviderCatalogStatus> resolvableProviderStatuses = {
  ProviderCatalogStatus.ready,
  ProviderCatalogStatus.loading,
};

/// Provider states the user may actively *choose* from.
const Set<ProviderCatalogStatus> selectableProviderStatuses = {
  ProviderCatalogStatus.ready,
};

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

/// Everything that can move the agent form forward.
///
/// Upstream's discriminated union becomes a sealed hierarchy, which makes the
/// reducer's switch exhaustive and removes upstream's unreachable `default:
/// throw new Error("unreachable")` arm.
sealed class AgentFormAction {
  const AgentFormAction();
}

/// Reopening the form: forget what the user touched and resolve again.
final class AgentFormRequestResolution extends AgentFormAction {
  const AgentFormRequestResolution();
}

/// The catalog is available; derive the selection once.
final class AgentFormCompleteResolution extends AgentFormAction {
  const AgentFormCompleteResolution({
    this.initialValues,
    this.preferences,
    required this.providerModelsByProvider,
    required this.allowedProviderMap,
  });

  final FormInitialValues? initialValues;
  final CreateAgentPreferences? preferences;
  final ProviderModelsByProvider providerModelsByProvider;
  final Map<String, AgentProviderDefinition> allowedProviderMap;
}

/// Programmatic server change (e.g. the route changed), not a user choice.
final class AgentFormSetServerId extends AgentFormAction {
  const AgentFormSetServerId(this.value);

  final String? value;
}

/// The user picked a server.
final class AgentFormSetServerIdFromUser extends AgentFormAction {
  const AgentFormSetServerIdFromUser(this.value);

  final String? value;
}

/// The user picked a provider; mode, model and thinking are re-derived for it.
final class AgentFormSetProviderFromUser extends AgentFormAction {
  const AgentFormSetProviderFromUser({
    required this.provider,
    required this.providerModels,
    this.providerDef,
    this.providerPrefs,
  });

  final String provider;
  final List<ProviderModelDefinition>? providerModels;
  final AgentProviderDefinition? providerDef;
  final ProviderCreateAgentPreferences? providerPrefs;
}

/// The user picked a provider and a model in one gesture (the combined model
/// picker), so the model is not re-derived from preferences.
final class AgentFormSetProviderAndModelFromUser extends AgentFormAction {
  const AgentFormSetProviderAndModelFromUser({
    required this.provider,
    required this.modelId,
    this.providerDef,
    required this.providerModels,
    this.providerPrefs,
  });

  final String provider;
  final String modelId;
  final AgentProviderDefinition? providerDef;
  final List<ProviderModelDefinition>? providerModels;
  final ProviderCreateAgentPreferences? providerPrefs;
}

/// The user picked a permission mode.
final class AgentFormSetModeFromUser extends AgentFormAction {
  const AgentFormSetModeFromUser(this.modeId);

  final String modeId;
}

/// The user picked a model; thinking follows unless the user pinned it.
final class AgentFormSetModelFromUser extends AgentFormAction {
  const AgentFormSetModelFromUser({
    required this.modelId,
    required this.availableModels,
  });

  final String modelId;
  final List<ProviderModelDefinition>? availableModels;
}

/// The user cleared the provider selection entirely.
final class AgentFormClearProviderSelectionFromUser extends AgentFormAction {
  const AgentFormClearProviderSelectionFromUser();
}

/// The user picked a thinking level.
final class AgentFormSetThinkingOptionFromUser extends AgentFormAction {
  const AgentFormSetThinkingOptionFromUser(this.thinkingOptionId);

  final String thinkingOptionId;
}

/// Programmatic working-directory change.
final class AgentFormSetWorkingDir extends AgentFormAction {
  const AgentFormSetWorkingDir(this.value);

  final String value;
}

/// The user chose a working directory.
final class AgentFormSetWorkingDirFromUser extends AgentFormAction {
  const AgentFormSetWorkingDirFromUser(this.value);

  final String value;
}

/// Fill in a server only if none is set yet; never overrides one.
final class AgentFormAutoSelectServer extends AgentFormAction {
  const AgentFormAutoSelectServer(this.candidateServerId);

  final String candidateServerId;
}

/// Closing the form: keep the values, but mark them unresolved for next open.
final class AgentFormReset extends AgentFormAction {
  const AgentFormReset();
}

// ---------------------------------------------------------------------------
// Selection helpers
// ---------------------------------------------------------------------------

/// JS truthiness for a string: `null` and `''` are both "absent".
///
/// Upstream leans on this in several guards (`if (provider)`,
/// `if (defaultModeId && ...)`); Dart's `!= null` alone would let an empty id
/// through and change behavior.
bool _hasValue(String? value) => value != null && value.isNotEmpty;

/// Trims a model id, treating a missing one as empty.
String normalizeSelectedModelId(String? modelId) => modelId?.trim() ?? '';

/// The catalog's declared default model, else its first entry.
ProviderModelDefinition? resolveDefaultModel(
  List<ProviderModelDefinition>? availableModels,
) {
  if (availableModels == null || availableModels.isEmpty) return null;
  for (final model in availableModels) {
    if (model.isDefault == true) return model;
  }
  return availableModels.first;
}

/// [resolveDefaultModel]'s id, or `''` when there is no catalog.
String resolveDefaultModelId(List<ProviderModelDefinition>? availableModels) =>
    resolveDefaultModel(availableModels)?.id ?? '';

/// The catalog entry a selection actually resolves to.
///
/// A selected id that the catalog does not contain falls back to the default
/// model rather than to nothing, so thinking options stay derivable while a
/// stale id is on screen.
ProviderModelDefinition? resolveEffectiveModel(
  List<ProviderModelDefinition>? availableModels,
  String modelId,
) {
  if (availableModels == null || availableModels.isEmpty) return null;
  final normalizedModelId = modelId.trim();
  if (normalizedModelId.isEmpty) return null;
  for (final model in availableModels) {
    if (model.id == normalizedModelId) return model;
  }
  return resolveDefaultModel(availableModels);
}

/// The thinking option to select for a model.
///
/// Models without thinking options resolve to `''` so the control hides. A
/// requested option that the model still offers wins; otherwise the model's own
/// default, then its first option.
String resolveThinkingOptionId({
  required List<ProviderModelDefinition>? availableModels,
  required String modelId,
  required String requestedThinkingOptionId,
}) {
  final effectiveModel = resolveEffectiveModel(availableModels, modelId);
  final thinkingOptions =
      effectiveModel?.thinkingOptions ?? const <ProviderSelectOption>[];
  if (thinkingOptions.isEmpty) return '';

  final normalizedThinkingOptionId = requestedThinkingOptionId.trim();
  if (normalizedThinkingOptionId.isNotEmpty &&
      thinkingOptions.any(
        (option) => option.id == normalizedThinkingOptionId,
      )) {
    return normalizedThinkingOptionId;
  }

  return effectiveModel?.defaultThinkingOptionId ?? thinkingOptions.first.id;
}

/// Mode ids normalize exactly like model ids upstream (`normalizeSelectedModeId`
/// is an alias for `normalizeSelectedModelId` there).
String _normalizeSelectedModeId(String? modeId) =>
    normalizeSelectedModelId(modeId);

/// Which mode a provider should land on.
///
/// Saved modes are user intent: an explicit initial mode, then the saved
/// preference, both win over the provider's default even when the provider does
/// not currently advertise them. The provider's default is only accepted when it
/// is actually offered — or when the provider advertises no modes at all, which
/// happens while a snapshot is still loading and would otherwise blank the
/// control.
String _resolvePreferredModeId({
  String? initialModeId,
  String? preferredModeId,
  AgentProviderDefinition? providerDef,
}) {
  final normalizedInitial = _normalizeSelectedModeId(initialModeId);
  if (normalizedInitial.isNotEmpty) return normalizedInitial;

  final normalizedPreferred = _normalizeSelectedModeId(preferredModeId);
  if (normalizedPreferred.isNotEmpty) return normalizedPreferred;

  final defaultModeId = providerDef?.defaultModeId;
  final modes = providerDef?.modes ?? const <ProviderMode>[];
  if (_hasValue(defaultModeId) &&
      (modes.isEmpty || modes.any((mode) => mode.id == defaultModeId))) {
    return defaultModeId!;
  }
  return modes.isEmpty ? '' : modes.first.id;
}

/// Writes a provider's selection back into saved preferences.
///
/// Upstream takes a `Partial<ProviderPreferences>`; Dart named parameters carry
/// the same "omitted means unchanged" semantics, and
/// [ProviderCreateAgentPreferences.copyWith] already merges `thinkingByModel`
/// and `featureValues` rather than replacing them, matching upstream's
/// `mergeDefinedRecord`.
CreateAgentPreferences mergeSelectedComposerPreferences({
  required CreateAgentPreferences preferences,
  required String provider,
  String? model,
  String? mode,
  Map<String, String>? thinkingByModel,
  Map<String, Object?>? featureValues,
}) => preferences.mergeProvider(
  provider,
  (current) => current.copyWith(
    model: model,
    mode: mode,
    thinkingByModel: thinkingByModel,
    featureValues: featureValues,
  ),
);

/// Folds a route-level server id into caller-supplied initial values.
///
/// An explicit `serverId` on [initialValues] always wins, including an explicit
/// `null` — that is the caller saying "start with no server", which must not be
/// overwritten by the ambient route. Only when the caller said nothing about the
/// server does [initialServerId] fill in, and a `null` route server contributes
/// nothing at all rather than forcing a clear.
FormInitialValues? combineInitialValues(
  FormInitialValues? initialValues,
  String? initialServerId,
) {
  final hasExplicitServerId = initialValues?.hasServerId ?? false;
  final serverIdFromOptions = initialServerId;

  if (initialValues == null &&
      !hasExplicitServerId &&
      serverIdFromOptions == null) {
    return null;
  }

  if (hasExplicitServerId) {
    return initialValues!.withServerIdOverride(initialValues.serverId);
  }

  if (serverIdFromOptions != null) {
    return (initialValues ?? const FormInitialValues()).withServerIdOverride(
      serverIdFromOptions,
    );
  }

  return initialValues;
}

/// Whether resolution actually moved anything, so an unchanged resolution can
/// keep the previous state object and avoid a re-render.
bool hasFormStateChanged(FormState prev, FormState next) =>
    prev.serverId != next.serverId ||
    prev.provider != next.provider ||
    prev.modeId != next.modeId ||
    prev.model != next.model ||
    prev.thinkingOptionId != next.thinkingOptionId ||
    prev.workingDir != next.workingDir;

/// Indexes definitions by provider id, preserving list order.
///
/// Order is observable: callers render the map's keys, and Dart's `Map`
/// preserves insertion order exactly as a JS `Map` does.
Map<String, AgentProviderDefinition> buildProviderDefinitionMap(
  List<AgentProviderDefinition> providerDefinitions,
) => {for (final definition in providerDefinitions) definition.id: definition};

/// The definitions a form may use, filtered to providers whose snapshot status
/// is in [statuses] and which are enabled.
///
/// With no snapshot at all every definition is allowed: the form must not blank
/// out a selection just because availability is unknown.
Map<String, AgentProviderDefinition> buildProviderDefinitionMapForStatuses({
  required List<ProviderSnapshotEntry>? snapshotEntries,
  required List<AgentProviderDefinition> providerDefinitions,
  required Set<ProviderCatalogStatus> statuses,
}) {
  if (snapshotEntries == null || snapshotEntries.isEmpty) {
    return buildProviderDefinitionMap(providerDefinitions);
  }

  final matchingProviders = <String>{
    for (final entry in snapshotEntries)
      if (statuses.contains(entry.status) && entry.enabled) entry.provider,
  };

  return buildProviderDefinitionMap([
    for (final definition in providerDefinitions)
      if (matchingProviders.contains(definition.id)) definition,
  ]);
}

String? _resolveProvider({
  required String? currentProvider,
  required bool userModified,
  required FormInitialValues? initialValues,
  required CreateAgentPreferences? preferences,
  required Map<String, AgentProviderDefinition> allowedProviderMap,
}) {
  bool isDisallowed(String? provider) =>
      _hasValue(provider) &&
      allowedProviderMap.isNotEmpty &&
      !allowedProviderMap.containsKey(provider);

  if (userModified) {
    if (isDisallowed(currentProvider)) return null;
    return currentProvider;
  }
  final initialProvider = initialValues?.provider;
  if (_hasValue(initialProvider) &&
      allowedProviderMap.containsKey(initialProvider)) {
    return initialProvider;
  }
  final preferredProvider = preferences?.provider;
  if (_hasValue(preferredProvider) &&
      allowedProviderMap.containsKey(preferredProvider)) {
    return preferredProvider;
  }
  if (isDisallowed(currentProvider)) return null;
  return currentProvider;
}

String _resolveModeId({
  required String? provider,
  required bool userModified,
  required String currentModeId,
  required FormInitialValues? initialValues,
  required AgentProviderDefinition? providerDef,
  required ProviderCreateAgentPreferences? providerPrefs,
}) {
  if (userModified) return currentModeId;
  if (!_hasValue(provider)) return '';
  return _resolvePreferredModeId(
    initialModeId: initialValues?.modeId,
    preferredModeId: providerPrefs?.mode,
    providerDef: providerDef,
  );
}

String _resolveModelField({
  required String? provider,
  required bool userModified,
  required String currentModel,
  required FormInitialValues? initialValues,
  required ProviderCreateAgentPreferences? providerPrefs,
  required List<ProviderModelDefinition>? availableModels,
}) {
  if (userModified) return currentModel;
  if (!_hasValue(provider)) return '';
  bool isValidModel(String id) =>
      availableModels?.any((model) => model.id == id) ?? false;
  final initialModel = normalizeSelectedModelId(initialValues?.model);
  final preferredModel = normalizeSelectedModelId(providerPrefs?.model);
  final defaultModelId = resolveDefaultModelId(availableModels);
  // `!availableModels` upstream is true only for a null catalog: an empty array
  // is truthy in JS, so a loaded-but-empty catalog invalidates the id instead of
  // passing it through.
  if (initialModel.isNotEmpty) {
    return availableModels == null || isValidModel(initialModel)
        ? initialModel
        : defaultModelId;
  }
  if (preferredModel.isNotEmpty) {
    return availableModels == null || isValidModel(preferredModel)
        ? preferredModel
        : defaultModelId;
  }
  return '';
}

String _resolveThinkingOption({
  required String? provider,
  required bool userModified,
  required String currentThinkingOptionId,
  required String modelId,
  required FormInitialValues? initialValues,
  required ProviderCreateAgentPreferences? providerPrefs,
}) {
  // The provider check deliberately precedes the user-modified check here,
  // unlike the mode and model resolvers: without a provider there is nothing a
  // thinking level could apply to.
  if (!_hasValue(provider)) return '';
  if (userModified) return currentThinkingOptionId;
  final initialThinkingOptionId = initialValues?.thinkingOptionId?.trim() ?? '';
  final effectiveModelId = modelId.trim();
  final preferredThinking = effectiveModelId.isNotEmpty
      ? (providerPrefs?.thinkingByModel[effectiveModelId]?.trim() ?? '')
      : '';
  if (initialThinkingOptionId.isNotEmpty) return initialThinkingOptionId;
  if (preferredThinking.isNotEmpty) return preferredThinking;
  return '';
}

/// Derives the form selection from initial values, saved preferences and the
/// provider catalog, leaving every user-touched field alone.
///
/// [availableModels] is the catalog for the *resolved* provider, which is why
/// [resolveFormStateFromProviderModels] resolves twice: the provider must be
/// known before its model list can be looked up.
FormState resolveFormState(
  FormInitialValues? initialValues,
  CreateAgentPreferences? preferences,
  List<ProviderModelDefinition>? availableModels,
  UserModifiedFields userModified,
  FormState currentState,
  Map<String, AgentProviderDefinition> allowedProviderMap,
) {
  final provider = _resolveProvider(
    currentProvider: currentState.provider,
    userModified: userModified.provider,
    initialValues: initialValues,
    preferences: preferences,
    allowedProviderMap: allowedProviderMap,
  );

  final providerDef = _hasValue(provider) ? allowedProviderMap[provider] : null;
  final providerPrefs = _hasValue(provider)
      ? preferences?.providerPreferences[provider]
      : null;

  final modeId = _resolveModeId(
    provider: provider,
    userModified: userModified.modeId,
    currentModeId: currentState.modeId,
    initialValues: initialValues,
    providerDef: providerDef,
    providerPrefs: providerPrefs,
  );

  final model = _resolveModelField(
    provider: provider,
    userModified: userModified.model,
    currentModel: currentState.model,
    initialValues: initialValues,
    providerPrefs: providerPrefs,
    availableModels: availableModels,
  );

  var thinkingOptionId = _resolveThinkingOption(
    provider: provider,
    userModified: userModified.thinkingOptionId,
    currentThinkingOptionId: currentState.thinkingOptionId,
    modelId: model,
    initialValues: initialValues,
    providerPrefs: providerPrefs,
  );

  // An empty (but present) catalog still counts as loaded here, matching
  // upstream's truthiness on the array.
  if (_hasValue(provider) && availableModels != null) {
    thinkingOptionId = resolveThinkingOptionId(
      availableModels: availableModels,
      modelId: model,
      requestedThinkingOptionId: thinkingOptionId,
    );
  }

  var serverId = currentState.serverId;
  if (!userModified.serverId && (initialValues?.hasServerId ?? false)) {
    serverId = initialValues!.serverId;
  }

  var workingDir = currentState.workingDir;
  if (!userModified.workingDir && initialValues?.workingDir != null) {
    workingDir = initialValues!.workingDir!;
  }

  return FormState(
    serverId: serverId,
    provider: provider,
    modeId: modeId,
    model: model,
    thinkingOptionId: thinkingOptionId,
    workingDir: workingDir,
  );
}

/// [resolveFormState] against a per-provider catalog map.
///
/// Runs the resolution twice on purpose: the first pass (with no catalog) only
/// exists to learn which provider wins, so the second pass can be handed that
/// provider's model list.
FormState resolveFormStateFromProviderModels(
  FormInitialValues? initialValues,
  CreateAgentPreferences? preferences,
  ProviderModelsByProvider providerModelsByProvider,
  UserModifiedFields userModified,
  FormState currentState,
  Map<String, AgentProviderDefinition> allowedProviderMap,
) {
  final providerResolved = resolveFormState(
    initialValues,
    preferences,
    null,
    userModified,
    currentState,
    allowedProviderMap,
  );
  final availableModels = _hasValue(providerResolved.provider)
      ? providerModelsByProvider[providerResolved.provider]
      : null;

  return resolveFormState(
    initialValues,
    preferences,
    availableModels,
    userModified,
    currentState,
    allowedProviderMap,
  );
}

String _pickNextModelForProvider({
  required List<ProviderModelDefinition>? providerModels,
  required ProviderCreateAgentPreferences? providerPrefs,
}) {
  bool isValidModel(String id) =>
      providerModels?.any((model) => model.id == id) ?? false;
  final preferredModel = normalizeSelectedModelId(providerPrefs?.model);
  final defaultModelId = resolveDefaultModelId(providerModels);
  if (preferredModel.isNotEmpty &&
      (providerModels == null || isValidModel(preferredModel))) {
    return preferredModel;
  }
  return defaultModelId;
}

String _pickNextModeForProvider({
  required AgentProviderDefinition? providerDef,
  required ProviderCreateAgentPreferences? providerPrefs,
}) => _resolvePreferredModeId(
  preferredModeId: providerPrefs?.mode,
  providerDef: providerDef,
);

/// Keeps the mode the user is already on when the provider does not change, so
/// picking a different model of the same provider does not silently reset
/// permissions.
String _pickNextModeForProviderAndModel({
  required String? currentProvider,
  required String currentModeId,
  required String provider,
  required AgentProviderDefinition? providerDef,
  required ProviderCreateAgentPreferences? providerPrefs,
}) {
  final normalizedModeId = _normalizeSelectedModeId(currentModeId);
  if (currentProvider == provider && normalizedModeId.isNotEmpty) {
    return normalizedModeId;
  }
  return _pickNextModeForProvider(
    providerDef: providerDef,
    providerPrefs: providerPrefs,
  );
}

String _pickNextThinkingOptionForProvider({
  required List<ProviderModelDefinition>? providerModels,
  required ProviderCreateAgentPreferences? providerPrefs,
  required String modelId,
}) {
  final preferredThinking = modelId.isNotEmpty
      ? (providerPrefs?.thinkingByModel[modelId]?.trim() ?? '')
      : '';
  return resolveThinkingOptionId(
    availableModels: providerModels,
    modelId: modelId,
    requestedThinkingOptionId: preferredThinking,
  );
}

AgentFormReducerState _completeResolution(
  AgentFormReducerState state,
  AgentFormCompleteResolution action,
) {
  // Resolution is once-per-open: a later snapshot must not re-derive a
  // selection the form already settled on.
  if (state.resolution == AgentFormResolutionState.completed) {
    return state;
  }
  final resolved = resolveFormStateFromProviderModels(
    action.initialValues,
    action.preferences,
    action.providerModelsByProvider,
    state.userModified,
    state.form,
    action.allowedProviderMap,
  );
  final nextState = state.copyWith(
    resolution: AgentFormResolutionState.completed,
  );
  if (!hasFormStateChanged(state.form, resolved)) return nextState;
  return nextState.copyWith(form: resolved);
}

/// The agent form reducer.
///
/// Returns the *same* state instance when an action is a no-op (a completed
/// resolution, an auto-select against an already-chosen server), mirroring
/// upstream's referential-equality contract that React relies on to skip
/// re-renders.
AgentFormReducerState resolveAgentForm(
  AgentFormReducerState state,
  AgentFormAction action,
) {
  switch (action) {
    case AgentFormRequestResolution():
      return state.copyWith(
        userModified: initialUserModified,
        resolution: pendingAgentFormResolution,
      );

    case AgentFormCompleteResolution():
      return _completeResolution(state, action);

    case AgentFormSetServerId(:final value):
      return state.copyWith(form: state.form.copyWith(serverId: value));

    case AgentFormSetServerIdFromUser(:final value):
      return state.copyWith(
        form: state.form.copyWith(serverId: value),
        userModified: state.userModified.copyWith(serverId: true),
      );

    case AgentFormSetProviderFromUser(
      :final provider,
      :final providerModels,
      :final providerDef,
      :final providerPrefs,
    ):
      final nextModelId = _pickNextModelForProvider(
        providerModels: providerModels,
        providerPrefs: providerPrefs,
      );
      final nextModeId = _pickNextModeForProvider(
        providerDef: providerDef,
        providerPrefs: providerPrefs,
      );
      final nextThinkingOptionId = _pickNextThinkingOptionForProvider(
        providerModels: providerModels,
        providerPrefs: providerPrefs,
        modelId: nextModelId,
      );
      return state.copyWith(
        form: state.form.copyWith(
          provider: provider,
          modeId: nextModeId,
          model: nextModelId,
          thinkingOptionId: nextThinkingOptionId,
        ),
        userModified: state.userModified.copyWith(provider: true),
      );

    case AgentFormSetProviderAndModelFromUser(
      :final provider,
      :final modelId,
      :final providerDef,
      :final providerModels,
      :final providerPrefs,
    ):
      final normalizedModelId = normalizeSelectedModelId(modelId);
      final nextModelId = normalizedModelId.isNotEmpty
          ? normalizedModelId
          : resolveDefaultModelId(providerModels);
      final nextThinkingOptionId = resolveThinkingOptionId(
        availableModels: providerModels,
        modelId: nextModelId,
        requestedThinkingOptionId: '',
      );
      final nextModeId = _pickNextModeForProviderAndModel(
        currentProvider: state.form.provider,
        currentModeId: state.form.modeId,
        provider: provider,
        providerDef: providerDef,
        providerPrefs: providerPrefs,
      );
      return state.copyWith(
        form: state.form.copyWith(
          provider: provider,
          model: nextModelId,
          modeId: nextModeId,
          thinkingOptionId: nextThinkingOptionId,
        ),
        userModified: state.userModified.copyWith(provider: true, model: true),
      );

    case AgentFormSetModeFromUser(:final modeId):
      return state.copyWith(
        form: state.form.copyWith(modeId: modeId),
        userModified: state.userModified.copyWith(modeId: true),
      );

    case AgentFormSetModelFromUser(:final modelId, :final availableModels):
      final normalizedModelId = normalizeSelectedModelId(modelId);
      final nextModelId = normalizedModelId.isNotEmpty
          ? normalizedModelId
          : resolveDefaultModelId(availableModels);
      final nextThinkingOptionId = resolveThinkingOptionId(
        availableModels: availableModels,
        modelId: nextModelId,
        // A thinking level the user pinned is offered back to the new model;
        // otherwise the new model's own default wins.
        requestedThinkingOptionId: state.userModified.thinkingOptionId
            ? state.form.thinkingOptionId
            : '',
      );
      return state.copyWith(
        form: state.form.copyWith(
          model: nextModelId,
          thinkingOptionId: nextThinkingOptionId,
        ),
        userModified: state.userModified.copyWith(model: true),
      );

    case AgentFormClearProviderSelectionFromUser():
      return state.copyWith(
        form: state.form.copyWith(
          provider: null,
          model: '',
          modeId: '',
          thinkingOptionId: '',
        ),
        userModified: state.userModified.copyWith(
          provider: true,
          model: true,
          modeId: true,
          thinkingOptionId: true,
        ),
      );

    case AgentFormSetThinkingOptionFromUser(:final thinkingOptionId):
      return state.copyWith(
        form: state.form.copyWith(thinkingOptionId: thinkingOptionId),
        userModified: state.userModified.copyWith(thinkingOptionId: true),
      );

    case AgentFormSetWorkingDir(:final value):
      return state.copyWith(form: state.form.copyWith(workingDir: value));

    case AgentFormSetWorkingDirFromUser(:final value):
      return state.copyWith(
        form: state.form.copyWith(workingDir: value),
        userModified: state.userModified.copyWith(workingDir: true),
      );

    case AgentFormAutoSelectServer(:final candidateServerId):
      if (_hasValue(state.form.serverId)) return state;
      return state.copyWith(
        form: state.form.copyWith(serverId: candidateServerId),
      );

    case AgentFormReset():
      return state.copyWith(
        userModified: initialUserModified,
        resolution: initialAgentFormResolution,
      );
  }
}
