import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

const int _maxDnsLabelLength = 63;
const int _hashSuffixLength = 8;

final class ServiceProxyUrls {
  const ServiceProxyUrls({
    required this.localProxyUrl,
    required this.publicProxyUrl,
  });

  final String? localProxyUrl;
  final String? publicProxyUrl;
  String? get proxyUrl => publicProxyUrl ?? localProxyUrl;
}

String buildServiceProxyLabel({
  required String projectSlug,
  required String? branchName,
  required String scriptName,
}) {
  final labels = <String>[_hostnameLabel(scriptName)];
  if (branchName != null && branchName != 'main' && branchName != 'master') {
    labels.add(_hostnameLabel(branchName));
  }
  labels.add(_hostnameLabel(projectSlug));
  return _capDnsLabel(labels.join('--'));
}

String buildLocalServiceHostname({
  required String projectSlug,
  required String? branchName,
  required String scriptName,
}) =>
    '${buildServiceProxyLabel(projectSlug: projectSlug, branchName: branchName, scriptName: scriptName)}.localhost';

String buildPublicServiceHostname({
  required String publicBaseUrl,
  required String projectSlug,
  required String? branchName,
  required String scriptName,
}) {
  final base = Uri.parse(publicBaseUrl);
  if (!base.hasScheme || base.host.isEmpty) {
    throw FormatException('Invalid public service base URL: $publicBaseUrl');
  }
  return '${buildServiceProxyLabel(projectSlug: projectSlug, branchName: branchName, scriptName: scriptName)}.${base.host}';
}

String buildPublicServiceProxyUrl({
  required String publicBaseUrl,
  required String projectSlug,
  required String? branchName,
  required String scriptName,
}) {
  final base = Uri.parse(publicBaseUrl);
  final hostname = buildPublicServiceHostname(
    publicBaseUrl: publicBaseUrl,
    projectSlug: projectSlug,
    branchName: branchName,
    scriptName: scriptName,
  );
  return Uri(
    scheme: base.scheme,
    host: hostname,
    port: base.hasPort ? base.port : null,
  ).toString();
}

ServiceProxyUrls projectServiceProxyUrls({
  required String projectSlug,
  required String? branchName,
  required String scriptName,
  required int? daemonPort,
  String? publicBaseUrl,
}) {
  final hostname = buildLocalServiceHostname(
    projectSlug: projectSlug,
    branchName: branchName,
    scriptName: scriptName,
  );
  return ServiceProxyUrls(
    localProxyUrl: daemonPort == null
        ? null
        : Uri(scheme: 'http', host: hostname, port: daemonPort).toString(),
    publicProxyUrl: publicBaseUrl == null
        ? null
        : buildPublicServiceProxyUrl(
            publicBaseUrl: publicBaseUrl,
            projectSlug: projectSlug,
            branchName: branchName,
            scriptName: scriptName,
          ),
  );
}

String _hostnameLabel(String value) {
  final decomposed = unorm.nfkd(value.toLowerCase());
  final withoutCombining = decomposed.replaceAll(
    RegExp(r'[\u0300-\u036f]'),
    '',
  );
  final normalized = withoutCombining
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return normalized.isEmpty ? 'untitled' : normalized;
}

String _capDnsLabel(String label) {
  if (label.length <= _maxDnsLabelLength) return label;
  final suffix = sha256
      .convert(utf8.encode(label))
      .toString()
      .substring(0, _hashSuffixLength);
  final maxPrefix = _maxDnsLabelLength - _hashSuffixLength - 2;
  final prefix = label.substring(0, maxPrefix).replaceFirst(RegExp(r'-+$'), '');
  return '${prefix.isEmpty ? 'svc' : prefix}--$suffix';
}
