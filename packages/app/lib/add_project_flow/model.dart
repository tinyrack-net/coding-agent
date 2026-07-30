enum AddProjectSelectionDirection { next, previous }

enum GithubCloneProtocol { https, ssh }

final class AddProjectHost {
  const AddProjectHost({
    required this.serverId,
    required this.label,
    required this.canAddProject,
    required this.canBrowse,
    required this.canCloneGithubRepositories,
    required this.canSearchGithubRepositories,
    required this.canCreateDirectory,
  });

  final String serverId;
  final String label;
  final bool canAddProject;
  final bool canBrowse;
  final bool canCloneGithubRepositories;
  final bool canSearchGithubRepositories;
  final bool canCreateDirectory;
}

final class GithubRepositoryChoice {
  const GithubRepositoryChoice({
    required this.id,
    required this.nameWithOwner,
    required this.cloneUrl,
    this.cloneProtocol,
    required this.description,
    required this.visibility,
    required this.updatedAt,
  });

  final String id;
  final String nameWithOwner;
  final String cloneUrl;
  final GithubCloneProtocol? cloneProtocol;
  final String? description;
  final String? visibility;
  final String? updatedAt;
}

sealed class AddProjectPage {
  const AddProjectPage({required this.activeIndex, required this.error});

  final int activeIndex;
  final String? error;
}

sealed class AddProjectSearchPage extends AddProjectPage {
  const AddProjectSearchPage({
    required this.query,
    required super.activeIndex,
    required super.error,
  });

  final String query;
}

final class AddProjectHostPage extends AddProjectSearchPage {
  const AddProjectHostPage({
    super.query = '',
    super.activeIndex = 0,
    super.error,
  });
}

final class AddProjectMethodPage extends AddProjectSearchPage {
  const AddProjectMethodPage({
    required this.hostId,
    this.isSubmitting = false,
    super.query = '',
    super.activeIndex = 0,
    super.error,
  });

  final String hostId;
  final bool isSubmitting;
}

final class AddProjectDirectorySearchPage extends AddProjectSearchPage {
  const AddProjectDirectorySearchPage({
    required this.hostId,
    this.isSubmitting = false,
    super.query = '',
    super.activeIndex = 0,
    super.error,
  });

  final String hostId;
  final bool isSubmitting;
}

final class AddProjectGithubSearchPage extends AddProjectSearchPage {
  const AddProjectGithubSearchPage({
    required this.hostId,
    super.query = '',
    super.activeIndex = 0,
    super.error,
  });

  final String hostId;
}

final class AddProjectGithubLocationPage extends AddProjectSearchPage {
  const AddProjectGithubLocationPage({
    required this.hostId,
    required this.repository,
    this.isSubmitting = false,
    super.query = '',
    super.activeIndex = 0,
    super.error,
  });

  final String hostId;
  final GithubRepositoryChoice repository;
  final bool isSubmitting;
}

final class AddProjectNewDirectoryParentPage extends AddProjectSearchPage {
  const AddProjectNewDirectoryParentPage({
    required this.hostId,
    super.query = '',
    super.activeIndex = 0,
    super.error,
  });

  final String hostId;
}

final class AddProjectNewDirectoryNamePage extends AddProjectPage {
  const AddProjectNewDirectoryNamePage({
    required this.hostId,
    required this.parentPath,
    this.name = '',
    super.activeIndex = 0,
    super.error,
    this.isSubmitting = false,
  });

  final String hostId;
  final String parentPath;
  final String name;
  final bool isSubmitting;
}

final class GithubLocationDraft {
  const GithubLocationDraft({required this.query, required this.activeIndex});

  final String query;
  final int activeIndex;
}

final class AddProjectFlowState {
  const AddProjectFlowState({
    required this.hosts,
    required this.pages,
    this.newDirectoryNameDrafts = const {},
    this.githubLocationDrafts = const {},
  });

  final List<AddProjectHost> hosts;
  final List<AddProjectPage> pages;
  final Map<String, String> newDirectoryNameDrafts;
  final Map<String, GithubLocationDraft> githubLocationDrafts;
}

AddProjectFlowState openAddProjectFlow({
  required List<AddProjectHost> hosts,
  String? preferredHostId,
}) {
  final preferredHost = preferredHostId == null
      ? null
      : hosts.where((host) => host.serverId == preferredHostId).firstOrNull;
  final onlyHost = hosts.length == 1 ? hosts.first : null;
  final initialHost = preferredHost ?? onlyHost;
  return AddProjectFlowState(
    hosts: List.unmodifiable(hosts),
    pages: [
      if (initialHost == null)
        const AddProjectHostPage()
      else
        AddProjectMethodPage(hostId: initialHost.serverId),
    ],
  );
}

AddProjectFlowState applyAvailableAddProjectHosts(
  AddProjectFlowState state,
  List<AddProjectHost> hosts, {
  String? preferredHostId,
}) {
  final current = currentAddProjectPage(state);
  if (state.pages.length != 1 || current is! AddProjectHostPage) {
    return _copyState(state, hosts: List.unmodifiable(hosts));
  }
  final preferredHost = preferredHostId == null
      ? null
      : hosts.where((host) => host.serverId == preferredHostId).firstOrNull;
  final onlyHost = hosts.length == 1 ? hosts.first : null;
  final initialHost = preferredHost ?? onlyHost;
  return _copyState(
    state,
    hosts: List.unmodifiable(hosts),
    pages: initialHost == null
        ? state.pages
        : [AddProjectMethodPage(hostId: initialHost.serverId)],
  );
}

AddProjectPage currentAddProjectPage(AddProjectFlowState state) {
  if (state.pages.isEmpty) {
    throw StateError('Add Project flow must always contain a page');
  }
  return state.pages.last;
}

AddProjectFlowState updateCurrentAddProjectPage(
  AddProjectFlowState state,
  AddProjectPage Function(AddProjectPage page) update,
) {
  final pages = [...state.pages];
  pages[pages.length - 1] = update(pages.last);
  return _copyState(state, pages: List.unmodifiable(pages));
}

AddProjectFlowState pushAddProjectPage(
  AddProjectFlowState state,
  AddProjectPage page,
) => _copyState(state, pages: List.unmodifiable([...state.pages, page]));

AddProjectFlowState? backAddProjectPage(AddProjectFlowState state) =>
    state.pages.length == 1
    ? null
    : _copyState(
        state,
        pages: List.unmodifiable(
          state.pages.sublist(0, state.pages.length - 1),
        ),
      );

AddProjectFlowState chooseAddProjectHost(
  AddProjectFlowState state,
  String hostId,
) => pushAddProjectPage(state, AddProjectMethodPage(hostId: hostId));

AddProjectFlowState openDirectorySearchPage(
  AddProjectFlowState state,
  String hostId,
) => pushAddProjectPage(state, AddProjectDirectorySearchPage(hostId: hostId));

AddProjectFlowState openGithubSearchPage(
  AddProjectFlowState state,
  String hostId,
) => pushAddProjectPage(state, AddProjectGithubSearchPage(hostId: hostId));

AddProjectFlowState openGithubLocationPage(
  AddProjectFlowState state,
  String hostId,
  GithubRepositoryChoice repository,
) {
  final draft = state
      .githubLocationDrafts[_githubLocationDraftKey(hostId, repository.id)];
  return pushAddProjectPage(
    state,
    AddProjectGithubLocationPage(
      hostId: hostId,
      repository: repository,
      query: draft?.query ?? '',
      activeIndex: draft?.activeIndex ?? 0,
    ),
  );
}

AddProjectFlowState openNewDirectoryParentPage(
  AddProjectFlowState state,
  String hostId,
) =>
    pushAddProjectPage(state, AddProjectNewDirectoryParentPage(hostId: hostId));

AddProjectFlowState openNewDirectoryNamePage(
  AddProjectFlowState state,
  String hostId,
  String parentPath,
) => pushAddProjectPage(
  state,
  AddProjectNewDirectoryNamePage(
    hostId: hostId,
    parentPath: parentPath,
    name:
        state.newDirectoryNameDrafts[_newDirectoryDraftKey(
          hostId,
          parentPath,
        )] ??
        '',
  ),
);

AddProjectFlowState setAddProjectPageInput(
  AddProjectFlowState state,
  String value,
) {
  final page = currentAddProjectPage(state);
  final updated = updateCurrentAddProjectPage(
    state,
    (current) => _copyPageWithInput(current, value),
  );
  if (page is! AddProjectGithubLocationPage) return updated;
  final drafts = {...updated.githubLocationDrafts};
  drafts[_githubLocationDraftKey(page.hostId, page.repository.id)] =
      GithubLocationDraft(query: value, activeIndex: 0);
  return _copyState(updated, githubLocationDrafts: Map.unmodifiable(drafts));
}

AddProjectFlowState setNewDirectoryName(
  AddProjectFlowState state,
  String value,
) {
  final page = currentAddProjectPage(state);
  if (page is! AddProjectNewDirectoryNamePage) return state;
  final updated = setAddProjectPageInput(state, value);
  final drafts = {...updated.newDirectoryNameDrafts};
  drafts[_newDirectoryDraftKey(page.hostId, page.parentPath)] = value;
  return _copyState(updated, newDirectoryNameDrafts: Map.unmodifiable(drafts));
}

AddProjectFlowState setAddProjectActiveIndex(
  AddProjectFlowState state,
  int activeIndex,
) {
  final page = currentAddProjectPage(state);
  final updated = updateCurrentAddProjectPage(
    state,
    (current) => _copyPageWithActiveIndex(current, activeIndex),
  );
  if (page is! AddProjectGithubLocationPage) return updated;
  final drafts = {...updated.githubLocationDrafts};
  drafts[_githubLocationDraftKey(page.hostId, page.repository.id)] =
      GithubLocationDraft(query: page.query, activeIndex: activeIndex);
  return _copyState(updated, githubLocationDrafts: Map.unmodifiable(drafts));
}

int moveAddProjectActiveIndex(
  int activeIndex,
  int optionCount,
  AddProjectSelectionDirection direction,
) {
  if (optionCount == 0) return 0;
  final delta = direction == AddProjectSelectionDirection.next ? 1 : -1;
  final next = activeIndex + delta;
  if (next < 0) return optionCount - 1;
  if (next >= optionCount) return 0;
  return next;
}

int moveAddProjectSelection(
  int activeIndex,
  List<bool> selectable,
  AddProjectSelectionDirection direction,
) {
  if (!selectable.any((value) => value)) return 0;
  var next = activeIndex;
  for (var count = 0; count < selectable.length; count += 1) {
    next = moveAddProjectActiveIndex(next, selectable.length, direction);
    if (selectable[next]) return next;
  }
  return activeIndex;
}

String _newDirectoryDraftKey(String hostId, String parentPath) =>
    '$hostId\u0000$parentPath';

String _githubLocationDraftKey(String hostId, String repositoryId) =>
    '$hostId\u0000$repositoryId';

AddProjectFlowState _copyState(
  AddProjectFlowState state, {
  List<AddProjectHost>? hosts,
  List<AddProjectPage>? pages,
  Map<String, String>? newDirectoryNameDrafts,
  Map<String, GithubLocationDraft>? githubLocationDrafts,
}) => AddProjectFlowState(
  hosts: hosts ?? state.hosts,
  pages: pages ?? state.pages,
  newDirectoryNameDrafts:
      newDirectoryNameDrafts ?? state.newDirectoryNameDrafts,
  githubLocationDrafts: githubLocationDrafts ?? state.githubLocationDrafts,
);

AddProjectPage _copyPageWithInput(AddProjectPage page, String value) =>
    switch (page) {
      AddProjectHostPage() => AddProjectHostPage(query: value),
      AddProjectMethodPage(:final hostId, :final isSubmitting) =>
        AddProjectMethodPage(
          hostId: hostId,
          isSubmitting: isSubmitting,
          query: value,
        ),
      AddProjectDirectorySearchPage(:final hostId, :final isSubmitting) =>
        AddProjectDirectorySearchPage(
          hostId: hostId,
          isSubmitting: isSubmitting,
          query: value,
        ),
      AddProjectGithubSearchPage(:final hostId) => AddProjectGithubSearchPage(
        hostId: hostId,
        query: value,
      ),
      AddProjectGithubLocationPage(
        :final hostId,
        :final repository,
        :final isSubmitting,
      ) =>
        AddProjectGithubLocationPage(
          hostId: hostId,
          repository: repository,
          isSubmitting: isSubmitting,
          query: value,
        ),
      AddProjectNewDirectoryParentPage(:final hostId) =>
        AddProjectNewDirectoryParentPage(hostId: hostId, query: value),
      AddProjectNewDirectoryNamePage(
        :final hostId,
        :final parentPath,
        :final isSubmitting,
      ) =>
        AddProjectNewDirectoryNamePage(
          hostId: hostId,
          parentPath: parentPath,
          name: value,
          isSubmitting: isSubmitting,
        ),
    };

AddProjectPage _copyPageWithActiveIndex(AddProjectPage page, int activeIndex) =>
    switch (page) {
      AddProjectHostPage(:final query, :final error) => AddProjectHostPage(
        query: query,
        activeIndex: activeIndex,
        error: error,
      ),
      AddProjectMethodPage(
        :final hostId,
        :final isSubmitting,
        :final query,
        :final error,
      ) =>
        AddProjectMethodPage(
          hostId: hostId,
          isSubmitting: isSubmitting,
          query: query,
          activeIndex: activeIndex,
          error: error,
        ),
      AddProjectDirectorySearchPage(
        :final hostId,
        :final isSubmitting,
        :final query,
        :final error,
      ) =>
        AddProjectDirectorySearchPage(
          hostId: hostId,
          isSubmitting: isSubmitting,
          query: query,
          activeIndex: activeIndex,
          error: error,
        ),
      AddProjectGithubSearchPage(:final hostId, :final query, :final error) =>
        AddProjectGithubSearchPage(
          hostId: hostId,
          query: query,
          activeIndex: activeIndex,
          error: error,
        ),
      AddProjectGithubLocationPage(
        :final hostId,
        :final repository,
        :final isSubmitting,
        :final query,
        :final error,
      ) =>
        AddProjectGithubLocationPage(
          hostId: hostId,
          repository: repository,
          isSubmitting: isSubmitting,
          query: query,
          activeIndex: activeIndex,
          error: error,
        ),
      AddProjectNewDirectoryParentPage(
        :final hostId,
        :final query,
        :final error,
      ) =>
        AddProjectNewDirectoryParentPage(
          hostId: hostId,
          query: query,
          activeIndex: activeIndex,
          error: error,
        ),
      AddProjectNewDirectoryNamePage(
        :final hostId,
        :final parentPath,
        :final name,
        :final error,
        :final isSubmitting,
      ) =>
        AddProjectNewDirectoryNamePage(
          hostId: hostId,
          parentPath: parentPath,
          name: name,
          activeIndex: activeIndex,
          error: error,
          isSubmitting: isSubmitting,
        ),
    };
