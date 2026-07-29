import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/sidebar/status_dot_color.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final palette = paseoPaletteFor(AppThemeName.dark);

  test('maps every state bucket to the frozen palette', () {
    expect(
      getStatusDotColor(
        palette: palette,
        bucket: WorkspaceStateBucket.needsInput,
      ),
      agentStatusNeedsInputColor,
    );
    expect(
      getStatusDotColor(palette: palette, bucket: WorkspaceStateBucket.failed),
      agentStatusFailedColor,
    );
    expect(
      getStatusDotColor(palette: palette, bucket: WorkspaceStateBucket.running),
      agentStatusRunningColor,
    );
    expect(
      getStatusDotColor(
        palette: palette,
        bucket: WorkspaceStateBucket.attention,
      ),
      agentStatusAttentionColor,
    );
    expect(
      getStatusDotColor(palette: palette, bucket: WorkspaceStateBucket.done),
      isNull,
    );
    expect(
      getStatusDotColor(
        palette: palette,
        bucket: WorkspaceStateBucket.done,
        showDoneAsInactive: true,
      ),
      palette.border,
    );
  });

  test('only needs-input and attention dots are emphasized', () {
    expect(
      isEmphasizedStatusDotBucket(WorkspaceStateBucket.needsInput),
      isTrue,
    );
    expect(isEmphasizedStatusDotBucket(WorkspaceStateBucket.attention), isTrue);
    expect(isEmphasizedStatusDotBucket(WorkspaceStateBucket.running), isFalse);
    expect(isEmphasizedStatusDotBucket(null), isFalse);
  });
}
