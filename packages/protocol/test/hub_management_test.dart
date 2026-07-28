import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  const connected = HubRelationshipStatus(
    state: HubConnectionState.connected,
    daemonId: 'daemon-1',
    hubOrigin: 'https://hub.example',
    scopes: ['hub.execution.*'],
    connectedAt: '2026-07-13T00:00:00.000Z',
    lastError: null,
  );

  test('trusted Hub management requests use exact frozen shapes', () {
    final requests = <HubManagementDaemonRequest>[
      const HubManagementDaemonConnectRequest(
        requestId: 'r1',
        hubUrl: 'https://hub.example',
        token: 'token',
      ),
      const HubManagementDaemonGetStatusRequest(requestId: 'r2'),
      const HubManagementDaemonDisconnectRequest(requestId: 'r3', force: true),
      const HubManagementDaemonDisconnectRequest(requestId: 'r4'),
    ];

    for (final request in requests) {
      expect(
        HubManagementDaemonRequest.fromJson(request.toJson()).toJson(),
        request.toJson(),
      );
    }
    expect(requests.last.toJson().containsKey('force'), isFalse);
  });

  test('relationship status and responses round-trip nullable fields', () {
    final responses = <HubManagementDaemonResponse>[
      const HubManagementDaemonConnectResponse(
        requestId: 'r1',
        status: connected,
      ),
      const HubManagementDaemonGetStatusResponse(
        requestId: 'r2',
        status: HubRelationshipStatus.notConnected(),
      ),
      const HubManagementDaemonDisconnectResponse(
        requestId: 'r3',
        status: HubRelationshipStatus(
          state: HubConnectionState.disconnecting,
          daemonId: 'daemon-1',
          hubOrigin: 'https://hub.example',
          scopes: ['hub.execution.*'],
          connectedAt: null,
          lastError: 'offline',
        ),
        warning: 'pending',
      ),
    ];

    expect(
      HubManagementDaemonConnectResponse.fromJson(
        responses[0].toJson(),
      ).toJson(),
      responses[0].toJson(),
    );
    expect(
      HubManagementDaemonGetStatusResponse.fromJson(
        responses[1].toJson(),
      ).toJson(),
      responses[1].toJson(),
    );
    expect(
      HubManagementDaemonDisconnectResponse.fromJson(
        responses[2].toJson(),
      ).toJson(),
      responses[2].toJson(),
    );
  });

  test('Hub management boundaries reject malformed values', () {
    expect(() => HubConnectionState.fromWire('future'), throwsFormatException);
    expect(
      () => HubManagementDaemonRequest.fromJson(const {
        'type': 'unknown',
        'requestId': 'r',
      }),
      throwsFormatException,
    );
    expect(
      () => HubManagementDaemonConnectRequest.fromJson(const {
        'type': HubManagementDaemonConnectRequest.type,
        'requestId': 'r',
        'hubUrl': 1,
        'token': 'token',
      }),
      throwsFormatException,
    );
    expect(
      () => HubRelationshipStatus.fromJson(const {
        'state': 'connected',
        'daemonId': null,
        'hubOrigin': null,
        'scopes': [1],
        'connectedAt': null,
        'lastError': null,
      }),
      throwsFormatException,
    );
    expect(
      () => HubManagementDaemonDisconnectResponse.fromJson({
        'type': HubManagementDaemonDisconnectResponse.type,
        'payload': {
          'requestId': 'r',
          'status': const HubRelationshipStatus.notConnected().toJson(),
          'warning': 4,
        },
      }),
      throwsFormatException,
    );
  });
}
