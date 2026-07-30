import 'dart:async';

import 'package:coding_agent_app/core/desktop/windows_agent_deep_link_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tinyrack/agent_navigation.test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'installs handler before listen and delivers pending after hot events',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add('native:${call.method}');
        if (call.method == 'listen') {
          await _invokeFromNative(
            messenger,
            channel.name,
            const MethodCall('open', 'coding-agent://h/server/agent/hot-agent'),
          );
          return 'coding-agent://h/server/agent/pending-agent';
        }
        return null;
      });
      final source = WindowsAgentDeepLinkSource.withChannel(channel);

      final subscription = await source.listen((uri) => calls.add('dart:$uri'));

      expect(calls, [
        'native:listen',
        'dart:coding-agent://h/server/agent/hot-agent',
        'dart:coding-agent://h/server/agent/pending-agent',
      ]);
      await subscription.cancel();
      expect(calls.last, 'native:cancel');
    },
  );

  test('cancel is idempotent and detaches the native handler', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return null;
    });
    final received = <String>[];
    final source = WindowsAgentDeepLinkSource.withChannel(channel);
    final subscription = await source.listen(received.add);

    await subscription.cancel();
    await subscription.cancel();
    await _invokeFromNative(
      messenger,
      channel.name,
      const MethodCall('open', 'coding-agent://h/server/agent/ignored-agent'),
    );

    expect(methods, ['listen', 'cancel']);
    expect(received, isEmpty);
  });

  test('failed listen cleans up so the binding can retry', () async {
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listen' && attempts++ == 0) {
        throw PlatformException(code: 'not-ready');
      }
      return null;
    });
    final source = WindowsAgentDeepLinkSource.withChannel(channel);

    await expectLater(source.listen((_) {}), throwsA(isA<PlatformException>()));
    final subscription = await source.listen((_) {});

    expect(attempts, 2);
    await subscription.cancel();
  });
}

Future<Object?> _invokeFromNative(
  TestDefaultBinaryMessenger messenger,
  String channel,
  MethodCall call,
) {
  const codec = StandardMethodCodec();
  final completer = Completer<Object?>();
  messenger.handlePlatformMessage(channel, codec.encodeMethodCall(call), (
    ByteData? response,
  ) {
    completer.complete(
      response == null ? null : codec.decodeEnvelope(response),
    );
  });
  return completer.future;
}
