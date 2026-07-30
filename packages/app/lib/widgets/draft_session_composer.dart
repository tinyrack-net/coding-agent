import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../attachments/attachment_store.dart';
import '../command_center/command_center.dart';
import '../composer/agent_command_autocomplete.dart';
import '../composer/composer_draft_store.dart';
import '../composer/composer_image_attachment_service.dart';
import '../composer/composer_image_attachments.dart';
import '../composer/create_agent_preferences.dart';
import '../composer/draft_agent_selection.dart';
import '../composer/draft_feature_values.dart';
import '../composer/file_mention_autocomplete.dart';
import '../composer/provider_model_selection.dart';
import '../composer/workspace_draft_submission.dart';
import '../core/daemon_client.dart';
import '../core/theme.dart';
import '../import_sessions/import_session_dialog.dart';
import '../keyboard/keyboard_ime.dart';
import '../providers/agent_commands.dart';
import '../providers/draft_provider_features.dart';
import '../providers/providers_snapshot.dart';
import '../state/agent_commands_provider.dart';
import '../state/agents_provider.dart';
import '../state/command_center_provider.dart';
import '../state/create_flow_provider.dart';
import '../state/daemon_providers.dart';
import '../state/directory_suggestions_provider.dart';
import '../state/draft_provider_features_provider.dart';
import '../state/providers_snapshot_provider.dart';
import '../state/queued_messages_provider.dart';
import '../state/timeline_provider.dart';
import '../state/workspace_attachments_provider.dart';
import '../state/worktree_tabs_provider.dart';
import 'composer.dart';
import 'combined_model_selector.dart';
import 'draft_feature_control.dart';
import 'composer_image_preview.dart';

AgentMode _legacyModeFor(String? modeId) => switch (modeId) {
  'plan' || 'read-only' => AgentMode.plan,
  'full' || 'full-access' || 'bypassPermissions' => AgentMode.fullAccess,
  _ => AgentMode.normal,
};

/// Inline composer for a `draft`-kind [WorktreeTab]: pick provider/model/mode
/// and an optional first prompt, then create the agent and convert this tab
/// to it in place. The worktree's cwd (and, for worktree-isolation agents,
/// its owning project/branch) are already fixed by the surrounding tab —
/// unlike [NewWorkspaceScreen], there is no project/isolation/base-ref
/// picker here.
class DraftSessionComposer extends ConsumerStatefulWidget {
  const DraftSessionComposer({
    super.key,
    required this.worktreePath,
    required this.tabId,
    this.workspaceId,
    this.projectPath,
    this.branch,
    this.isWorktree = false,
    this.imageAttachmentService,
    this.draftStore,
    this.preferencesService,
    this.isPaneFocused = true,
  });

  /// The agent's `cwd` once created — always this worktree's path.
  final String worktreePath;

  /// The draft tab converting to an agent tab on submit.
  final String tabId;
  final String? workspaceId;

  /// Set when [isWorktree] is true: the owning repo the worktree was
  /// created from.
  final String? projectPath;

  /// Set when [isWorktree] is true: the worktree's branch.
  final String? branch;

  final bool isWorktree;
  final ComposerImageAttachmentService? imageAttachmentService;
  final ComposerDraftStore? draftStore;
  final CreateAgentPreferencesService? preferencesService;
  final bool isPaneFocused;

  @override
  ConsumerState<DraftSessionComposer> createState() =>
      _DraftSessionComposerState();
}

class _DraftSessionComposerState extends ConsumerState<DraftSessionComposer> {
  final _promptController = TextEditingController();
  final _promptFocusNode = FocusNode();
  final List<PendingComposerImage> _images = [];

  String? _provider;
  String? _model;
  String? _modeId;
  String? _thinkingOptionId;
  Map<String, Object?> _featureValues = const {};
  bool _submitting = false;
  bool _addingImages = false;
  String? _errorMessage;
  late final ComposerImageAttachmentService _imageAttachmentService;
  late final ComposerDraftStore _draftStore;
  late final CreateAgentPreferencesService _preferencesService;
  CreateAgentPreferences _preferences = const CreateAgentPreferences();
  var _draftRevision = 0;
  var _suspendDraftPersistence = false;
  Future<void> _draftWrite = Future.value();
  late final Future<void> _draftHydration;
  bool _autoSubmitScheduled = false;
  bool _selectionTouched = false;
  var _autocompleteSelectedIndex = 0;
  var _debouncedFileFilterQuery = '';
  Timer? _fileFilterDebounce;
  final Object _commandCenterOwnerToken = Object();
  late final CommandCenterRegistryNotifier _commandCenterRegistry;
  CommandCenterRegistrationOwner? _commandCenterOwner;
  String? _commandCenterSignature;

  String get _draftKey => buildComposerDraftKey(
    serverId: 'local',
    agentId: widget.tabId,
    draftId: widget.tabId,
  );

  @override
  void initState() {
    super.initState();
    _imageAttachmentService =
        widget.imageAttachmentService ?? ComposerImageAttachmentService();
    _draftStore = widget.draftStore ?? PreferencesComposerDraftStore();
    _preferencesService =
        widget.preferencesService ?? createAgentPreferencesService;
    _commandCenterRegistry = ref.read(commandCenterRegistryProvider.notifier);
    _promptController.addListener(_onDraftTextChanged);
    _draftHydration = _hydrateDraft();
    unawaited(_hydratePreferences());
  }

  Future<void> _hydratePreferences() async {
    try {
      final preferences = await _preferencesService.load();
      if (!mounted) return;
      setState(() {
        _preferences = preferences;
        if (!_selectionTouched && preferences.provider != null) {
          _provider = preferences.provider;
          _model = null;
          _modeId = null;
          _thinkingOptionId = null;
          _featureValues = const {};
        }
      });
    } catch (_) {
      // Keep session-local values when preference storage is unavailable.
    }
  }

  Map<String, Object?> get _persistedFeatureValues {
    final provider = _provider;
    if (provider == null) return const {};
    return _preferences.providerPreferences[provider]?.featureValues ??
        const {};
  }

  void _setFeatureValue(String featureId, Object? value) {
    setState(() {
      _featureValues = {..._featureValues, featureId: value};
    });
    final provider = _provider;
    if (provider == null) return;
    unawaited(
      _persistSelection(provider: provider, featureValues: {featureId: value}),
    );
  }

  Future<void> _persistSelection({
    required String provider,
    String? model,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?>? featureValues,
  }) async {
    try {
      final preferences = await _preferencesService.update(
        (current) => mergeCreateAgentSelectionPreferences(
          preferences: current,
          provider: provider,
          modelId: model,
          modeId: modeId,
          thinkingOptionId: thinkingOptionId,
          featureValues: featureValues,
        ),
      );
      if (mounted) setState(() => _preferences = preferences);
    } catch (_) {
      // The local selection remains effective when persistence fails.
    }
  }

  void _selectProvider(String? provider) {
    setState(() {
      _selectionTouched = true;
      _provider = provider;
      _model = null;
      _modeId = null;
      _thinkingOptionId = null;
      _featureValues = const {};
    });
    if (provider != null) {
      unawaited(_persistSelection(provider: provider));
    }
  }

  void _selectProviderModel(String provider, String model) {
    setState(() {
      _selectionTouched = true;
      final providerChanged = _provider != provider;
      _provider = provider;
      _model = model;
      _thinkingOptionId = null;
      if (providerChanged) {
        _modeId = null;
        _featureValues = const {};
      }
    });
    unawaited(_persistSelection(provider: provider, model: model));
  }

  void _selectMode(String? modeId) {
    setState(() {
      _selectionTouched = true;
      _modeId = modeId;
    });
    final provider = _provider;
    if (provider != null) {
      unawaited(_persistSelection(provider: provider, modeId: modeId));
    }
  }

  void _selectThinking(String? thinkingOptionId) {
    setState(() {
      _selectionTouched = true;
      _thinkingOptionId = thinkingOptionId;
    });
    final provider = _provider;
    if (provider != null) {
      unawaited(
        _persistSelection(
          provider: provider,
          model: _model,
          thinkingOptionId: thinkingOptionId,
        ),
      );
    }
  }

  void _toggleFavoriteModel(String provider, String modelId) {
    unawaited(_updateFavoriteModel(provider, modelId));
  }

  Future<void> _updateFavoriteModel(String provider, String modelId) async {
    try {
      final preferences = await _preferencesService.update(
        (current) => toggleFavoriteModel(
          preferences: current,
          provider: provider,
          modelId: modelId,
        ),
      );
      if (mounted) setState(() => _preferences = preferences);
    } catch (_) {
      // Favorite changes are best-effort local preferences.
    }
  }

  @override
  void dispose() {
    final owner = _commandCenterOwner;
    if (owner != null) {
      Future<void>.microtask(() => _commandCenterRegistry.remove(owner));
    }
    _promptController.removeListener(_onDraftTextChanged);
    _fileFilterDebounce?.cancel();
    _promptController.dispose();
    _promptFocusNode.dispose();
    super.dispose();
  }

  void _syncCommandCenterModels({
    required String serverId,
    required List<ProviderSelectorProvider> providers,
    required String selectedProvider,
    required String selectedModelId,
    required bool enabled,
  }) {
    final modelSignature = [
      for (final provider in providers)
        if (provider.modelSelection case ProviderModelRows(:final rows))
          for (final model in rows)
            '${provider.id}:${model.modelId}:${model.modelLabel}',
    ].join(',');
    final signature = [
      serverId,
      enabled,
      selectedProvider,
      selectedModelId,
      modelSignature,
    ].join('|');
    if (_commandCenterSignature == signature) return;
    _commandCenterSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _commandCenterSignature != signature) return;
      final notifier = _commandCenterRegistry;
      final sourceId = 'draft:$serverId:${widget.tabId}';
      var owner = _commandCenterOwner;
      if (owner != null && owner.sourceId != sourceId) {
        notifier.remove(owner);
        owner = null;
      }
      owner ??= CommandCenterRegistrationOwner(
        sourceId: sourceId,
        token: _commandCenterOwnerToken,
      );
      _commandCenterOwner = owner;
      if (!enabled) {
        notifier.remove(owner);
        return;
      }
      notifier.replace(
        CommandCenterRegistration(
          owner: owner,
          contributions: buildModelChoiceContributions(
            serverId: serverId,
            providers: providers,
            selectedProvider: selectedProvider,
            selectedModelId: selectedModelId,
            groupLabel: 'Model',
            searchKeywords: 'model switch',
            select: _selectProviderModel,
          ),
        ),
      );
    });
  }

  void _onDraftTextChanged() {
    _scheduleFileFilterQuery();
    if (_suspendDraftPersistence) return;
    _draftRevision += 1;
    _persistDraft();
    if (mounted) setState(() => _autocompleteSelectedIndex = 0);
  }

  void _scheduleFileFilterQuery() {
    final selection = _promptController.selection;
    final mention = findActiveFileMention(
      text: _promptController.text,
      cursorIndex: selection.isValid
          ? selection.extentOffset
          : _promptController.text.length,
    );
    final query = mention?.query ?? '';
    _fileFilterDebounce?.cancel();
    if (query == _debouncedFileFilterQuery) return;
    _fileFilterDebounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      setState(() => _debouncedFileFilterQuery = query);
    });
  }

  Future<void> _hydrateDraft() async {
    final revision = _draftRevision;
    final draft = await _draftStore.load(_draftKey);
    if (!mounted || revision != _draftRevision) return;
    if (draft == null) {
      _scheduleAttachmentGc();
      return;
    }
    final images = await _imageAttachmentService.restore(draft.images);
    if (!mounted || revision != _draftRevision) return;
    _suspendDraftPersistence = true;
    _promptController.text = draft.text;
    _suspendDraftPersistence = false;
    setState(() => _images.addAll(images));
    _scheduleAttachmentGc();
  }

  void _persistDraft() {
    final draft = ComposerDraft(
      text: _promptController.text,
      images: _images
          .map((image) => image.metadata)
          .whereType<AttachmentMetadata>()
          .toList(growable: false),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _draftWrite = _draftWrite
        .then((_) async {
          if (draft.hasContent) {
            await _draftStore.save(_draftKey, draft);
          } else {
            await _draftStore.clear(
              _draftKey,
              lifecycle: ComposerDraftLifecycle.abandoned,
            );
          }
          await _garbageCollectDraftAttachments();
        })
        .catchError((_) {
          // Draft persistence is best effort and must not block agent creation.
        });
  }

  void _scheduleAttachmentGc() {
    _draftWrite = _draftWrite.then((_) => _garbageCollectDraftAttachments());
  }

  Future<void> _garbageCollectDraftAttachments() async {
    try {
      final referencedIds = await _draftStore.collectActiveAttachmentIds()
        ..addAll(ref.read(createFlowProvider.notifier).activeAttachmentIds());
      referencedIds.addAll(
        ref.read(timelineAttachmentOwnersProvider.notifier).attachmentIds(),
      );
      referencedIds
        ..addAll(ref.read(queuedMessagesProvider.notifier).attachmentIds())
        ..addAll(
          ref.read(workspaceScreenshotOwnersProvider.notifier).attachmentIds(),
        );
      await _imageAttachmentService.garbageCollectReferenced(referencedIds);
    } catch (_) {
      // GC failures do not affect the create flow.
    }
  }

  Future<void> _addDroppedImages(List<DropItem> items) async {
    if (_addingImages || _submitting) return;
    setState(() => _addingImages = true);
    try {
      final images = await _imageAttachmentService.persistDropped(items);
      if (!mounted || images.isEmpty) return;
      setState(() => _images.addAll(images));
      _persistDraft();
    } finally {
      if (mounted) setState(() => _addingImages = false);
    }
  }

  Future<void> _pickImages() async {
    if (_addingImages || _submitting) return;
    setState(() => _addingImages = true);
    try {
      final images = await _imageAttachmentService.pick();
      if (!mounted || images.isEmpty) return;
      setState(() => _images.addAll(images));
      _persistDraft();
    } finally {
      if (mounted) setState(() => _addingImages = false);
    }
  }

  void _removeImage(PendingComposerImage image) {
    setState(() => _images.remove(image));
    _persistDraft();
    unawaited(_imageAttachmentService.delete(image));
  }

  Future<void> _openImportSessions() async {
    await showImportSessionDialog(
      context: context,
      client: ref.read(daemonClientProvider),
      cwd: widget.worktreePath,
      workspaceId: widget.workspaceId,
      onImported: (agent) {
        ref.read(agentsProvider.notifier).upsert(agent);
        ref
            .read(worktreeTabsProvider(widget.worktreePath).notifier)
            .focusAgent(agent.agentId);
      },
    );
  }

  Future<void> _submit({
    required int providerCount,
    required List<ProviderModelDefinition> availableModels,
    required bool isModelLoading,
    required bool hasClient,
  }) async {
    final provider = _provider;
    final model = _model ?? '';
    final text = _promptController.text.trim();
    final readinessError = validateDraftSubmission(
      text: text,
      allowsEmptyAutoSubmit: shouldAllowEmptyDraftText(
        allowsEmptyAutoSubmit: false,
        attachments: _images,
      ),
      providerCount: providerCount,
      selectedProvider: provider,
      isModelLoading: isModelLoading,
      effectiveModelId: model,
      availableModels: availableModels,
      workspaceDirectory: widget.worktreePath,
      hasClient: hasClient,
    );
    if (readinessError != null) {
      setState(() => _errorMessage = readinessError);
      return;
    }
    if (provider == null) return;
    final clientMessageId = const Uuid().v4();
    final featureValues = _resolvedFeatureValues();
    final attempt = PendingCreateAttempt(
      draftId: widget.tabId,
      serverId: 'local',
      workspaceId: widget.workspaceId,
      agentId: null,
      clientMessageId: clientMessageId,
      text: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      lifecycle: CreateFlowLifecycle.active,
      images: _images
          .map((image) => image.metadata)
          .whereType<AttachmentMetadata>()
          .toList(growable: false),
    );
    ref.read(createFlowProvider.notifier).setPending(attempt);
    await _runCreateAttempt(
      attempt: attempt,
      provider: provider,
      model: model,
      modeId: _modeId,
      thinkingOptionId: _thinkingOptionId,
      featureValues: featureValues,
      images: List<PendingComposerImage>.of(_images),
    );
  }

  Future<void> _runCreateAttempt({
    required PendingCreateAttempt attempt,
    required String provider,
    required String model,
    required String? modeId,
    required String? thinkingOptionId,
    required Map<String, Object?> featureValues,
    required List<PendingComposerImage> images,
  }) async {
    final flow = ref.read(createFlowProvider.notifier);
    final tabs = ref.read(worktreeTabsProvider(widget.worktreePath).notifier);
    final actions = ref.read(agentActionsProvider);
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final promptImages = await _imageAttachmentService.encodeForSend(images);
      if (images.isNotEmpty && promptImages.isEmpty) {
        throw StateError('Failed to read attached images.');
      }
      final agent = await actions.create(
        cwd: widget.worktreePath,
        provider: provider,
        model: model,
        mode: _legacyModeFor(modeId),
        modeId: modeId,
        thinkingOptionId: thinkingOptionId,
        featureValues: featureValues,
        workspaceId: widget.workspaceId,
        projectPath: widget.projectPath,
        branch: widget.branch,
        isWorktree: widget.isWorktree,
        initialPrompt: attempt.text,
        clientMessageId: attempt.clientMessageId,
        images: promptImages,
        attachments: attempt.attachments,
      );

      flow.updateAgentId(draftId: widget.tabId, agentId: agent.agentId);
      ref
          .read(timelineProvider(agent.agentId).notifier)
          .handoffCreatedUserMessage(
            OptimisticUserMessage(
              id: attempt.clientMessageId,
              text: attempt.text,
              timestamp: attempt.timestamp,
              images: attempt.images,
              attachments: attempt.attachments,
            ),
          );
      flow.markLifecycle(
        draftId: widget.tabId,
        lifecycle: CreateFlowLifecycle.sent,
      );
      tabs.retarget(widget.tabId, agent.agentId);
      try {
        await _draftStore.clear(
          _draftKey,
          lifecycle: ComposerDraftLifecycle.sent,
        );
        await _garbageCollectDraftAttachments();
      } catch (_) {
        // The agent already exists and owns the tab. Cleanup must not turn a
        // successful create into a visible create failure.
      }
      if (mounted) {
        setState(() => _submitting = false);
      }
    } catch (e) {
      flow.markLifecycle(
        draftId: widget.tabId,
        lifecycle: CreateFlowLifecycle.abandoned,
      );
      flow.clear(widget.tabId);
      _persistDraft();
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = 'Failed to create agent: $e';
      });
    }
  }

  void _schedulePendingAutoSubmit(PendingWorkspaceDraftSubmission submission) {
    if (_autoSubmitScheduled) return;
    _autoSubmitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_consumePendingAutoSubmit(submission));
    });
  }

  Future<void> _consumePendingAutoSubmit(
    PendingWorkspaceDraftSubmission expected,
  ) async {
    await _draftHydration;
    if (!mounted) return;
    final attempt = ref.read(createFlowProvider)[widget.tabId];
    if (!isActiveCreateFlowForDraft(
          pending: attempt,
          serverId: expected.serverId,
          draftId: expected.draftId,
        ) ||
        attempt?.workspaceId != expected.workspaceId ||
        attempt?.clientMessageId != expected.clientMessageId) {
      _autoSubmitScheduled = false;
      return;
    }
    final submission = ref
        .read(workspaceDraftSubmissionProvider.notifier)
        .consume(
          serverId: expected.serverId,
          workspaceId: expected.workspaceId,
          draftId: expected.draftId,
        );
    if (submission == null) return;
    _suspendDraftPersistence = true;
    _promptController.text = '';
    _suspendDraftPersistence = false;
    final images = List<PendingComposerImage>.of(_images);
    setState(() => _images.clear());
    await _runCreateAttempt(
      attempt: attempt!,
      provider: submission.provider,
      model: submission.model,
      modeId: submission.modeId,
      thinkingOptionId: submission.thinkingOptionId,
      featureValues: submission.featureValues,
      images: images,
    );
    if (mounted && ref.read(createFlowProvider)[widget.tabId] == null) {
      _suspendDraftPersistence = true;
      _promptController.text = submission.text;
      _suspendDraftPersistence = false;
      setState(() => _images.addAll(images));
      _persistDraft();
      _autoSubmitScheduled = false;
    }
  }

  ListCommandsDraftConfig? _draftConfigWithFeatures(
    Map<String, Object?> featureValues,
  ) => buildDraftCommandConfig(
    provider: _provider,
    cwd: widget.worktreePath,
    modeId: _modeId ?? '',
    modelId: _model ?? '',
    thinkingOptionId: _thinkingOptionId ?? '',
    featureValues: featureValues.isEmpty ? null : featureValues,
  );

  ListCommandsDraftConfig? get _featureDraftConfig =>
      _draftConfigWithFeatures(const {});

  DraftProviderFeaturesScope? _featureScope() {
    final config = _featureDraftConfig;
    if (config == null) return null;
    final client = ref.read(daemonClientProvider);
    return DraftProviderFeaturesScope(
      client: client,
      serverId: client.serverInfo?.serverId ?? 'local',
      draftConfig: config,
    );
  }

  Map<String, Object?> _resolvedFeatureValues() {
    final scope = _featureScope();
    if (scope == null) return const {};
    final state = ref.read(draftProviderFeaturesProvider(scope));
    return resolveDraftFeatureValues(
      features: state.features,
      persisted: _persistedFeatureValues,
      local: _featureValues,
    );
  }

  int get _cursorIndex {
    final selection = _promptController.selection;
    return selection.isValid
        ? selection.extentOffset
        : _promptController.text.length;
  }

  List<CommandAutocompleteEntry> _commandEntries(
    SlashCommandRange range,
    Iterable<AgentSlashCommand> commands,
  ) {
    final entries = [
      for (final command in commands)
        CommandAutocompleteEntry(command: command),
    ];
    final available = range.position == SlashCommandPosition.inline
        ? filterInlineSkillCommandEntries(entries)
        : entries;
    return filterAndRankCommandAutocompleteEntries(available, range.query);
  }

  void _replaceCommand(
    CommandAutocompleteEntry entry,
    SlashCommandRange range,
  ) {
    final text = applySlashCommandReplacement(
      text: _promptController.text,
      command: range,
      commandName: entry.command.name,
    );
    final cursor = range.start + entry.command.name.length + 2;
    _promptController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor.clamp(0, text.length)),
    );
    _promptFocusNode.requestFocus();
  }

  void _replaceFile(DirectorySuggestionEntry entry, FileMentionRange mention) {
    final text = applyFileMentionReplacement(
      text: _promptController.text,
      mention: mention,
      relativePath: entry.path,
    );
    final cursor =
        mention.start + formatQuotedFileMentionPath(entry.path).length;
    _promptController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor.clamp(0, text.length)),
    );
    _promptFocusNode.requestFocus();
  }

  KeyEventResult _onPromptKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (isImeComposingTextEditingValue(_promptController.value)) {
      return KeyEventResult.ignored;
    }
    final client = ref.read(daemonClientProvider);
    final serverId = client.serverInfo?.serverId ?? 'local';
    final mention = findActiveFileMention(
      text: _promptController.text,
      cursorIndex: _cursorIndex,
    );
    if (mention != null) {
      final state = ref.read(
        directorySuggestionsProvider(
          DirectorySuggestionsScope(
            client: client,
            serverId: serverId,
            cwd: widget.worktreePath,
            query: _debouncedFileFilterQuery,
            enabled: true,
          ),
        ),
      );
      if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (state.entries.isEmpty) return KeyEventResult.handled;
        final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
        setState(() {
          _autocompleteSelectedIndex =
              (_autocompleteSelectedIndex + delta) % state.entries.length;
        });
        return KeyEventResult.handled;
      }
      if ((event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.tab) &&
          state.entries.isNotEmpty) {
        _replaceFile(
          state.entries[_autocompleteSelectedIndex.clamp(
            0,
            state.entries.length - 1,
          )],
          mention,
        );
        return KeyEventResult.handled;
      }
    } else {
      final range = findActiveSlashCommand(
        text: _promptController.text,
        cursorIndex: _cursorIndex,
      );
      final config = _draftConfigWithFeatures(_resolvedFeatureValues());
      if (range != null && config != null) {
        final state = ref.read(
          agentCommandsProvider(
            AgentCommandsScope(
              client: client,
              serverId: serverId,
              agentId: '__new_agent__',
              draftConfig: config,
            ),
          ),
        );
        final entries = _commandEntries(range, state.commands);
        if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          if (entries.isEmpty) return KeyEventResult.handled;
          final delta = event.logicalKey == LogicalKeyboardKey.arrowDown
              ? 1
              : -1;
          setState(() {
            _autocompleteSelectedIndex =
                (_autocompleteSelectedIndex + delta) % entries.length;
          });
          return KeyEventResult.handled;
        }
        if ((event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.tab) &&
            entries.isNotEmpty) {
          _replaceCommand(
            entries[_autocompleteSelectedIndex.clamp(0, entries.length - 1)],
            range,
          );
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(daemonClientProvider);
    final serverId = client.serverInfo?.serverId ?? 'local';
    final snapshotScope = ProvidersSnapshotScope(
      client: client,
      serverId: serverId,
      cwd: widget.worktreePath,
    );
    final snapshot = ref.watch(providersSnapshotProvider(snapshotScope));
    final pendingAttempt = ref.watch(createFlowProvider)[widget.tabId];
    final pendingAutoSubmit = ref.watch(
      workspaceDraftSubmissionProvider,
    )[widget.tabId];
    if (pendingAutoSubmit != null &&
        pendingAutoSubmit.workspaceDirectory == widget.worktreePath &&
        pendingAutoSubmit.workspaceId == widget.workspaceId) {
      _selectionTouched = true;
      _provider = pendingAutoSubmit.provider;
      _model = pendingAutoSubmit.model;
      _modeId = pendingAutoSubmit.modeId;
      _thinkingOptionId = pendingAutoSubmit.thinkingOptionId;
      _featureValues = pendingAutoSubmit.featureValues;
      _schedulePendingAutoSubmit(pendingAutoSubmit);
    }
    final isSubmitting =
        _submitting || pendingAttempt?.lifecycle == CreateFlowLifecycle.active;
    final providers = [
      for (final entry in snapshot.entries ?? const <ProviderSnapshotEntry>[])
        if (entry.enabled && entry.status == ProviderCatalogStatus.ready) entry,
    ];
    final modelSelectorProviders = buildSelectableProviderSelectorProviders(
      snapshot.entries,
    );
    final favoriteKeys = {
      for (final favorite in _preferences.favoriteModels)
        buildFavoriteModelKey(
          provider: favorite.provider,
          modelId: favorite.modelId,
        ),
    };

    if (!snapshot.supportsSnapshot) {
      return const Center(
        child: Text('Update the host to use provider discovery.'),
      );
    }
    if (snapshot.isLoading && snapshot.entries == null) {
      return const Center(child: ProgressRing());
    }
    if (snapshot.error case final error? when snapshot.entries == null) {
      return Center(child: Text('Failed to load providers: $error'));
    }
    if (providers.isEmpty) {
      return const Center(
        child: Text(
          'No agent providers are available. Install or enable a provider '
          'on this host and try again.',
        ),
      );
    }

    final preferredProvider = _provider ?? _preferences.provider;
    var selectedProvider = providers.first;
    for (final entry in providers) {
      if (entry.provider == preferredProvider) {
        selectedProvider = entry;
        break;
      }
    }
    final providerChanged =
        _provider != null && _provider != selectedProvider.provider;
    _provider = selectedProvider.provider;
    if (providerChanged) {
      _model = null;
      _modeId = null;
      _thinkingOptionId = null;
      _featureValues = const {};
    }
    final providerPreferences =
        _preferences.providerPreferences[selectedProvider.provider];
    final models = selectedProvider.models ?? const <ProviderModelDefinition>[];
    final effectiveModel = resolveEffectiveDraftModelId(
      selectedModelId: _model ?? providerPreferences?.model,
      availableModels: models,
    );
    _model = effectiveModel;
    final effectiveMode = resolveEffectiveDraftModeId(
      selectedModeId: _modeId ?? providerPreferences?.mode,
      provider: selectedProvider,
    );
    _modeId = effectiveMode;
    final effectiveThinking = resolveEffectiveDraftThinkingOptionId(
      selectedThinkingOptionId:
          _thinkingOptionId ??
          providerPreferences?.thinkingByModel[effectiveModel],
      effectiveModelId: effectiveModel,
      availableModels: models,
    );
    _thinkingOptionId = effectiveThinking;
    ProviderModelDefinition? modelDefinition;
    for (final model in models) {
      if (model.id == effectiveModel) modelDefinition = model;
    }
    final thinkingOptions =
        modelDefinition?.thinkingOptions ?? const <ProviderSelectOption>[];
    final featureConfig = _featureDraftConfig;
    final featureScope = featureConfig == null
        ? null
        : DraftProviderFeaturesScope(
            client: client,
            serverId: serverId,
            draftConfig: featureConfig,
          );
    final featureState = featureScope == null
        ? const DraftProviderFeaturesState()
        : ref.watch(draftProviderFeaturesProvider(featureScope));
    final effectiveFeatureValues = resolveDraftFeatureValues(
      features: featureState.features,
      persisted: _persistedFeatureValues,
      local: _featureValues,
    );

    final fileMention = findActiveFileMention(
      text: _promptController.text,
      cursorIndex: _cursorIndex,
    );
    final commandRange = fileMention == null
        ? findActiveSlashCommand(
            text: _promptController.text,
            cursorIndex: _cursorIndex,
          )
        : null;
    final draftConfig = _draftConfigWithFeatures(effectiveFeatureValues);
    final commandState = ref.watch(
      agentCommandsProvider(
        AgentCommandsScope(
          client: client,
          serverId: serverId,
          agentId: '__new_agent__',
          draftConfig: draftConfig,
          enabled: commandRange != null && draftConfig != null,
        ),
      ),
    );
    final commandEntries = commandRange == null
        ? const <CommandAutocompleteEntry>[]
        : _commandEntries(commandRange, commandState.commands);
    final fileState = ref.watch(
      directorySuggestionsProvider(
        DirectorySuggestionsScope(
          client: client,
          serverId: serverId,
          cwd: widget.worktreePath,
          query: _debouncedFileFilterQuery,
          enabled: fileMention != null,
        ),
      ),
    );
    final visibleCount = fileMention != null
        ? fileState.entries.length
        : commandEntries.length;
    final selectedIndex = visibleCount == 0
        ? -1
        : _autocompleteSelectedIndex.clamp(0, visibleCount - 1);
    _syncCommandCenterModels(
      serverId: serverId,
      providers: modelSelectorProviders,
      selectedProvider: selectedProvider.provider,
      selectedModelId: effectiveModel,
      enabled: widget.isPaneFocused && !isSubmitting,
    );

    return DropTarget(
      onDragDone: (details) => unawaited(_addDroppedImages(details.files)),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ComboBox<String>(
                        key: const ValueKey('draft-provider-selector'),
                        value: selectedProvider.provider,
                        items: [
                          for (final p in providers)
                            ComboBoxItem(
                              value: p.provider,
                              child: Text(p.label ?? p.provider),
                            ),
                        ],
                        onChanged: isSubmitting ? null : _selectProvider,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CombinedModelSelector(
                        serverId: serverId,
                        providers: modelSelectorProviders,
                        selectedProvider: selectedProvider.provider,
                        selectedModel: effectiveModel,
                        favoriteKeys: favoriteKeys,
                        isLoading: snapshot.isLoading || snapshot.isFetching,
                        disabled: isSubmitting,
                        onSelect: _selectProviderModel,
                        onToggleFavorite: _toggleFavoriteModel,
                        onOpen: () => ref
                            .read(
                              providersSnapshotProvider(snapshotScope).notifier,
                            )
                            .refetchIfStale(selectedProvider.provider),
                        onRetryProvider: (provider) => unawaited(
                          ref
                              .read(
                                providersSnapshotProvider(
                                  snapshotScope,
                                ).notifier,
                              )
                              .refresh([provider]),
                        ),
                        isRetryingProvider: snapshot.isRefreshing,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ComboBox<String>(
                        key: const ValueKey('draft-mode-selector'),
                        value: effectiveMode.isEmpty ? null : effectiveMode,
                        items: [
                          for (final mode
                              in selectedProvider.modes ??
                                  const <ProviderMode>[])
                            ComboBoxItem(
                              value: mode.id,
                              child: Text(mode.label),
                            ),
                        ],
                        onChanged: isSubmitting ? null : _selectMode,
                      ),
                    ),
                    if (thinkingOptions.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: ComboBox<String>(
                          key: const ValueKey('draft-thinking-selector'),
                          value: effectiveThinking.isEmpty
                              ? null
                              : effectiveThinking,
                          items: [
                            for (final option in thinkingOptions)
                              ComboBoxItem(
                                value: option.id,
                                child: Text(option.label),
                              ),
                          ],
                          onChanged: isSubmitting ? null : _selectThinking,
                        ),
                      ),
                    ],
                  ],
                ),
                if (featureState.isLoading) ...[
                  const SizedBox(height: 12),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: ProgressRing(strokeWidth: 2),
                    ),
                  ),
                ] else if (featureState.error case final error?) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Failed to load provider features: $error',
                    key: const ValueKey('draft-provider-features-error'),
                    style: TextStyle(color: context.tokens.error),
                  ),
                ] else if (featureState.features.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    key: const ValueKey('draft-provider-features'),
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final feature in featureState.features)
                        DraftFeatureControl(
                          feature: feature,
                          value: applyDraftFeatureValue(
                            feature,
                            effectiveFeatureValues,
                          ),
                          enabled: !isSubmitting,
                          onChanged: (value) =>
                              _setFeatureValue(feature.id, value),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                if (pendingAttempt != null &&
                    pendingAttempt.lifecycle == CreateFlowLifecycle.active) ...[
                  InfoBar(
                    title: const Text('Creating agent'),
                    content: Text(
                      pendingAttempt.text.isEmpty
                          ? 'Sending attached context…'
                          : pendingAttempt.text,
                    ),
                    severity: InfoBarSeverity.info,
                  ),
                  const SizedBox(height: 12),
                ],
                if (fileMention != null)
                  ComposerFileAutocompletePopup(
                    key: const ValueKey('draft-file-autocomplete'),
                    entries: fileState.entries,
                    selectedIndex: selectedIndex,
                    isLoading: fileState.isLoading,
                    error: fileState.error,
                    onSelected: (entry) => _replaceFile(entry, fileMention),
                  )
                else if (commandRange != null)
                  ComposerCommandAutocompletePopup(
                    key: const ValueKey('draft-command-autocomplete'),
                    entries: commandEntries,
                    selectedIndex: selectedIndex,
                    isLoading: commandState.isLoading,
                    error: commandState.error,
                    onSelected: (entry) => _replaceCommand(entry, commandRange),
                  ),
                if (fileMention != null || commandRange != null)
                  const SizedBox(height: 8),
                Focus(
                  onKeyEvent: _onPromptKeyEvent,
                  child: TextBox(
                    controller: _promptController,
                    focusNode: _promptFocusNode,
                    minLines: 3,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    placeholder: 'What do you want to do? (optional)',
                  ),
                ),
                if (_images.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final image in _images)
                        ComposerImagePreview(
                          image: image,
                          onRemove: isSubmitting
                              ? null
                              : () => _removeImage(image),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Button(
                      key: const ValueKey('composer-import-agent-pill'),
                      onPressed: isSubmitting ? null : _openImportSessions,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(FluentIcons.download, size: 14),
                          SizedBox(width: 8),
                          Text('Import session'),
                        ],
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      key: const ValueKey('draft-image-picker'),
                      icon: _addingImages
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: ProgressRing(strokeWidth: 2),
                            )
                          : const Icon(FluentIcons.photo2, size: 16),
                      onPressed: isSubmitting || _addingImages
                          ? null
                          : _pickImages,
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed:
                          isSubmitting ||
                              selectedProvider.models == null ||
                              featureState.isLoading
                          ? null
                          : () => _submit(
                              providerCount: providers.length,
                              availableModels: models,
                              isModelLoading: selectedProvider.models == null,
                              hasClient:
                                  client.currentState ==
                                  DaemonConnectionState.connected,
                            ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          isSubmitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: ProgressRing(strokeWidth: 2),
                                )
                              : const Icon(FluentIcons.return_key, size: 16),
                          const SizedBox(width: 6),
                          const Text('Create'),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage!,
                    style: TextStyle(color: context.tokens.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
