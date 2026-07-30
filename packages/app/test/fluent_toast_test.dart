import 'package:coding_agent_app/widgets/fluent/toast.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(AppToast.dismissCurrent);

  testWidgets('default toast dismisses itself after four seconds', (
    tester,
  ) async {
    final context = await _pumpToastHost(tester);

    final handle = AppToast.show(context, 'Transient toast');
    await tester.pump();

    expect(handle.isActive, isTrue);
    expect(find.text('Transient toast'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3999));
    expect(find.text('Transient toast'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
    expect(handle.isActive, isFalse);
    expect(find.text('Transient toast'), findsNothing);
  });

  testWidgets('null duration remains visible until its handle dismisses it', (
    tester,
  ) async {
    final context = await _pumpToastHost(tester);

    final handle = AppToast.show(context, 'Persistent toast', duration: null);
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));

    expect(handle.isActive, isTrue);
    expect(find.text('Persistent toast'), findsOneWidget);

    handle.dismiss();
    handle.dismiss();
    await tester.pump();

    expect(handle.isActive, isFalse);
    expect(find.text('Persistent toast'), findsNothing);
  });

  testWidgets('stale handle cannot dismiss the replacement toast', (
    tester,
  ) async {
    final context = await _pumpToastHost(tester);

    final stale = AppToast.show(context, 'Reconnect', duration: null);
    final replacement = AppToast.show(
      context,
      'Unrelated notice',
      duration: null,
    );
    await tester.pump();

    expect(stale.isActive, isFalse);
    expect(replacement.isActive, isTrue);
    stale.dismiss();
    await tester.pump();

    expect(replacement.isActive, isTrue);
    expect(find.text('Unrelated notice'), findsOneWidget);
  });

  testWidgets('replacing a toast cancels its pending dismiss timer', (
    tester,
  ) async {
    final context = await _pumpToastHost(tester);

    final stale = AppToast.show(
      context,
      'Short toast',
      duration: const Duration(milliseconds: 100),
    );
    final replacement = AppToast.show(
      context,
      'Persistent replacement',
      duration: null,
    );
    await tester.pump(const Duration(seconds: 1));

    expect(stale.isActive, isFalse);
    expect(replacement.isActive, isTrue);
    expect(find.text('Persistent replacement'), findsOneWidget);
  });

  testWidgets('close action dismisses only its active toast', (tester) async {
    final context = await _pumpToastHost(tester);

    final handle = AppToast.show(context, 'Closable', duration: null);
    await tester.pump();
    final close = find.byType(IconButton);
    expect(close, findsOneWidget);

    await tester.tap(close);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(handle.isActive, isFalse);
    expect(find.text('Closable'), findsNothing);
  });
}

Future<BuildContext> _pumpToastHost(WidgetTester tester) async {
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
  return toastContext;
}
