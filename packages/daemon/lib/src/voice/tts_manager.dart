import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import 'speech_provider.dart';
import 'voice_types.dart';

const int maxTtsSegmentChars = 260;
const int ttsPrefetchSegments = 2;
const Duration closedAudioIdTtl = Duration(seconds: 10);

typedef AudioOutputEmitter = void Function(AudioOutputMessage message);

final class TtsManager {
  TtsManager({
    required this.sessionId,
    required TextToSpeechResolver resolveTts,
    String Function()? createAudioId,
    DateTime Function()? now,
    void Function(String message)? onWarning,
  }) : _resolveTts = resolveTts,
       _createAudioId = createAudioId ?? const Uuid().v4,
       _now = now ?? DateTime.now,
       _onWarning = onWarning;

  final String sessionId;
  final TextToSpeechResolver _resolveTts;
  final String Function() _createAudioId;
  final DateTime Function() _now;
  final void Function(String message)? _onWarning;
  final Map<String, _PendingPlayback> _pendingPlaybacks = {};
  final Map<String, DateTime> _recentlyClosedAudioIds = {};

  Future<void> generateAndWaitForPlayback({
    required String text,
    required AudioOutputEmitter emitMessage,
    required VoiceAbortSignal abortSignal,
    required bool isVoiceMode,
  }) async {
    final segments = _splitTextForTts(text);
    final inflight = <int, Future<_PreparedSegmentResult>>{};
    var nextSegmentToSchedule = 0;

    void scheduleNextSegments() {
      while (nextSegmentToSchedule < segments.length &&
          inflight.length < ttsPrefetchSegments) {
        final segment = segments[nextSegmentToSchedule];
        inflight[segment.index] = _scheduleSegmentSynthesis(
          segment,
          abortSignal,
        );
        nextSegmentToSchedule += 1;
      }
    }

    scheduleNextSegments();

    try {
      for (final segment in segments) {
        if (abortSignal.aborted) return;

        final result = await inflight[segment.index]!;
        inflight.remove(segment.index);
        scheduleNextSegments();

        switch (result) {
          case _PreparedSegmentAborted():
            return;
          case _PreparedSegmentError(:final error, :final stackTrace):
            Error.throwWithStackTrace(error, stackTrace);
          case _PreparedSegmentReady(:final prepared):
            await _emitPreparedSegment(
              prepared: prepared,
              emitMessage: emitMessage,
              abortSignal: abortSignal,
              isVoiceMode: isVoiceMode,
            );
        }

        scheduleNextSegments();
      }
    } finally {
      _cleanupPrefetchedSegments(inflight);
    }
  }

  void confirmAudioPlayed(String chunkId) {
    final separator = chunkId.indexOf(':');
    final audioId = separator < 0 ? chunkId : chunkId.substring(0, separator);
    final pending = _pendingPlaybacks[audioId];

    if (pending == null) {
      final now = _now();
      _pruneRecentlyClosedAudioIds(now);
      final expiresAt = _recentlyClosedAudioIds[audioId];
      if (expiresAt != null && expiresAt.isAfter(now)) return;
      _onWarning?.call('Received confirmation for unknown audio ID: $chunkId');
      return;
    }

    if (pending.pendingChunks > 0) pending.pendingChunks -= 1;
    if (pending.pendingChunks == 0 && pending.streamEnded) {
      pending.resolve();
      _pendingPlaybacks.remove(audioId);
      _rememberClosedAudioId(audioId);
    }
  }

  void cancelPendingPlaybacks(String reason) {
    if (_pendingPlaybacks.isEmpty) return;
    for (final entry in _pendingPlaybacks.entries.toList(growable: false)) {
      entry.value.resolve();
      _pendingPlaybacks.remove(entry.key);
      _rememberClosedAudioId(entry.key);
    }
  }

  void cleanup() {
    for (final entry in _pendingPlaybacks.entries.toList(growable: false)) {
      entry.value.reject(StateError('Session closed'));
      _pendingPlaybacks.remove(entry.key);
      _rememberClosedAudioId(entry.key);
    }
  }

  Future<_PreparedSegment> _synthesizeSegment(
    _TtsSegment segment,
    VoiceAbortSignal abortSignal,
  ) async {
    final tts = _resolveTts();
    if (tts == null) throw StateError('TTS not configured');
    if (abortSignal.aborted) throw StateError('TTS synthesis aborted');

    final speech = await tts.synthesizeSpeech(segment.text);
    if (abortSignal.aborted) {
      await speech.destroy();
      throw StateError('TTS synthesis aborted');
    }

    return _PreparedSegment(
      index: segment.index,
      text: segment.text,
      speech: speech,
    );
  }

  Future<_PreparedSegmentResult> _scheduleSegmentSynthesis(
    _TtsSegment segment,
    VoiceAbortSignal abortSignal,
  ) async {
    try {
      final prepared = await _synthesizeSegment(segment, abortSignal);
      if (abortSignal.aborted) {
        await prepared.speech.destroy();
        return const _PreparedSegmentAborted();
      }
      return _PreparedSegmentReady(prepared);
    } catch (error, stackTrace) {
      if (abortSignal.aborted) return const _PreparedSegmentAborted();
      return _PreparedSegmentError(error, stackTrace);
    }
  }

  void _cleanupPrefetchedSegments(
    Map<int, Future<_PreparedSegmentResult>> inflight,
  ) {
    for (final pending in inflight.values) {
      unawaited(
        pending
            .then((result) async {
              if (result case _PreparedSegmentReady(:final prepared)) {
                await _destroyQuietly(prepared.speech);
              }
            })
            .catchError((_) {}),
      );
    }
  }

  Future<void> _emitPreparedSegment({
    required _PreparedSegment prepared,
    required AudioOutputEmitter emitMessage,
    required VoiceAbortSignal abortSignal,
    required bool isVoiceMode,
  }) async {
    final speech = prepared.speech;
    final audioId = _createAudioId();
    final playbackCompleter = Completer<void>();
    final pending = _PendingPlayback(playbackCompleter);
    _pendingPlaybacks[audioId] = pending;

    StreamSubscription<List<int>>? subscription;
    final streamDone = Completer<void>();
    final buffers = <List<int>>[];
    var abortObserverActive = true;
    var abortCleanup = Future<void>.value();
    final removeAbortListener = abortSignal.addAbortListener(() {
      abortCleanup = () async {
        if (!abortObserverActive) return;
        pending.streamEnded = true;
        pending.pendingChunks = 0;
        _pendingPlaybacks.remove(audioId);
        _rememberClosedAudioId(audioId);
        pending.resolve();
        await subscription?.cancel();
        if (!streamDone.isCompleted) streamDone.complete();
        await _destroyQuietly(speech);
      }();
    });

    try {
      if (abortSignal.aborted) {
        pending.streamEnded = true;
        pending.pendingChunks = 0;
        _pendingPlaybacks.remove(audioId);
        _rememberClosedAudioId(audioId);
        pending.resolve();
      } else {
        subscription = speech.stream.listen(
          (chunk) {
            if (!abortSignal.aborted) buffers.add(List<int>.from(chunk));
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!streamDone.isCompleted) {
              streamDone.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (!streamDone.isCompleted) streamDone.complete();
          },
          cancelOnError: true,
        );
        await streamDone.future;
      }

      if (!abortSignal.aborted && buffers.isNotEmpty) {
        final bytes = <int>[for (final buffer in buffers) ...buffer];
        final chunkId = '$audioId:0';
        pending.pendingChunks = 1;
        emitMessage(
          AudioOutputMessage(
            payload: AudioOutputPayload(
              id: chunkId,
              groupId: audioId,
              chunkIndex: 0,
              isLastChunk: true,
              audio: base64Encode(bytes),
              format: speech.format,
              isVoiceMode: isVoiceMode,
            ),
          ),
        );
      }

      pending.streamEnded = true;
      if (pending.pendingChunks == 0) {
        _pendingPlaybacks.remove(audioId);
        _rememberClosedAudioId(audioId);
        pending.resolve();
      }

      await playbackCompleter.future;
    } catch (_) {
      if (!abortSignal.aborted) {
        _pendingPlaybacks.remove(audioId);
        rethrow;
      }
    } finally {
      abortObserverActive = false;
      removeAbortListener();
      await abortCleanup;
      await subscription?.cancel();
      await _destroyQuietly(speech);
    }
  }

  Future<void> _destroyQuietly(SpeechStreamResult speech) async {
    try {
      await speech.destroy();
    } catch (_) {
      // Node Readable.destroy() is best-effort in the frozen implementation.
    }
  }

  void _pruneRecentlyClosedAudioIds(DateTime now) {
    _recentlyClosedAudioIds.removeWhere(
      (_, expiresAt) => !expiresAt.isAfter(now),
    );
  }

  void _rememberClosedAudioId(String audioId) {
    final now = _now();
    _pruneRecentlyClosedAudioIds(now);
    _recentlyClosedAudioIds[audioId] = now.add(closedAudioIdTtl);
  }
}

List<_TtsSegment> _splitTextForTts(String text) {
  final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) {
    throw StateError('Cannot synthesize empty text');
  }

  final parts = <_TtsSegment>[];
  var segmentIndex = 0;
  for (final sentence in _splitAfterPunctuation(normalized, '.!?')) {
    for (final fragment in _splitOversizedFragment(
      sentence,
      maxTtsSegmentChars,
    )) {
      parts.add(_TtsSegment(index: segmentIndex, text: fragment));
      segmentIndex += 1;
    }
  }
  return parts;
}

List<String> _splitOversizedFragment(String fragment, int maxChars) {
  final trimmed = fragment.trim();
  if (trimmed.isEmpty) return const [];
  if (trimmed.length <= maxChars) return [trimmed];

  final clauseChunks = _splitAfterPunctuation(trimmed, ',;:');
  if (clauseChunks.length > 1) {
    final parts = <String>[];
    var current = '';

    void pushCurrent() {
      final value = current.trim();
      if (value.isNotEmpty) parts.add(value);
      current = '';
    }

    for (final clause in clauseChunks) {
      final clauseText = clause.trim();
      if (clauseText.isEmpty) continue;
      if (clauseText.length > maxChars) {
        pushCurrent();
        parts.addAll(_splitOversizedFragment(clauseText, maxChars));
        continue;
      }
      if (current.isEmpty) {
        current = clauseText;
        continue;
      }
      final candidate = '$current $clauseText';
      if (candidate.length <= maxChars) {
        current = candidate;
        continue;
      }
      pushCurrent();
      current = clauseText;
    }

    pushCurrent();
    if (parts.length > 1 || parts.first != trimmed) return parts;
  }

  final parts = <String>[];
  var remaining = trimmed;
  while (remaining.length > maxChars) {
    var index = remaining.lastIndexOf(' ', maxChars);
    if (index < (maxChars * 0.5).floor()) index = maxChars;
    parts.add(remaining.substring(0, index).trim());
    remaining = remaining.substring(index).trim();
  }
  if (remaining.isNotEmpty) parts.add(remaining);
  return parts;
}

List<String> _splitAfterPunctuation(String value, String punctuation) {
  final parts = <String>[];
  var start = 0;
  for (var index = 0; index + 1 < value.length; index += 1) {
    if (punctuation.contains(value[index]) && value[index + 1] == ' ') {
      parts.add(value.substring(start, index + 1));
      start = index + 2;
      index += 1;
    }
  }
  parts.add(value.substring(start));
  return parts;
}

final class _TtsSegment {
  const _TtsSegment({required this.index, required this.text});

  final int index;
  final String text;
}

final class _PreparedSegment {
  const _PreparedSegment({
    required this.index,
    required this.text,
    required this.speech,
  });

  final int index;
  final String text;
  final SpeechStreamResult speech;
}

sealed class _PreparedSegmentResult {
  const _PreparedSegmentResult();
}

final class _PreparedSegmentReady extends _PreparedSegmentResult {
  const _PreparedSegmentReady(this.prepared);

  final _PreparedSegment prepared;
}

final class _PreparedSegmentAborted extends _PreparedSegmentResult {
  const _PreparedSegmentAborted();
}

final class _PreparedSegmentError extends _PreparedSegmentResult {
  const _PreparedSegmentError(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

final class _PendingPlayback {
  _PendingPlayback(this._completer);

  final Completer<void> _completer;
  int pendingChunks = 0;
  bool streamEnded = false;

  void resolve() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void reject(Object error) {
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}
