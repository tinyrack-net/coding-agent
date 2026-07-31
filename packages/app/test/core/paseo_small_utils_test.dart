// Ports of the upstream test suites for Paseo's smallest decision helpers:
// workspace-draft-pane-focus, file-pane-render-mode, status-loader, latency,
// extract-agent-model, project-display-name, desktop-badge-state, and
// message-compaction-label.
import 'package:coding_agent_app/core/paseo_small_utils.dart';
import 'package:flutter_test/flutter_test.dart';

const _translations = {
  'message.compaction.loading': 'Compacting…',
  'message.compaction.auto': 'Auto-compacted',
  'message.compaction.manual': 'Compacted',
  'message.compaction.completed': 'Compacted',
  'message.compaction.withTokens': 'Compacted with tokens',
};

String t(String key) => _translations[key] ?? key;

void main() {
  group('shouldAutoFocusWorkspaceDraftComposer', () {
    test('focuses with the pane but never mid-submit', () {
      expect(
        shouldAutoFocusWorkspaceDraftComposer(
          isPaneFocused: true,
          isSubmitting: false,
        ),
        isTrue,
      );
      expect(
        shouldAutoFocusWorkspaceDraftComposer(
          isPaneFocused: true,
          isSubmitting: true,
        ),
        isFalse,
      );
      expect(
        shouldAutoFocusWorkspaceDraftComposer(
          isPaneFocused: false,
          isSubmitting: false,
        ),
        isFalse,
      );
    });
  });

  group('isRenderedMarkdownFile', () {
    test('detects markdown regardless of case or surrounding space', () {
      expect(isRenderedMarkdownFile('README.md'), isTrue);
      expect(isRenderedMarkdownFile('notes.MARKDOWN'), isTrue);
      expect(isRenderedMarkdownFile('  docs/guide.md  '), isTrue);
    });

    test('leaves every other file to the code editor', () {
      expect(isRenderedMarkdownFile('main.dart'), isFalse);
      expect(isRenderedMarkdownFile('md'), isFalse);
      expect(isRenderedMarkdownFile(''), isFalse);
    });
  });

  group('shouldRenderSyncedStatusLoader', () {
    test('spins only for a running workspace', () {
      expect(
        shouldRenderSyncedStatusLoader(StatusLoaderBucket.running),
        isTrue,
      );
      for (final bucket in const [
        StatusLoaderBucket.needsInput,
        StatusLoaderBucket.failed,
        StatusLoaderBucket.attention,
        StatusLoaderBucket.done,
      ]) {
        expect(shouldRenderSyncedStatusLoader(bucket), isFalse);
      }
      expect(shouldRenderSyncedStatusLoader(null), isFalse);
    });
  });

  group('formatLatency', () {
    test('uses microseconds for sub-millisecond latency', () {
      expect(formatLatency(0.4), '400µs');
    });

    test('uses integer milliseconds below one second', () {
      expect(formatLatency(7.200000047683716), '7ms');
      expect(formatLatency(999.4), '999ms');
    });

    test('uses seconds at one second and above', () {
      expect(formatLatency(1000), '1s');
      expect(formatLatency(1234), '1.2s');
      expect(formatLatency(10040), '10s');
    });
  });

  group('extractAgentModel', () {
    test('prefers the runtime model over the configured one', () {
      expect(
        extractAgentModel(runtimeModel: 'gpt-5', configuredModel: 'gpt-4'),
        'gpt-5',
      );
    });

    test('falls back to the configured model when runtime is blank', () {
      expect(
        extractAgentModel(runtimeModel: '   ', configuredModel: 'gpt-4'),
        'gpt-4',
      );
      expect(extractAgentModel(configuredModel: 'gpt-4'), 'gpt-4');
    });

    test('treats blank and missing values as unset', () {
      expect(extractAgentModel(), isNull);
      expect(
        extractAgentModel(runtimeModel: '  ', configuredModel: ''),
        isNull,
      );
    });
  });

  group('projectDisplayNameFromProjectId', () {
    test('shows owner and repo for GitHub remote ids', () {
      expect(
        projectDisplayNameFromProjectId('remote:github.com/getpaseo/paseo'),
        'getpaseo/paseo',
      );
    });

    test('shows the trailing directory name for local projects', () {
      expect(projectDisplayNameFromProjectId('/Users/me/dev/paseo'), 'paseo');
      expect(
        projectDisplayNameFromProjectId(r'C:\Users\me\dev\paseo'),
        'paseo',
      );
    });

    test('falls back to the id when there is nothing to shorten', () {
      expect(
        projectDisplayNameFromProjectId('remote:github.com/'),
        'remote:github.com/',
      );
      expect(projectDisplayNameFromProjectId('///'), '///');
    });
  });

  group('projectIconPlaceholderLabelFromDisplayName', () {
    test('uses the repo name rather than the owner', () {
      expect(
        projectIconPlaceholderLabelFromDisplayName('getpaseo/paseo'),
        'paseo',
      );
    });

    test('returns the display name when it has no separator', () {
      expect(projectIconPlaceholderLabelFromDisplayName('paseo'), 'paseo');
    });

    test('returns empty for blank input', () {
      expect(projectIconPlaceholderLabelFromDisplayName('   '), '');
    });
  });

  group('desktop badge state', () {
    test('counts only workspaces waiting on the user', () {
      expect(
        isWorkspaceActionableForDesktopBadge(
          DesktopBadgeWorkspaceStatus.attention,
        ),
        isTrue,
      );
      expect(
        isWorkspaceActionableForDesktopBadge(
          DesktopBadgeWorkspaceStatus.needsInput,
        ),
        isTrue,
      );
      expect(
        isWorkspaceActionableForDesktopBadge(
          DesktopBadgeWorkspaceStatus.failed,
        ),
        isTrue,
      );
      expect(
        isWorkspaceActionableForDesktopBadge(
          DesktopBadgeWorkspaceStatus.running,
        ),
        isFalse,
      );
      expect(
        isWorkspaceActionableForDesktopBadge(DesktopBadgeWorkspaceStatus.done),
        isFalse,
      );
    });

    test('reports no badge rather than a zero', () {
      expect(
        deriveMacDockBadgeCountFromWorkspaceStatuses(const [
          DesktopBadgeWorkspaceStatus.running,
          DesktopBadgeWorkspaceStatus.done,
        ]),
        isNull,
      );
      expect(deriveMacDockBadgeCountFromWorkspaceStatuses(const []), isNull);
    });

    test('counts every actionable workspace', () {
      expect(
        deriveMacDockBadgeCountFromWorkspaceStatuses(const [
          DesktopBadgeWorkspaceStatus.attention,
          DesktopBadgeWorkspaceStatus.running,
          DesktopBadgeWorkspaceStatus.failed,
          DesktopBadgeWorkspaceStatus.needsInput,
        ]),
        3,
      );
    });
  });

  group('getCompactionMarkerLabel', () {
    test('loading wins over every other branch', () {
      expect(
        getCompactionMarkerLabel(
          status: CompactionMarkerStatus.loading,
          trigger: CompactionMarkerTrigger.auto,
          preTokens: 42000,
          t: t,
        ),
        'Compacting…',
      );
    });

    test('distinguishes automatic from manual compaction', () {
      expect(
        getCompactionMarkerLabel(
          status: CompactionMarkerStatus.completed,
          trigger: CompactionMarkerTrigger.auto,
          t: t,
        ),
        'Auto-compacted',
      );
      expect(
        getCompactionMarkerLabel(
          status: CompactionMarkerStatus.completed,
          trigger: CompactionMarkerTrigger.manual,
          t: t,
        ),
        'Compacted',
      );
    });

    test('reports pre-compaction tokens in thousands when known', () {
      expect(
        getCompactionMarkerLabel(
          status: CompactionMarkerStatus.completed,
          preTokens: 42400,
          t: t,
          withTokens: (thousands) => 'Compacted ${thousands}k tokens',
        ),
        'Compacted 42k tokens',
      );
    });

    test('falls back to the plain completed label', () {
      expect(
        getCompactionMarkerLabel(
          status: CompactionMarkerStatus.completed,
          t: t,
        ),
        'Compacted',
      );
      expect(
        getCompactionMarkerLabel(
          status: CompactionMarkerStatus.completed,
          preTokens: 0,
          t: t,
        ),
        'Compacted',
      );
    });
  });
}
