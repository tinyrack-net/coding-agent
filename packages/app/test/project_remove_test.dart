import 'dart:async';

import 'package:coding_agent_app/projects/project_remove.dart';
import 'package:flutter_test/flutter_test.dart';

const _project = ProjectRemoveProject(
  projectKey: 'remote:github.com/acme/app',
  hosts: [ProjectRemoveHost('host-a'), ProjectRemoveHost('host-b')],
);

void main() {
  test('requires every host to support project removal', () {
    final readiness = getProjectRemoveReadiness(
      project: _project,
      supportsProjectRemove: (serverId) => serverId == 'host-a',
    );

    expect(readiness, isA<ProjectRemoveNeedsHostUpdate>());
    expect((readiness as ProjectRemoveNeedsHostUpdate).serverIds, ['host-b']);
  });

  test('returns every capable host as a removal target', () {
    final readiness = getProjectRemoveReadiness(
      project: _project,
      supportsProjectRemove: (_) => true,
    );

    expect(readiness, isA<ProjectRemoveReady>());
    expect((readiness as ProjectRemoveReady).targets, [
      const ProjectRemoveTarget('host-a'),
      const ProjectRemoveTarget('host-b'),
    ]);
  });

  test('removes the project from every host concurrently', () async {
    final calls = <String, List<String>>{'host-a': [], 'host-b': []};
    final gates = {'host-a': Completer<void>(), 'host-b': Completer<void>()};

    final future = removeProjectFromHosts(
      projectKey: _project.projectKey,
      targets: const [
        ProjectRemoveTarget('host-a'),
        ProjectRemoveTarget('host-b'),
      ],
      getRemover: (serverId) => (projectKey) async {
        calls[serverId]!.add(projectKey);
        await gates[serverId]!.future;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls['host-a'], [_project.projectKey]);
    expect(calls['host-b'], [_project.projectKey]);
    for (final gate in gates.values) {
      gate.complete();
    }

    final outcome = await future;
    expect(outcome, isA<ProjectRemoved>());
    expect((outcome as ProjectRemoved).serverIds, ['host-a', 'host-b']);
  });

  test('reports disconnected hosts before sending any request', () async {
    final removed = <String>[];
    final outcome = await removeProjectFromHosts(
      projectKey: _project.projectKey,
      targets: const [
        ProjectRemoveTarget('host-a'),
        ProjectRemoveTarget('host-b'),
      ],
      getRemover: (serverId) => serverId == 'host-a'
          ? (projectKey) async => removed.add(projectKey)
          : null,
    );

    expect(outcome, isA<ProjectRemoveHostDisconnected>());
    expect((outcome as ProjectRemoveHostDisconnected).serverIds, ['host-b']);
    expect(removed, isEmpty);
  });

  test('reports every host whose removal fails', () async {
    final outcome = await removeProjectFromHosts(
      projectKey: _project.projectKey,
      targets: const [
        ProjectRemoveTarget('host-a'),
        ProjectRemoveTarget('host-b'),
      ],
      getRemover: (serverId) => (_) async {
        if (serverId == 'host-b') throw StateError('failed');
      },
    );

    expect(outcome, isA<ProjectRemoveFailed>());
    expect((outcome as ProjectRemoveFailed).serverIds, ['host-b']);
  });
}
