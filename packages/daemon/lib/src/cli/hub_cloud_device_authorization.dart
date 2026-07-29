import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const hubDeviceAuthorizationStartTimeout = Duration(seconds: 15);

final class HubDeviceAuthorizationException implements Exception {
  const HubDeviceAuthorizationException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

final class HubDeviceAuthorization {
  const HubDeviceAuthorization({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresAt,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final Uri verificationUriComplete;
  final DateTime expiresAt;
  final int interval;

  factory HubDeviceAuthorization.fromJson(Object? value) {
    final json = _map(value, 'authorization');
    return HubDeviceAuthorization(
      deviceCode: _minLength(json['deviceCode'], 32, 'deviceCode'),
      userCode: _minLength(json['userCode'], 1, 'userCode'),
      verificationUri: _activationUri(
        json['verificationUri'],
        'verificationUri',
      ),
      verificationUriComplete: _activationUri(
        json['verificationUriComplete'],
        'verificationUriComplete',
      ),
      expiresAt: _dateTime(json['expiresAt'], 'expiresAt'),
      interval: _interval(json['interval']),
    );
  }
}

sealed class HubDeviceAuthorizationPoll {
  const HubDeviceAuthorizationPoll();

  factory HubDeviceAuthorizationPoll.fromJson(Object? value) {
    final json = _map(value, 'poll');
    return switch (json['status']) {
      'pending' => HubDeviceAuthorizationPending(
        interval: _interval(json['interval']),
      ),
      'slow_down' => HubDeviceAuthorizationSlowDown(
        interval: _interval(json['interval']),
      ),
      'approved' => HubDeviceAuthorizationApproved(
        interval: _interval(json['interval']),
        enrollmentToken: _minLength(
          json['enrollmentToken'],
          32,
          'enrollmentToken',
        ),
      ),
      'denied' => HubDeviceAuthorizationDenied(
        interval: _interval(json['interval']),
      ),
      'expired' => HubDeviceAuthorizationExpired(
        interval: _interval(json['interval']),
      ),
      'enrolled' => HubDeviceAuthorizationEnrolled(
        interval: _interval(json['interval']),
      ),
      'retry_later' => const HubDeviceAuthorizationRetryLater(),
      final status => throw FormatException(
        'Unknown device authorization poll status: $status',
      ),
    };
  }
}

final class HubDeviceAuthorizationPending extends HubDeviceAuthorizationPoll {
  const HubDeviceAuthorizationPending({required this.interval});
  final int interval;
}

final class HubDeviceAuthorizationSlowDown extends HubDeviceAuthorizationPoll {
  const HubDeviceAuthorizationSlowDown({required this.interval});
  final int interval;
}

final class HubDeviceAuthorizationApproved extends HubDeviceAuthorizationPoll {
  const HubDeviceAuthorizationApproved({
    required this.interval,
    required this.enrollmentToken,
  });
  final int interval;
  final String enrollmentToken;
}

final class HubDeviceAuthorizationDenied extends HubDeviceAuthorizationPoll {
  const HubDeviceAuthorizationDenied({required this.interval});
  final int interval;
}

final class HubDeviceAuthorizationExpired extends HubDeviceAuthorizationPoll {
  const HubDeviceAuthorizationExpired({required this.interval});
  final int interval;
}

final class HubDeviceAuthorizationEnrolled extends HubDeviceAuthorizationPoll {
  const HubDeviceAuthorizationEnrolled({required this.interval});
  final int interval;
}

final class HubDeviceAuthorizationRetryLater
    extends HubDeviceAuthorizationPoll {
  const HubDeviceAuthorizationRetryLater();
}

abstract interface class HubCloudDeviceAuthorization {
  Future<HubDeviceAuthorization> start(String hubUrl, String displayName);

  Future<HubDeviceAuthorizationPoll> poll(
    String hubUrl,
    String deviceCode,
    Duration timeout,
  );
}

final class HubCloudDeviceAuthorizationClient
    implements HubCloudDeviceAuthorization {
  HubCloudDeviceAuthorizationClient({
    http.Client? client,
    this.startTimeout = hubDeviceAuthorizationStartTimeout,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration startTimeout;

  Future<void> close() async {
    if (_ownsClient) _client.close();
  }

  @override
  Future<HubDeviceAuthorization> start(
    String hubUrl,
    String displayName,
  ) async {
    final uri = hubDeviceAuthorizationEndpoint(
      hubUrl,
      '/api/device-authorizations/',
    );
    try {
      final response = await _client
          .post(
            uri,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'displayName': displayName}),
          )
          .timeout(startTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HubDeviceAuthorizationException(
          'Cloud registration failed (${response.statusCode})',
        );
      }
      return HubDeviceAuthorization.fromJson(jsonDecode(response.body));
    } on TimeoutException catch (error) {
      throw HubDeviceAuthorizationException(
        'Cloud registration start timed out',
        error,
      );
    }
  }

  @override
  Future<HubDeviceAuthorizationPoll> poll(
    String hubUrl,
    String deviceCode,
    Duration timeout,
  ) async {
    final uri = hubDeviceAuthorizationEndpoint(
      hubUrl,
      '/api/device-authorizations/poll',
    );
    late final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'deviceCode': deviceCode}),
          )
          .timeout(timeout);
    } on Object {
      return const HubDeviceAuthorizationRetryLater();
    }
    if (response.statusCode == 408 ||
        response.statusCode == 425 ||
        response.statusCode == 429 ||
        response.statusCode >= 500) {
      return const HubDeviceAuthorizationRetryLater();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HubDeviceAuthorizationException(
        'Cloud registration poll failed (${response.statusCode})',
      );
    }
    return HubDeviceAuthorizationPoll.fromJson(jsonDecode(response.body));
  }
}

Uri hubDeviceAuthorizationEndpoint(String hubUrl, String pathname) {
  late final Uri url;
  try {
    url = Uri.parse(hubUrl);
  } on FormatException {
    throw const HubDeviceAuthorizationException(
      'Hub URL must be an HTTP or HTTPS origin without credentials or a query',
    );
  }
  if ((url.scheme != 'http' && url.scheme != 'https') ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty ||
      url.hasQuery ||
      url.hasFragment) {
    throw const HubDeviceAuthorizationException(
      'Hub URL must be an HTTP or HTTPS origin without credentials or a query',
    );
  }
  final basePath = url.path.endsWith('/')
      ? url.path.substring(0, url.path.length - 1)
      : url.path;
  return url.replace(path: '$basePath$pathname');
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  return value.cast<String, Object?>();
}

String _minLength(Object? value, int length, String field) {
  if (value is! String || value.length < length) {
    throw FormatException('$field must contain at least $length characters');
  }
  return value;
}

Uri _activationUri(Object? value, String field) {
  if (value is! String) throw FormatException('$field must be a URL');
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw FormatException('$field must be an HTTP or HTTPS URL');
  }
  return uri;
}

DateTime _dateTime(Object? value, String field) {
  if (value is! String ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$',
      ).hasMatch(value)) {
    throw FormatException('$field must be a date-time');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$field must be a date-time');
  }
  return parsed;
}

int _interval(Object? value) {
  if (value is! int || value < 5) {
    throw const FormatException('interval must be an integer of at least 5');
  }
  return value;
}
