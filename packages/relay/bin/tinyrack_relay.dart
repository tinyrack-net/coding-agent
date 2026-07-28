import 'dart:async';
import 'dart:io';

import 'package:tinyrack_relay/tinyrack_relay.dart';

Future<void> main(List<String> arguments) async {
  final options = _RelayOptions.parse(arguments, Platform.environment);
  final server = TinyrackRelayServer(
    address: options.address,
    port: options.port,
    upstream: options.upstream,
    log: stderr.writeln,
  );
  await server.start();
  stdout.writeln(
    'Tinyrack relay listening on ${server.httpUri}'
    '${options.upstream == null ? '' : ' -> ${options.upstream}'}',
  );

  final stopping = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  void stop(ProcessSignal _) {
    if (!stopping.isCompleted) stopping.complete();
  }

  if (!Platform.isWindows) {
    subscriptions.add(ProcessSignal.sigterm.watch().listen(stop));
  }
  subscriptions.add(ProcessSignal.sigint.watch().listen(stop));
  await stopping.future;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  await server.close();
}

final class _RelayOptions {
  const _RelayOptions({
    required this.address,
    required this.port,
    this.upstream,
  });

  final InternetAddress address;
  final int port;
  final Uri? upstream;

  static _RelayOptions parse(
    List<String> arguments,
    Map<String, String> environment,
  ) {
    var listen = environment['TINYRACK_RELAY_LISTEN'] ?? '127.0.0.1:8787';
    var upstream = environment['TINYRACK_RELAY_UPSTREAM'];
    for (var index = 0; index < arguments.length; index += 1) {
      switch (arguments[index]) {
        case '--listen':
          if (index + 1 >= arguments.length) {
            throw const FormatException('--listen requires host:port');
          }
          listen = arguments[++index];
        case '--upstream':
          if (index + 1 >= arguments.length) {
            throw const FormatException('--upstream requires an origin URL');
          }
          upstream = arguments[++index];
        default:
          throw FormatException('Unknown argument: ${arguments[index]}');
      }
    }
    final separator = listen.lastIndexOf(':');
    if (separator <= 0) {
      throw const FormatException('Listen address must be host:port');
    }
    final host = listen.substring(0, separator);
    final port = int.tryParse(listen.substring(separator + 1));
    if (port == null || port < 0 || port > 65535) {
      throw const FormatException('Listen port is invalid');
    }
    return _RelayOptions(
      address: InternetAddress(host),
      port: port,
      upstream: upstream == null || upstream.trim().isEmpty
          ? null
          : Uri.parse(upstream),
    );
  }
}
