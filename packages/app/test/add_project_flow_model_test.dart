import 'package:coding_agent_app/add_project_flow/model.dart';
import 'package:coding_agent_app/add_project_flow/options.dart';
import 'package:flutter_test/flutter_test.dart';

const host = AddProjectHost(
  serverId: 'host-1',
  label: 'Local',
  canAddProject: true,
  canBrowse: true,
  canCloneGithubRepositories: true,
  canSearchGithubRepositories: true,
  canCreateDirectory: true,
);

void main() {
  group('Add Project navigation', () {
    test('skips a single connected host without adding it to history', () {
      final state = openAddProjectFlow(hosts: const [host]);

      final page = currentAddProjectPage(state);
      expect(page, isA<AddProjectMethodPage>());
      expect((page as AddProjectMethodPage).hostId, 'host-1');
      expect(page.query, '');
      expect(page.activeIndex, 0);
      expect(page.error, isNull);
      expect(backAddProjectPage(state), isNull);
    });

    test('honors a preferred host and applies late host availability', () {
      const remote = AddProjectHost(
        serverId: 'host-2',
        label: 'Remote',
        canAddProject: true,
        canBrowse: false,
        canCloneGithubRepositories: true,
        canSearchGithubRepositories: false,
        canCreateDirectory: true,
      );
      final preferred = openAddProjectFlow(
        hosts: const [host, remote],
        preferredHostId: remote.serverId,
      );
      expect(
        (currentAddProjectPage(preferred) as AddProjectMethodPage).hostId,
        remote.serverId,
      );

      final waiting = openAddProjectFlow(hosts: const []);
      final available = applyAvailableAddProjectHosts(waiting, const [host]);
      expect(
        (currentAddProjectPage(available) as AddProjectMethodPage).hostId,
        host.serverId,
      );

      final choosing = openAddProjectFlow(hosts: const [host, remote]);
      expect(currentAddProjectPage(choosing), isA<AddProjectHostPage>());
      final navigated = chooseAddProjectHost(choosing, host.serverId);
      final refreshed = applyAvailableAddProjectHosts(navigated, const [
        remote,
      ]);
      expect(refreshed.hosts, const [remote]);
      expect(currentAddProjectPage(refreshed), isA<AddProjectMethodPage>());
    });

    test('restores page input and selection after Back', () {
      const secondHost = AddProjectHost(
        serverId: 'host-2',
        label: 'Remote',
        canAddProject: true,
        canBrowse: true,
        canCloneGithubRepositories: true,
        canSearchGithubRepositories: true,
        canCreateDirectory: true,
      );
      var state = openAddProjectFlow(hosts: const [host, secondHost]);
      state = setAddProjectPageInput(state, 'rem');
      state = setAddProjectActiveIndex(state, 1);
      state = chooseAddProjectHost(state, secondHost.serverId);
      state = openDirectorySearchPage(state, secondHost.serverId);

      state = backAddProjectPage(state) ?? state;
      state = backAddProjectPage(state) ?? state;

      final page = currentAddProjectPage(state) as AddProjectHostPage;
      expect(page.query, 'rem');
      expect(page.activeIndex, 1);
      expect(page.error, isNull);
    });

    test('wraps keyboard selection in both directions', () {
      expect(
        moveAddProjectActiveIndex(2, 3, AddProjectSelectionDirection.next),
        0,
      );
      expect(
        moveAddProjectActiveIndex(0, 3, AddProjectSelectionDirection.previous),
        2,
      );
      expect(
        moveAddProjectSelection(0, const [
          true,
          false,
          true,
        ], AddProjectSelectionDirection.next),
        2,
      );
      expect(
        moveAddProjectSelection(1, const [
          false,
          false,
        ], AddProjectSelectionDirection.next),
        0,
      );
      expect(
        moveAddProjectSelection(2, const [
          true,
          false,
          true,
        ], AddProjectSelectionDirection.previous),
        0,
      );
      expect(
        moveAddProjectActiveIndex(0, 0, AddProjectSelectionDirection.next),
        0,
      );
    });

    test('exposes every page transition and rejects an empty stack', () {
      var state = openAddProjectFlow(hosts: const [host]);
      state = openDirectorySearchPage(state, host.serverId);
      expect(
        currentAddProjectPage(state),
        isA<AddProjectDirectorySearchPage>(),
      );
      state = openGithubSearchPage(state, host.serverId);
      expect(currentAddProjectPage(state), isA<AddProjectGithubSearchPage>());
      state = openNewDirectoryParentPage(state, host.serverId);
      expect(
        currentAddProjectPage(state),
        isA<AddProjectNewDirectoryParentPage>(),
      );

      expect(
        () => currentAddProjectPage(
          const AddProjectFlowState(hosts: [], pages: []),
        ),
        throwsStateError,
      );
    });

    test('input and selection updates preserve each page variant', () {
      const repository = GithubRepositoryChoice(
        id: 'repo',
        nameWithOwner: 'owner/repo',
        cloneUrl: 'owner/repo',
        description: null,
        visibility: null,
        updatedAt: null,
      );
      final pages = <AddProjectPage>[
        const AddProjectHostPage(error: 'old'),
        const AddProjectMethodPage(hostId: 'host-1', error: 'old'),
        const AddProjectDirectorySearchPage(
          hostId: 'host-1',
          isSubmitting: true,
          error: 'old',
        ),
        const AddProjectGithubSearchPage(hostId: 'host-1', error: 'old'),
        const AddProjectGithubLocationPage(
          hostId: 'host-1',
          repository: repository,
          isSubmitting: true,
          error: 'old',
        ),
        const AddProjectNewDirectoryParentPage(hostId: 'host-1', error: 'old'),
        const AddProjectNewDirectoryNamePage(
          hostId: 'host-1',
          parentPath: '~/dev',
          isSubmitting: true,
          error: 'old',
        ),
      ];

      for (final page in pages) {
        final initial = AddProjectFlowState(hosts: const [host], pages: [page]);
        final withInput = setAddProjectPageInput(initial, 'next');
        final inputPage = currentAddProjectPage(withInput);
        expect(inputPage.activeIndex, 0);
        expect(inputPage.error, isNull);
        if (inputPage case final AddProjectSearchPage search) {
          expect(search.query, 'next');
        } else {
          expect((inputPage as AddProjectNewDirectoryNamePage).name, 'next');
        }

        final withIndex = setAddProjectActiveIndex(withInput, 3);
        expect(currentAddProjectPage(withIndex).activeIndex, 3);
      }
    });

    test('restores a directory name after reselecting its parent', () {
      var state = openAddProjectFlow(hosts: const [host]);
      state = openNewDirectoryParentPage(state, host.serverId);
      state = openNewDirectoryNamePage(state, host.serverId, '~/dev');
      state = setNewDirectoryName(state, 'command-center');
      state = backAddProjectPage(state) ?? state;
      state = openNewDirectoryNamePage(state, host.serverId, '~/dev');

      final page =
          currentAddProjectPage(state) as AddProjectNewDirectoryNamePage;
      expect(page.parentPath, '~/dev');
      expect(page.name, 'command-center');

      final unchanged = setNewDirectoryName(
        openAddProjectFlow(hosts: const [host]),
        'ignored',
      );
      expect(currentAddProjectPage(unchanged), isA<AddProjectMethodPage>());
    });

    test('restores GitHub destination query and active parent', () {
      const repository = GithubRepositoryChoice(
        id: 'repo-1',
        nameWithOwner: 'getpaseo/paseo',
        cloneUrl: 'git@github.com:getpaseo/paseo.git',
        description: null,
        visibility: 'public',
        updatedAt: null,
      );
      var state = openAddProjectFlow(hosts: const [host]);
      state = openGithubLocationPage(state, host.serverId, repository);
      state = setAddProjectPageInput(state, '~/dev');
      state = setAddProjectActiveIndex(state, 2);
      state = backAddProjectPage(state) ?? state;
      state = openGithubLocationPage(state, host.serverId, repository);

      final page = currentAddProjectPage(state) as AddProjectGithubLocationPage;
      expect(page.query, '~/dev');
      expect(page.activeIndex, 2);
    });
  });

  group('Add Project options', () {
    test('filters hosts by label and stable server id', () {
      const remote = AddProjectHost(
        serverId: 'remote-a',
        label: 'Build Host',
        canAddProject: true,
        canBrowse: false,
        canCloneGithubRepositories: true,
        canSearchGithubRepositories: true,
        canCreateDirectory: true,
      );
      expect(filterAddProjectHosts(const [host, remote], 'build'), [remote]);
      expect(filterAddProjectHosts(const [host, remote], 'HOST-1'), [host]);
      expect(filterAddProjectHosts(const [host, remote], ''), [host, remote]);
    });

    test('hides mutations when the host lacks stable project identity', () {
      const outdatedHost = AddProjectHost(
        serverId: 'host-1',
        label: 'Local',
        canAddProject: false,
        canBrowse: true,
        canCloneGithubRepositories: true,
        canSearchGithubRepositories: true,
        canCreateDirectory: true,
      );

      expect(buildAddProjectMethods(outdatedHost), isEmpty);
      expect(
        addProjectMethodEmptyText(outdatedHost),
        'Update the host to use Add Project.',
      );
    });

    test('keeps upgrade methods discoverable and hides Browse', () {
      const limited = AddProjectHost(
        serverId: 'host-1',
        label: 'Local',
        canAddProject: true,
        canBrowse: false,
        canCloneGithubRepositories: false,
        canSearchGithubRepositories: false,
        canCreateDirectory: false,
      );
      final methods = buildAddProjectMethods(limited);

      expect(methods.map((option) => option.id), [
        directorySearchMethodId,
        githubMethodId,
        newDirectoryMethodId,
      ]);
      expect(
        methods[1].description,
        'Update this host to clone GitHub repositories',
      );
      expect(methods[1].disabled, isTrue);
      expect(methods[2].description, 'Update this host to create directories');
      expect(methods[2].disabled, isTrue);
      expect(addProjectMethodEmptyText(null), 'No matching options');

      final full = buildAddProjectMethods(host);
      expect(full.map((option) => option.id), [
        directorySearchMethodId,
        browseMethodId,
        githubMethodId,
        newDirectoryMethodId,
      ]);
      expect(
        full[2].description,
        'Search projects available to your GitHub account',
      );

      const manualGithub = AddProjectHost(
        serverId: 'host-1',
        label: 'Local',
        canAddProject: true,
        canBrowse: false,
        canCloneGithubRepositories: true,
        canSearchGithubRepositories: false,
        canCreateDirectory: true,
      );
      expect(
        buildAddProjectMethods(manualGithub)[1].description,
        'Enter a GitHub URL or owner/repo',
      );
    });

    test('offers URL and protocol-specific owner/repo clone choices', () {
      final remote = buildManualGithubRepositoryChoices(
        'git@github.com:getpaseo/paseo.git',
      );
      expect(remote, hasLength(1));
      expect(remote.single.id, 'manual:git@github.com:getpaseo/paseo.git');
      expect(remote.single.nameWithOwner, 'getpaseo/paseo');
      expect(remote.single.cloneUrl, 'git@github.com:getpaseo/paseo.git');

      final shorthand = buildManualGithubRepositoryChoices('getpaseo/paseo');
      expect(shorthand.map((choice) => choice.cloneProtocol), [
        GithubCloneProtocol.https,
        GithubCloneProtocol.ssh,
      ]);
      expect(shorthand.map((choice) => choice.cloneUrl).toSet(), {
        'getpaseo/paseo',
      });
      expect(buildManualGithubRepositoryChoices('paseo'), isEmpty);
      expect(buildManualGithubRepositoryChoices(''), isEmpty);
      final gitlab = buildManualGithubRepositoryChoices(
        'https://gitlab.com/getpaseo/paseo.git',
      );
      expect(gitlab.single.nameWithOwner, 'paseo');
    });

    test('shows final clone paths while retaining parent values', () {
      final options = buildCloneLocationOptions(
        parents: const ['~/dev', '~/workspace'],
        repositoryName: 'paseo',
        existingPaths: const ['~/workspace/paseo'],
      );

      expect(options, hasLength(2));
      expect(options.first.id, '~/dev');
      expect(options.first.path, '~/dev');
      expect(options.first.displayPath, '~/dev/paseo');
      expect(options.first.secondaryText, 'Parent directory: ~/dev');
      expect(options.first.disabled, isFalse);
      expect(options.last.secondaryText, 'Already exists');
      expect(options.last.disabled, isTrue);
    });

    test('deduplicates equivalent absolute-home and tilde destinations', () {
      final options = buildCloneLocationOptions(
        parents: const ['/Users/moboudra/dev', '~/dev'],
        repositoryName: 'dotfiles',
        existingPaths: const [],
      );

      expect(options, hasLength(1));
      expect(options.single.id, '/Users/moboudra/dev');
      expect(options.single.displayPath, '/Users/moboudra/dev/dotfiles');
    });

    test('preserves frozen path helpers and suggested parent order', () {
      expect(pathBaseName(r'C:\src\paseo\'), 'paseo');
      expect(parentDirectory(r'C:\src\paseo'), r'C:\src');
      expect(parentDirectory('paseo'), isNull);
      expect(parentDirectory('/paseo'), '/');
      expect(joinDirectoryPath(r'C:\src', 'paseo'), r'C:\src\paseo');
      expect(joinDirectoryPath('/src/', 'paseo'), '/src/paseo');
      expect(
        buildSuggestedParentDirectories(const ['~/dev/one', '~/dev/two']),
        const [
          '~/dev',
          '~/Developer',
          '~/src',
          '~/projects',
          '~/workspace',
          '~',
        ],
      );
    });
  });
}
