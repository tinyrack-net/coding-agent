/// Frozen Paseo 0.2.0 agent attention notification payload builder.
///
/// The daemon raises a push notification whenever an agent finishes, errors, or
/// blocks on a permission prompt. Both the daemon and the client need the exact
/// same title/body/data triple: the daemon renders it, the client parses
/// `data` to route a cold start straight at the originating agent. That is why
/// this lives in the wire-contract package rather than in either endpoint.
///
/// Ported from `packages/protocol/src/agent-attention-notification.ts`.
library;

import 'dart:convert';

import 'messages/agent.dart';
import 'timeline/timeline_item.dart';

/// Notification bodies are truncated to this many UTF-16 code units.
///
/// Kept private to mirror the frozen module, where the constant is not
/// exported; callers observe it only through [buildAgentAttentionNotificationPayload].
const int _notificationPreviewLimit = 220;

/// Categories a pending permission prompt can fall into.
///
/// Upstream models this as the string union
/// `"tool" | "plan" | "question" | "mode" | "other"`. The enum names are the
/// wire values verbatim, so [Enum.name] is the encoder and
/// `values.byName` the decoder — the same convention the rest of this package
/// uses for `AgentRunState` and [AgentAttentionReason].
enum NotificationPermissionKind { tool, plan, question, mode, other }

/// A pending permission prompt, reduced to what a notification body needs.
///
/// This is the daemon's in-memory `pendingPermissions` entry. It is declared
/// here (rather than reused from the timeline `PermissionItem`) because the two
/// shapes are genuinely different: `PermissionItem` is the *timeline* rendering
/// of a prompt (`permissionId`/`toolName`/`status`/`detail`), while this is the
/// *provider* request that produced it.
final class NotificationPermissionRequest {
  const NotificationPermissionRequest({
    required this.id,
    required this.provider,
    required this.name,
    required this.kind,
    this.title,
    this.description,
    this.input,
    this.metadata,
  });

  /// Provider-scoped identifier used to resolve the prompt.
  final String id;

  /// Provider that raised the prompt (`claude`, `codex`, ...).
  final String provider;

  /// Tool or capability name being requested.
  final String name;

  /// What sort of prompt this is.
  final NotificationPermissionKind kind;

  /// Human-facing headline, when the provider supplied one.
  final String? title;

  /// Human-facing detail, when the provider supplied one.
  final String? description;

  /// Raw tool input, used as a last-resort notification body.
  final Map<String, Object?>? input;

  /// Provider metadata, used after [input] as a last-resort body.
  final Map<String, Object?>? metadata;

  static NotificationPermissionRequest fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    if (kind is! String) {
      throw const FormatException('kind must be a string');
    }
    return NotificationPermissionRequest(
      id: _requiredString(json, 'id'),
      provider: _requiredString(json, 'provider'),
      name: _requiredString(json, 'name'),
      kind: _permissionKind(kind),
      title: json['title'] as String?,
      description: json['description'] as String?,
      input: (json['input'] as Map?)?.cast<String, Object?>(),
      metadata: (json['metadata'] as Map?)?.cast<String, Object?>(),
    );
  }

  /// Optional fields are omitted rather than emitted as `null`, matching how
  /// `JSON.stringify` drops `undefined` members of the frozen interface.
  Map<String, Object?> toJson() => {
    'id': id,
    'provider': provider,
    'name': name,
    'kind': kind.name,
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (input != null) 'input': input,
    if (metadata != null) 'metadata': metadata,
  };
}

/// The `data` bag delivered alongside the notification.
///
/// Clients read this to open the right destination even from a cold start,
/// which is why [workspaceId] travels with the agent id.
final class AgentAttentionNotificationData {
  const AgentAttentionNotificationData({
    required this.serverId,
    required this.agentId,
    required this.reason,
    this.workspaceId,
    this.extra = const {},
  });

  /// Daemon/server the agent belongs to.
  final String serverId;

  /// Workspace that owns the agent.
  ///
  /// Nullable because the frozen `AgentAttentionNotificationData` declares
  /// `workspaceId?: string` even though the builder input requires it — older
  /// payloads in flight may lack it.
  final String? workspaceId;

  /// Agent whose state changed.
  final String agentId;

  /// Why the notification fired.
  final AgentAttentionReason reason;

  /// Unrecognised keys preserved verbatim.
  ///
  /// The frozen interface carries `[key: string]: unknown`, so push transports
  /// are free to staple extra fields on. Round-tripping them keeps this
  /// decoder from silently dropping data.
  ///
  /// Deviation: extras are re-emitted *after* the four known keys, so a payload
  /// whose extras were interleaved with known keys round-trips with the same
  /// entries but a normalised key order.
  final Map<String, Object?> extra;

  static AgentAttentionNotificationData fromJson(Map<String, Object?> json) {
    const known = {'serverId', 'workspaceId', 'agentId', 'reason'};
    return AgentAttentionNotificationData(
      serverId: _requiredString(json, 'serverId'),
      workspaceId: json['workspaceId'] as String?,
      agentId: _requiredString(json, 'agentId'),
      reason: _attentionReason(json['reason']),
      extra: {
        for (final entry in json.entries)
          if (!known.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  /// Emits `serverId, workspaceId?, agentId, reason` in that order, byte-for-byte
  /// matching the object literal in the frozen builder. `workspaceId` is omitted
  /// when null because `JSON.stringify` omits `undefined` members.
  Map<String, Object?> toJson() => {
    'serverId': serverId,
    if (workspaceId != null) 'workspaceId': workspaceId,
    'agentId': agentId,
    'reason': reason.name,
    ...extra,
  };
}

/// A ready-to-deliver push notification.
final class AgentAttentionNotificationPayload {
  const AgentAttentionNotificationPayload({
    required this.title,
    required this.body,
    required this.data,
  });

  /// Short headline, derived solely from the reason.
  final String title;

  /// Preview of the assistant message or permission prompt, or a fallback.
  final String body;

  /// Routing information for the client.
  final AgentAttentionNotificationData data;

  static AgentAttentionNotificationPayload fromJson(Map<String, Object?> json) {
    final data = json['data'];
    if (data is! Map) {
      throw const FormatException('data must be an object');
    }
    return AgentAttentionNotificationPayload(
      title: _requiredString(json, 'title'),
      body: _requiredString(json, 'body'),
      data: AgentAttentionNotificationData.fromJson(
        data.cast<String, Object?>(),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'title': title,
    'body': body,
    'data': data.toJson(),
  };
}

/// Recovers the newest assistant message from a timeline.
///
/// Providers stream assistant content as consecutive chunks, so the newest
/// message is the *trailing run* of assistant items, concatenated in order —
/// not just the final item. Scanning stops at the first non-assistant item
/// encountered after at least one chunk was collected.
///
/// Deviation: the frozen helper accepts a structural
/// `{ type: string; text?: string }` and skips assistant items whose `text` is
/// not a string. [AssistantMessageItem.text] is non-nullable here, so that case
/// is unrepresentable; `TimelineItem.fromJson` already coerces a missing `text`
/// to `''`, which this function then returns as an empty message rather than
/// null.
String? findLatestAssistantMessageFromTimeline(List<TimelineItem> timeline) {
  final chunks = <String>[];
  for (var i = timeline.length - 1; i >= 0; i -= 1) {
    final item = timeline[i];
    if (item is! AssistantMessageItem) {
      if (chunks.isNotEmpty) {
        break;
      }
      continue;
    }
    chunks.add(item.text);
  }

  if (chunks.isEmpty) {
    return null;
  }

  return chunks.reversed.join();
}

/// Returns the most recently inserted pending permission request.
///
/// Relies on insertion order, exactly as the frozen helper relies on JS `Map`
/// iteration order. Dart's default `Map` literal/`LinkedHashMap` preserves
/// insertion order, so the two agree.
NotificationPermissionRequest? findLatestPermissionRequest(
  Map<String, NotificationPermissionRequest> pendingPermissions,
) {
  NotificationPermissionRequest? latest;
  for (final request in pendingPermissions.values) {
    latest = request;
  }
  return latest;
}

/// Builds the notification for an agent that needs the user's attention.
///
/// [workspaceId] is required — mirroring the frozen input interface — because a
/// notification that cannot name its workspace cannot open a cold destination.
/// [assistantMessage] is consulted only for [AgentAttentionReason.finished] and
/// [permissionRequest] only for [AgentAttentionReason.permission]; errors always
/// use the fallback body.
AgentAttentionNotificationPayload buildAgentAttentionNotificationPayload({
  required AgentAttentionReason reason,
  required String serverId,
  required String workspaceId,
  required String agentId,
  String? assistantMessage,
  NotificationPermissionRequest? permissionRequest,
}) {
  final preview = switch (reason) {
    AgentAttentionReason.finished => _buildNotificationPreview(
      assistantMessage,
    ),
    AgentAttentionReason.permission => _buildNotificationPreview(
      _buildPermissionDetails(permissionRequest),
    ),
    AgentAttentionReason.error => null,
  };

  return AgentAttentionNotificationPayload(
    title: _resolveAgentAttentionTitle(reason),
    body: preview ?? _resolveAgentAttentionFallbackBody(reason),
    data: AgentAttentionNotificationData(
      serverId: serverId,
      workspaceId: workspaceId,
      agentId: agentId,
      reason: reason,
    ),
  );
}

String _resolveAgentAttentionTitle(AgentAttentionReason reason) =>
    switch (reason) {
      AgentAttentionReason.permission => 'Agent needs permission',
      AgentAttentionReason.error => 'Agent needs attention',
      AgentAttentionReason.finished => 'Agent finished',
    };

String _resolveAgentAttentionFallbackBody(AgentAttentionReason reason) =>
    switch (reason) {
      AgentAttentionReason.permission => 'Permission requested.',
      AgentAttentionReason.error => 'Encountered an error.',
      AgentAttentionReason.finished => 'Finished working.',
    };

/// Collapses whitespace runs into single spaces and trims the ends.
///
/// Dart's `RegExp` follows ECMA-262, so `\s` covers the same set as the frozen
/// regex — including NBSP, ogham space and U+FEFF.
String _normalizeNotificationText(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Truncates to [limit] UTF-16 code units, appending an ellipsis.
///
/// Deviation (faithful): like the frozen `String.prototype.slice`, this cuts on
/// a UTF-16 boundary and can therefore split a surrogate pair, leaving a lone
/// surrogate at the end. Dart `String.substring` indexes code units too, so the
/// output is identical — including that lone surrogate.
String _truncateNotificationText(String text, int limit) {
  if (text.length <= limit) {
    return text;
  }
  final trimmed = text.substring(0, limit - 3 < 0 ? 0 : limit - 3).trimRight();
  return trimmed.isNotEmpty ? '$trimmed...' : text.substring(0, limit);
}

/// Strips Markdown syntax while keeping the prose (and code) content.
///
/// The rewrite order is load-bearing and reproduced exactly: list prefixes are
/// stripped before thematic breaks, so `- - -` becomes `- -` rather than
/// vanishing.
String _stripMarkdownToText(String markdown) {
  var text = markdown.replaceAll('\r\n', '\n');

  // Strip fenced code markers but keep the code content itself.
  text = text.replaceAll(RegExp(r'^\s*```[^\n]*$', multiLine: true), '');
  text = text.replaceAll(RegExp(r'^\s*~~~[^\n]*$', multiLine: true), '');

  // Markdown links/images.
  text = _replaceGroup(text, RegExp(r'!\[([^\]]*)\]\((?:[^()\\]|\\.)*\)'));
  text = _replaceGroup(text, RegExp(r'\[([^\]]+)\]\((?:[^()\\]|\\.)*\)'));

  // Structural prefixes.
  text = text.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true), '');
  text = text.replaceAll(RegExp(r'^\s{0,3}>+\s?', multiLine: true), '');
  text = text.replaceAll(
    RegExp(r'^\s{0,3}(?:[*+-]|\d+\.)\s+', multiLine: true),
    '',
  );
  text = text.replaceAll(
    RegExp(r'^\s{0,3}(?:[-*_]\s*){3,}$', multiLine: true),
    '',
  );

  // Inline markdown markers.
  text = _replaceGroup(text, RegExp(r'`([^`]+)`'));
  text = _replaceGroup(text, RegExp(r'\*\*([^*]+)\*\*'));
  text = _replaceGroup(text, RegExp(r'__([^_]+)__'));
  text = _replaceGroup(text, RegExp(r'\*([^*\n]+)\*'));
  text = _replaceGroup(text, RegExp(r'_([^_\n]+)_'));
  text = _replaceGroup(text, RegExp(r'~~([^~]+)~~'));

  // Angle-bracketed URL autolinks.
  text = _replaceGroup(text, RegExp(r'<([^>\n]+)>'));

  return text;
}

/// Global replace of [pattern] with its first capture group, matching the
/// frozen `replace(/.../g, "$1")` calls.
String _replaceGroup(String text, RegExp pattern) =>
    text.replaceAllMapped(pattern, (match) => match.group(1) ?? '');

String? _buildNotificationPreview(String? text) {
  // The frozen guard is `if (!text)`, so an empty string is treated as absent.
  if (text == null || text.isEmpty) {
    return null;
  }

  final normalized = _normalizeNotificationText(_stripMarkdownToText(text));
  if (normalized.isEmpty) {
    return null;
  }

  return _truncateNotificationText(normalized, _notificationPreviewLimit);
}

/// Best-effort JSON encode; returns null when the value cannot be encoded.
///
/// Deviation: `JSON.stringify` renders the JS number `1.0` as `1`, while Dart
/// renders the double `1.0` as `1.0`. Integral values held as Dart `int` encode
/// identically; only a deliberately-double integral value differs.
String? _safeStringify(Object? value) {
  try {
    return jsonEncode(value);
  } on Object {
    return null;
  }
}

/// Derives the most informative one-line description of a permission prompt.
///
/// Preference order matches the frozen helper: title, then title + description,
/// then a JSON preview of `input`, then of `metadata`, then the tool name, and
/// finally the prompt kind.
String? _buildPermissionDetails(NotificationPermissionRequest? request) {
  if (request == null) {
    return null;
  }

  final title = request.title?.trim();
  final description = request.description?.trim();
  final details = <String>[];

  // `if (title)` in JS: a whitespace-only title trims to "" and is falsy.
  if (title != null && title.isNotEmpty) {
    details.add(title);
  }
  if (description != null && description.isNotEmpty && description != title) {
    details.add(description);
  }
  if (details.isNotEmpty) {
    return details.join(' - ');
  }

  // `request.input ? ... : null` is truthiness on the object, not on its size,
  // so an empty map still yields the "{}" preview and short-circuits metadata.
  final inputPreview = request.input != null
      ? _safeStringify(request.input)
      : null;
  if (inputPreview != null && inputPreview.isNotEmpty) {
    return inputPreview;
  }

  final metadataPreview = request.metadata != null
      ? _safeStringify(request.metadata)
      : null;
  if (metadataPreview != null && metadataPreview.isNotEmpty) {
    return metadataPreview;
  }

  // `request.name?.trim() || request.kind`.
  final name = request.name.trim();
  return name.isNotEmpty ? name : request.kind.name;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('$key must be a string');
  }
  return value;
}

NotificationPermissionKind _permissionKind(String value) {
  try {
    return NotificationPermissionKind.values.byName(value);
  } on ArgumentError {
    throw FormatException('Unknown permission kind: $value');
  }
}

AgentAttentionReason _attentionReason(Object? value) {
  if (value is! String) {
    throw const FormatException('reason must be a string');
  }
  try {
    return AgentAttentionReason.values.byName(value);
  } on ArgumentError {
    throw FormatException('Unknown attention reason: $value');
  }
}
