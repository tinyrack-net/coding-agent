import 'package:coding_agent_app/sidebar/sidebar_project_row_model.dart';
import 'package:flutter_test/flutter_test.dart';

SidebarProjectEntry project({
  String projectKey = 'project-1',
  String projectName = 'paseo',
  List<SidebarProjectHost>? hosts,
}) => SidebarProjectEntry(
  projectKey: projectKey,
  projectName: projectName,
  hosts:
      hosts ??
      const [
        SidebarProjectHost(
          serverId: 'srv',
          iconWorkingDir: '/repo',
          canCreateWorktree: true,
        ),
      ],
);

void main() {
  group('buildSidebarProjectRowModel', () {
    test('renders a project as an expanded section', () {
      final result = buildSidebarProjectRowModel(
        project: project(
          hosts: const [
            SidebarProjectHost(
              serverId: 'srv',
              iconWorkingDir: '/notes',
              canCreateWorktree: false,
            ),
          ],
        ),
        collapsed: false,
      );

      expect(result.chevron, SidebarProjectChevron.collapse);
      expect(result.trailingAction, isA<SidebarProjectNoTrailingAction>());
    });

    test('renders a collapsed git project with a new workspace action', () {
      final result = buildSidebarProjectRowModel(
        project: project(),
        collapsed: true,
      );

      expect(result.chevron, SidebarProjectChevron.expand);
      expect(
        (result.trailingAction as SidebarProjectNewWorkspaceAction).target,
        const SidebarProjectHostTarget(
          serverId: 'srv',
          iconWorkingDir: '/repo',
        ),
      );
    });

    test('allows a non-git host when workspace multiplicity is supported', () {
      final result = buildSidebarProjectRowModel(
        project: project(
          hosts: const [
            SidebarProjectHost(
              serverId: 'srv',
              iconWorkingDir: '/notes',
              canCreateWorktree: false,
            ),
          ],
        ),
        collapsed: false,
        supportsMultiplicityByServerId: const {'srv': true},
      );

      expect(
        (result.trailingAction as SidebarProjectNewWorkspaceAction).target,
        const SidebarProjectHostTarget(
          serverId: 'srv',
          iconWorkingDir: '/notes',
        ),
      );
    });

    test('hides the action when a non-git host lacks multiplicity', () {
      final result = buildSidebarProjectRowModel(
        project: project(
          hosts: const [
            SidebarProjectHost(
              serverId: 'srv',
              iconWorkingDir: '/notes',
              canCreateWorktree: false,
            ),
          ],
        ),
        collapsed: false,
        supportsMultiplicityByServerId: const {'srv': false},
      );

      expect(result.trailingAction, isA<SidebarProjectNoTrailingAction>());
    });

    test('git capability wins regardless of multiplicity', () {
      final result = buildSidebarProjectRowModel(
        project: project(),
        collapsed: false,
        supportsMultiplicityByServerId: const {'srv': false},
      );

      expect(result.trailingAction, isA<SidebarProjectNewWorkspaceAction>());
    });

    test('targets the first host that can create a workspace', () {
      final result = buildSidebarProjectRowModel(
        project: project(
          hosts: const [
            SidebarProjectHost(
              serverId: 'host-a',
              iconWorkingDir: '/repo/a',
              canCreateWorktree: false,
            ),
            SidebarProjectHost(
              serverId: 'host-b',
              iconWorkingDir: '/repo/b',
              canCreateWorktree: true,
            ),
          ],
        ),
        collapsed: false,
      );

      expect(
        (result.trailingAction as SidebarProjectNewWorkspaceAction).target,
        const SidebarProjectHostTarget(
          serverId: 'host-b',
          iconWorkingDir: '/repo/b',
        ),
      );
    });

    test('targets the first multiplicity-capable host', () {
      final result = buildSidebarProjectRowModel(
        project: project(
          hosts: const [
            SidebarProjectHost(
              serverId: 'host-a',
              iconWorkingDir: '/repo/a',
              canCreateWorktree: false,
            ),
            SidebarProjectHost(
              serverId: 'host-b',
              iconWorkingDir: '/repo/b',
              canCreateWorktree: false,
            ),
          ],
        ),
        collapsed: false,
        supportsMultiplicityByServerId: const {'host-b': true},
      );

      expect(
        (result.trailingAction as SidebarProjectNewWorkspaceAction).target,
        const SidebarProjectHostTarget(
          serverId: 'host-b',
          iconWorkingDir: '/repo/b',
        ),
      );
    });
  });

  group('resolveSidebarProjectIconTarget', () {
    test('uses the first valid project host', () {
      expect(
        resolveSidebarProjectIconTarget(
          project(
            hosts: const [
              SidebarProjectHost(
                serverId: 'host-b',
                iconWorkingDir: '/repo/b',
                canCreateWorktree: true,
              ),
              SidebarProjectHost(
                serverId: 'host-a',
                iconWorkingDir: '/repo/a',
                canCreateWorktree: true,
              ),
            ],
          ),
        ),
        const SidebarProjectHostTarget(
          serverId: 'host-b',
          iconWorkingDir: '/repo/b',
        ),
      );
    });

    test('skips blank host targets', () {
      expect(
        resolveSidebarProjectIconTarget(
          project(
            hosts: const [
              SidebarProjectHost(
                serverId: '',
                iconWorkingDir: '/bad',
                canCreateWorktree: true,
              ),
              SidebarProjectHost(
                serverId: 'host-b',
                iconWorkingDir: ' /repo/b ',
                canCreateWorktree: true,
              ),
            ],
          ),
        ),
        const SidebarProjectHostTarget(
          serverId: 'host-b',
          iconWorkingDir: '/repo/b',
        ),
      );
    });

    test('returns null when no host has a complete target', () {
      expect(
        resolveSidebarProjectIconTarget(
          project(
            hosts: const [
              SidebarProjectHost(
                serverId: 'host-a',
                iconWorkingDir: ' ',
                canCreateWorktree: true,
              ),
            ],
          ),
        ),
        isNull,
      );
    });
  });
}
