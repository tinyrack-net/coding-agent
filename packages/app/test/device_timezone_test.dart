import 'package:coding_agent_app/core/device_timezone.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_timezone');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('returns the platform IANA timezone identifier', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getLocalTimezone');
          return {
            'identifier': 'Asia/Seoul',
            'localizedName': '대한민국 표준시',
            'locale': 'ko_KR',
          };
        });

    expect(await getDeviceTimeZone(), 'Asia/Seoul');
  });
}
