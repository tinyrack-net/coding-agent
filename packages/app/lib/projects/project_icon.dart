import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/daemon_client.dart';
import '../state/daemon_providers.dart';

const _projectIconColors = <Color>[
  Color(0xFF8B5CF6),
  Color(0xFF0EA5E9),
  Color(0xFF10B981),
  Color(0xFFF97316),
  Color(0xFFEC4899),
  Color(0xFF6366F1),
  Color(0xFF14B8A6),
  Color(0xFFEF4444),
  Color(0xFFEAB308),
  Color(0xFF3B82F6),
];

Color deriveProjectIconColor(String projectKey) {
  var hash = 0;
  for (final rune in projectKey.runes) {
    // JavaScript's `for...of` iterates Unicode scalars while charCodeAt(0)
    // returns the leading UTF-16 unit. Mirror the frozen implementation.
    final codeUnit = rune <= 0xFFFF ? rune : 0xD800 + ((rune - 0x10000) >> 10);
    hash = (hash * 31 + codeUnit) & 0xFFFFFFFF;
  }
  return _projectIconColors[hash % _projectIconColors.length];
}

final class ProjectIconTarget {
  const ProjectIconTarget({required this.serverId, required this.cwd});

  final String serverId;
  final String cwd;

  @override
  bool operator ==(Object other) =>
      other is ProjectIconTarget &&
      serverId == other.serverId &&
      cwd == other.cwd;

  @override
  int get hashCode => Object.hash(serverId, cwd);
}

final _projectIconConnectionProvider = StreamProvider.autoDispose
    .family<DaemonConnectionState, String>((ref, serverId) {
      final client = ref.watch(hostRuntimeClientsProvider)[serverId];
      if (client == null) {
        return Stream.value(DaemonConnectionState.disconnected);
      }
      return (() async* {
        yield client.currentState;
        yield* client.connectionState;
      })();
    });

final class _ProjectIconCache {
  final values = <ProjectIconTarget, ProjectIcon?>{};
}

final _projectIconCacheProvider = Provider<_ProjectIconCache>(
  (ref) => _ProjectIconCache(),
);

/// Frozen Paseo project-icon query semantics: request only while connected,
/// retain the result indefinitely, and retry when that host reconnects.
final projectIconProvider =
    FutureProvider.family<ProjectIcon?, ProjectIconTarget>((ref, target) async {
      final cwd = target.cwd.trim();
      if (cwd.isEmpty) return null;
      final normalized = ProjectIconTarget(serverId: target.serverId, cwd: cwd);
      final cache = ref.watch(_projectIconCacheProvider).values;
      if (cache.containsKey(normalized)) return cache[normalized];
      final client = ref.watch(hostRuntimeClientsProvider)[target.serverId];
      final connection = ref.watch(
        _projectIconConnectionProvider(target.serverId),
      );
      if (client == null ||
          connection.value != DaemonConnectionState.connected) {
        return null;
      }
      final response = await client.requestProjectIcon(cwd);
      cache[normalized] = response.icon;
      return response.icon;
    });

class ProjectIconView extends ConsumerWidget {
  const ProjectIconView({
    super.key,
    required this.serverId,
    required this.cwd,
    required this.projectKey,
    required this.projectName,
    required this.size,
    required this.borderRadius,
    required this.fontSize,
  });

  final String serverId;
  final String cwd;
  final String projectKey;
  final String projectName;
  final double size;
  final double borderRadius;
  final double fontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = ref
        .watch(
          projectIconProvider(ProjectIconTarget(serverId: serverId, cwd: cwd)),
        )
        .value;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: _iconImage(icon) ?? _fallback(),
        ),
      ),
    );
  }

  Widget _fallback() {
    final trimmed = projectName.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
    return ColoredBox(
      key: ValueKey('project-icon-fallback-$projectKey'),
      color: deriveProjectIconColor(projectKey),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget? _iconImage(ProjectIcon? icon) {
    if (icon == null) return null;
    Uint8List bytes;
    try {
      bytes = base64Decode(icon.data);
    } on FormatException {
      return null;
    }
    if (icon.mimeType == 'image/svg+xml') {
      try {
        return SvgPicture.string(
          utf8.decode(bytes),
          key: ValueKey('project-icon-image-$projectKey'),
          fit: BoxFit.cover,
        );
      } on FormatException {
        return null;
      }
    }
    return Image.memory(
      bytes,
      key: ValueKey('project-icon-image-$projectKey'),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => _fallback(),
    );
  }
}
