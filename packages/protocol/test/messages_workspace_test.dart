import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('ProjectInfo', () {
    test('round-trips with all fields', () {
      const info = ProjectInfo(
        path: 'C:/repo',
        name: 'repo',
        isGitRepo: true,
      );
      final decoded = ProjectInfo.fromJson(roundTrip(info.toJson()));
      expect(decoded.path, 'C:/repo');
      expect(decoded.name, 'repo');
      expect(decoded.isGitRepo, isTrue);
    });

    test('fromJson applies defaults for missing optional fields', () {
      final decoded = ProjectInfo.fromJson(const {'path': 'C:/x'});
      expect(decoded.path, 'C:/x');
      expect(decoded.name, '');
      expect(decoded.isGitRepo, isFalse);
    });

    test('fromJson throws when path missing', () {
      expect(() => ProjectInfo.fromJson(const {}), throwsA(anything));
    });
  });

  group('WorktreeInfo', () {
    test('round-trips with all fields', () {
      const info = WorktreeInfo(
        path: 'C:/repo/wt1',
        branch: 'feature/x',
        projectPath: 'C:/repo',
        isMain: false,
      );
      final decoded = WorktreeInfo.fromJson(roundTrip(info.toJson()));
      expect(decoded.path, 'C:/repo/wt1');
      expect(decoded.branch, 'feature/x');
      expect(decoded.projectPath, 'C:/repo');
      expect(decoded.isMain, isFalse);
    });

    test('main worktree round-trips isMain true', () {
      const info = WorktreeInfo(
        path: 'C:/repo',
        branch: 'main',
        projectPath: 'C:/repo',
        isMain: true,
      );
      final decoded = WorktreeInfo.fromJson(roundTrip(info.toJson()));
      expect(decoded.isMain, isTrue);
    });

    test('fromJson applies defaults for missing optional fields', () {
      final decoded = WorktreeInfo.fromJson(const {'path': 'C:/x'});
      expect(decoded.path, 'C:/x');
      expect(decoded.branch, '');
      expect(decoded.projectPath, '');
      expect(decoded.isMain, isFalse);
    });

    test('fromJson throws when path missing', () {
      expect(() => WorktreeInfo.fromJson(const {}), throwsA(anything));
    });
  });
}
