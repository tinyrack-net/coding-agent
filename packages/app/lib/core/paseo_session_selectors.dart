/// Port of five frozen Paseo 0.2.0 modules that sit on the read side of the
/// session: what the app *derives* from a session snapshot, and the two
/// stateful helpers that feed it.
///
/// - `utils/assistant-image-metadata.ts` — the LRU caches behind assistant
///   image sizing: measured intrinsic dimensions keyed by every alias a source
///   can be spelled with, the markdown image-source parse cache, and the
///   message-height estimate a virtualized chat list falls back to.
/// - `utils/test-daemon-connection.ts` — building a daemon client config from a
///   stored [HostConnection] and probing it once, turning the many ways a
///   connection can fail into one reportable reason.
/// - `types/agent-activity.ts` — the ACP session-update union and
///   [groupActivities], which collapses a raw activity log into the renderable
///   run of grouped text blocks and merged tool calls.
/// - `stores/session-store-hooks/selectors.ts` — the pure selectors over a
///   sessions snapshot (workspace lookup, hydration gating, the cross-host
///   workspace structure) plus the sidebar-order composition applied on top.
/// - `dictation/dictation-stream-sender.ts` — the non-React state machine that
///   buffers base64 PCM segments and replays them into a dictation stream.
///
/// ## Reuse
///
/// This library re-declares nothing the repo already ports:
///
/// - **[AssistantImageHeightEstimator]** in `core/paseo_more_utils.dart` exists
///   *because* `assistant-image-metadata.ts` was unported. This library is that
///   port, and [AssistantImageMetadataCache.estimateMessageHeightFromCache] is
///   written to that exact `int? Function(String markdown)` shape, so
///   `AssistantMessageHeightEstimateCache(imageFallback: cache.estimateMessageHeightFromCache)`
///   restores upstream's hard-wired `markdownEstimate ?? imageEstimate` chain
///   without either module editing the other.
/// - [resolveAssistantImageSource] and its [AssistantImageDirectSource] /
///   [AssistantImageFileRpcSource] arms from `core/paseo_ui_utils.dart`, which
///   already ports `utils/assistant-image-source.ts`.
/// - [createImageSourceCacheKey] from `attachments/paseo_attachment_rules.dart`,
///   which already ports `attachments/utils.ts` — including the data-URL
///   fingerprinting that keeps a megabyte of base64 out of a cache key.
/// - [HostConnection] and its four arms, [buildDaemonWebSocketUrl],
///   [buildRelayWebSocketUrl], `shouldUseTlsForDefaultHostedRelay`,
///   [WorkspaceDescriptor], [WorkspaceProjectDescriptor] and
///   [WorkspaceProjectKind] from `package:agent_protocol`.
/// - [LocalTransportTarget] / [LocalTransportType] from
///   `keyboard/paseo_browser_shortcuts.dart`, which ports
///   `desktop/daemon/desktop-daemon-transport.ts`.
/// - [resolveWorkspaceMapKeyByIdentity] from
///   `workspace/paseo_workspace_paths.dart`, the port of
///   `utils/workspace-identity.ts` that upstream's selectors import directly.
/// - [WorkspaceStructureProject] / [WorkspaceStructureHostPlacement] and
///   [canCreateWorktreeForProjectKind] from `core/paseo_app_misc.dart`.
/// - [DesktopBadgeWorkspaceStatus] and [projectDisplayNameFromProjectId] from
///   `core/paseo_small_utils.dart`.
/// - [ComposerTranslator] from `composer/composer_input_labels.dart` as the
///   `i18n.t` stand-in.
///
/// ## Ported-in dependencies
///
/// `projects/workspace-structure.ts` is outside this cluster and has no Dart
/// home; only its *types* were ported (into `core/paseo_app_misc.dart`, whose
/// author could not reach the builder). Its builder is reproduced here as the
/// private `_buildWorkspaceStructureProjects`, exactly as
/// `core/paseo_ui_utils.dart` carries a private copy of
/// `file-explorer/preview-target.ts`. It is private so this library does not
/// claim to own another module's public API; when `workspace-structure.ts` gets
/// a real home, the private copy is the thing to delete.
///
/// ## JS semantics reproduced deliberately
///
/// - **Truthiness is not a null check.** `if (update.title)` skips an empty
///   string but `if (update.input)` keeps an empty object, because `{}` and `[]`
///   are truthy in JS while `""` is not. Every such branch is flagged at its
///   use site.
/// - **`Map` iteration order** is insertion order in both languages, so JS
///   `Map` maps onto Dart's `LinkedHashMap` and the LRU eviction order below is
///   identical.
/// - **`Array.prototype.sort` is stable in V8; `List.sort` is not in Dart**, so
///   every comparator here carries an original-index tiebreak.
/// - **`Object.is`** compares primitives by value and objects by reference;
///   Dart's `identical` is reference-only. See [jsObjectIs].
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart'
    show
        DirectPipeHostConnection,
        DirectSocketHostConnection,
        DirectTcpHostConnection,
        HostConnection,
        RelayHostConnection,
        RelayRole,
        WorkspaceDescriptor,
        WorkspaceProjectDescriptor,
        WorkspaceProjectKind,
        WorkspaceStateBucket,
        buildDaemonWebSocketUrl,
        buildRelayWebSocketUrl;
// `shouldUseTlsForDefaultHostedRelay` is deprecated as the *migration fallback*
// for connection offers that predate an explicit `useTls` flag. That is exactly
// the case this module still has to handle, and upstream calls it in the same
// place, so the deprecation is acknowledged rather than avoided.
import 'package:agent_protocol/agent_protocol.dart'
    show
        // ignore: deprecated_member_use
        shouldUseTlsForDefaultHostedRelay;

import '../attachments/paseo_attachment_rules.dart'
    show createImageSourceCacheKey;
import '../composer/composer_input_labels.dart' show ComposerTranslator;
import '../keyboard/paseo_browser_shortcuts.dart'
    show LocalTransportTarget, LocalTransportType;
import '../workspace/paseo_workspace_paths.dart'
    show resolveWorkspaceMapKeyByIdentity;
import 'paseo_app_misc.dart'
    show
        WorkspaceStructureHostPlacement,
        WorkspaceStructureProject,
        canCreateWorktreeForProjectKind;
import 'paseo_small_utils.dart'
    show DesktopBadgeWorkspaceStatus, projectDisplayNameFromProjectId;
import 'paseo_ui_utils.dart'
    show
        AssistantImageDirectSource,
        AssistantImageFileRpcSource,
        resolveAssistantImageSource;

export 'paseo_small_utils.dart' show DesktopBadgeWorkspaceStatus;

// ===========================================================================
// utils/assistant-image-metadata.ts
// ===========================================================================

/// An image's measured intrinsic size, plus the ratio every layout decision
/// actually uses.
///
/// [aspectRatio] is stored rather than recomputed because it is what the load
/// state publishes and what the height estimate divides by; keeping the source
/// dimensions alongside it makes a cached entry self-describing when debugging
/// a wrong-sized image.
final class AssistantImageMetadata {
  const AssistantImageMetadata({
    required this.width,
    required this.height,
    required this.aspectRatio,
  });

  final num width;
  final num height;
  final double aspectRatio;

  @override
  bool operator ==(Object other) =>
      other is AssistantImageMetadata &&
      other.width == width &&
      other.height == height &&
      other.aspectRatio == aspectRatio;

  @override
  int get hashCode => Object.hash(width, height, aspectRatio);

  @override
  String toString() =>
      'AssistantImageMetadata(width: $width, height: $height, '
      'aspectRatio: $aspectRatio)';
}

/// What an assistant image widget should draw right now.
///
/// Upstream's `{ status: "loading" } | { status: "ready"; aspectRatio } |
/// { status: "error" }` union, as a sealed hierarchy so a renderer cannot
/// forget an arm. The `error` arm has no producer in this module — upstream
/// only constructs it from a widget's own `onError` — but it is part of the
/// frozen type and is kept so callers can exhaustively switch.
sealed class AssistantImageLoadState {
  const AssistantImageLoadState();
}

/// Nothing measured yet: reserve space, do not commit to a shape.
final class AssistantImageLoading extends AssistantImageLoadState {
  const AssistantImageLoading();

  @override
  bool operator ==(Object other) => other is AssistantImageLoading;

  @override
  int get hashCode => (AssistantImageLoading).hashCode;

  @override
  String toString() => 'AssistantImageLoading()';
}

/// Measured: the widget can size itself before a byte of the image arrives.
final class AssistantImageReady extends AssistantImageLoadState {
  const AssistantImageReady({required this.aspectRatio});

  final double aspectRatio;

  @override
  bool operator ==(Object other) =>
      other is AssistantImageReady && other.aspectRatio == aspectRatio;

  @override
  int get hashCode => Object.hash(AssistantImageReady, aspectRatio);

  @override
  String toString() => 'AssistantImageReady(aspectRatio: $aspectRatio)';
}

/// The image could not be loaded at all.
final class AssistantImageError extends AssistantImageLoadState {
  const AssistantImageError();

  @override
  bool operator ==(Object other) => other is AssistantImageError;

  @override
  int get hashCode => (AssistantImageError).hashCode;

  @override
  String toString() => 'AssistantImageError()';
}

/// How many measured images are remembered before the least recently touched
/// entry is evicted.
const int assistantImageMetadataCacheLimit = 500;

/// How many parsed markdown bodies are remembered before eviction.
const int assistantImageParseCacheLimit = 500;

/// The width the height estimate lays images out at.
///
/// Upstream derives this as `MAX_CONTENT_WIDTH - 8`, where `MAX_CONTENT_WIDTH`
/// is 820 in `constants/layout.ts`. That constant has no Dart port yet — the
/// same inlining with the same note already exists in
/// `core/paseo_more_utils.dart` for its own `- 16` variant — so the arithmetic
/// is inlined with the derivation recorded here.
const int assistantImageEstimateWidth = 820 - 8;

/// The floor for a single estimated image block, so an extremely wide image
/// still reserves a visible amount of space.
const int assistantImageMinHeight = 160;

/// Vertical gap charged once per image block.
const int assistantImageBlockGap = 24;

/// The message chrome around an assistant bubble that also carries text.
const int assistantMessageBaseHeight = 96;

/// The message chrome around a bubble that is *only* images — far less, because
/// there is no prose block to pad.
const int assistantMessageImageOnlyBaseHeight = 40;

/// The floor for a whole estimated assistant message.
const int assistantMessageMinHeight = 220;

/// `![alt](target)`, where the target is either `<angle bracketed>` or a run of
/// characters that stops at `)` or a newline.
///
/// Anchoring the non-bracketed arm on `[^)\n]+` is what makes a data URL with an
/// unbalanced paren fail closed rather than swallow the rest of the message.
final RegExp _markdownImagePattern = RegExp(r'!\[[^\]]*]\((<[^>]+>|[^)\n]+)\)');

/// Splits a markdown image target from an optional `"title"` suffix.
///
/// Lazy first group plus an optional quoted tail: the engine grows the source
/// one character at a time until the remainder is either nothing or whitespace
/// followed by a matched quote pair, which is exactly CommonMark's link-title
/// shape.
final RegExp _markdownImageTitlePattern = RegExp(
  '^(.*?)(?:\\s+([\'"]).*?\\2)?\$',
);

/// Whether a markdown body mentions an image data URL at all.
///
/// Used only as a *caching* decision: a body carrying an inline base64 payload
/// is typically huge and never repeats, so keying a cache by the body itself
/// would retain megabytes for no hit rate.
final RegExp _dataImageMarkerPattern = RegExp(
  r'data:image/',
  caseSensitive: false,
);

/// The result of scanning one markdown body for images.
final class _AssistantImageParse {
  const _AssistantImageParse({
    required this.sources,
    required this.hasNonImageText,
  });

  final List<String> sources;

  /// Whether anything but the image syntax survives — this picks the message's
  /// base height, and an image-only bubble is much shorter.
  final bool hasNonImageText;
}

/// Re-inserts [key] at the most-recent end of [cache], then evicts the oldest
/// entry once the cache grows past [limit].
///
/// Delete-then-set rather than a plain assignment because Dart's `LinkedHashMap`
/// keeps an existing key in its original position on overwrite, exactly like a
/// JS `Map` — so without the delete a re-read would never refresh recency.
void _touchCacheEntry<K, V>(
  LinkedHashMap<K, V> cache,
  K key,
  V value,
  int limit,
) {
  cache.remove(key);
  cache[key] = value;
  if (cache.length <= limit) {
    return;
  }
  final oldestKey = cache.keys.isEmpty ? null : cache.keys.first;
  if (oldestKey != null) {
    cache.remove(oldestKey);
  }
}

/// Normalizes one captured markdown image target, or null when nothing usable
/// is left.
String? _normalizeAssistantImageSourceToken(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  if (trimmed.startsWith('<') && trimmed.endsWith('>')) {
    final inner = trimmed.substring(1, trimmed.length - 1).trim();
    return inner.isEmpty ? null : inner;
  }

  final titleMatch = _markdownImageTitlePattern.firstMatch(trimmed);
  final source = titleMatch?.group(1)?.trim() ?? trimmed;
  return source.isEmpty ? null : source;
}

_AssistantImageParse _parseAssistantImageMarkdown(String markdown) {
  final sources = <String>[];
  for (final match in _markdownImagePattern.allMatches(markdown)) {
    final normalized = _normalizeAssistantImageSourceToken(
      match.group(1) ?? '',
    );
    if (normalized != null) {
      sources.add(normalized);
    }
  }
  return _AssistantImageParse(
    sources: sources,
    hasNonImageText: markdown
        .replaceAll(_markdownImagePattern, '')
        .trim()
        .isNotEmpty,
  );
}

/// Maps measured metadata onto the state an image widget renders.
///
/// A missing measurement is `loading`, never `error`: not having measured an
/// image yet says nothing about whether it will load.
AssistantImageLoadState getAssistantImageLoadStateFromMetadata(
  AssistantImageMetadata? metadata,
) {
  if (metadata == null) {
    return const AssistantImageLoading();
  }
  return AssistantImageReady(aspectRatio: metadata.aspectRatio);
}

/// The measured-image and markdown-parse caches behind assistant image sizing.
///
/// **Deviation:** upstream holds both maps as module-level state with a
/// `clearAssistantImageMetadataCache()` reset that only its own test suite
/// calls. They are instance state here for the same reason
/// `AssistantMessageHeightEstimateCache` is a class in
/// `core/paseo_more_utils.dart`: the estimator is *injected* into that cache
/// rather than imported, so a per-instance cache is what the seam actually
/// wants, and a test can hold an isolated one without a global reset. The only
/// upstream behaviour lost is cross-module sharing of one process-wide cache,
/// which no consumer in this repo depends on — every consumer receives the
/// instance it should read.
final class AssistantImageMetadataCache {
  AssistantImageMetadataCache();

  /// Insertion-ordered so the first key is the least recently touched, matching
  /// JS `Map`. Keyed by *every* alias a source can be spelled with, so the same
  /// image measured under a workspace-scoped path is found again by bare path.
  final LinkedHashMap<String, AssistantImageMetadata> _metadata =
      LinkedHashMap<String, AssistantImageMetadata>();

  final LinkedHashMap<String, _AssistantImageParse> _parses =
      LinkedHashMap<String, _AssistantImageParse>();

  /// How many measurements are held. Not upstream API; exposed because the
  /// eviction limit is otherwise unobservable.
  int get metadataLength => _metadata.length;

  /// How many parsed bodies are held. Not upstream API, same reason.
  int get parseLength => _parses.length;

  String _createSourceAliasKey(String source) =>
      'source:${createImageSourceCacheKey(source)}';

  /// The key for how this source actually *resolves*, or null when it cannot be
  /// loaded at all.
  ///
  /// A file-RPC image is keyed by host as well as path, because `/tmp/shot.png`
  /// on two different machines is two different images.
  String? _createResolutionKey({
    required String source,
    String? workspaceRoot,
    String? serverId,
  }) {
    final resolution = resolveAssistantImageSource(
      source: source,
      workspaceRoot: workspaceRoot,
    );
    return switch (resolution) {
      null => null,
      AssistantImageDirectSource(:final uri) =>
        'direct:${createImageSourceCacheKey(uri)}',
      AssistantImageFileRpcSource(:final cwd, :final path) =>
        'file:${serverId ?? 'unknown-server'}:$cwd:$path',
    };
  }

  /// Every key one source should be filed under, most specific first.
  ///
  /// The resolution key is unshifted ahead of the raw alias so a lookup that
  /// *can* resolve prefers the host-scoped entry, while a later lookup with no
  /// workspace root still finds the same measurement through the alias. That
  /// two-key scheme is the whole reason a screenshot measured during streaming
  /// is still sized correctly when the message is re-rendered from history.
  List<String> _metadataKeys({
    required String source,
    String? workspaceRoot,
    String? serverId,
  }) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) {
      return const [];
    }

    final keys = [_createSourceAliasKey(trimmed)];
    final resolutionKey = _createResolutionKey(
      source: source,
      workspaceRoot: workspaceRoot,
      serverId: serverId,
    );
    if (resolutionKey != null) {
      keys.insert(0, resolutionKey);
    }
    // Upstream's `[...new Set(keys)]`: order-preserving de-duplication, which
    // matters because the alias and the resolution key coincide for a data URL.
    return LinkedHashSet<String>.of(keys).toList();
  }

  /// The measurement for [source], refreshing its recency on a hit.
  ///
  /// Reading counts as a touch so an image that is still on screen is never the
  /// eviction candidate.
  AssistantImageMetadata? getMetadata({
    required String source,
    String? workspaceRoot,
    String? serverId,
  }) {
    for (final key in _metadataKeys(
      source: source,
      workspaceRoot: workspaceRoot,
      serverId: serverId,
    )) {
      final metadata = _metadata[key];
      if (metadata != null) {
        _touchCacheEntry(
          _metadata,
          key,
          metadata,
          assistantImageMetadataCacheLimit,
        );
        return metadata;
      }
    }
    return null;
  }

  /// Records a real measurement under every alias, or returns null when the
  /// dimensions are unusable.
  ///
  /// Non-finite or non-positive dimensions are rejected rather than clamped: a
  /// zero height would make the aspect ratio infinite and the height estimate
  /// meaningless, and a decoder reporting one has failed, not produced a very
  /// thin image.
  AssistantImageMetadata? setMetadata({
    required String source,
    required num width,
    required num height,
    String? workspaceRoot,
    String? serverId,
  }) {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return null;
    }

    final metadata = AssistantImageMetadata(
      width: width,
      height: height,
      aspectRatio: width / height,
    );

    for (final key in _metadataKeys(
      source: source,
      workspaceRoot: workspaceRoot,
      serverId: serverId,
    )) {
      _touchCacheEntry(
        _metadata,
        key,
        metadata,
        assistantImageMetadataCacheLimit,
      );
    }

    return metadata;
  }

  /// Every image source referenced by [markdown], in document order.
  ///
  /// The parse is memoised unless the body contains a `data:image/` payload —
  /// see [_dataImageMarkerPattern] for why that exception exists.
  List<String> extractImageSources(String markdown) {
    final shouldCacheParse = !_dataImageMarkerPattern.hasMatch(markdown);
    final cachedParse = shouldCacheParse ? _parses[markdown] : null;
    if (cachedParse != null) {
      _touchCacheEntry(
        _parses,
        markdown,
        cachedParse,
        assistantImageParseCacheLimit,
      );
      return cachedParse.sources;
    }

    final parsed = _parseAssistantImageMarkdown(markdown);
    if (shouldCacheParse) {
      _touchCacheEntry(
        _parses,
        markdown,
        parsed,
        assistantImageParseCacheLimit,
      );
    }
    return parsed.sources;
  }

  /// The estimated pixel height of an assistant message, or null when nothing
  /// can be said about it.
  ///
  /// Shaped as [AssistantImageHeightEstimator] on purpose — see the library
  /// doc: this is the fallback `core/paseo_more_utils.dart` was written to
  /// accept.
  ///
  /// Null in two cases, both meaning "let the list use its own placeholder":
  /// the message has no images, or none of its images has been measured yet.
  /// Note that images are looked up *without* a workspace root or server id,
  /// matching upstream — the estimate runs where that context is not available,
  /// and the alias key is what makes the lookup still hit.
  ///
  /// Unlike [extractImageSources] this never populates the parse cache; it only
  /// reads one, so an estimate for a body that was never rendered stays free of
  /// retained state.
  int? estimateMessageHeightFromCache(String markdown) {
    final parsed = _parses[markdown] ?? _parseAssistantImageMarkdown(markdown);
    if (parsed.sources.isEmpty) {
      return null;
    }

    final knownHeights = <int>[];
    for (final source in parsed.sources) {
      final metadata = getMetadata(source: source);
      if (metadata == null) {
        continue;
      }
      knownHeights.add(
        math.max(
          assistantImageMinHeight,
          // JS `Math.round` breaks ties toward +infinity while Dart's
          // `num.round()` breaks them away from zero; the operand here is
          // always positive, so the two agree.
          (assistantImageEstimateWidth / metadata.aspectRatio).round(),
        ),
      );
    }

    if (knownHeights.isEmpty) {
      return null;
    }

    final baseHeight = parsed.hasNonImageText
        ? assistantMessageBaseHeight
        : assistantMessageImageOnlyBaseHeight;

    final estimatedHeight =
        baseHeight +
        knownHeights.fold<int>(0, (sum, height) => sum + height) +
        assistantImageBlockGap * knownHeights.length;

    return math.max(assistantMessageMinHeight, estimatedHeight);
  }

  /// Drops every measurement and every parsed body.
  void clear() {
    _metadata.clear();
    _parses.clear();
  }
}

// ===========================================================================
// utils/test-daemon-connection.ts
// ===========================================================================

/// The `server_info` handshake fields a probe cares about.
final class DaemonProbeServerInfo {
  const DaemonProbeServerInfo({required this.serverId, required this.hostname});

  final String serverId;

  /// Null when the daemon reported no hostname — a valid state, not an error.
  final String? hostname;

  @override
  bool operator ==(Object other) =>
      other is DaemonProbeServerInfo &&
      other.serverId == serverId &&
      other.hostname == hostname;

  @override
  int get hashCode => Object.hash(serverId, hostname);

  @override
  String toString() =>
      'DaemonProbeServerInfo(serverId: $serverId, hostname: $hostname)';
}

/// The slice of a daemon client this module drives.
///
/// Deliberately narrow: a probe only needs to connect once, read the handshake,
/// and hang up. Typing against the full client would drag every RPC into a
/// module whose entire job is deciding whether a connection works.
abstract interface class DaemonProbeClient {
  /// The transport's own last error, which is often more specific than the
  /// exception `connect` throws — see [pickBestProbeFailureReason].
  String? get lastError;

  Future<void> connect();

  Future<void> close();

  /// The handshake, or null when the socket opened but never announced itself.
  DaemonProbeServerInfo? getLastServerInfoMessage();
}

/// Which kind of client is connecting, as the daemon labels it.
///
/// Only [mobile] is produced here (upstream hard-codes `clientType: "mobile"`
/// for probes); the rest of the frozen union is kept so a config built
/// elsewhere can be represented.
enum DaemonClientType {
  mobile('mobile'),
  browser('browser'),
  cli('cli'),
  mcp('mcp');

  const DaemonClientType(this.wireName);

  final String wireName;
}

/// End-to-end encryption settings for a relay-brokered connection.
final class DaemonClientE2eeConfig {
  const DaemonClientE2eeConfig({
    required this.enabled,
    this.daemonPublicKeyB64,
  });

  final bool enabled;
  final String? daemonPublicKeyB64;

  @override
  bool operator ==(Object other) =>
      other is DaemonClientE2eeConfig &&
      other.enabled == enabled &&
      other.daemonPublicKeyB64 == daemonPublicKeyB64;

  @override
  int get hashCode => Object.hash(enabled, daemonPublicKeyB64);

  @override
  String toString() =>
      'DaemonClientE2eeConfig(enabled: $enabled, '
      'daemonPublicKeyB64: $daemonPublicKeyB64)';
}

/// Auto-reconnect settings. A probe always disables them — a probe that
/// silently reconnected would report success for a connection the user cannot
/// actually keep.
final class DaemonClientReconnectConfig {
  const DaemonClientReconnectConfig({required this.enabled});

  final bool enabled;

  @override
  bool operator ==(Object other) =>
      other is DaemonClientReconnectConfig && other.enabled == enabled;

  @override
  int get hashCode => enabled.hashCode;

  @override
  String toString() => 'DaemonClientReconnectConfig(enabled: $enabled)';
}

/// What a daemon client needs in order to be constructed.
///
/// **Deviation:** upstream imports `DaemonClientConfig` from
/// `@getpaseo/client`. This repo's `core/daemon_client.dart` takes a `Uri`,
/// a token and relay options instead of a config object, so the frozen config
/// shape is declared here — only the fields `buildDaemonProbeClientConfig`
/// actually sets, plus the opaque [transportFactory] slot the local-socket
/// path fills. Fields the probe never touches (`webSocketFactory`, `logger`,
/// `runtimeMetrics*`, `authHeader`, `runtimeGeneration`) are omitted rather
/// than carried as dead weight; a wiring layer that needs them can widen this
/// type without changing any decision here.
final class DaemonProbeClientConfig {
  const DaemonProbeClientConfig({
    required this.url,
    required this.clientId,
    required this.clientType,
    required this.suppressSendErrors,
    required this.reconnect,
    this.appVersion,
    this.password,
    this.e2ee,
    this.capabilities,
    this.transportFactory,
  });

  final String url;
  final String clientId;
  final DaemonClientType clientType;

  /// Null when the app could not determine its own version, matching upstream's
  /// `resolveAppVersion() ?? undefined`.
  final String? appVersion;

  /// True for a probe: a send failure during a throwaway connection is noise.
  final bool suppressSendErrors;

  final DaemonClientReconnectConfig reconnect;

  /// Present only for a direct TCP connection that stored one.
  final String? password;

  /// Present only for relay connections.
  final DaemonClientE2eeConfig? e2ee;

  /// Opt-in client capabilities, passed straight through.
  final Map<String, Object?>? capabilities;

  /// The local-socket / named-pipe transport constructor, opaque to this
  /// module. Typed as [Object] because its real type belongs to the desktop
  /// transport layer and nothing here inspects it.
  final Object? transportFactory;

  @override
  String toString() =>
      'DaemonProbeClientConfig(url: $url, clientId: $clientId, '
      'clientType: ${clientType.wireName}, appVersion: $appVersion, '
      'password: ${password == null ? null : '<redacted>'}, e2ee: $e2ee)';
}

/// A probe that failed, carrying both the raw signals it was derived from.
///
/// [message] is the user-facing reason; [reason] and [lastError] are kept so a
/// diagnostics view can show what was actually observed rather than the
/// summarised verdict.
final class DaemonConnectionTestException implements Exception {
  const DaemonConnectionTestException(
    this.message, {
    required this.reason,
    required this.lastError,
  });

  final String message;
  final String? reason;
  final String? lastError;

  @override
  String toString() => 'DaemonConnectionTestException: $message';
}

/// A successful probe: the live client plus what it learned.
final class DaemonProbeResult<TClient extends DaemonProbeClient> {
  const DaemonProbeResult({
    required this.client,
    required this.serverId,
    required this.hostname,
  });

  /// Still open — the caller owns closing it. A probe that closed on success
  /// would force an immediate reconnect for the common "probe then use" flow.
  final TClient client;

  final String serverId;
  final String? hostname;
}

/// Everything the probe needs from the outside world.
///
/// Every field is a callback so this module never constructs a socket, reads a
/// preference, or reaches for a global. There is deliberately **no** default
/// instance: upstream's default wires `new DaemonClient(config)` directly, and
/// providing that here would let a logic path open a real connection.
final class DaemonConnectionDependencies<TClient extends DaemonProbeClient> {
  const DaemonConnectionDependencies({
    required this.getClientId,
    required this.resolveAppVersion,
    required this.createLocalTransportFactory,
    required this.buildLocalTransportUrl,
    required this.createClient,
  });

  /// The stable per-install client id. Async because it may have to be created
  /// and persisted on first use.
  final Future<String> Function() getClientId;

  /// The app's own version, or null when it cannot be determined.
  final String? Function() resolveAppVersion;

  /// The local-socket transport constructor, or null on a host that has none
  /// (a browser, say).
  final Object? Function() createLocalTransportFactory;

  final String Function(LocalTransportTarget target) buildLocalTransportUrl;

  final TClient Function(DaemonProbeClientConfig config) createClient;
}

/// Trims, and treats a whitespace-only value as absent.
String? _normalizeNonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The reason strings that say a transport broke without saying why.
bool _isGenericTransportPhrase(String value) {
  final lowered = value.toLowerCase();
  return lowered == 'transport error' || lowered == 'transport closed';
}

/// Picks the more informative of the two failure signals.
///
/// The thrown [reason] usually wins, but a *generic* thrown reason defers to a
/// specific [lastError]: "transport closed" tells the user nothing while
/// "certificate expired" tells them everything. Exposed because it is the rule
/// a caller re-applies when it has its own extra signal.
String pickBestProbeFailureReason(String? reason, String? lastError) {
  final genericReason = reason != null && _isGenericTransportPhrase(reason);
  final genericLastError =
      lastError != null &&
      (_isGenericTransportPhrase(lastError) ||
          lastError.toLowerCase() == 'unable to connect');

  if (genericReason && lastError != null && !genericLastError) {
    return lastError;
  }
  if (reason != null) return reason;
  if (lastError != null) return lastError;
  return 'Unable to connect';
}

/// Whether a failure looks like the stored password being wrong.
///
/// Only ever true when a password was actually supplied, so a passwordless
/// connection can never be blamed on credentials. `1006` is included because a
/// browser WebSocket reports an authenticated-handshake rejection as an
/// abnormal close with no code detail; without it, a wrong password on the web
/// build surfaces as an unexplained disconnect.
bool isIncorrectDaemonPasswordFailure({
  required DaemonProbeClientConfig config,
  required String? reason,
  required String? lastError,
}) {
  final password = config.password;
  if (password == null || password.isEmpty) {
    return false;
  }
  final details = [
    if (reason != null && reason.isNotEmpty) reason,
    if (lastError != null && lastError.isNotEmpty) lastError,
  ].join('\n').toLowerCase();
  return details.contains('401') ||
      details.contains('4001') ||
      details.contains('unauthorized') ||
      details.contains('code 1006');
}

/// Builds the client config for [connection].
///
/// Relay connections require [serverId] because the relay routes by it; there
/// is no way to reach "whichever daemon is behind this relay".
///
/// **Deviation:** upstream's relay URL goes through the WHATWG `URL` class,
/// which drops the default port for `wss:` — `wss://[::1]/ws?…`. This repo's
/// [buildRelayWebSocketUrl] builds through Dart's `Uri`, which only knows
/// default ports for `http`/`https`, so it emits `wss://[::1]:443/ws?…`. The
/// two address the same endpoint and the difference belongs to the already
/// ported protocol helper, not to this decision.
Future<DaemonProbeClientConfig>
buildDaemonProbeClientConfig<TClient extends DaemonProbeClient>(
  HostConnection connection, {
  String? serverId,
  Map<String, Object?>? capabilities,
  required DaemonConnectionDependencies<TClient> deps,
}) async {
  final clientId = await deps.getClientId();
  final localTransportFactory = deps.createLocalTransportFactory();
  final isLocal =
      connection is DirectSocketHostConnection ||
      connection is DirectPipeHostConnection;

  DaemonProbeClientConfig base(String url, {String? password, Object? e2ee}) =>
      DaemonProbeClientConfig(
        url: url,
        clientId: clientId,
        clientType: DaemonClientType.mobile,
        appVersion: deps.resolveAppVersion(),
        suppressSendErrors: true,
        reconnect: const DaemonClientReconnectConfig(enabled: false),
        capabilities: capabilities,
        password: password,
        e2ee: e2ee as DaemonClientE2eeConfig?,
        // Upstream spreads the transport factory in only for local connections
        // *and* only when the host provides one, so a desktop-only factory is
        // never attached to a TCP or relay config.
        transportFactory: isLocal ? localTransportFactory : null,
      );

  if (connection is DirectSocketHostConnection) {
    return base(
      deps.buildLocalTransportUrl(
        LocalTransportTarget(
          transportType: LocalTransportType.socket,
          transportPath: connection.path,
        ),
      ),
    );
  }

  if (connection is DirectPipeHostConnection) {
    return base(
      deps.buildLocalTransportUrl(
        LocalTransportTarget(
          transportType: LocalTransportType.pipe,
          transportPath: connection.path,
        ),
      ),
    );
  }

  if (connection is DirectTcpHostConnection) {
    return base(
      buildDaemonWebSocketUrl(connection.endpoint, useTls: connection.useTls),
      // Upstream spreads `connection.password` in only when truthy, so a stored
      // empty-string password is dropped rather than sent.
      password: (connection.password?.isEmpty ?? true)
          ? null
          : connection.password,
    );
  }

  connection as RelayHostConnection;
  if (serverId == null || serverId.isEmpty) {
    throw const DaemonConnectionTestException(
      'serverId is required to probe a relay connection',
      reason: null,
      lastError: null,
    );
  }

  return base(
    buildRelayWebSocketUrl(
      endpoint: connection.relayEndpoint,
      // `?? shouldUseTlsForDefaultHostedRelay(...)` is nullish, not falsy: a
      // connection that explicitly stored `useTls: false` keeps plaintext even
      // on port 443.
      useTls:
          connection.useTls ??
          // ignore: deprecated_member_use
          shouldUseTlsForDefaultHostedRelay(connection.relayEndpoint),
      serverId: serverId,
      role: RelayRole.client,
    ),
    e2ee: DaemonClientE2eeConfig(
      enabled: true,
      daemonPublicKeyB64: connection.daemonPublicKeyB64,
    ),
  );
}

/// Schedules [callback] after [duration], returning a handle that cancels it.
///
/// A parameter rather than a bare `Timer` so a test can drive the timeout
/// deterministically instead of waiting six real seconds.
typedef ProbeTimeoutScheduler =
    void Function() Function(Duration duration, void Function() callback);

void Function() _defaultProbeTimeoutScheduler(
  Duration duration,
  void Function() callback,
) {
  final timer = Timer(duration, callback);
  return timer.cancel;
}

/// Connects [config] once and reads the handshake, failing after [timeout].
///
/// Every failure path closes the client before rejecting — a probe that leaked
/// a half-open socket per attempt would exhaust the daemon's connection slots
/// during a retry loop. Close failures are swallowed for the same reason
/// upstream swallows them: the connection is already being abandoned.
Future<DaemonProbeResult<TClient>>
connectAndProbeDaemon<TClient extends DaemonProbeClient>(
  DaemonProbeClientConfig config,
  Duration timeout, {
  required DaemonConnectionDependencies<TClient> deps,
  ProbeTimeoutScheduler scheduleTimeout = _defaultProbeTimeoutScheduler,
}) {
  final client = deps.createClient(config);
  final completer = Completer<DaemonProbeResult<TClient>>();

  void closeQuietly() {
    unawaited(client.close().catchError((_) {}));
  }

  final cancelTimeout = scheduleTimeout(timeout, () {
    if (completer.isCompleted) return;
    closeQuietly();
    completer.completeError(
      DaemonConnectionTestException(
        'Connection timed out',
        reason: 'Connection timed out',
        lastError: client.lastError,
      ),
    );
  });

  client
      .connect()
      .then((_) {
        cancelTimeout();
        if (completer.isCompleted) return;
        final serverInfo = client.getLastServerInfoMessage();
        if (serverInfo == null) {
          closeQuietly();
          completer.completeError(
            DaemonConnectionTestException(
              'Missing server info message',
              reason: 'Missing server info message',
              lastError: client.lastError,
            ),
          );
          return;
        }
        completer.complete(
          DaemonProbeResult<TClient>(
            client: client,
            serverId: serverInfo.serverId,
            hostname: serverInfo.hostname,
          ),
        );
      })
      .catchError((Object error) {
        cancelTimeout();
        if (completer.isCompleted) return;
        final reason = _normalizeNonEmptyString(_describeProbeError(error));
        final lastError = _normalizeNonEmptyString(client.lastError);
        final message =
            isIncorrectDaemonPasswordFailure(
              config: config,
              reason: reason,
              lastError: lastError,
            )
            ? 'Incorrect password'
            : pickBestProbeFailureReason(reason, lastError);
        closeQuietly();
        completer.completeError(
          DaemonConnectionTestException(
            message,
            reason: reason,
            lastError: lastError,
          ),
        );
      });

  return completer.future;
}

/// Everything `Exception('…')` prepends to its message.
///
/// Dart's `Exception` factory returns a private class whose message is
/// reachable *only* through `toString()`, so recovering `error.message` means
/// removing this prefix.
const String _dartExceptionPrefix = 'Exception: ';

/// Upstream's `error instanceof Error ? error.message : String(error)`.
///
/// Dart has no universal `message` accessor and `toString()` prefixes the type
/// name, so the message is recovered per shape. This matters because
/// [pickBestProbeFailureReason] compares the reason against exact phrases: a
/// stringified `Exception: Transport error` would fail the "generic phrase"
/// test and be reported verbatim to the user instead of deferring to the more
/// specific transport error.
String _describeProbeError(Object error) {
  final described = switch (error) {
    DaemonConnectionTestException(:final message) => message,
    FormatException(:final message) => message,
    ArgumentError(:final message) => '$message',
    StateError(:final message) => message,
    _ => '$error',
  };
  return described.startsWith(_dartExceptionPrefix)
      ? described.substring(_dartExceptionPrefix.length)
      : described;
}

/// How long to wait for a probe.
///
/// Relay connections get longer because they traverse a broker; a direct socket
/// that has not answered in six seconds is not going to.
///
/// The `options?.timeoutMs` check upstream is *truthy*, so an explicit `0` falls
/// through to the default rather than timing out instantly. That is reproduced
/// by treating a non-positive override as absent.
Duration resolveDaemonProbeTimeout(
  HostConnection connection, {
  Duration? timeout,
}) {
  if (timeout != null && timeout > Duration.zero) return timeout;
  return connection is RelayHostConnection
      ? const Duration(seconds: 10)
      : const Duration(seconds: 6);
}

/// Builds a config for [connection] and probes it once.
Future<DaemonProbeResult<TClient>>
connectToDaemon<TClient extends DaemonProbeClient>(
  HostConnection connection, {
  String? serverId,
  Duration? timeout,
  Map<String, Object?>? capabilities,
  required DaemonConnectionDependencies<TClient> deps,
  ProbeTimeoutScheduler scheduleTimeout = _defaultProbeTimeoutScheduler,
}) async {
  final config = await buildDaemonProbeClientConfig(
    connection,
    serverId: serverId,
    capabilities: capabilities,
    deps: deps,
  );
  return connectAndProbeDaemon(
    config,
    resolveDaemonProbeTimeout(connection, timeout: timeout),
    deps: deps,
    scheduleTimeout: scheduleTimeout,
  );
}

// ===========================================================================
// types/agent-activity.ts
// ===========================================================================

/// How far along a tool call is.
///
/// **Renamed from upstream's `ToolCallStatus`.** `package:agent_protocol`
/// already exports a `ToolCallStatus` for this repo's own timeline model, whose
/// members are a *different* set (`running`/`success`/`error`/`canceled` rather
/// than `in_progress`/`completed`/`failed`). Keeping the bare name would make
/// the two silently ambiguous in every file that touches both, and the wrong
/// one is trivially mistaken for the right one. The `Acp` prefix names the wire
/// this update actually comes from.
enum AcpToolCallStatus {
  pending('pending'),
  inProgress('in_progress'),
  completed('completed'),
  failed('failed');

  const AcpToolCallStatus(this.wireName);

  final String wireName;
}

/// What a tool call is broadly doing, which drives its icon and its summary
/// line.
enum ToolKind {
  read('read'),
  edit('edit'),
  delete('delete'),
  move('move'),
  search('search'),
  execute('execute'),
  think('think'),
  fetch('fetch'),
  switchMode('switch_mode'),
  other('other');

  const ToolKind(this.wireName);

  final String wireName;
}

/// Who produced a run of text.
enum TextMessageType {
  user('user'),
  agent('agent'),
  thought('thought');

  const TextMessageType(this.wireName);

  final String wireName;
}

/// A plan entry's progress.
enum PlanEntryStatus {
  pending('pending'),
  inProgress('in_progress'),
  completed('completed');

  const PlanEntryStatus(this.wireName);

  final String wireName;
}

/// A plan entry's importance.
enum PlanEntryPriority {
  high('high'),
  medium('medium'),
  low('low');

  const PlanEntryPriority(this.wireName);

  final String wireName;
}

/// One update in an agent session's stream.
///
/// Upstream's `SessionUpdate` union, discriminated by a `kind` string, as a
/// sealed hierarchy so a renderer must handle every arm.
sealed class SessionUpdate {
  const SessionUpdate();
}

/// A slice of the user's own message, echoed back by the agent.
final class UserMessageChunk extends SessionUpdate {
  const UserMessageChunk({required this.text});

  final String text;
}

/// A slice of the agent's visible reply.
final class AgentMessageChunk extends SessionUpdate {
  const AgentMessageChunk({required this.text});

  final String text;
}

/// A slice of the agent's reasoning, rendered separately from its reply.
final class AgentThoughtChunk extends SessionUpdate {
  const AgentThoughtChunk({required this.text});

  final String text;
}

/// A tool call being announced for the first time.
final class ToolCall extends SessionUpdate {
  const ToolCall({
    required this.toolCallId,
    required this.title,
    this.status,
    this.toolKind,
    this.input,
    this.output,
    this.content,
    this.locations,
  });

  final String toolCallId;
  final String title;
  final AcpToolCallStatus? status;
  final ToolKind? toolKind;
  final Map<String, Object?>? input;
  final Map<String, Object?>? output;
  final List<Object?>? content;
  final List<Object?>? locations;
}

/// A patch to an already-announced tool call.
///
/// Every field is optional and *nullable* upstream, where `null` and `undefined`
/// are both skipped by the truthiness guards in the merge. Dart collapses the
/// two onto `null`, which is observably identical because no merge branch
/// distinguishes them.
final class ToolCallUpdate extends SessionUpdate {
  const ToolCallUpdate({
    required this.toolCallId,
    this.title,
    this.status,
    this.toolKind,
    this.input,
    this.output,
    this.content,
    this.locations,
  });

  final String toolCallId;
  final String? title;
  final AcpToolCallStatus? status;
  final ToolKind? toolKind;
  final Map<String, Object?>? input;
  final Map<String, Object?>? output;
  final List<Object?>? content;
  final List<Object?>? locations;
}

/// One row of the agent's plan.
final class PlanEntry {
  const PlanEntry({
    required this.content,
    required this.status,
    required this.priority,
  });

  final String content;
  final PlanEntryStatus status;
  final PlanEntryPriority priority;

  @override
  bool operator ==(Object other) =>
      other is PlanEntry &&
      other.content == content &&
      other.status == status &&
      other.priority == priority;

  @override
  int get hashCode => Object.hash(content, status, priority);

  @override
  String toString() =>
      'PlanEntry(content: $content, status: ${status.wireName}, '
      'priority: ${priority.wireName})';
}

/// The agent's current plan, replaced wholesale on every emission.
final class Plan extends SessionUpdate {
  const Plan({required this.entries});

  final List<PlanEntry> entries;
}

/// One slash command the agent offers.
final class AvailableCommand {
  const AvailableCommand({required this.name, required this.description});

  final String name;
  final String description;

  @override
  bool operator ==(Object other) =>
      other is AvailableCommand &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(name, description);

  @override
  String toString() =>
      'AvailableCommand(name: $name, description: $description)';
}

/// The agent's command list, replaced wholesale.
final class AvailableCommandsUpdate extends SessionUpdate {
  const AvailableCommandsUpdate({required this.availableCommands});

  final List<AvailableCommand> availableCommands;
}

/// The agent switched modes (plan/edit/ask, provider-defined).
final class CurrentModeUpdate extends SessionUpdate {
  const CurrentModeUpdate({required this.currentModeId});

  final String currentModeId;
}

/// Something a grouped activity list can render.
///
/// Upstream's `GroupedActivity = GroupedTextMessage | MergedToolCall |
/// AgentActivity`. [AgentActivity] extends this directly rather than being
/// wrapped, because upstream pushes the raw activity into the result array
/// untouched and a wrapper would be an observable difference.
sealed class GroupedActivity {
  const GroupedActivity();
}

/// One timestamped update as it arrived.
final class AgentActivity extends GroupedActivity {
  const AgentActivity({required this.timestamp, required this.update});

  final DateTime timestamp;
  final SessionUpdate update;
}

/// A contiguous run of same-author text chunks, concatenated.
///
/// The run breaks whenever the author changes or anything non-text intervenes,
/// which is what keeps a tool call from being swallowed into the middle of a
/// paragraph.
final class GroupedTextMessage extends GroupedActivity {
  const GroupedTextMessage({
    required this.messageType,
    required this.text,
    required this.startTimestamp,
    required this.endTimestamp,
  });

  final TextMessageType messageType;
  final String text;
  final DateTime startTimestamp;
  final DateTime endTimestamp;

  @override
  bool operator ==(Object other) =>
      other is GroupedTextMessage &&
      other.messageType == messageType &&
      other.text == text &&
      other.startTimestamp == startTimestamp &&
      other.endTimestamp == endTimestamp;

  @override
  int get hashCode =>
      Object.hash(messageType, text, startTimestamp, endTimestamp);

  @override
  String toString() =>
      'GroupedTextMessage(${messageType.wireName}, ${text.length} chars, '
      '$startTimestamp..$endTimestamp)';
}

/// One tool call with every update folded in, rendered at the position where it
/// was *first* seen.
///
/// Holding the position is the point: a tool call that completes ten seconds
/// and three paragraphs later still renders where the agent started it, so the
/// transcript reads in the order things happened rather than the order they
/// finished.
final class MergedToolCall extends GroupedActivity {
  const MergedToolCall({
    required this.toolCallId,
    required this.title,
    required this.status,
    required this.startTimestamp,
    required this.endTimestamp,
    this.toolKind,
    this.input,
    this.output,
    this.content,
    this.locations,
  });

  final String toolCallId;
  final String title;
  final AcpToolCallStatus status;
  final ToolKind? toolKind;
  final Map<String, Object?>? input;
  final Map<String, Object?>? output;
  final List<Object?>? content;
  final List<Object?>? locations;
  final DateTime startTimestamp;

  /// Advances on every update, so a caller can show how long the call ran.
  final DateTime endTimestamp;

  @override
  bool operator ==(Object other) =>
      other is MergedToolCall &&
      other.toolCallId == toolCallId &&
      other.title == title &&
      other.status == status &&
      other.toolKind == toolKind &&
      _jsonEquals(other.input, input) &&
      _jsonEquals(other.output, output) &&
      _jsonEquals(other.content, content) &&
      _jsonEquals(other.locations, locations) &&
      other.startTimestamp == startTimestamp &&
      other.endTimestamp == endTimestamp;

  @override
  int get hashCode => Object.hash(
    toolCallId,
    title,
    status,
    toolKind,
    startTimestamp,
    endTimestamp,
  );

  @override
  String toString() =>
      'MergedToolCall($toolCallId, $title, ${status.wireName}, '
      'input: $input, output: $output, content: $content, '
      'locations: $locations, $startTimestamp..$endTimestamp)';
}

/// A run of same-author text still being accumulated.
final class _TextGroup {
  _TextGroup({
    required this.messageType,
    required this.chunks,
    required this.startTimestamp,
    required this.endTimestamp,
  });

  final TextMessageType messageType;
  final List<String> chunks;
  final DateTime startTimestamp;
  DateTime endTimestamp;
}

/// A tool call being merged, plus the slot it reserved in the output.
final class _ToolCallAccumulator {
  _ToolCallAccumulator({
    required this.toolCallId,
    required this.title,
    required this.status,
    required this.startTimestamp,
    required this.endTimestamp,
    required this.insertIndex,
    this.toolKind,
    this.input,
    this.output,
    this.content,
    this.locations,
  });

  final String toolCallId;
  String title;
  AcpToolCallStatus status;
  ToolKind? toolKind;
  Map<String, Object?>? input;
  Map<String, Object?>? output;
  List<Object?>? content;
  List<Object?>? locations;
  final DateTime startTimestamp;
  DateTime endTimestamp;
  final int insertIndex;

  MergedToolCall toMergedToolCall() => MergedToolCall(
    toolCallId: toolCallId,
    title: title,
    status: status,
    toolKind: toolKind,
    input: input,
    output: output,
    content: content,
    locations: locations,
    startTimestamp: startTimestamp,
    endTimestamp: endTimestamp,
  );
}

/// Collapses a raw activity log into what a transcript renders.
///
/// Three rules, all upstream:
///
/// * **Adjacent same-author text chunks merge** into one block, so a streamed
///   reply is one paragraph rather than a hundred fragments.
/// * **Tool calls merge by id and render at first sight.** A `tool_call_update`
///   that arrives before its `tool_call` still reserves a slot, so an agent that
///   patches before announcing does not reorder the transcript.
/// * **Everything else passes through** in order, flushing any open text run
///   first.
///
/// The merge is applied after the walk, not during it, because a tool call's
/// final shape is not known until the stream ends; the reserved slots are filled
/// in one pass at the end.
List<GroupedActivity> groupActivities(List<AgentActivity> activities) {
  final result = <GroupedActivity?>[];
  // Insertion-ordered, matching the JS `Map` upstream keys tool calls by: the
  // final fill pass walks it, and while the slot index makes the *output* order
  // independent of it, keeping the guarantee explicit costs nothing.
  final toolCallsById = <String, _ToolCallAccumulator>{};
  _TextGroup? currentTextGroup;

  void flushTextGroup() {
    final group = currentTextGroup;
    if (group == null) {
      return;
    }

    result.add(
      GroupedTextMessage(
        messageType: group.messageType,
        text: group.chunks.join(),
        startTimestamp: group.startTimestamp,
        endTimestamp: group.endTimestamp,
      ),
    );
    currentTextGroup = null;
  }

  for (final activity in activities) {
    final update = activity.update;

    final textChunk = switch (update) {
      UserMessageChunk(:final text) => (TextMessageType.user, text),
      AgentMessageChunk(:final text) => (TextMessageType.agent, text),
      AgentThoughtChunk(:final text) => (TextMessageType.thought, text),
      _ => null,
    };

    if (textChunk != null) {
      final (messageType, text) = textChunk;
      final group = currentTextGroup;

      if (group != null && group.messageType == messageType) {
        group.chunks.add(text);
        group.endTimestamp = activity.timestamp;
      } else {
        flushTextGroup();

        currentTextGroup = _TextGroup(
          messageType: messageType,
          chunks: [text],
          startTimestamp: activity.timestamp,
          endTimestamp: activity.timestamp,
        );
      }
      continue;
    }

    if (update is ToolCall || update is ToolCallUpdate) {
      flushTextGroup();
      _applyToolCallUpdate(
        update: update,
        timestamp: activity.timestamp,
        result: result,
        toolCallsById: toolCallsById,
      );
      continue;
    }

    flushTextGroup();
    result.add(activity);
  }

  flushTextGroup();

  for (final toolCall in toolCallsById.values) {
    result[toolCall.insertIndex] = toolCall.toMergedToolCall();
  }

  // Upstream's `result.filter(isGroupedActivity)`. Every reserved slot is filled
  // by the loop above, so in practice nothing is dropped; the filter is kept
  // because it is what makes the placeholder scheme total.
  return [for (final item in result) ?item];
}

void _applyToolCallUpdate({
  required SessionUpdate update,
  required DateTime timestamp,
  required List<GroupedActivity?> result,
  required Map<String, _ToolCallAccumulator> toolCallsById,
}) {
  if (update is ToolCall) {
    final existing = toolCallsById[update.toolCallId];
    if (existing != null) {
      _mergeInitialToolCall(existing, update, timestamp);
      return;
    }
    _insertNewToolCall(
      result: result,
      toolCallsById: toolCallsById,
      accumulator: _accumulatorFromToolCall(update, timestamp, result.length),
    );
    return;
  }

  update as ToolCallUpdate;
  final existing = toolCallsById[update.toolCallId];
  if (existing != null) {
    _mergeToolCallUpdate(existing, update, timestamp);
    return;
  }
  _insertNewToolCall(
    result: result,
    toolCallsById: toolCallsById,
    accumulator: _accumulatorFromToolCallUpdate(
      update,
      timestamp,
      result.length,
    ),
  );
}

/// Folds a late-arriving initial `tool_call` into a slot an update already
/// reserved.
///
/// The title is assigned unconditionally — upstream has no truthiness guard on
/// it here, because `ToolCall.title` is required — while the optional fields
/// keep whatever the update had if the initial call omits them.
void _mergeInitialToolCall(
  _ToolCallAccumulator existing,
  ToolCall update,
  DateTime timestamp,
) {
  existing.title = update.title;
  if (update.status != null) existing.status = update.status!;
  if (update.toolKind != null) existing.toolKind = update.toolKind;
  // `if (update.input)` in JS: an *empty map* is truthy, so `{}` still
  // overwrites. Only absence skips.
  if (update.input != null) existing.input = update.input;
  if (update.output != null) existing.output = update.output;
  if (update.content != null) existing.content = update.content;
  if (update.locations != null) existing.locations = update.locations;
  existing.endTimestamp = timestamp;
}

/// Folds a patch into an existing tool call.
///
/// `input` and `output` are *merged* key-wise while `content` and `locations`
/// are replaced, because the former two accumulate arguments and results across
/// partial emissions while the latter two are always sent whole.
void _mergeToolCallUpdate(
  _ToolCallAccumulator existing,
  ToolCallUpdate update,
  DateTime timestamp,
) {
  // `if (update.title)` in JS: an empty-string title is falsy and therefore
  // does *not* clear an existing title.
  final title = update.title;
  if (title != null && title.isNotEmpty) existing.title = title;
  if (update.status != null) existing.status = update.status!;
  if (update.toolKind != null) existing.toolKind = update.toolKind;
  if (update.input != null) {
    existing.input = {...?existing.input, ...update.input!};
  }
  if (update.output != null) {
    existing.output = {...?existing.output, ...update.output!};
  }
  if (update.content != null) existing.content = update.content;
  if (update.locations != null) existing.locations = update.locations;
  existing.endTimestamp = timestamp;
}

_ToolCallAccumulator _accumulatorFromToolCall(
  ToolCall update,
  DateTime timestamp,
  int insertIndex,
) => _ToolCallAccumulator(
  toolCallId: update.toolCallId,
  title: update.title,
  status: update.status ?? AcpToolCallStatus.pending,
  toolKind: update.toolKind,
  input: update.input,
  output: update.output,
  content: update.content,
  locations: update.locations,
  startTimestamp: timestamp,
  endTimestamp: timestamp,
  insertIndex: insertIndex,
);

/// Seeds an accumulator from a patch that arrived before its announcement.
///
/// The `"Tool Call"` placeholder title is upstream's `update.title || "Tool
/// Call"` — falsy, so an empty-string title also gets the placeholder rather
/// than rendering a nameless row.
_ToolCallAccumulator _accumulatorFromToolCallUpdate(
  ToolCallUpdate update,
  DateTime timestamp,
  int insertIndex,
) => _ToolCallAccumulator(
  toolCallId: update.toolCallId,
  title: (update.title == null || update.title!.isEmpty)
      ? 'Tool Call'
      : update.title!,
  status: update.status ?? AcpToolCallStatus.pending,
  toolKind: update.toolKind,
  input: update.input,
  output: update.output,
  content: update.content,
  locations: update.locations,
  startTimestamp: timestamp,
  endTimestamp: timestamp,
  insertIndex: insertIndex,
);

/// Reserves the tool call's render position with a placeholder, filled in once
/// the whole log has been walked.
void _insertNewToolCall({
  required List<GroupedActivity?> result,
  required Map<String, _ToolCallAccumulator> toolCallsById,
  required _ToolCallAccumulator accumulator,
}) {
  result.add(null);
  toolCallsById[accumulator.toolCallId] = accumulator;
}

// ===========================================================================
// stores/session-store-hooks/selectors.ts
// ===========================================================================

/// One host's slice of the sessions snapshot.
final class SessionWorkspacesSnapshot {
  const SessionWorkspacesSnapshot({
    required this.workspaces,
    this.hasHydratedWorkspaces,
    this.emptyProjects,
  });

  /// Whether the daemon's *authoritative* workspace list has landed.
  ///
  /// Nullable, and distinct from `false`, because upstream reads
  /// `hasHydratedWorkspaces?` off a store record where the field may simply not
  /// exist yet. Both absent and `false` mean "not authoritative", which is why
  /// [selectHasHydratedWorkspaces] collapses them — but the shape is preserved
  /// so a snapshot built from a partial store round-trips.
  final bool? hasHydratedWorkspaces;

  /// Keyed by whatever the store filed each workspace under, which is not
  /// necessarily the descriptor's own id — see [resolveWorkspaceMapKeyByIdentity].
  final Map<String, WorkspaceDescriptor> workspaces;

  /// Projects with no live workspace, so a project row survives archiving its
  /// last workspace.
  final Map<String, WorkspaceProjectDescriptor>? emptyProjects;
}

/// The read model every workspace selector below takes.
final class SessionsSnapshot {
  const SessionsSnapshot({required this.sessions});

  final Map<String, SessionWorkspacesSnapshot> sessions;
}

/// The persisted sidebar ordering the user dragged into place.
final class SidebarOrderSnapshot {
  const SidebarOrderSnapshot({
    this.projectOrder = const [],
    this.workspaceOrderByProject = const {},
  });

  final List<String> projectOrder;
  final Map<String, List<String>> workspaceOrderByProject;
}

/// The cross-host project tree the sidebar renders.
final class WorkspaceStructure {
  const WorkspaceStructure({required this.projects});

  final List<WorkspaceStructureProject> projects;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceStructure &&
      workspaceStructureDeepEquals(other.projects, projects);

  @override
  int get hashCode => projects.length.hashCode;

  @override
  String toString() => 'WorkspaceStructure(${projects.length} projects)';
}

const List<String> _emptyWorkspaceKeys = [];

/// The single empty structure every empty result returns.
///
/// A shared const instance, not a fresh one: upstream returns the same object
/// so a memoised consumer sees reference stability across empty renders, and
/// `const` gives Dart the identical guarantee.
const WorkspaceStructure emptyWorkspaceStructure = WorkspaceStructure(
  projects: [],
);

/// Upstream's `Object.is`.
///
/// **Deviation, reproduced rather than papered over:** Dart's [identical] is
/// reference equality, while `Object.is` compares *primitives by value* — two
/// separately computed equal strings are `Object.is`-equal in JS but not
/// `identical` in Dart. Strings, booleans and numbers are therefore compared by
/// value here, with `Object.is`'s two numeric quirks preserved: `NaN` equals
/// itself, and `+0` does not equal `-0`.
bool jsObjectIs(Object? a, Object? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a is num && b is num) {
    if (a.isNaN && b.isNaN) return true;
    if (a == 0 && b == 0) return a.isNegative == b.isNegative;
    return a == b;
  }
  if (a is String && b is String) return a == b;
  if (a is bool && b is bool) return a == b;
  return identical(a, b);
}

/// Upstream's `fast-deep-equal`.
///
/// **Deviation:** `fast-deep-equal` walks an object's own enumerable properties
/// reflectively, which Dart cannot do. This walks collections recursively and
/// otherwise falls back to `==`, which is value equality for every type this
/// module produces — with one explicit arm for [WorkspaceStructureProject],
/// whose home (`core/paseo_app_misc.dart`) declares no `==` and which this
/// library may not edit. Without that arm the sidebar would rebuild on every
/// status-only workspace update, which is exactly the churn the deep comparison
/// exists to prevent.
bool workspaceStructureDeepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;

  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (!workspaceStructureDeepEquals(a[index], b[index])) return false;
    }
    return true;
  }

  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!workspaceStructureDeepEquals(a[key], b[key])) return false;
    }
    return true;
  }

  if (a is WorkspaceStructureProject && b is WorkspaceStructureProject) {
    return a.projectKey == b.projectKey &&
        a.projectName == b.projectName &&
        a.projectKind == b.projectKind &&
        a.iconWorkingDir == b.iconWorkingDir &&
        workspaceStructureDeepEquals(a.hosts, b.hosts) &&
        workspaceStructureDeepEquals(a.workspaceKeys, b.workspaceKeys);
  }

  if (a is WorkspaceStructure && b is WorkspaceStructure) {
    return workspaceStructureDeepEquals(a.projects, b.projects);
  }

  return a == b;
}

/// Key-wise equality for the loosely typed `input`/`output`/`content` payloads a
/// tool call carries. Same walk as [workspaceStructureDeepEquals], named
/// separately so the tool-call arm does not read as a workspace concern.
bool _jsonEquals(Object? a, Object? b) => workspaceStructureDeepEquals(a, b);

/// The two equality functions the workspace selectors are subscribed with.
///
/// Which one a call site picks is a real decision, not a detail: [identity] is
/// right for a selector that returns a stored object unchanged (a re-render is
/// wanted exactly when the store swapped it), and [deep] is right for a selector
/// that *derives* a fresh value every call (where identity would always differ
/// and every store write would re-render).
final class WorkspaceEqualityFns {
  const WorkspaceEqualityFns();

  bool identity(Object? a, Object? b) => jsObjectIs(a, b);

  bool deep(Object? a, Object? b) => workspaceStructureDeepEquals(a, b);
}

/// See [WorkspaceEqualityFns].
const WorkspaceEqualityFns workspaceEqualityFns = WorkspaceEqualityFns();

/// Reorders [items] to follow [storedOrder], leaving unlisted items where they
/// are.
///
/// The algorithm is deliberately positional rather than a sort: it walks the
/// input, and every position that *held* an ordered item gets the next item from
/// the stored order instead. That is what lets a user-dragged order coexist with
/// items the order has never heard of — a freshly created workspace stays where
/// the natural sort put it instead of jumping to one end.
///
/// The stored order is pruned to known, non-duplicated keys first, so a stale
/// entry cannot consume a slot and shift everything after it.
List<T> applyStoredOrdering<T>({
  required List<T> items,
  required List<String> storedOrder,
  required String Function(T item) getKey,
}) {
  if (items.length <= 1 || storedOrder.isEmpty) {
    return items;
  }

  final itemByKey = <String, T>{};
  for (final item in items) {
    itemByKey[getKey(item)] = item;
  }

  final prunedOrder = <String>[];
  final seen = <String>{};
  for (final key in storedOrder) {
    if (!itemByKey.containsKey(key) || seen.contains(key)) {
      continue;
    }
    seen.add(key);
    prunedOrder.add(key);
  }

  if (prunedOrder.isEmpty) {
    return items;
  }

  final orderedSet = prunedOrder.toSet();
  final ordered = <T>[];
  var orderedIndex = 0;

  for (final item in items) {
    final key = getKey(item);
    if (!orderedSet.contains(key)) {
      ordered.add(item);
      continue;
    }

    final targetKey = orderedIndex < prunedOrder.length
        ? prunedOrder[orderedIndex]
        : key;
    orderedIndex += 1;
    ordered.add(itemByKey[targetKey] ?? item);
  }

  return ordered;
}

/// The workspace a route names, or null.
///
/// Resolution goes through [resolveWorkspaceMapKeyByIdentity] rather than a
/// direct map read because a route carries the workspace's *own* id while the
/// store may be keyed by something else.
WorkspaceDescriptor? selectWorkspace(
  SessionsSnapshot state,
  String? serverId,
  String? workspaceId,
) {
  if (serverId == null ||
      serverId.isEmpty ||
      workspaceId == null ||
      workspaceId.isEmpty) {
    return null;
  }
  final workspaces = state.sessions[serverId]?.workspaces;
  final workspaceKey = resolveWorkspaceMapKeyByIdentity(
    workspaces: workspaces,
    workspaceId: workspaceId,
  );
  return workspaceKey == null ? null : workspaces?[workspaceKey];
}

/// Projects one field (or tuple of fields) out of a workspace, or null when
/// there is no workspace.
///
/// The point is subscription width: a consumer that only needs the name
/// re-renders when the name changes rather than when anything on the descriptor
/// does.
T? selectWorkspaceFields<T>(
  SessionsSnapshot state,
  String? serverId,
  String? workspaceId,
  T Function(WorkspaceDescriptor workspace) project,
) {
  final workspace = selectWorkspace(state, serverId, workspaceId);
  return workspace == null ? null : project(workspace);
}

/// The workspace's directory, never its opaque id.
///
/// An empty directory collapses to null (upstream's `|| null` is falsy, not
/// nullish), because a blank path is not a directory a caller can act on.
String? selectWorkspaceDirectory(
  SessionsSnapshot state,
  String? serverId,
  String? workspaceId,
) {
  final directory = selectWorkspace(
    state,
    serverId,
    workspaceId,
  )?.workspaceDirectory;
  return (directory == null || directory.isEmpty) ? null : directory;
}

/// Whether the route's workspace resolves at all.
bool selectWorkspaceExists(
  SessionsSnapshot state,
  String? serverId,
  String? workspaceId,
) => selectWorkspace(state, serverId, workspaceId) != null;

/// Whether this host's authoritative workspace list has landed.
bool selectHasHydratedWorkspaces(SessionsSnapshot state, String? serverId) =>
    serverId == null || serverId.isEmpty
    ? false
    : state.sessions[serverId]?.hasHydratedWorkspaces ?? false;

/// The subset of [serverIds] whose workspace lists are authoritative.
///
/// This is the gate that keeps a cached-but-unconfirmed workspace out of the
/// cross-host directory: a replica restored from disk is addressable by route
/// immediately, but must not *publish* a project row until the daemon confirms
/// it, or a stale row would appear and then vanish.
List<String> selectHydratedWorkspaceServerIds(
  SessionsSnapshot state,
  List<String> serverIds,
) => [
  for (final serverId in serverIds)
    if (state.sessions[serverId]?.hasHydratedWorkspaces == true) serverId,
];

/// The cross-host project list, built from the given hosts only.
///
/// Hosts with neither workspaces nor empty projects are skipped entirely rather
/// than contributing an empty session, so an idle host cannot influence the
/// result.
List<WorkspaceStructureProject> selectWorkspaceStructureProjects(
  SessionsSnapshot state,
  List<String> serverIds,
) {
  final sessions = <_WorkspaceStructureSession>[];

  for (final serverId in serverIds) {
    final session = state.sessions[serverId];
    final workspaces = session?.workspaces;
    final emptyProjects = session?.emptyProjects;
    if ((workspaces == null || workspaces.isEmpty) &&
        (emptyProjects == null || emptyProjects.isEmpty)) {
      continue;
    }
    sessions.add(
      _WorkspaceStructureSession(
        serverId: serverId,
        workspaces: workspaces?.values ?? const [],
        emptyProjects: emptyProjects?.values ?? const [],
      ),
    );
  }

  if (sessions.isEmpty) {
    return emptyWorkspaceStructure.projects;
  }

  return _buildWorkspaceStructureProjects(sessions);
}

/// The persisted project order.
///
/// Upstream's `state.projectOrder ?? EMPTY_WORKSPACE_KEYS` guards a store field
/// that may not exist; Dart's non-nullable field makes the guard unreachable, so
/// only the empty-case identity is preserved.
List<String> selectProjectOrder(SidebarOrderSnapshot state) =>
    state.projectOrder.isEmpty ? _emptyWorkspaceKeys : state.projectOrder;

/// The persisted per-project workspace order.
Map<String, List<String>> selectWorkspaceOrderByScope(
  SidebarOrderSnapshot state,
) => state.workspaceOrderByProject;

/// Applies the user's persisted ordering to a freshly built project list.
///
/// Kept separate from [selectWorkspaceStructureProjects] so the expensive
/// build re-runs only on membership changes while the cheap reorder re-runs on
/// every drag.
WorkspaceStructure composeWorkspaceStructure({
  required List<WorkspaceStructureProject> projects,
  required List<String> projectOrder,
  required Map<String, List<String>> workspaceOrderByScope,
}) {
  if (projects.isEmpty) {
    return emptyWorkspaceStructure;
  }

  final orderedProjects = applyStoredOrdering<WorkspaceStructureProject>(
    items: [
      for (final project in projects)
        WorkspaceStructureProject(
          projectKey: project.projectKey,
          projectName: project.projectName,
          projectKind: project.projectKind,
          iconWorkingDir: project.iconWorkingDir,
          hosts: project.hosts,
          workspaceKeys: applyStoredOrdering<String>(
            items: project.workspaceKeys,
            storedOrder:
                workspaceOrderByScope[project.projectKey] ??
                _emptyWorkspaceKeys,
            getKey: (workspaceKey) => workspaceKey,
          ),
        ),
    ],
    storedOrder: projectOrder,
    getKey: (project) => project.projectKey,
  );

  return WorkspaceStructure(projects: orderedProjects);
}

/// The map keys of a host's workspaces, in store order.
///
/// Deliberately the *keys*, not the ids: this feeds membership and reorder
/// detection, and the key is what the store's own iteration order is expressed
/// in.
List<String> selectWorkspaceKeys(SessionsSnapshot state, String? serverId) {
  if (serverId == null || serverId.isEmpty) {
    return _emptyWorkspaceKeys;
  }
  final workspaces = state.sessions[serverId]?.workspaces;
  return workspaces == null
      ? _emptyWorkspaceKeys
      : workspaces.keys.toList(growable: false);
}

/// Project roots worth offering when the user adds a project on this host.
///
/// Blank roots are dropped rather than offered as an unusable suggestion.
List<String> selectRecommendedProjectPaths(
  SessionsSnapshot state,
  String? serverId,
) {
  if (serverId == null || serverId.isEmpty) {
    return _emptyWorkspaceKeys;
  }
  final workspaces = state.sessions[serverId]?.workspaces;
  if (workspaces == null) {
    return _emptyWorkspaceKeys;
  }
  return [
    for (final workspace in workspaces.values)
      if (workspace.projectRootPath.isNotEmpty) workspace.projectRootPath,
  ];
}

/// Whether this host has any workspace at all.
bool selectHasWorkspaces(SessionsSnapshot state, String? serverId) {
  if (serverId == null || serverId.isEmpty) {
    return false;
  }
  return (state.sessions[serverId]?.workspaces.length ?? 0) > 0;
}

/// Every workspace status across every host, for the desktop dock badge.
///
/// Statuses only — deliberately not the workspaces — so the badge subscription
/// survives any descriptor change that does not move a workspace between
/// buckets.
///
/// **Deviation:** upstream's `workspace.status` *is* the badge status type
/// because both are the same string union. This repo splits them into
/// [WorkspaceStateBucket] (the wire enum) and [DesktopBadgeWorkspaceStatus] (the
/// badge enum), so the same five members are mapped across explicitly.
List<DesktopBadgeWorkspaceStatus> selectWorkspaceStatusesForBadges(
  SessionsSnapshot state,
) {
  final statuses = <DesktopBadgeWorkspaceStatus>[];
  for (final session in state.sessions.values) {
    for (final workspace in session.workspaces.values) {
      statuses.add(desktopBadgeStatusFromWorkspaceState(workspace.status));
    }
  }
  return statuses;
}

/// Maps the wire status bucket onto the badge status. Total in both directions —
/// the two enums carry the same five members.
DesktopBadgeWorkspaceStatus desktopBadgeStatusFromWorkspaceState(
  WorkspaceStateBucket status,
) => switch (status) {
  WorkspaceStateBucket.attention => DesktopBadgeWorkspaceStatus.attention,
  WorkspaceStateBucket.needsInput => DesktopBadgeWorkspaceStatus.needsInput,
  WorkspaceStateBucket.failed => DesktopBadgeWorkspaceStatus.failed,
  WorkspaceStateBucket.running => DesktopBadgeWorkspaceStatus.running,
  WorkspaceStateBucket.done => DesktopBadgeWorkspaceStatus.done,
};

// ---------------------------------------------------------------------------
// projects/workspace-structure.ts (private dependency of the selectors above)
// ---------------------------------------------------------------------------
//
// Upstream `selectors.ts` imports `buildWorkspaceStructureProjects` from
// `projects/workspace-structure.ts`. That module is outside this port's cluster
// and has no Dart home; only its *types* were ported, into
// `core/paseo_app_misc.dart`, by a port that needed them for
// `buildHostProjectList`. The builder is therefore reproduced here as private
// code, exactly as `core/paseo_ui_utils.dart` carries a private copy of
// `file-explorer/preview-target.ts`. Reusing the public types rather than
// re-declaring them keeps the two halves of that upstream module compatible.

final class _WorkspaceStructureSession {
  const _WorkspaceStructureSession({
    required this.serverId,
    required this.workspaces,
    required this.emptyProjects,
  });

  final String serverId;
  final Iterable<WorkspaceDescriptor> workspaces;
  final Iterable<WorkspaceProjectDescriptor> emptyProjects;
}

final class _RawStructureWorkspace {
  const _RawStructureWorkspace({
    required this.workspaceId,
    required this.workspaceName,
    required this.workspaceKey,
  });

  final String workspaceId;
  final String workspaceName;
  final String workspaceKey;
}

final class _RawStructureProject {
  _RawStructureProject({
    required this.projectKey,
    required this.projectName,
    required this.projectKind,
    required this.iconWorkingDir,
  });

  final String projectKey;
  final String projectName;
  final WorkspaceProjectKind projectKind;
  final String iconWorkingDir;

  /// Insertion-ordered per host, matching the JS `Map` upstream keys by server
  /// id — a later host re-registers itself with fresher placement data without
  /// moving in the list.
  final LinkedHashMap<String, WorkspaceStructureHostPlacement> hosts =
      LinkedHashMap<String, WorkspaceStructureHostPlacement>();

  final List<_RawStructureWorkspace> workspaces = [];
}

/// A digit code unit.
bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// Approximates `String.prototype.localeCompare(other, undefined, { numeric:
/// true, sensitivity: "base" })`.
///
/// **Deviation:** Dart's core library ships no ICU collator, and the app's
/// `intl` dependency exposes no comparator either. This reproduces the two
/// properties the sidebar ordering actually depends on — digit runs compare as
/// numbers so `w2` precedes `w10`, and case differences do not separate
/// otherwise-equal names — and falls back to UTF-16 code-unit order for
/// everything else. It therefore diverges from ICU on accents (`é` sorts after
/// `z` here) and on punctuation weighting. The divergence is confined to
/// display ordering of same-named projects and is pinned by a test so it is
/// visible rather than accidental.
int compareWorkspaceStructureNamesNumericBase(String left, String right) {
  final a = left.toLowerCase();
  final b = right.toLowerCase();
  var i = 0;
  var j = 0;

  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i);
    final cb = b.codeUnitAt(j);

    if (_isAsciiDigit(ca) && _isAsciiDigit(cb)) {
      var ai = i;
      while (ai < a.length && _isAsciiDigit(a.codeUnitAt(ai))) {
        ai += 1;
      }
      var bj = j;
      while (bj < b.length && _isAsciiDigit(b.codeUnitAt(bj))) {
        bj += 1;
      }
      // Leading zeros carry no numeric weight, but a longer significant run is
      // always the larger number.
      final an = a.substring(i, ai).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final bn = b.substring(j, bj).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (an.length != bn.length) return an.length < bn.length ? -1 : 1;
      final digitsCompare = an.compareTo(bn);
      if (digitsCompare != 0) return digitsCompare < 0 ? -1 : 1;
      i = ai;
      j = bj;
      continue;
    }

    if (ca != cb) return ca < cb ? -1 : 1;
    i += 1;
    j += 1;
  }

  if (i < a.length) return 1;
  if (j < b.length) return -1;
  return 0;
}

/// Case-insensitive comparison with no numeric handling — upstream's
/// `sensitivity: "base"` tiebreak on workspace ids.
int _compareBaseInsensitive(String left, String right) {
  final compared = left.toLowerCase().compareTo(right.toLowerCase());
  return compared == 0 ? 0 : (compared < 0 ? -1 : 1);
}

/// The project key a workspace belongs to.
///
/// The daemon's placement block wins when it carries one; the flat `projectId`
/// is the fallback for older daemons. Upstream's `??` is nullish, so a placement
/// that carries an *empty* key would keep it — reproduced by only rejecting a
/// missing or non-string value.
String _structureProjectKeyFor(WorkspaceDescriptor workspace) {
  final fromPlacement = workspace.project?['projectKey'];
  return fromPlacement is String ? fromPlacement : workspace.projectId;
}

List<WorkspaceStructureProject> _buildWorkspaceStructureProjects(
  List<_WorkspaceStructureSession> sessions,
) {
  // Insertion-ordered, matching upstream's `Map`: the sort below is stable on
  // this order, so two projects with the same display name keep the order the
  // hosts were walked in.
  final byProject = <String, _RawStructureProject>{};

  for (final session in sessions) {
    for (final emptyProject in session.emptyProjects) {
      final projectKey = emptyProject.projectId;
      final placement = WorkspaceStructureHostPlacement(
        serverId: session.serverId,
        iconWorkingDir: emptyProject.projectRootPath,
        canCreateWorktree: canCreateWorktreeForProjectKind(
          emptyProject.projectKind,
        ),
      );
      final existing = byProject[projectKey];

      if (existing == null) {
        byProject[projectKey] = _RawStructureProject(
          projectKey: projectKey,
          projectName:
              emptyProject.projectCustomName ?? emptyProject.projectDisplayName,
          projectKind: emptyProject.projectKind,
          iconWorkingDir: emptyProject.projectRootPath,
        )..hosts[session.serverId] = placement;
        continue;
      }

      existing.hosts[session.serverId] = placement;
    }

    for (final workspace in session.workspaces) {
      final projectKey = _structureProjectKeyFor(workspace);
      final existing = byProject[projectKey];
      final placement = WorkspaceStructureHostPlacement(
        serverId: session.serverId,
        iconWorkingDir: workspace.projectRootPath,
        canCreateWorktree: canCreateWorktreeForProjectKind(
          workspace.projectKind,
        ),
      );
      final entry = _RawStructureWorkspace(
        workspaceId: workspace.id,
        workspaceName: workspace.name,
        workspaceKey: '${session.serverId}:${workspace.id}',
      );

      if (existing == null) {
        byProject[projectKey] =
            _RawStructureProject(
                projectKey: projectKey,
                projectName:
                    workspace.projectCustomName ?? workspace.projectDisplayName,
                projectKind: workspace.projectKind,
                iconWorkingDir: workspace.projectRootPath,
              )
              ..hosts[session.serverId] = placement
              ..workspaces.add(entry);
        continue;
      }

      existing.hosts[session.serverId] = placement;
      existing.workspaces.add(entry);
    }
  }

  final projects = <WorkspaceStructureProject>[];
  for (final raw in byProject.values) {
    // `List.sort` is not stable in Dart while V8's is, so the original index is
    // carried as the final tiebreak.
    final indexed =
        [
          for (var index = 0; index < raw.workspaces.length; index++)
            (index, raw.workspaces[index]),
        ]..sort((left, right) {
          final nameDelta = compareWorkspaceStructureNamesNumericBase(
            left.$2.workspaceName,
            right.$2.workspaceName,
          );
          if (nameDelta != 0) return nameDelta;
          final idDelta = _compareBaseInsensitive(
            left.$2.workspaceId,
            right.$2.workspaceId,
          );
          if (idDelta != 0) return idDelta;
          return left.$1.compareTo(right.$1);
        });

    projects.add(
      WorkspaceStructureProject(
        projectKey: raw.projectKey,
        projectName: raw.projectName.isEmpty
            // Upstream's third fallback: `projectDisplayNameFromProjectId`
            // only runs when both stored names are nullish. A descriptor's
            // display name is non-nullable here, so it only applies when that
            // name is blank.
            ? projectDisplayNameFromProjectId(raw.projectKey)
            : raw.projectName,
        projectKind: raw.projectKind,
        iconWorkingDir: raw.iconWorkingDir,
        hosts: raw.hosts.values.toList(growable: false),
        workspaceKeys: [for (final entry in indexed) entry.$2.workspaceKey],
      ),
    );
  }

  final indexedProjects =
      [
        for (var index = 0; index < projects.length; index++)
          (index, projects[index]),
      ]..sort((left, right) {
        final nameDelta = compareWorkspaceStructureNamesNumericBase(
          left.$2.projectName,
          right.$2.projectName,
        );
        return nameDelta != 0 ? nameDelta : left.$1.compareTo(right.$1);
      });

  return [for (final entry in indexedProjects) entry.$2];
}

// ===========================================================================
// dictation/dictation-stream-sender.ts
// ===========================================================================

/// The most segments one flush turn will send.
///
/// The cap is the whole point of the class: a phone that buffered eight minutes
/// of native dictation while offline would otherwise push ~480 frames in one
/// synchronous burst and block the UI thread. Chunking spreads that across event
/// loop turns.
const int maxDictationChunksPerFlushTurn = 128;

/// What the daemon returns when a dictation stream is finalised.
final class DictationFinishResult {
  const DictationFinishResult({required this.dictationId, required this.text});

  final String dictationId;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is DictationFinishResult &&
      other.dictationId == dictationId &&
      other.text == text;

  @override
  int get hashCode => Object.hash(dictationId, text);

  @override
  String toString() =>
      'DictationFinishResult(dictationId: $dictationId, text: $text)';
}

/// The slice of a daemon client [DictationStreamSender] drives.
///
/// **Deviation:** upstream types against the whole `DaemonClient`. This repo's
/// `core/daemon_client.dart` carries no dictation RPCs yet, so the four calls
/// plus the connection flag are declared as an injected interface — which is
/// also what keeps this state machine testable without a socket.
abstract interface class DictationStreamTransport {
  bool get isConnected;

  Future<void> startDictationStream(String dictationId, String format);

  void sendDictationStreamChunk(
    String dictationId,
    int seq,
    String audio,
    String format,
  );

  Future<DictationFinishResult> finishDictationStream(
    String dictationId,
    int finalSeq,
  );

  void cancelDictationStream(String dictationId);
}

/// Cancels a scheduled flush.
typedef DictationFlushHandle = void Function();

/// Schedules [callback] on the next event loop turn, returning its canceller.
///
/// Upstream this is `setTimeout(fn, 0)`. It is a parameter so a test can step
/// the flush loop one turn at a time and observe the chunk cap, rather than
/// racing a real timer.
typedef DictationFlushScheduler =
    DictationFlushHandle Function(void Function() callback);

/// Yields to the event loop once. Upstream's `waitForNextFlushTurn`.
typedef DictationFlushTurn = Future<void> Function();

DictationFlushHandle _defaultDictationFlushScheduler(void Function() callback) {
  final timer = Timer(Duration.zero, callback);
  return timer.cancel;
}

Future<void> _defaultDictationFlushTurn() =>
    Future<void>.delayed(Duration.zero);

/// Small, non-widget state machine for dictation streaming.
///
/// Responsibilities:
/// - maintain an ordered buffer of base64 PCM segments;
/// - start or restart a dictation stream (its `dictationId`);
/// - send the segments the daemon has not seen yet, when connected;
/// - finish or cancel the stream.
///
/// Sending stays *synchronous* on purpose — there is no internal async mutex —
/// so an enqueue can never miss a flush because another flush was mid-`await`.
/// The only asynchrony is the deliberate turn yield that caps burst size.
final class DictationStreamSender {
  DictationStreamSender({
    required DictationStreamTransport? initialTransport,
    required this.format,
    required this.createDictationId,
    required this.translate,
    this.scheduleFlushTurn = _defaultDictationFlushScheduler,
    this.awaitFlushTurn = _defaultDictationFlushTurn,
    this.onStartError,
  }) : _transport = initialTransport;

  /// The audio MIME type every chunk is labelled with.
  final String format;

  /// Mints a dictation id.
  ///
  /// **Deviation:** upstream defaults this to `generateMessageId` from
  /// `types/stream.ts`, which has no Dart port. Required rather than defaulted
  /// so no logic path here reaches for a random source of its own.
  final String Function() createDictationId;

  /// The `i18n.t` stand-in for the two user-facing finish errors. Upstream calls
  /// the module-global `i18n`; injecting it keeps this library free of a
  /// singleton.
  final ComposerTranslator translate;

  /// Where a background start failure is reported. Upstream writes it to
  /// `console.error`; a callback keeps that observable instead of swallowed.
  final void Function(Object error, StackTrace stackTrace)? onStartError;

  /// See [DictationFlushScheduler].
  final DictationFlushScheduler scheduleFlushTurn;

  /// See [DictationFlushTurn].
  final DictationFlushTurn awaitFlushTurn;

  DictationStreamTransport? _transport;

  String? _dictationId;
  int _sendSeq = 0;
  List<String> _segments = [];
  bool _streamReady = false;
  DictationFlushHandle? _cancelScheduledFlush;
  List<Completer<void>> _drainWaiters = [];

  /// Bumped on every (re)start so a stale start continuation cannot mark a
  /// newer stream ready — the reconnect race this whole class exists for.
  int _startGeneration = 0;
  Future<void>? _startFuture;

  /// Swaps the transport, e.g. after a reconnect produced a new client.
  void setTransport(DictationStreamTransport? transport) {
    _transport = transport;
  }

  /// The live stream's id, or null when no stream is running.
  String? getDictationId() => _dictationId;

  int getSegmentCount() => _segments.length;

  /// The sequence number of the last buffered segment; `-1` when empty.
  int getFinalSeq() => _segments.length - 1;

  bool hasSegments() => _segments.isNotEmpty;

  /// Forgets everything, including the buffered audio.
  void clearAll() {
    _clearScheduledFlush();
    _dictationId = null;
    _sendSeq = 0;
    _segments = [];
    _streamReady = false;
    _startFuture = null;
    _startGeneration += 1;
  }

  /// Forgets the *stream* but keeps the audio, so the next start replays it from
  /// sequence zero. This is what a reconnect does.
  void resetStreamForReplay() {
    _clearScheduledFlush();
    _dictationId = null;
    _sendSeq = 0;
    _streamReady = false;
    _startFuture = null;
    _startGeneration += 1;
  }

  /// Buffers one base64 PCM segment and sends it if the stream is live.
  ///
  /// While disconnected this only buffers — the segments survive for the replay
  /// after reconnect, which is why nothing is dropped here.
  void enqueueSegment(String base64Pcm) {
    _segments.add(base64Pcm);

    final transport = _transport;
    if (transport == null || !transport.isConnected) {
      return;
    }

    if (_dictationId == null) {
      if (_startFuture == null) {
        unawaited(
          restartStream('enqueue').catchError((Object error, StackTrace stack) {
            onStartError?.call(error, stack);
          }),
        );
      }
      return;
    }

    flush();
  }

  /// Sends up to [maxDictationChunksPerFlushTurn] pending segments, returning
  /// how many went out.
  ///
  /// Reschedules itself when segments remain, and resolves anyone waiting on a
  /// drain when they do not.
  int flush() {
    final transport = _transport;
    final dictationId = _dictationId;
    if (transport == null ||
        !transport.isConnected ||
        dictationId == null ||
        !_streamReady) {
      return 0;
    }

    var sent = 0;
    while (_sendSeq < _segments.length &&
        sent < maxDictationChunksPerFlushTurn) {
      final seq = _sendSeq;
      final audio = _segments[seq];
      transport.sendDictationStreamChunk(dictationId, seq, audio, format);
      _sendSeq = seq + 1;
      sent += 1;
    }
    if (_hasPendingSegments()) {
      _scheduleFlush();
    } else {
      _resolveDrainWaiters();
    }
    return sent;
  }

  /// Starts a fresh stream and replays every buffered segment into it.
  ///
  /// [reason] is upstream's call-site marker; it is accepted and ignored so the
  /// call sites read the same.
  ///
  /// Does nothing while disconnected — there is nothing to start against, and
  /// the buffer already holds everything a later start will need.
  Future<void> restartStream(String reason) async {
    final transport = _transport;
    if (transport == null || !transport.isConnected) {
      return;
    }

    _startGeneration += 1;
    final generation = _startGeneration;

    final dictationId = createDictationId();
    _dictationId = dictationId;
    _sendSeq = 0;
    _streamReady = false;

    // A closure invoked immediately rather than `Future(...)`, so the body runs
    // synchronously up to its first `await` exactly as upstream's
    // `(async () => { … })()` does. Deferring it to the event loop instead would
    // let an `enqueueSegment` land between the id being minted and the start
    // being issued.
    Future<void> startStream() async {
      await transport.startDictationStream(dictationId, format);
      // Both guards matter: a newer restart may have superseded this one, and
      // `clearAll` may have dropped the stream entirely while the start was in
      // flight. Marking ready in either case would send chunks under an id the
      // daemon has forgotten.
      if (_startGeneration != generation) {
        return;
      }
      if (_dictationId != dictationId) {
        return;
      }
      _streamReady = true;
      flush();
    }

    late final Future<void> start;
    start = startStream()
        .then(
          (value) => value,
          onError: (Object error, StackTrace stack) {
            // Keep the segments for a retry, but clear the stream so `finish`
            // fails cleanly instead of finalising an id that was never opened.
            if (_startGeneration == generation && _dictationId == dictationId) {
              _dictationId = null;
              _streamReady = false;
            }
            Error.throwWithStackTrace(error, stack);
          },
        )
        .whenComplete(() {
          if (identical(_startFuture, start)) {
            _startFuture = null;
          }
        });

    _startFuture = start;
    await start;
  }

  /// Flushes everything and finalises the stream, returning the transcript.
  ///
  /// Throws when there is no usable transport, when the stream cannot be
  /// started, or when the flush loop stalls because the connection dropped
  /// mid-drain — never silently returning a partial transcript.
  Future<DictationFinishResult> finish(int finalSeq) async {
    final transport = _transport;
    if (transport == null) {
      throw StateError(translate('common.errors.daemonClientUnavailable'));
    }
    if (!transport.isConnected) {
      throw StateError(translate('common.errors.daemonClientDisconnected'));
    }

    if (_dictationId == null) {
      await restartStream('finalize');
    }
    final pendingStart = _startFuture;
    if (pendingStart != null) {
      await pendingStart;
    }

    final dictationId = _dictationId;
    if (dictationId == null || !_streamReady) {
      throw StateError('Failed to start dictation stream');
    }

    flush();
    await _waitForFlushDrain();
    return transport.finishDictationStream(dictationId, finalSeq);
  }

  /// Abandons the live stream, telling the daemon to discard it, and keeps the
  /// buffered audio for a replay.
  void cancel() {
    final transport = _transport;
    final dictationId = _dictationId;
    if (transport != null && transport.isConnected && dictationId != null) {
      transport.cancelDictationStream(dictationId);
    }
    resetStreamForReplay();
  }

  bool _hasPendingSegments() => _sendSeq < _segments.length;

  void _scheduleFlush() {
    if (_cancelScheduledFlush != null) {
      return;
    }
    _cancelScheduledFlush = scheduleFlushTurn(() {
      _cancelScheduledFlush = null;
      flush();
    });
  }

  void _clearScheduledFlush() {
    final cancel = _cancelScheduledFlush;
    if (cancel == null) {
      return;
    }
    cancel();
    _cancelScheduledFlush = null;
  }

  /// Blocks until every buffered segment has been sent.
  ///
  /// Re-checks the connection on every pass so a drop mid-drain surfaces as an
  /// error rather than an await that never resolves.
  Future<void> _waitForFlushDrain() async {
    while (_hasPendingSegments()) {
      final transport = _transport;
      if (transport == null ||
          !transport.isConnected ||
          _dictationId == null ||
          !_streamReady) {
        throw StateError('Failed to flush dictation stream');
      }
      final waiter = Completer<void>();
      _drainWaiters.add(waiter);
      await waiter.future;
      await awaitFlushTurn();
    }
  }

  void _resolveDrainWaiters() {
    final waiters = _drainWaiters;
    _drainWaiters = [];
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}
