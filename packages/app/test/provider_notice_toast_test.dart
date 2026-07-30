import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/provider_notice_toast.dart';
import 'package:coding_agent_app/widgets/fluent/toast.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(AppToast.dismissCurrent);

  testWidgets(
    'thinking next-turn warning uses warning styling for five seconds',
    (tester) async {
      late BuildContext toastContext;
      await tester.pumpWidget(
        FluentApp(
          home: Builder(
            builder: (context) {
              toastContext = context;
              return const SizedBox();
            },
          ),
        ),
      );

      showProviderNoticeToast(
        toastContext,
        const AgentProviderNotice(
          type: AgentProviderNoticeType.warning,
          message: 'Thinking level applies next turn',
        ),
      );
      await tester.pump();

      expect(find.text('Thinking level applies next turn'), findsOneWidget);
      expect(
        tester.widget<InfoBar>(find.byType(InfoBar)).severity,
        InfoBarSeverity.warning,
      );

      await tester.pump(const Duration(milliseconds: 4999));
      expect(find.text('Thinking level applies next turn'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Thinking level applies next turn'), findsNothing);
    },
  );
}
