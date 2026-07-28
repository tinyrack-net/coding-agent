import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'audio.dart';
import 'pcm16_resampler.dart';
import 'provider_resolver.dart';
import 'recordings_debug.dart';
import 'speech_provider.dart';
import 'stt_debug.dart';

const double defaultSttBatchCommitEverySeconds = 15;
const Duration defaultSttFinalTimeout = Duration(seconds: 120);

final class TranscriptionMetadata {
  const TranscriptionMetadata({this.agentId, this.requestId, this.label});

  final String? agentId;
  final String? requestId;
  final String? label;
}

final class SessionTranscriptionResult {
  const SessionTranscriptionResult({
    required this.text,
    required this.duration,
    required this.byteLength,
    required this.format,
    this.language,
    this.logprobs,
    this.avgLogprob,
    this.isLowConfidence,
    this.debugRecordingPath,
  });

  final String text;
  final String? language;
  final double duration;
  final List<LogprobToken>? logprobs;
  final double? avgLogprob;
  final bool? isLowConfidence;
  final String? debugRecordingPath;
  final int byteLength;
  final String format;

  TranscriptionResult get transcription => TranscriptionResult(
    text: text,
    language: language,
    duration: duration,
    logprobs: logprobs,
    avgLogprob: avgLogprob,
    isLowConfidence: isLowConfidence,
  );
}

final class SttManager {
  SttManager({
    required this.sessionId,
    required SpeechLogger logger,
    required Object? resolveStt,
    this.language = 'en',
    SttDebugAudioPersister? debugPersister,
    double? batchCommitEverySeconds,
    this.finalTimeout = defaultSttFinalTimeout,
    DateTime Function()? now,
    Map<String, String>? environment,
    String? cwd,
  }) : _logger = logger.child({
         'module': 'agent',
         'component': 'stt-manager',
         'sessionId': sessionId,
       }),
       _resolveStt = toResolver<SpeechToTextProvider?>(resolveStt),
       _now = now ?? DateTime.now,
       _batchCommitEverySeconds =
           batchCommitEverySeconds ??
           resolveSttBatchCommitEverySeconds(
             environment ?? Platform.environment,
           ),
       _debugPersister =
           debugPersister ??
           SttDebugAudioPersister(
             debugDirectory: resolveRecordingsDebugDir(
               explicitEnvironmentName: 'TINYRACK_STT_DEBUG_AUDIO_DIR',
               environment: environment ?? Platform.environment,
               cwd: cwd ?? Directory.current.path,
             ),
           );

  final String sessionId;
  final String language;
  final Duration finalTimeout;
  final SpeechLogger _logger;
  final SpeechToTextResolver _resolveStt;
  final SttDebugAudioPersister _debugPersister;
  final double _batchCommitEverySeconds;
  final DateTime Function() _now;

  SpeechToTextProvider? getProvider() => _resolveStt();

  Future<SessionTranscriptionResult> transcribe(
    Uint8List audio,
    String format, {
    TranscriptionMetadata? metadata,
  }) async {
    final stt = _resolveStt();
    if (stt == null) throw StateError('STT not configured');

    _logger.debug(
      'Transcribing audio',
      fields: {
        'bytes': audio.length,
        'format': format,
        if (metadata?.label != null) 'label': metadata!.label,
      },
    );

    String? debugRecordingPath;
    try {
      debugRecordingPath = await _debugPersister.persist(
        audio,
        DebugAudioMetadata(
          sessionId: sessionId,
          agentId: metadata?.agentId,
          requestId: metadata?.requestId,
          label: metadata?.label,
          format: format,
        ),
        _logger,
      );
    } catch (error) {
      _logger.warning(
        'Failed to persist debug audio',
        fields: {'error': error},
      );
    }

    final session = stt.createSession(
      SpeechSessionParameters(
        logger: _logger.child({'component': 'stt-session'}),
        language: language,
      ),
    );
    final pcmForModel = _preparePcmForModel(
      audio,
      format,
      session.requiredSampleRate,
    );

    final subscriptions = <StreamSubscription<Object?>>[];
    Timer? timeoutTimer;
    try {
      final startedAt = _now();
      await session.connect();

      final committedSegmentIds = <String>[];
      final transcriptsBySegmentId = <String, String>{};
      final finalTranscriptSegmentIds = <String>{};
      final transcriptMetaBySegmentId = <String, _TranscriptSegmentMeta>{};
      var expectedFinals = 0;
      var settled = false;
      final allFinalsReady = Completer<void>();

      void resolveIfComplete() {
        if (settled) return;
        if (expectedFinals > 0 &&
            finalTranscriptSegmentIds.length >= expectedFinals) {
          settled = true;
          allFinalsReady.complete();
          return;
        }
        if (expectedFinals == 0 && finalTranscriptSegmentIds.isNotEmpty) {
          settled = true;
          allFinalsReady.complete();
        }
      }

      void rejectWith(Object? error) {
        if (settled) return;
        settled = true;
        final resolved = error is Error || error is Exception
            ? error!
            : StateError('$error');
        allFinalsReady.completeError(resolved);
      }

      subscriptions
        ..add(session.errors.listen(rejectWith))
        ..add(
          session.committedEvents.listen((event) {
            committedSegmentIds.add(event.segmentId);
            expectedFinals += 1;
            resolveIfComplete();
          }),
        )
        ..add(
          session.transcriptEvents.listen((event) {
            transcriptsBySegmentId[event.segmentId] = event.transcript;
            if (!event.isFinal) return;
            finalTranscriptSegmentIds.add(event.segmentId);
            transcriptMetaBySegmentId[event.segmentId] = _TranscriptSegmentMeta(
              language: event.language,
              logprobs: event.logprobs,
              avgLogprob: event.avgLogprob,
              isLowConfidence: event.isLowConfidence,
            );
            resolveIfComplete();
          }),
        );

      final appendChunkBytes = math.max(
        1,
        (session.requiredSampleRate * 2).round(),
      );
      final commitEveryBytes = _batchCommitEverySeconds > 0
          ? math.max(
              1,
              (session.requiredSampleRate * 2 * _batchCommitEverySeconds)
                  .round(),
            )
          : 0;

      var bytesSinceCommit = 0;
      for (
        var offset = 0;
        offset < pcmForModel.length;
        offset += appendChunkBytes
      ) {
        final end = math.min(pcmForModel.length, offset + appendChunkBytes);
        final chunk = Uint8List.sublistView(pcmForModel, offset, end);
        if (chunk.isEmpty) continue;
        session.appendPcm16(chunk);
        bytesSinceCommit += chunk.length;

        if (commitEveryBytes > 0 && bytesSinceCommit >= commitEveryBytes) {
          session.commit();
          bytesSinceCommit = 0;
        }
      }

      if (bytesSinceCommit > 0 || expectedFinals == 0) {
        session.commit();
      }

      timeoutTimer = Timer(finalTimeout, () {
        if (settled) return;
        settled = true;
        _logger.warning(
          'Timed out waiting for final STT segments; returning available '
          'transcripts',
          fields: {
            'expectedFinals': expectedFinals,
            'receivedFinals': finalTranscriptSegmentIds.length,
            if (metadata?.label != null) 'label': metadata!.label,
          },
        );
        allFinalsReady.complete();
      });

      await allFinalsReady.future;
      timeoutTimer.cancel();

      final result = _assembleTranscriptionResult(
        committedSegmentIds: committedSegmentIds,
        transcriptsBySegmentId: transcriptsBySegmentId,
        finalTranscriptSegmentIds: finalTranscriptSegmentIds,
        transcriptMetaBySegmentId: transcriptMetaBySegmentId,
        durationMs: _now().difference(startedAt).inMilliseconds,
      );
      final filteredText = result.isLowConfidence == true ? '' : result.text;
      _logger.debug(
        result.isLowConfidence == true
            ? 'Filtered low-confidence transcription (likely non-speech)'
            : 'Transcription complete',
        fields: {
          'text': result.text,
          if (result.avgLogprob != null) 'avgLogprob': result.avgLogprob,
        },
      );

      return SessionTranscriptionResult(
        text: filteredText,
        language: result.language,
        duration: result.duration ?? 0,
        logprobs: result.logprobs,
        avgLogprob: result.avgLogprob,
        isLowConfidence: result.isLowConfidence,
        debugRecordingPath: debugRecordingPath,
        byteLength: audio.length,
        format: format,
      );
    } finally {
      timeoutTimer?.cancel();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      session.close();
    }
  }

  void cleanup() {}
}

double resolveSttBatchCommitEverySeconds(Map<String, String> environment) {
  final value = environment['TINYRACK_STT_BATCH_COMMIT_EVERY_SECONDS'];
  if (value == null || value.isEmpty) {
    return defaultSttBatchCommitEverySeconds;
  }
  final parsed = double.tryParse(value);
  if (parsed == null || !parsed.isFinite || parsed < 0) {
    return defaultSttBatchCommitEverySeconds;
  }
  return parsed;
}

Uint8List _preparePcmForModel(
  Uint8List audio,
  String format,
  int requiredSampleRate,
) {
  late final int inputRate;
  late final Uint8List pcm16;
  final normalized = format.toLowerCase();
  if (normalized.contains('audio/wav')) {
    final parsed = parsePcm16MonoWav(audio);
    inputRate = parsed.sampleRate;
    pcm16 = parsed.pcm16;
  } else if (normalized.contains('audio/pcm')) {
    inputRate =
        parsePcmRateFromFormat(format, requiredSampleRate) ??
        requiredSampleRate;
    pcm16 = audio;
  } else {
    throw FormatException('Unsupported audio format for STT: $format');
  }

  if (inputRate == requiredSampleRate) return pcm16;
  return Pcm16MonoResampler(
    inputRate: inputRate,
    outputRate: requiredSampleRate,
  ).processChunk(pcm16);
}

TranscriptionResult _assembleTranscriptionResult({
  required List<String> committedSegmentIds,
  required Map<String, String> transcriptsBySegmentId,
  required Set<String> finalTranscriptSegmentIds,
  required Map<String, _TranscriptSegmentMeta> transcriptMetaBySegmentId,
  required int durationMs,
}) {
  final committedSet = committedSegmentIds.toSet();
  final orderedSegmentIds = [
    ...committedSegmentIds,
    for (final segmentId in transcriptsBySegmentId.keys)
      if (!committedSet.contains(segmentId)) segmentId,
  ];
  final transcript = [
    for (final segmentId in orderedSegmentIds)
      transcriptsBySegmentId[segmentId] ?? '',
  ].join(' ').trim();
  final orderedFinalMeta = [
    for (final segmentId in orderedSegmentIds)
      if (finalTranscriptSegmentIds.contains(segmentId) &&
          transcriptMetaBySegmentId[segmentId] != null)
        transcriptMetaBySegmentId[segmentId]!,
  ];
  String? language;
  for (final metadata in orderedFinalMeta) {
    if (metadata.language?.isNotEmpty == true) {
      language = metadata.language;
      break;
    }
  }
  final singleSegmentMeta = orderedFinalMeta.length == 1
      ? orderedFinalMeta.single
      : null;
  final allLowConfidence =
      orderedFinalMeta.isNotEmpty &&
      orderedFinalMeta.every((metadata) => metadata.isLowConfidence == true);

  return TranscriptionResult(
    text: transcript,
    language: language,
    duration: durationMs.toDouble(),
    logprobs: singleSegmentMeta?.logprobs,
    avgLogprob: singleSegmentMeta?.avgLogprob,
    isLowConfidence: allLowConfidence ? true : null,
  );
}

final class _TranscriptSegmentMeta {
  const _TranscriptSegmentMeta({
    this.language,
    this.logprobs,
    this.avgLogprob,
    this.isLowConfidence,
  });

  final String? language;
  final List<LogprobToken>? logprobs;
  final double? avgLogprob;
  final bool? isLowConfidence;
}
