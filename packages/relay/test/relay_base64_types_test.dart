import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  test('base64 codec accepts standard and unpadded URL-safe input', () {
    final bytes = Uint8List.fromList([251, 255, 239, 1]);
    expect(relayBase64Encode(bytes), '+//vAQ==');
    expect(relayBase64Decode('+//vAQ=='), bytes);
    expect(relayBase64Decode('  -__vAQ  '), bytes);
  });

  test('relay session attachment preserves v1/v2 wire contracts', () {
    final attachment = RelaySessionAttachment.fromJson({
      'serverId': 'server-1',
      'role': 'client',
      'version': '2',
      'connectionId': 'connection-1',
      'createdAt': 42,
    });
    expect(attachment.role, RelayConnectionRole.client);
    expect(attachment.toJson(), {
      'serverId': 'server-1',
      'role': 'client',
      'version': '2',
      'connectionId': 'connection-1',
      'createdAt': 42,
    });

    expect(
      const RelaySessionAttachment(
        serverId: 'server-1',
        role: RelayConnectionRole.server,
        createdAt: 7,
      ).toJson(),
      {'serverId': 'server-1', 'role': 'server', 'createdAt': 7},
    );
    expect(() => RelayConnectionRole.parse('peer'), throwsFormatException);
    expect(
      () => RelaySessionAttachment.fromJson({
        'serverId': 'server-1',
        'role': 'server',
        'version': '3',
        'createdAt': 0,
      }),
      throwsFormatException,
    );
  });
}
