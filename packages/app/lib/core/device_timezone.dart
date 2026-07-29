import 'package:flutter_timezone/flutter_timezone.dart';

typedef DeviceTimeZoneLoader = Future<String> Function();

/// Returns the device's standardized IANA timezone identifier, matching
/// `Intl.DateTimeFormat().resolvedOptions().timeZone` in Paseo.
Future<String> getDeviceTimeZone() async =>
    (await FlutterTimezone.getLocalTimezone()).identifier;
