import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../attachments/attachment_store.dart';
import '../composer/composer_draft_store.dart';
import '../composer/composer_image_attachment_service.dart';
import '../composer/composer_image_attachments.dart';
import '../composer/checkout_link_selection.dart';
import '../composer/create_agent_preferences.dart';
import '../composer/draft_agent_selection.dart';
import '../composer/draft_feature_values.dart';
import '../composer/provider_model_selection.dart';
import '../composer/workspace_draft_submission.dart';
import '../core/daemon_client.dart';
import '../core/host_routes.dart';
import '../core/theme.dart';
import '../import_sessions/import_session_dialog.dart';
import '../providers/draft_provider_features.dart';
import '../providers/providers_snapshot.dart';
import '../state/agents_provider.dart';
import '../state/add_project_flow_provider.dart';
import '../state/create_flow_provider.dart';
import '../state/daemon_providers.dart';
import '../state/draft_provider_features_provider.dart';
import '../state/providers_snapshot_provider.dart';
import '../state/host_registry_provider.dart';
import '../state/queued_messages_provider.dart';
import '../state/timeline_provider.dart';
import '../state/workspace_attachments_provider.dart';
import '../state/workspace_catalog_provider.dart';
import '../state/workspace_providers.dart';
import '../state/worktree_tabs_provider.dart';
import '../workspace/workspace_tab_model.dart';
import '../widgets/fluent/page_back_button.dart';
import '../widgets/fluent/search_picker_dialog.dart';
import '../widgets/composer_image_preview.dart';
import '../widgets/combined_model_selector.dart';
import '../widgets/draft_feature_control.dart';

/// How the new workspace's working directory is provisioned. Mirrors
/// Paseo's "Isolation" picker (`Local` / `New worktree`).
enum WorkspaceIsolation { local, worktree }

/// Full-screen "New workspace" flow (Paseo parity): pick a project, an
/// isolation mode, and — for worktree isolation — a branch/PR to start from;
/// type an optional first message; submitting creates the agent (and its
/// worktree, if any) and navigates straight into its chat.
class NewWorkspaceScreen extends ConsumerStatefulWidget {
  const NewWorkspaceScreen({
    super.key,
    this.initialProjectPath,
    this.initialServerId,
    this.initialDisplayName,
    this.initialProjectId,
    this.initialDraftId,
    this.imageAttachmentService,
    this.draftStore,
    this.preferencesService,
    this.navigateToCreatedWorkspace,
  });

  final String? initialProjectPath;
  final String? initialServerId;
  final String? initialDisplayName;
  final String? initialProjectId;
  final String? initialDraftId;
  final ComposerImageAttachmentService? imageAttachmentService;
  final ComposerDraftStore? draftStore;
  final CreateAgentPreferencesService? preferencesService;
  final ValueChanged<String>? navigateToCreatedWorkspace;

  @override
  ConsumerState<NewWorkspaceScreen> createState() => _NewWorkspaceScreenState();
}

class _NewWorkspaceScreenState extends ConsumerState<NewWorkspaceScreen> {
  final _promptController = TextEditingController();
  final List<PendingComposerImage> _images = [];

  String? _projectChoice;
  WorkspaceIsolation _isolation = WorkspaceIsolation.local;
  String? _baseRef;
  String? _provider;
  String? _model;
  String? _modeId;
  String? _thinkingOptionId;
  Map<String, Object?> _featureValues = const {};
  CreateAgentPreferences _preferences = const CreateAgentPreferences();
  bool _submitting = false;
  bool _addingImages = false;
  String? _errorMessage;
  late final ComposerImageAttachmentService _imageAttachmentService;
  late final ComposerDraftStore _draftStore;
  late final CreateAgentPreferencesService _preferencesService;
  var _draftRevision = 0;
  var _suspendDraftPersistence = false;
  Future<void> _draftWrite = Future.value();
  bool _selectionTouched = false;
  final _checkoutLinks = CheckoutLinkSelectionLifecycle();
  var _checkoutLookupsInFlight = 0;

  /// Resolve the transport selected by the route before falling back to the
  /// compatibility active-host client.
  ///
  /// Add Project opens `/new` with the host that registered the project. The
  /// active-host provider can still be one frame behind that navigation (and
  /// is intentionally mutable while another host is selected), so using it
  /// for the create flow can send provider/workspace requests to the wrong
  /// daemon. Keep every request in this screen pinned to the route host.
  DaemonClient _routeClient(WidgetRef ref) {
    final serverId = widget.initialServerId?.trim();
    if (serverId != null && serverId.isNotEmpty) {
      final hostClient = ref.read(hostDaemonClientProvider(serverId));
      if (hostClient != null) return hostClient;
    }
    return ref.read(daemonClientProvider);
  }

  DaemonClient _watchRouteClient(WidgetRef ref) {
    final serverId = widget.initialServerId?.trim();
    if (serverId != null && serverId.isNotEmpty) {
      final hostClient = ref.watch(hostDaemonClientProvider(serverId));
      if (hostClient != null) return hostClient;
    }
    return ref.watch(daemonClientProvider);
  }

  @override
  void initState() {
    super.initState();
    _imageAttachmentService =
        widget.imageAttachmentService ?? ComposerImageAttachmentService();
    _draftStore = widget.draftStore ?? PreferencesComposerDraftStore();
    _preferencesService =
        widget.preferencesService ?? createAgentPreferencesService;
    _promptController.addListener(_onDraftTextChanged);
    unawaited(_activateInitialHost());
    unawaited(_hydrateDraft());
    unawaited(_hydratePreferences());
  }

  Future<void> _activateInitialHost() async {
    final serverId = widget.initialServerId?.trim();
    if (serverId == null || serverId.isEmpty) return;
    final registry = ref.read(hostRegistryProvider);
    if (!registry.hosts.any((host) => host.serverId == serverId)) return;
    if (registry.activeServerId == serverId) return;
    try {
      await ref.read(hostRegistryProvider.notifier).selectHost(serverId);
    } catch (_) {
      // Keep the launcher usable if a host disappears during bootstrap.
    }
  }

  String get _draftKey =>
      buildNewWorkspaceComposerDraftKey(widget.initialDraftId);

  @override
  void dispose() {
    _promptController.removeListener(_onDraftTextChanged);
    _promptController.dispose();
    super.dispose();
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
        _isolation = switch (preferences.isolation) {
          'worktree' => WorkspaceIsolation.worktree,
          _ => WorkspaceIsolation.local,
        };
      });
    } catch (_) {
      // Keep the create flow usable when local preference storage fails.
    }
  }

  Map<String, Object?> get _persistedFeatureValues {
    final provider = _provider;
    if (provider == null) return const {};
    return _preferences.providerPreferences[provider]?.featureValues ??
        const {};
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
      // Session selections remain authoritative if persistence fails.
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

  void _setFeatureValue(String featureId, Object? value) {
    setState(() {
      _featureValues = {..._featureValues, featureId: value};
    });
    final provider = _provider;
    if (provider != null) {
      unawaited(
        _persistSelection(
          provider: provider,
          featureValues: {featureId: value},
        ),
      );
    }
  }

  void _onDraftTextChanged() {
    if (_suspendDraftPersistence) return;
    _draftRevision += 1;
    _persistDraft();
    _detectCheckoutLinks();
  }

  CheckoutLinkTarget? _checkoutTarget([String? projectPath]) {
    final cwd = (projectPath ?? _projectChoice)?.trim();
    if (cwd == null || cwd.isEmpty) return null;
    final client = _routeClient(ref);
    return CheckoutLinkTarget(
      serverId: client.serverInfo?.serverId ?? 'local',
      cwd: cwd,
    );
  }

  void _changeCheckoutTarget(String projectPath) {
    final target = _checkoutTarget(projectPath);
    if (target == null) return;
    _checkoutLinks.changeTarget(target, text: _promptController.text);
  }

  void _detectCheckoutLinks() {
    final target = _checkoutTarget();
    if (target == null) return;
    final lookups = _checkoutLinks.observe(
      text: _promptController.text,
      target: target,
    );
    if (lookups.isNotEmpty) unawaited(_resolveCheckoutLinks(lookups));
  }

  Future<void> _resolveCheckoutLinks(List<CheckoutLinkLookup> lookups) async {
    if (mounted) {
      setState(() => _checkoutLookupsInFlight += 1);
    }
    try {
      final client = _routeClient(ref);
      for (final lookup in lookups) {
        try {
          final response = ForgeSearchResponse.fromJson(
            await client.requestSessionMessage(
              ForgeSearchRequest(
                cwd: lookup.target.cwd,
                query: '${lookup.reference.number}',
                limit: 20,
                kinds: const [ForgeSearchKind.changeRequest],
                requestId: const Uuid().v4(),
              ).toJson(),
            ),
          );
          if (response.error != null) continue;
          final match = response.items
              .where(
                (item) =>
                    forgeItemMatchesGithubPullRequest(item, lookup.reference),
              )
              .firstOrNull;
          if (match != null && mounted && _checkoutLinks.apply(lookup, match)) {
            setState(() => _baseRef = null);
            break;
          }
        } catch (_) {
          // Paste detection is opportunistic; normal composer input remains
          // usable when the forge CLI is unavailable or unauthenticated.
        }
      }
    } finally {
      if (mounted) {
        setState(() => _checkoutLookupsInFlight -= 1);
      }
    }
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
    _detectCheckoutLinks();
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
          // Draft persistence remains best effort.
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
      // GC failures do not affect workspace creation.
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

  Future<void> _addProject() async {
    final routeServerId = widget.initialServerId?.trim();
    final preferredHostId = routeServerId != null && routeServerId.isNotEmpty
        ? routeServerId
        : ref.read(activeHostProvider)?.serverId ??
              _routeClient(ref).serverInfo?.serverId;
    final result = await ref
        .read(addProjectFlowProvider.notifier)
        .open(preferredHostId: preferredHostId);
    if (!mounted || result == null) return;
    final registry = ref.read(hostRegistryProvider);
    if (registry.activeServerId != result.serverId &&
        registry.hosts.any((host) => host.serverId == result.serverId)) {
      await ref.read(hostRegistryProvider.notifier).selectHost(result.serverId);
      if (!mounted) return;
      ref.invalidate(projectsProvider);
    }
    ref.read(projectsProvider.notifier).upsert(result.project);
    _changeCheckoutTarget(result.project.path);
    setState(() {
      _projectChoice = result.project.path;
      _baseRef = null;
    });
  }

  Future<void> _pickProject() async {
    final projects = ref.read(projectsProvider).value ?? const <ProjectInfo>[];
    final chosen = await showDialog<Object?>(
      context: context,
      builder: (context) => SearchPickerDialog<ProjectInfo>(
        title: 'Project',
        searchHint: 'Search projects',
        emptyText: 'No projects available.',
        items: projects,
        itemLabel: (p) => p.name.isEmpty ? p.path : p.name,
        itemIcon: (p) =>
            p.isGitRepo ? FluentIcons.folder_horizontal : FluentIcons.folder,
        footer: (dialogContext) => ListTile(
          leading: const Icon(FluentIcons.add),
          title: const Text('Add project'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(const _AddProjectSentinel()),
        ),
      ),
    );
    if (chosen is _AddProjectSentinel) {
      await _addProject();
      return;
    }
    if (chosen is ProjectInfo) {
      _changeCheckoutTarget(chosen.path);
      setState(() {
        _projectChoice = chosen.path;
        _baseRef = null;
      });
    }
  }

  Future<void> _pickIsolation() async {
    final chosen = await showDialog<WorkspaceIsolation>(
      context: context,
      builder: (context) => SearchPickerDialog<WorkspaceIsolation>(
        title: 'Isolation',
        searchable: false,
        items: WorkspaceIsolation.values,
        itemLabel: (v) =>
            v == WorkspaceIsolation.local ? 'Local' : 'New worktree',
        itemIcon: (v) => v == WorkspaceIsolation.local
            ? FluentIcons.folder
            : FluentIcons.branch_fork2,
      ),
    );
    if (chosen != null) {
      setState(() {
        _isolation = chosen;
        _baseRef = null;
      });
      try {
        final preferences = await _preferencesService.update(
          (current) => current.copyWith(isolation: chosen.name),
        );
        if (mounted) setState(() => _preferences = preferences);
      } catch (_) {
        // The in-memory selection remains usable if persistence fails.
      }
    }
  }

  Future<void> _pickBaseRef(String projectPath) async {
    // Ensure the branch list has been fetched before opening the picker.
    ref.read(branchesProvider(projectPath));
    final branches = await ref.read(branchesProvider(projectPath).future);
    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SearchPickerDialog<String>(
        title: 'Start from',
        searchHint: 'Search branches',
        emptyText: 'No matching refs.',
        items: branches.branches,
        itemLabel: (b) => b,
        itemIcon: (_) => FluentIcons.branch_fork2,
      ),
    );
    if (chosen != null) {
      _checkoutLinks.selectBranch(chosen);
      setState(() => _baseRef = chosen);
    }
  }

  DraftProviderFeaturesScope? _featureScope({
    required String serverId,
    required String cwd,
  }) {
    final config = buildDraftCommandConfig(
      provider: _provider,
      cwd: cwd,
      modeId: _modeId ?? '',
      modelId: _model ?? '',
      thinkingOptionId: _thinkingOptionId ?? '',
    );
    if (config == null) return null;
    return DraftProviderFeaturesScope(
      client: _routeClient(ref),
      serverId: serverId,
      draftConfig: config,
    );
  }

  Map<String, Object?> _resolvedFeatureValues({
    required String serverId,
    required String cwd,
  }) {
    final scope = _featureScope(serverId: serverId, cwd: cwd);
    if (scope == null) return const {};
    final features = ref.read(draftProviderFeaturesProvider(scope)).features;
    return resolveDraftFeatureValues(
      features: features,
      persisted: _persistedFeatureValues,
      local: _featureValues,
    );
  }

  Future<void> _submit({
    required int providerCount,
    required List<ProviderModelDefinition> availableModels,
    required bool isModelLoading,
    required bool hasClient,
  }) async {
    final navigateToCreatedWorkspace =
        widget.navigateToCreatedWorkspace ?? GoRouter.maybeOf(context)?.go;
    final provider = _provider;
    final model = _model ?? '';
    final projectPath = _projectChoice;
    final readinessError = validateDraftSubmission(
      text: _promptController.text,
      allowsEmptyAutoSubmit: true,
      providerCount: providerCount,
      selectedProvider: provider,
      isModelLoading: isModelLoading,
      effectiveModelId: model,
      availableModels: availableModels,
      workspaceDirectory: projectPath,
      hasClient: hasClient,
    );
    if (readinessError != null) {
      setState(() => _errorMessage = readinessError);
      return;
    }
    if (provider == null || projectPath == null) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final client = _routeClient(ref);
      final serverId = widget.initialServerId?.trim().isNotEmpty == true
          ? widget.initialServerId!.trim()
          : client.serverInfo?.serverId ?? 'local';
      final featureValues = _resolvedFeatureValues(
        serverId: serverId,
        cwd: projectPath,
      );
      await _persistSelection(
        provider: provider,
        model: model,
        modeId: _modeId,
        thinkingOptionId: _thinkingOptionId,
        featureValues: featureValues.isEmpty ? null : featureValues,
      );
      final projects =
          ref.read(projectsProvider).value ?? const <ProjectInfo>[];
      final selectedProject = projects
          .where((project) => project.path == projectPath)
          .firstOrNull;
      final isWorktree =
          _isolation == WorkspaceIsolation.worktree &&
          selectedProject?.isGitRepo == true;
      final prompt = _promptController.text.trim();
      final images = List<PendingComposerImage>.of(_images);
      final promptImages = await _imageAttachmentService.encodeForSend(images);
      if (images.isNotEmpty && promptImages.isEmpty) {
        throw StateError('Failed to read attached images.');
      }
      final WorkspaceCreateSource source;
      if (!isWorktree) {
        source = DirectoryWorkspaceCreateSource(path: projectPath);
      } else {
        final selection = _checkoutLinks.selection;
        if (selection is ChangeRequestCheckoutLinkSelection) {
          final item = selection.item;
          final headRefName = item.headRefName?.trim();
          final forge = (item.forge ?? 'github').toLowerCase();
          source = WorktreeWorkspaceCreateSource(
            cwd: projectPath,
            action: WorktreeCreateAction.checkout,
            refName: headRefName?.isEmpty == false ? headRefName : null,
            checkoutSource: checkoutSourceForChangeRequest(item),
            githubPrNumber: forge == 'github' ? item.number : null,
          );
        } else {
          final branches = ref.read(branchesProvider(projectPath)).value;
          final baseRef =
              _baseRef ??
              (branches != null && branches.currentBranch.isNotEmpty
                  ? branches.currentBranch
                  : 'main');
          source = WorktreeWorkspaceCreateSource(
            cwd: projectPath,
            action: WorktreeCreateAction.branchOff,
            refName: baseRef,
          );
        }
      }
      final workspaceResponse = WorkspaceCreateResponse.fromJson(
        await client.requestSessionMessage(
          WorkspaceCreateRequest(
            requestId: const Uuid().v4(),
            source: source,
            firstAgentContext: prompt.isEmpty && promptImages.isEmpty
                ? null
                : {
                    if (prompt.isNotEmpty) 'prompt': prompt,
                    if (promptImages.isNotEmpty)
                      'images': promptImages
                          .map((image) => image.toJson())
                          .toList(growable: false),
                  },
          ).toJson(),
        ),
      );
      final workspace = workspaceResponse.workspace;
      if (workspace == null) {
        throw StateError(
          workspaceResponse.error ?? 'Workspace creation returned no workspace',
        );
      }
      ref
          .read(workspaceCatalogCacheProvider.notifier)
          .upsert(serverId, workspace);
      if (prompt.isEmpty && promptImages.isEmpty) {
        if (mounted) setState(() => _submitting = false);
        ref
            .read(selectedWorktreeProvider.notifier)
            .select(workspace.workspaceDirectory);
        await _draftStore.clear(
          _draftKey,
          lifecycle: ComposerDraftLifecycle.sent,
        );
        _openCreatedWorkspace(
          serverId,
          workspace.id,
          navigate: navigateToCreatedWorkspace,
        );
        return;
      }

      final draftId = const Uuid().v4();
      final clientMessageId = const Uuid().v4();
      final imageMetadata = images
          .map((image) => image.metadata)
          .whereType<AttachmentMetadata>()
          .toList(growable: false);
      final workspaceDraftKey = buildComposerDraftKey(
        serverId: serverId,
        agentId: draftId,
        draftId: draftId,
      );
      await _draftWrite;
      await _draftStore.save(
        workspaceDraftKey,
        ComposerDraft(
          text: prompt,
          images: imageMetadata,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      ref
          .read(createFlowProvider.notifier)
          .setPending(
            PendingCreateAttempt(
              draftId: draftId,
              serverId: serverId,
              workspaceId: workspace.id,
              agentId: null,
              clientMessageId: clientMessageId,
              text: prompt,
              timestamp: DateTime.now().millisecondsSinceEpoch,
              lifecycle: CreateFlowLifecycle.active,
              images: imageMetadata,
            ),
          );
      ref
          .read(workspaceDraftSubmissionProvider.notifier)
          .setPending(
            PendingWorkspaceDraftSubmission(
              serverId: serverId,
              workspaceId: workspace.id,
              workspaceDirectory: workspace.workspaceDirectory,
              draftId: draftId,
              text: prompt,
              images: imageMetadata,
              cwd: workspace.workspaceDirectory,
              provider: provider,
              model: model,
              modeId: _modeId ?? '',
              thinkingOptionId: _thinkingOptionId,
              featureValues: featureValues,
              clientMessageId: clientMessageId,
              timestamp: DateTime.now().millisecondsSinceEpoch,
              allowEmptyText: true,
            ),
          );
      ref
          .read(worktreeTabsProvider(workspace.workspaceDirectory).notifier)
          .focusOpenIntentTarget(WorkspaceDraftTabTarget(draftId: draftId));
      if (mounted) setState(() => _submitting = false);
      ref
          .read(selectedWorktreeProvider.notifier)
          .select(workspace.workspaceDirectory);
      try {
        await _draftStore.clear(
          _draftKey,
          lifecycle: ComposerDraftLifecycle.sent,
        );
        await _garbageCollectDraftAttachments();
      } catch (_) {
        // Workspace and agent creation already succeeded.
      }
      _openCreatedWorkspace(
        serverId,
        workspace.id,
        openIntent: 'draft:$draftId',
        navigate: navigateToCreatedWorkspace,
      );
    } catch (e) {
      if (!mounted) return;
      _persistDraft();
      setState(() {
        _submitting = false;
        _errorMessage = 'Failed to create worktree: $e';
      });
    }
  }

  void _openCreatedWorkspace(
    String serverId,
    String workspaceId, {
    String? openIntent,
    ValueChanged<String>? navigate,
  }) {
    final route = openIntent == null
        ? buildHostWorkspaceRoute(serverId, workspaceId)
        : buildHostWorkspaceOpenRoute(serverId, workspaceId, openIntent);
    if (navigate != null) {
      // Paseo prepares the target tab in its local workspace layout store and
      // then replaces the launcher with the canonical workspace route.
      navigate(route);
      return;
    }
    // Keep isolated widget hosts usable when no application router is mounted.
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  Future<void> _openImportSessions() async {
    final imported = await showImportSessionDialog(
      context: context,
      client: _routeClient(ref),
      onImported: (agent) {
        ref.read(agentsProvider.notifier).upsert(agent);
        ref
            .read(worktreeTabsProvider(agent.cwd).notifier)
            .focusAgent(agent.agentId);
        ref.read(selectedWorktreeProvider.notifier).select(agent.cwd);
      },
    );
    if (imported != null && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = _watchRouteClient(ref);
    final serverId = widget.initialServerId?.trim().isNotEmpty == true
        ? widget.initialServerId!.trim()
        : client.serverInfo?.serverId ?? 'local';
    final projects = ref.watch(projectsProvider).value ?? const <ProjectInfo>[];

    // Keep the choice valid if the project list changed under us; default to
    // the first available project (Paseo: route project -> last active ->
    // first available).
    final requestedProject =
        _projectChoice ??
        widget.initialProjectPath?.trim() ??
        projects
            .where(
              (project) =>
                  widget.initialDisplayName?.trim().isNotEmpty == true &&
                  project.name == widget.initialDisplayName!.trim(),
            )
            .firstOrNull
            ?.path;
    final choice =
        requestedProject != null &&
            requestedProject.isNotEmpty &&
            projects.any((p) => p.path == requestedProject)
        ? requestedProject
        : (projects.isEmpty ? null : projects.first.path);
    _projectChoice = choice;
    final checkoutTarget = _checkoutTarget(choice);
    if (checkoutTarget != null && _checkoutLinks.target != checkoutTarget) {
      _checkoutLinks.changeTarget(checkoutTarget, text: _promptController.text);
    }
    final selectedProject = projects.where((p) => p.path == choice).firstOrNull;
    final selectedChangeRequest =
        _checkoutLinks.selection is ChangeRequestCheckoutLinkSelection
        ? (_checkoutLinks.selection as ChangeRequestCheckoutLinkSelection).item
        : null;
    final snapshotScope = ProvidersSnapshotScope(
      client: client,
      serverId: serverId,
      cwd: selectedProject?.path,
    );
    final snapshot = ref.watch(providersSnapshotProvider(snapshotScope));

    return ScaffoldPage(
      header: const PageHeader(
        leading: PageBackButton(),
        title: Text('New workspace'),
      ),
      content: DropTarget(
        onDragDone: (details) => unawaited(_addDroppedImages(details.files)),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: !snapshot.supportsSnapshot
                ? const Text('Update the host to use provider discovery.')
                : snapshot.isLoading && snapshot.entries == null
                ? const Center(child: ProgressRing())
                : snapshot.error != null && snapshot.entries == null
                ? Text('Failed to load providers: ${snapshot.error}')
                : Builder(
                    builder: (context) {
                      final providers = [
                        for (final provider
                            in snapshot.entries ??
                                const <ProviderSnapshotEntry>[])
                          if (provider.enabled &&
                              provider.status == ProviderCatalogStatus.ready)
                            provider,
                      ];
                      final modelSelectorProviders =
                          buildSelectableProviderSelectorProviders(
                            snapshot.entries,
                          );
                      final favoriteKeys = {
                        for (final favorite in _preferences.favoriteModels)
                          buildFavoriteModelKey(
                            provider: favorite.provider,
                            modelId: favorite.modelId,
                          ),
                      };
                      if (providers.isEmpty) {
                        return const Text(
                          'No agent providers are available. '
                          'Install or enable a provider on this host and try again.',
                        );
                      }

                      final preferredProvider =
                          _provider ?? _preferences.provider;
                      final selectedProvider = providers.firstWhere(
                        (provider) => provider.provider == preferredProvider,
                        orElse: () => providers.first,
                      );
                      final providerChanged =
                          _provider != null &&
                          _provider != selectedProvider.provider;
                      _provider = selectedProvider.provider;
                      if (providerChanged) {
                        _model = null;
                        _modeId = null;
                        _thinkingOptionId = null;
                        _featureValues = const {};
                      }

                      final providerPreferences = _preferences
                          .providerPreferences[selectedProvider.provider];
                      final models =
                          selectedProvider.models ??
                          const <ProviderModelDefinition>[];
                      final effectiveModel = resolveEffectiveDraftModelId(
                        selectedModelId: _model ?? providerPreferences?.model,
                        availableModels: models,
                      );
                      final modes =
                          selectedProvider.modes ?? const <ProviderMode>[];
                      final effectiveMode = resolveEffectiveDraftModeId(
                        selectedModeId: _modeId ?? providerPreferences?.mode,
                        provider: selectedProvider,
                      );
                      final modelDefinition = models
                          .where((model) => model.id == effectiveModel)
                          .firstOrNull;
                      final thinkingOptions =
                          modelDefinition?.thinkingOptions ??
                          const <ProviderSelectOption>[];
                      final persistedThinking =
                          providerPreferences?.thinkingByModel[effectiveModel];
                      final effectiveThinking =
                          resolveEffectiveDraftThinkingOptionId(
                            selectedThinkingOptionId:
                                _thinkingOptionId ?? persistedThinking,
                            effectiveModelId: effectiveModel,
                            availableModels: models,
                          );
                      _model = effectiveModel.isEmpty ? null : effectiveModel;
                      _modeId = effectiveMode.isEmpty ? null : effectiveMode;
                      _thinkingOptionId = effectiveThinking.isEmpty
                          ? null
                          : effectiveThinking;

                      DraftProviderFeaturesScope? featureScope;
                      final draftConfig = buildDraftCommandConfig(
                        provider: selectedProvider.provider,
                        cwd: selectedProject?.path ?? '',
                        modeId: effectiveMode,
                        modelId: effectiveModel,
                        thinkingOptionId: effectiveThinking,
                      );
                      if (draftConfig != null) {
                        featureScope = DraftProviderFeaturesScope(
                          client: client,
                          serverId: serverId,
                          draftConfig: draftConfig,
                        );
                      }
                      final featureState = featureScope == null
                          ? const DraftProviderFeaturesState()
                          : ref.watch(
                              draftProviderFeaturesProvider(featureScope),
                            );
                      final effectiveFeatureValues = resolveDraftFeatureValues(
                        features: featureState.features,
                        persisted:
                            providerPreferences?.featureValues ?? const {},
                        local: _featureValues,
                      );

                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                PickerBadge(
                                  icon: selectedProject?.isGitRepo == true
                                      ? FluentIcons.folder_horizontal
                                      : FluentIcons.folder,
                                  label: selectedProject == null
                                      ? 'Choose project'
                                      : (selectedProject.name.isEmpty
                                            ? selectedProject.path
                                            : selectedProject.name),
                                  tooltip: 'Choose project',
                                  onTap: _pickProject,
                                ),
                                if (selectedProject != null &&
                                    selectedProject.isGitRepo) ...[
                                  PickerBadge(
                                    icon: _isolation == WorkspaceIsolation.local
                                        ? FluentIcons.folder
                                        : FluentIcons.branch_fork2,
                                    label:
                                        _isolation == WorkspaceIsolation.local
                                        ? 'Local'
                                        : 'New worktree',
                                    tooltip: 'Isolation',
                                    onTap: _pickIsolation,
                                  ),
                                  if (_isolation == WorkspaceIsolation.worktree)
                                    _BaseRefBadge(
                                      projectPath: selectedProject.path,
                                      baseRef: selectedChangeRequest == null
                                          ? _baseRef
                                          : '#${selectedChangeRequest.number} '
                                                '${selectedChangeRequest.title}',
                                      onTap: () =>
                                          _pickBaseRef(selectedProject.path),
                                    ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: ComboBox<String>(
                                    key: const ValueKey(
                                      'new-workspace-provider-selector',
                                    ),
                                    value: selectedProvider.provider,
                                    items: [
                                      for (final p in providers)
                                        ComboBoxItem(
                                          value: p.provider,
                                          child: Text(p.label ?? p.provider),
                                        ),
                                    ],
                                    onChanged: _submitting
                                        ? null
                                        : _selectProvider,
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
                                    isLoading:
                                        snapshot.isLoading ||
                                        snapshot.isFetching,
                                    disabled: _submitting,
                                    onSelect: _selectProviderModel,
                                    onToggleFavorite: _toggleFavoriteModel,
                                    onOpen: () => ref
                                        .read(
                                          providersSnapshotProvider(
                                            snapshotScope,
                                          ).notifier,
                                        )
                                        .refetchIfStale(
                                          selectedProvider.provider,
                                        ),
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
                            if (modes.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              ComboBox<String>(
                                key: const ValueKey(
                                  'new-workspace-mode-selector',
                                ),
                                value: effectiveMode.isEmpty
                                    ? null
                                    : effectiveMode,
                                items: [
                                  for (final mode in modes)
                                    ComboBoxItem(
                                      value: mode.id,
                                      child: Text(mode.label),
                                    ),
                                ],
                                onChanged: _submitting ? null : _selectMode,
                              ),
                            ],
                            if (thinkingOptions.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              ComboBox<String>(
                                key: const ValueKey(
                                  'new-workspace-thinking-selector',
                                ),
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
                                onChanged: _submitting ? null : _selectThinking,
                              ),
                            ],
                            if (featureState.isLoading &&
                                featureState.features.isEmpty) ...[
                              const SizedBox(height: 12),
                              const Align(
                                alignment: Alignment.centerLeft,
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: ProgressRing(strokeWidth: 2),
                                ),
                              ),
                            ] else if (featureState.features.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Wrap(
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
                                      enabled: !_submitting,
                                      onChanged: (value) =>
                                          _setFeatureValue(feature.id, value),
                                      keyPrefix: 'new-workspace-feature',
                                    ),
                                ],
                              ),
                            ],
                            if (featureState.error != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Failed to load provider features: '
                                '${featureState.error}',
                                style: TextStyle(color: context.tokens.error),
                              ),
                            ],
                            const SizedBox(height: 20),
                            TextBox(
                              controller: _promptController,
                              minLines: 3,
                              maxLines: 8,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              placeholder: 'What do you want to do? (optional)',
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
                                      onRemove: _submitting
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
                                  key: const ValueKey(
                                    'open-project-import-session',
                                  ),
                                  onPressed: _submitting
                                      ? null
                                      : _openImportSessions,
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
                                  key: const ValueKey(
                                    'new-workspace-image-picker',
                                  ),
                                  icon: _addingImages
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: ProgressRing(strokeWidth: 2),
                                        )
                                      : const Icon(
                                          FluentIcons.photo2,
                                          size: 16,
                                        ),
                                  onPressed: _submitting || _addingImages
                                      ? null
                                      : _pickImages,
                                ),
                                const SizedBox(width: 8),
                                FilledButton(
                                  onPressed:
                                      _submitting ||
                                          _checkoutLookupsInFlight > 0 ||
                                          selectedProvider.models == null ||
                                          choice == null
                                      ? null
                                      : () => _submit(
                                          providerCount: providers.length,
                                          availableModels: models,
                                          isModelLoading:
                                              selectedProvider.models == null,
                                          hasClient:
                                              client.currentState ==
                                              DaemonConnectionState.connected,
                                        ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _submitting
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: ProgressRing(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(
                                              FluentIcons.return_key,
                                              size: 16,
                                            ),
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
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

/// Sentinel returned by the project picker's "Add project" footer row.
class _AddProjectSentinel {
  const _AddProjectSentinel();
}

/// The "Start from" badge: shows the chosen base ref, or the project's
/// current branch (falling back to the literal `"main"`) while none has
/// been explicitly picked yet.
class _BaseRefBadge extends ConsumerWidget {
  const _BaseRefBadge({
    required this.projectPath,
    required this.baseRef,
    required this.onTap,
  });

  final String projectPath;
  final String? baseRef;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branchesAsync = ref.watch(branchesProvider(projectPath));
    final currentBranch = branchesAsync.maybeWhen<String>(
      data: (b) => b.currentBranch.isNotEmpty ? b.currentBranch : 'main',
      orElse: () => 'main',
    );
    final label = baseRef ?? currentBranch;
    return PickerBadge(
      icon: FluentIcons.branch_fork2,
      label: label,
      tooltip: 'Choose where to start from',
      onTap: onTap,
    );
  }
}
