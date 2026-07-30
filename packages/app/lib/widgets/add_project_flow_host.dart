import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../add_project_flow/model.dart';
import '../add_project_flow/options.dart';
import '../add_project_flow/project_picker_options.dart';
import '../core/daemon_client.dart';
import '../state/add_project_flow_provider.dart';
import '../state/daemon_providers.dart';
import '../state/host_registry_provider.dart';
import '../state/project_summaries_provider.dart';

class AddProjectFlowHost extends ConsumerWidget {
  const AddProjectFlowHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = ref.watch(addProjectFlowProvider).request;
    if (request == null) return const SizedBox.shrink();
    return AddProjectFlowDialog(
      key: ValueKey(request.id),
      request: request,
      onClose: () => ref.read(addProjectFlowProvider.notifier).close(),
      onAdded: (result) =>
          ref.read(addProjectFlowProvider.notifier).close(result),
    );
  }
}

class AddProjectFlowDialog extends ConsumerStatefulWidget {
  const AddProjectFlowDialog({
    super.key,
    required this.request,
    required this.onClose,
    required this.onAdded,
    this.hostsOverride,
    this.clientsOverride,
    this.recommendedPathsOverride,
    this.pickDirectoryPath = getDirectoryPath,
  });

  final AddProjectFlowRequest request;
  final VoidCallback onClose;
  final ValueChanged<AddProjectFlowResult> onAdded;
  final List<AddProjectHost>? hostsOverride;
  final Map<String, DaemonClient>? clientsOverride;
  final Map<String, List<String>>? recommendedPathsOverride;
  final Future<String?> Function({String? confirmButtonText}) pickDirectoryPath;

  @override
  ConsumerState<AddProjectFlowDialog> createState() =>
      _AddProjectFlowDialogState();
}

class _AddProjectFlowDialogState extends ConsumerState<AddProjectFlowDialog> {
  late AddProjectFlowState _flow;
  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  Timer? _debounce;
  List<String> _serverPaths = const [];
  Map<String, DaemonClient> _clients = const {};
  Map<String, List<String>> _recommendedPaths = const {};
  String _hostsSignature = '';
  bool _loading = false;
  bool _submissionInFlight = false;
  Object? _queryError;

  @override
  void initState() {
    super.initState();
    _flow = openAddProjectFlow(
      hosts: widget.hostsOverride ?? const [],
      preferredHostId: widget.request.preferredHostId,
    );
    _syncInput();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  AddProjectPage get _page => currentAddProjectPage(_flow);

  @override
  Widget build(BuildContext context) {
    final overriddenClients = widget.clientsOverride;
    final Map<String, DaemonClient> runtimeClients;
    if (overriddenClients != null) {
      runtimeClients = overriddenClients;
    } else {
      final registered = ref.watch(hostRuntimeClientsProvider);
      final active = ref.watch(daemonClientProvider);
      final activeServerId = active.serverInfo?.serverId;
      runtimeClients = {
        ...registered,
        if (activeServerId != null && activeServerId.isNotEmpty)
          activeServerId: active,
      };
    }
    final hosts =
        widget.hostsOverride ?? _buildAvailableHosts(ref, runtimeClients);
    _clients = runtimeClients;
    _recommendedPaths =
        widget.recommendedPathsOverride ?? _buildRecommendedPaths(ref);
    _scheduleHostSync(hosts);
    final page = _page;
    final host = _hostFor(page);
    final rows = _buildRows(page, host);
    final activeIndex = rows.isEmpty
        ? 0
        : page.activeIndex.clamp(0, rows.length - 1);
    final isSubmitting = _isSubmitting(page);
    final preview =
        page is AddProjectNewDirectoryNamePage && page.name.trim().isNotEmpty
        ? joinDirectoryPath(page.parentPath, page.name.trim())
        : null;

    return Positioned.fill(
      child: ColoredBox(
        key: const ValueKey('add-project-flow'),
        color: Colors.black.withValues(alpha: 0.45),
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('add-project-flow-backdrop'),
                onTap: widget.onClose,
                behavior: HitTestBehavior.opaque,
              ),
            ),
            Align(
              alignment: const Alignment(0, -0.72),
              child: Focus(
                autofocus: true,
                onKeyEvent: (_, event) => _handleKey(event, rows, activeIndex),
                child: Container(
                  key: ValueKey('add-project-flow-page-${_pageKind(page)}'),
                  width: 560,
                  constraints: const BoxConstraints(maxHeight: 620),
                  decoration: BoxDecoration(
                    color: FluentTheme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: FluentTheme.of(
                        context,
                      ).resources.cardStrokeColorDefault,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        blurRadius: 24,
                        color: Color(0x55000000),
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                if (_flow.pages.length > 1) ...[
                                  IconButton(
                                    key: const ValueKey(
                                      'add-project-flow-back',
                                    ),
                                    icon: const Icon(
                                      FluentIcons.back,
                                      size: 14,
                                    ),
                                    onPressed: _back,
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Expanded(
                                  child: Column(
                                    key: const ValueKey(
                                      'add-project-flow-title',
                                    ),
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _pageTitle(page),
                                        style: FluentTheme.of(
                                          context,
                                        ).typography.subtitle,
                                      ),
                                      if (host != null)
                                        Text(
                                          host.label,
                                          style: FluentTheme.of(
                                            context,
                                          ).typography.caption,
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            TextBox(
                              key: const ValueKey('add-project-flow-input'),
                              controller: _inputController,
                              focusNode: _inputFocus,
                              enabled: !isSubmitting,
                              placeholder: _pagePlaceholder(page),
                              onChanged: _changeInput,
                              onSubmitted: (_) =>
                                  _submitActive(rows, activeIndex),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: ListView(
                          key: const ValueKey('add-project-flow-results'),
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          shrinkWrap: true,
                          children: [
                            if (preview != null)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  preview,
                                  key: const ValueKey(
                                    'add-project-flow-path-preview',
                                  ),
                                ),
                              ),
                            if (isSubmitting)
                              _stateText(
                                _progressText(page),
                                'add-project-flow-progress',
                              )
                            else if (page.error != null)
                              _errorText(page.error!, 'add-project-flow-error')
                            else if (_queryError != null)
                              _errorText(
                                'Unable to search directories',
                                'add-project-flow-query-error',
                              )
                            else if (_loading)
                              _stateText(
                                'Loading...',
                                'add-project-flow-loading',
                              )
                            else if (rows.isEmpty &&
                                page is! AddProjectNewDirectoryNamePage)
                              _stateText(
                                _emptyText(page, host),
                                'add-project-flow-empty',
                              )
                            else
                              for (
                                var index = 0;
                                index < rows.length;
                                index += 1
                              )
                                _FlowRow(
                                  option: rows[index],
                                  active: index == activeIndex,
                                ),
                          ],
                        ),
                      ),
                      Container(
                        key: const ValueKey('add-project-flow-footer'),
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: FluentTheme.of(
                                context,
                              ).resources.dividerStrokeColorDefault,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Expanded(child: Text('↑ ↓  Navigate')),
                            const Expanded(
                              child: Text(
                                'Enter  Select',
                                textAlign: TextAlign.center,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                _flow.pages.length > 1
                                    ? 'Esc  Back'
                                    : 'Esc  Close',
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<AddProjectHost> _buildAvailableHosts(
    WidgetRef ref,
    Map<String, DaemonClient> clients,
  ) {
    final registry = ref.watch(hostRegistryProvider);
    final desktop =
        !kIsWeb &&
        const {
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
        }.contains(defaultTargetPlatform);
    final hosts = [
      for (final profile in registry.hosts)
        if (clients[profile.serverId] case final client?
            when client.currentState == DaemonConnectionState.connected)
          AddProjectHost(
            serverId: profile.serverId,
            label: profile.label,
            canAddProject:
                client.serverInfo?.features['projectAdd'] == true &&
                client.serverInfo?.features['stableProjectIdentity'] == true,
            canBrowse:
                desktop &&
                isLoopbackHost(client.uri.host) &&
                client.serverInfo?.features['projectAdd'] == true,
            canCloneGithubRepositories:
                client.serverInfo?.features['projectGithubClone'] == true,
            canSearchGithubRepositories: false,
            canCreateDirectory: false,
          ),
    ];
    if (hosts.isNotEmpty) return hosts;
    return [
      for (final entry in clients.entries)
        if (entry.value.currentState == DaemonConnectionState.connected)
          _hostFromClient(
            entry.key,
            entry.value.serverInfo?.hostname ?? entry.key,
            entry.value,
            desktop: desktop,
          ),
    ];
  }

  AddProjectHost _hostFromClient(
    String serverId,
    String label,
    DaemonClient client, {
    required bool desktop,
  }) => AddProjectHost(
    serverId: serverId,
    label: label,
    canAddProject:
        client.serverInfo?.features['projectAdd'] == true &&
        client.serverInfo?.features['stableProjectIdentity'] == true,
    canBrowse:
        desktop &&
        isLoopbackHost(client.uri.host) &&
        client.serverInfo?.features['projectAdd'] == true,
    canCloneGithubRepositories:
        client.serverInfo?.features['projectGithubClone'] == true,
    canSearchGithubRepositories: false,
    canCreateDirectory: false,
  );

  Map<String, List<String>> _buildRecommendedPaths(WidgetRef ref) {
    final projects = ref.watch(projectSummariesProvider).value?.projects;
    if (projects == null) return const {};
    final result = <String, List<String>>{};
    for (final project in projects) {
      for (final host in project.hosts) {
        result.putIfAbsent(host.serverId, () => []).add(host.repoRoot);
      }
    }
    return result;
  }

  void _scheduleHostSync(List<AddProjectHost> hosts) {
    final signature = hosts
        .map(
          (host) =>
              '${host.serverId}:${host.canAddProject}:'
              '${host.canBrowse}:${host.canCloneGithubRepositories}',
        )
        .join('|');
    if (signature == _hostsSignature) return;
    _hostsSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _flow = applyAvailableAddProjectHosts(
          _flow,
          hosts,
          preferredHostId: widget.request.preferredHostId,
        );
        _syncInput();
      });
    });
  }

  AddProjectHost? _hostFor(AddProjectPage page) {
    final hostId = switch (page) {
      AddProjectHostPage() => null,
      AddProjectMethodPage(:final hostId) => hostId,
      AddProjectDirectorySearchPage(:final hostId) => hostId,
      AddProjectGithubSearchPage(:final hostId) => hostId,
      AddProjectGithubLocationPage(:final hostId) => hostId,
      AddProjectNewDirectoryParentPage(:final hostId) => hostId,
      AddProjectNewDirectoryNamePage(:final hostId) => hostId,
    };
    return hostId == null
        ? null
        : _flow.hosts.where((host) => host.serverId == hostId).firstOrNull;
  }

  List<_FlowRowOption> _buildRows(AddProjectPage page, AddProjectHost? host) {
    if (page is AddProjectHostPage) {
      return [
        for (final choice in filterAddProjectHosts(_flow.hosts, page.query))
          _FlowRowOption(
            id: choice.serverId,
            title: choice.label,
            subtitle: choice.serverId,
            icon: FluentIcons.server,
            key: ValueKey('add-project-flow-host-${choice.serverId}'),
            select: () =>
                _setFlow(chooseAddProjectHost(_flow, choice.serverId)),
          ),
      ];
    }
    if (page is AddProjectMethodPage) {
      if (host == null) return const [];
      final query = page.query.trim().toLowerCase();
      return [
        for (final method in buildAddProjectMethods(host))
          if (query.isEmpty ||
              method.label.toLowerCase().contains(query) ||
              method.description.toLowerCase().contains(query))
            _FlowRowOption(
              id: method.id,
              title: method.label,
              subtitle: method.description,
              icon: _methodIcon(method.id),
              disabled: method.disabled,
              key: ValueKey('add-project-flow-method-${method.id}'),
              select: () => _selectMethod(method.id, host),
            ),
      ];
    }
    if (page is AddProjectDirectorySearchPage) {
      return [
        for (final option in _pathOptions(page.query, page.hostId))
          _FlowRowOption(
            id: option.path,
            title: option.path,
            subtitle: option.kind == ProjectPickerOptionKind.path
                ? 'Use this path'
                : option.path,
            icon: FluentIcons.folder,
            key: ValueKey('add-project-flow-path-${option.path}'),
            select: () => unawaited(_openProject(page.hostId, option.path)),
          ),
      ];
    }
    if (page is AddProjectGithubSearchPage) {
      return [
        for (final repository in buildManualGithubRepositoryChoices(page.query))
          _FlowRowOption(
            id: repository.id,
            title: repository.cloneProtocol == null
                ? repository.nameWithOwner
                : '${repository.nameWithOwner} via '
                      '${repository.cloneProtocol!.name.toUpperCase()}',
            subtitle: repository.description,
            icon: FluentIcons.git_graph,
            key: ValueKey('add-project-flow-repository-${repository.id}'),
            select: () => _setFlow(
              openGithubLocationPage(_flow, page.hostId, repository),
            ),
          ),
      ];
    }
    if (page is AddProjectGithubLocationPage) {
      final repositoryName = pathBaseName(page.repository.nameWithOwner);
      final parents = buildSuggestedParentDirectories(
        _recommendedPaths[page.hostId] ?? const [],
      );
      final filtered = buildProjectPickerOptions(
        recommendedPaths: parents,
        serverPaths: _serverPaths,
        query: page.query,
      ).map((option) => option.path).toList(growable: false);
      final existing = [...?_recommendedPaths[page.hostId], ..._serverPaths];
      return [
        for (final option in buildCloneLocationOptions(
          parents: filtered,
          repositoryName: repositoryName,
          existingPaths: existing,
        ))
          _FlowRowOption(
            id: option.id,
            title: option.displayPath,
            subtitle: option.secondaryText,
            icon: FluentIcons.hard_drive,
            disabled: option.disabled,
            key: ValueKey('add-project-flow-path-${option.displayPath}'),
            select: () => unawaited(_cloneProject(page, option.path)),
          ),
      ];
    }
    if (page is AddProjectNewDirectoryParentPage) {
      return [
        for (final option in _pathOptions(page.query, page.hostId))
          _FlowRowOption(
            id: option.path,
            title: option.path,
            subtitle: option.kind == ProjectPickerOptionKind.path
                ? 'Use this parent'
                : option.path,
            icon: FluentIcons.folder,
            key: ValueKey('add-project-flow-path-${option.path}'),
            select: () => _setFlow(
              openNewDirectoryNamePage(_flow, page.hostId, option.path),
            ),
          ),
      ];
    }
    return const [];
  }

  List<ProjectPickerOption> _pathOptions(String query, String hostId) =>
      buildProjectPickerOptions(
        recommendedPaths: _recommendedPaths[hostId] ?? const [],
        serverPaths: _serverPaths,
        query: query,
      );

  void _selectMethod(String method, AddProjectHost host) {
    switch (method) {
      case directorySearchMethodId:
        _setFlow(openDirectorySearchPage(_flow, host.serverId));
      case browseMethodId:
        unawaited(_browse(host.serverId));
      case githubMethodId:
        _setFlow(openGithubSearchPage(_flow, host.serverId));
      case newDirectoryMethodId:
        _setFlow(openNewDirectoryParentPage(_flow, host.serverId));
    }
  }

  Future<void> _browse(String serverId) async {
    try {
      final path = await widget.pickDirectoryPath(
        confirmButtonText: 'Add project',
      );
      if (path != null && path.trim().isNotEmpty) {
        await _openProject(serverId, path.trim());
      }
    } on Object {
      if (mounted) _setStatus(error: 'Unable to browse for a directory');
    }
  }

  Future<void> _openProject(String serverId, String path) async {
    if (_submissionInFlight) return;
    final client = _clients[serverId];
    if (client == null) return;
    _submissionInFlight = true;
    _setStatus(isSubmitting: true, error: null);
    try {
      final response = await client.request(MessageTypes.projectAddRequest, {
        'path': path,
      });
      final project = ProjectInfo.fromJson(
        response['project'] as Map<String, Object?>? ?? const {},
      );
      if (!mounted) return;
      widget.onAdded(
        AddProjectFlowResult(serverId: serverId, project: project),
      );
    } on Object {
      if (mounted) {
        _setStatus(isSubmitting: false, error: 'Unable to add project');
      }
    } finally {
      _submissionInFlight = false;
    }
  }

  Future<void> _cloneProject(
    AddProjectGithubLocationPage page,
    String parentPath,
  ) async {
    if (_submissionInFlight) return;
    final client = _clients[page.hostId];
    if (client == null) return;
    _submissionInFlight = true;
    _setStatus(isSubmitting: true, error: null);
    try {
      final response = await client.cloneGithubProject(
        repo: page.repository.cloneUrl,
        targetDirectory: parentPath,
        cloneProtocol: switch (page.repository.cloneProtocol) {
          GithubCloneProtocol.https => ProjectGithubCloneProtocol.https,
          GithubCloneProtocol.ssh => ProjectGithubCloneProtocol.ssh,
          null => null,
        },
      );
      final descriptor = response.project;
      if (response.error != null || descriptor == null) {
        _setStatus(
          isSubmitting: false,
          error: response.error ?? 'Unable to clone repository',
        );
        return;
      }
      if (!mounted) return;
      widget.onAdded(
        AddProjectFlowResult(
          serverId: page.hostId,
          project: ProjectInfo(
            path: descriptor.projectRootPath,
            name: descriptor.projectDisplayName,
            isGitRepo: descriptor.projectKind == WorkspaceProjectKind.git,
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        _setStatus(isSubmitting: false, error: '$error');
      }
    } finally {
      _submissionInFlight = false;
    }
  }

  void _setFlow(AddProjectFlowState next) {
    setState(() {
      _flow = next;
      _serverPaths = const [];
      _queryError = null;
      _loading = false;
      _syncInput();
    });
    _inputFocus.requestFocus();
    _queueDirectoryFetch();
  }

  void _changeInput(String value) {
    setState(() {
      _flow = _page is AddProjectNewDirectoryNamePage
          ? setNewDirectoryName(_flow, value)
          : setAddProjectPageInput(_flow, value);
      _queryError = null;
    });
    _queueDirectoryFetch();
  }

  void _queueDirectoryFetch() {
    _debounce?.cancel();
    final page = _page;
    if (!_searchesDirectories(page)) return;
    _debounce = Timer(const Duration(milliseconds: 250), _fetchDirectories);
  }

  Future<void> _fetchDirectories() async {
    final page = _page;
    final hostId = _pageHostId(page);
    final client = hostId == null ? null : _clients[hostId];
    if (client == null || !_searchesDirectories(page)) return;
    final query = page is AddProjectSearchPage ? page.query : '';
    setState(() {
      _loading = true;
      _queryError = null;
    });
    try {
      final response = await client.getDirectorySuggestions(
        query: query,
        includeFiles: false,
        includeDirectories: true,
        limit: 30,
      );
      if (!mounted ||
          _pageHostId(_page) != hostId ||
          (_page is AddProjectSearchPage &&
              (_page as AddProjectSearchPage).query != query)) {
        return;
      }
      setState(() {
        _serverPaths = [
          for (final entry in response.entries)
            if (entry.kind == DirectorySuggestionKind.directory) entry.path,
        ];
        _queryError = response.error;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _queryError = error;
        _loading = false;
      });
    }
  }

  KeyEventResult _handleKey(
    KeyEvent event,
    List<_FlowRowOption> rows,
    int activeIndex,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _back();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _submitActive(rows, activeIndex);
      return KeyEventResult.handled;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => AddProjectSelectionDirection.next,
      LogicalKeyboardKey.arrowUp => AddProjectSelectionDirection.previous,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;
    final next = moveAddProjectSelection(
      activeIndex,
      rows.map((row) => !row.disabled).toList(growable: false),
      direction,
    );
    setState(() => _flow = setAddProjectActiveIndex(_flow, next));
    return KeyEventResult.handled;
  }

  void _submitActive(List<_FlowRowOption> rows, int activeIndex) {
    if (_page is AddProjectNewDirectoryNamePage) return;
    if (rows.isEmpty) return;
    final row = rows[activeIndex];
    if (!row.disabled) row.select();
  }

  void _back() {
    final previous = backAddProjectPage(_flow);
    if (previous == null) {
      widget.onClose();
    } else {
      _setFlow(previous);
    }
  }

  void _setStatus({bool? isSubmitting, String? error}) {
    setState(() {
      _flow = updateCurrentAddProjectPage(
        _flow,
        (page) => switch (page) {
          AddProjectMethodPage(
            :final hostId,
            isSubmitting: final currentSubmitting,
            :final query,
            :final activeIndex,
          ) =>
            AddProjectMethodPage(
              hostId: hostId,
              isSubmitting: isSubmitting ?? currentSubmitting,
              query: query,
              activeIndex: activeIndex,
              error: error,
            ),
          AddProjectDirectorySearchPage(
            :final hostId,
            :final query,
            :final activeIndex,
          ) =>
            AddProjectDirectorySearchPage(
              hostId: hostId,
              query: query,
              activeIndex: activeIndex,
              error: error,
              isSubmitting: isSubmitting ?? page.isSubmitting,
            ),
          AddProjectGithubLocationPage(
            :final hostId,
            :final repository,
            :final query,
            :final activeIndex,
          ) =>
            AddProjectGithubLocationPage(
              hostId: hostId,
              repository: repository,
              query: query,
              activeIndex: activeIndex,
              error: error,
              isSubmitting: isSubmitting ?? page.isSubmitting,
            ),
          AddProjectNewDirectoryNamePage(
            :final hostId,
            :final parentPath,
            :final name,
            :final activeIndex,
          ) =>
            AddProjectNewDirectoryNamePage(
              hostId: hostId,
              parentPath: parentPath,
              name: name,
              activeIndex: activeIndex,
              error: error,
              isSubmitting: isSubmitting ?? page.isSubmitting,
            ),
          _ => page,
        },
      );
    });
  }

  void _syncInput() {
    final text = switch (_page) {
      AddProjectSearchPage(:final query) => query,
      AddProjectNewDirectoryNamePage(:final name) => name,
    };
    _inputController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

final class _FlowRowOption {
  const _FlowRowOption({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.key,
    required this.select,
    this.disabled = false,
  });

  final String id;
  final String title;
  final String? subtitle;
  final IconData icon;
  final Key key;
  final VoidCallback select;
  final bool disabled;
}

class _FlowRow extends StatelessWidget {
  const _FlowRow({required this.option, required this.active});

  final _FlowRowOption option;
  final bool active;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: option.disabled ? 0.45 : 1,
    child: Container(
      key: option.key,
      color: active
          ? FluentTheme.of(context).accentColor.withValues(alpha: 0.12)
          : null,
      child: ListTile(
        leading: Icon(option.icon, size: 16),
        title: Text(option.title),
        subtitle: option.subtitle == null ? null : Text(option.subtitle!),
        onPressed: option.disabled ? null : option.select,
      ),
    ),
  );
}

Widget _stateText(String text, String key) => Padding(
  padding: const EdgeInsets.all(12),
  child: Text(text, key: ValueKey(key)),
);

Widget _errorText(String text, String key) => Padding(
  padding: const EdgeInsets.all(12),
  child: Text(
    text,
    key: ValueKey(key),
    style: const TextStyle(color: Color(0xFFD13438)),
  ),
);

IconData _methodIcon(String method) => switch (method) {
  githubMethodId => FluentIcons.git_graph,
  newDirectoryMethodId => FluentIcons.new_folder,
  browseMethodId => FluentIcons.folder_open,
  _ => FluentIcons.search,
};

String _pageKind(AddProjectPage page) => switch (page) {
  AddProjectHostPage() => 'host',
  AddProjectMethodPage() => 'method',
  AddProjectDirectorySearchPage() => 'directory-search',
  AddProjectGithubSearchPage() => 'github-search',
  AddProjectGithubLocationPage() => 'github-location',
  AddProjectNewDirectoryParentPage() => 'new-directory-parent',
  AddProjectNewDirectoryNamePage() => 'new-directory-name',
};

String _pageTitle(AddProjectPage page) => switch (page) {
  AddProjectHostPage() => 'Choose a host',
  AddProjectMethodPage() => 'Add project',
  AddProjectDirectorySearchPage() => 'Search for directory',
  AddProjectGithubSearchPage() => 'Clone from GitHub',
  AddProjectGithubLocationPage() => 'Choose clone location',
  AddProjectNewDirectoryParentPage() => 'Choose parent directory',
  AddProjectNewDirectoryNamePage() => 'Name new directory',
};

String _pagePlaceholder(AddProjectPage page) => switch (page) {
  AddProjectHostPage() => 'Search hosts',
  AddProjectMethodPage() => 'Search methods',
  AddProjectDirectorySearchPage() => 'Search directories or enter a path',
  AddProjectGithubSearchPage() => 'GitHub URL or owner/repo',
  AddProjectGithubLocationPage() => 'Search parent directories',
  AddProjectNewDirectoryParentPage() => 'Search parent directories',
  AddProjectNewDirectoryNamePage() => 'Directory name',
};

String _emptyText(AddProjectPage page, AddProjectHost? host) => switch (page) {
  AddProjectHostPage() => 'No connected hosts',
  AddProjectGithubSearchPage() => 'Enter a GitHub URL or owner/repo',
  AddProjectMethodPage() => addProjectMethodEmptyText(host),
  _ => 'No matching directories',
};

String _progressText(AddProjectPage page) => switch (page) {
  AddProjectGithubLocationPage() => 'Cloning project...',
  AddProjectNewDirectoryNamePage() => 'Creating directory...',
  _ => 'Adding project...',
};

bool _isSubmitting(AddProjectPage page) => switch (page) {
  AddProjectMethodPage(:final isSubmitting) => isSubmitting,
  AddProjectDirectorySearchPage(:final isSubmitting) => isSubmitting,
  AddProjectGithubLocationPage(:final isSubmitting) => isSubmitting,
  AddProjectNewDirectoryNamePage(:final isSubmitting) => isSubmitting,
  _ => false,
};

bool _searchesDirectories(AddProjectPage page) =>
    page is AddProjectDirectorySearchPage ||
    page is AddProjectGithubLocationPage ||
    page is AddProjectNewDirectoryParentPage;

String? _pageHostId(AddProjectPage page) => switch (page) {
  AddProjectHostPage() => null,
  AddProjectMethodPage(:final hostId) => hostId,
  AddProjectDirectorySearchPage(:final hostId) => hostId,
  AddProjectGithubSearchPage(:final hostId) => hostId,
  AddProjectGithubLocationPage(:final hostId) => hostId,
  AddProjectNewDirectoryParentPage(:final hostId) => hostId,
  AddProjectNewDirectoryNamePage(:final hostId) => hostId,
};
