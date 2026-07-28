import 'checkout_pr.dart';

final class CheckoutCheckAnnotation {
  const CheckoutCheckAnnotation({
    this.path,
    this.startLine,
    this.endLine,
    this.annotationLevel,
    this.message,
    this.title,
    this.rawDetails,
  });

  final String? path;
  final num? startLine;
  final num? endLine;
  final String? annotationLevel;
  final String? message;
  final String? title;
  final String? rawDetails;

  factory CheckoutCheckAnnotation.fromJson(Map<String, Object?> json) =>
      CheckoutCheckAnnotation(
        path: _optionalString(json['path'], 'annotation.path'),
        startLine: _optionalNumber(json['startLine'], 'annotation.startLine'),
        endLine: _optionalNumber(json['endLine'], 'annotation.endLine'),
        annotationLevel: _optionalString(
          json['annotationLevel'],
          'annotation.annotationLevel',
        ),
        message: _optionalString(json['message'], 'annotation.message'),
        title: _optionalString(json['title'], 'annotation.title'),
        rawDetails: _optionalString(
          json['rawDetails'],
          'annotation.rawDetails',
        ),
      );

  Map<String, Object?> toJson() => {
    if (path != null) 'path': path,
    if (startLine != null) 'startLine': startLine,
    if (endLine != null) 'endLine': endLine,
    if (annotationLevel != null) 'annotationLevel': annotationLevel,
    if (message != null) 'message': message,
    if (title != null) 'title': title,
    if (rawDetails != null) 'rawDetails': rawDetails,
  };
}

final class CheckoutCheckFailedJob {
  const CheckoutCheckFailedJob({
    required this.jobId,
    required this.name,
    this.status,
    this.conclusion,
    this.url,
    this.logTail,
    this.logTruncated,
  });

  final num jobId;
  final String name;
  final String? status;
  final String? conclusion;
  final String? url;
  final String? logTail;
  final bool? logTruncated;

  factory CheckoutCheckFailedJob.fromJson(Map<String, Object?> json) =>
      CheckoutCheckFailedJob(
        jobId: _number(json['jobId'], 'job.jobId'),
        name: _string(json['name'], 'job.name'),
        status: _optionalString(json['status'], 'job.status'),
        conclusion: _optionalString(json['conclusion'], 'job.conclusion'),
        url: _optionalString(json['url'], 'job.url'),
        logTail: _optionalString(json['logTail'], 'job.logTail'),
        logTruncated: _optionalBool(json['logTruncated'], 'job.logTruncated'),
      );

  Map<String, Object?> toJson() => {
    'jobId': jobId,
    'name': name,
    if (status != null) 'status': status,
    if (conclusion != null) 'conclusion': conclusion,
    if (url != null) 'url': url,
    if (logTail != null) 'logTail': logTail,
    if (logTruncated != null) 'logTruncated': logTruncated,
  };
}

final class CheckoutPipelineJob {
  const CheckoutPipelineJob({
    required this.id,
    required this.name,
    required this.stage,
    required this.status,
    required this.rawStatus,
    required this.url,
    required this.allowFailure,
    required this.durationSeconds,
  });

  final num id;
  final String name;
  final String stage;
  final String status;
  final String rawStatus;
  final String? url;
  final bool allowFailure;
  final num? durationSeconds;

  factory CheckoutPipelineJob.fromJson(Map<String, Object?> json) =>
      CheckoutPipelineJob(
        id: _number(json['id'], 'pipelineJob.id'),
        name: _string(json['name'], 'pipelineJob.name'),
        stage: _string(json['stage'], 'pipelineJob.stage'),
        status: _string(json['status'], 'pipelineJob.status'),
        rawStatus: _string(json['rawStatus'], 'pipelineJob.rawStatus'),
        url: _optionalString(json['url'], 'pipelineJob.url'),
        allowFailure:
            _optionalBool(json['allowFailure'], 'pipelineJob.allowFailure') ??
            false,
        durationSeconds: _optionalNumber(
          json['durationSeconds'],
          'pipelineJob.durationSeconds',
        ),
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'stage': stage,
    'status': status,
    'rawStatus': rawStatus,
    'url': url,
    'allowFailure': allowFailure,
    'durationSeconds': durationSeconds,
  };
}

final class CheckoutPipelineStage {
  const CheckoutPipelineStage({
    required this.name,
    required this.status,
    required this.jobs,
  });

  final String name;
  final String status;
  final List<CheckoutPipelineJob> jobs;

  factory CheckoutPipelineStage.fromJson(Map<String, Object?> json) =>
      CheckoutPipelineStage(
        name: _string(json['name'], 'stage.name'),
        status: _string(json['status'], 'stage.status'),
        jobs: _objects(
          json['jobs'],
          'stage.jobs',
        ).map(CheckoutPipelineJob.fromJson).toList(growable: false),
      );

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status,
    'jobs': jobs.map((job) => job.toJson()).toList(growable: false),
  };
}

final class CheckoutPipeline {
  const CheckoutPipeline({
    required this.id,
    required this.status,
    required this.rawStatus,
    required this.url,
    required this.ref,
    required this.sha,
    required this.stages,
  });

  final num id;
  final String status;
  final String rawStatus;
  final String? url;
  final String? ref;
  final String? sha;
  final List<CheckoutPipelineStage> stages;

  factory CheckoutPipeline.fromJson(Map<String, Object?> json) =>
      CheckoutPipeline(
        id: _number(json['id'], 'pipeline.id'),
        status: _string(json['status'], 'pipeline.status'),
        rawStatus: _string(json['rawStatus'], 'pipeline.rawStatus'),
        url: _optionalString(json['url'], 'pipeline.url'),
        ref: _optionalString(json['ref'], 'pipeline.ref'),
        sha: _optionalString(json['sha'], 'pipeline.sha'),
        stages: _objects(
          json['stages'],
          'pipeline.stages',
        ).map(CheckoutPipelineStage.fromJson).toList(growable: false),
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'status': status,
    'rawStatus': rawStatus,
    'url': url,
    'ref': ref,
    'sha': sha,
    'stages': stages.map((stage) => stage.toJson()).toList(growable: false),
  };
}

final class CheckoutCheckDetails {
  const CheckoutCheckDetails({
    required this.checkRunId,
    required this.name,
    required this.annotations,
    required this.failedJobs,
    required this.truncated,
    this.workflowRunId,
    this.status,
    this.conclusion,
    this.url,
    this.detailsUrl,
    this.output,
    this.pipeline,
  });

  final num checkRunId;
  final num? workflowRunId;
  final String name;
  final String? status;
  final String? conclusion;
  final String? url;
  final String? detailsUrl;
  final Map<String, Object?>? output;
  final List<CheckoutCheckAnnotation> annotations;
  final List<CheckoutCheckFailedJob> failedJobs;
  final bool truncated;
  final CheckoutPipeline? pipeline;

  factory CheckoutCheckDetails.fromJson(Map<String, Object?> json) {
    final rawOutput = json['output'];
    final rawPipeline = json['pipeline'];
    return CheckoutCheckDetails(
      checkRunId: _number(json['checkRunId'], 'checkRunId'),
      workflowRunId: _optionalNumber(json['workflowRunId'], 'workflowRunId'),
      name: _string(json['name'], 'name'),
      status: _optionalString(json['status'], 'status'),
      conclusion: _optionalString(json['conclusion'], 'conclusion'),
      url: _optionalString(json['url'], 'url'),
      detailsUrl: _optionalString(json['detailsUrl'], 'detailsUrl'),
      output: rawOutput == null ? null : _checkOutput(rawOutput),
      annotations: _objects(
        json['annotations'],
        'annotations',
      ).map(CheckoutCheckAnnotation.fromJson).toList(growable: false),
      failedJobs: _objects(
        json['failedJobs'],
        'failedJobs',
      ).map(CheckoutCheckFailedJob.fromJson).toList(growable: false),
      truncated: _optionalBool(json['truncated'], 'truncated') ?? false,
      pipeline: rawPipeline == null
          ? null
          : CheckoutPipeline.fromJson(_map(rawPipeline, 'pipeline')),
    );
  }

  Map<String, Object?> toJson() => {
    'checkRunId': checkRunId,
    if (workflowRunId != null) 'workflowRunId': workflowRunId,
    'name': name,
    if (status != null) 'status': status,
    if (conclusion != null) 'conclusion': conclusion,
    if (url != null) 'url': url,
    if (detailsUrl != null) 'detailsUrl': detailsUrl,
    if (output != null) 'output': _checkOutput(output),
    'annotations': annotations
        .map((annotation) => annotation.toJson())
        .toList(growable: false),
    'failedJobs': failedJobs.map((job) => job.toJson()).toList(growable: false),
    'truncated': truncated,
    if (pipeline != null) 'pipeline': pipeline!.toJson(),
  };
}

final class CheckoutForgeGetCheckDetailsRequest {
  const CheckoutForgeGetCheckDetailsRequest({
    required this.type,
    required this.cwd,
    required this.requestId,
    this.repoOwner,
    this.repoName,
    this.checkRunId,
    this.workflowRunId,
    this.changeRequestNumber,
  });

  static const modernType = 'checkout.forge.get_check_details.request';
  static const legacyGithubType = 'checkout.github.get_check_details.request';
  final String type;
  final String cwd;
  final String? repoOwner;
  final String? repoName;
  final int? checkRunId;
  final int? workflowRunId;
  final int? changeRequestNumber;
  final String requestId;

  factory CheckoutForgeGetCheckDetailsRequest.fromJson(
    Map<String, Object?> json,
  ) {
    final type = json['type'];
    if (type != modernType && type != legacyGithubType) {
      throw const FormatException(
        'Invalid checkout check-details request type',
      );
    }
    return CheckoutForgeGetCheckDetailsRequest(
      type: type! as String,
      cwd: _string(json['cwd'], 'cwd'),
      repoOwner: _repoSegment(json['repoOwner'], 'repoOwner'),
      repoName: _repoSegment(json['repoName'], 'repoName'),
      checkRunId: _positiveInt(json['checkRunId'], 'checkRunId'),
      workflowRunId: _positiveInt(json['workflowRunId'], 'workflowRunId'),
      changeRequestNumber: _positiveInt(
        json['changeRequestNumber'],
        'changeRequestNumber',
      ),
      requestId: _string(json['requestId'], 'requestId'),
    );
  }

  String get responseType => type == modernType
      ? CheckoutForgeGetCheckDetailsResponse.modernType
      : CheckoutForgeGetCheckDetailsResponse.legacyGithubType;

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    if (repoOwner != null) 'repoOwner': repoOwner,
    if (repoName != null) 'repoName': repoName,
    if (checkRunId != null) 'checkRunId': checkRunId,
    if (workflowRunId != null) 'workflowRunId': workflowRunId,
    if (changeRequestNumber != null) 'changeRequestNumber': changeRequestNumber,
    'requestId': requestId,
  };
}

final class CheckoutForgeGetCheckDetailsResponse {
  const CheckoutForgeGetCheckDetailsResponse({
    required this.type,
    required this.cwd,
    required this.success,
    required this.details,
    required this.error,
    required this.requestId,
  });

  static const modernType = 'checkout.forge.get_check_details.response';
  static const legacyGithubType = 'checkout.github.get_check_details.response';
  final String type;
  final String cwd;
  final bool success;
  final CheckoutCheckDetails? details;
  final CheckoutError? error;
  final String requestId;

  factory CheckoutForgeGetCheckDetailsResponse.fromJson(
    Map<String, Object?> json,
  ) {
    final type = json['type'];
    if (type != modernType && type != legacyGithubType) {
      throw const FormatException(
        'Invalid checkout check-details response type',
      );
    }
    final payload = _map(json['payload'], 'payload');
    final rawDetails = payload['details'];
    final rawError = payload['error'];
    return CheckoutForgeGetCheckDetailsResponse(
      type: type! as String,
      cwd: _string(payload['cwd'], 'cwd'),
      success: _bool(payload['success'], 'success'),
      details: rawDetails == null
          ? null
          : CheckoutCheckDetails.fromJson(_map(rawDetails, 'details')),
      error: rawError == null
          ? null
          : CheckoutError.fromJson(_map(rawError, 'error')),
      requestId: _string(payload['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'success': success,
      'details': details?.toJson(),
      'error': error?.toJson(),
      'requestId': requestId,
    },
  };
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$field must be an object');
}

Map<String, Object?> _checkOutput(Object? value) {
  final source = _map(value, 'output');
  final output = <String, Object?>{};
  for (final field in const ['title', 'summary', 'text']) {
    if (!source.containsKey(field)) continue;
    final entry = source[field];
    if (entry != null && entry is! String) {
      throw FormatException('output.$field must be a string or null');
    }
    output[field] = entry;
  }
  return output;
}

List<Map<String, Object?>> _objects(Object? value, String field) {
  if (value == null) return const [];
  if (value is List && value.every((entry) => entry is Map)) {
    return [for (final entry in value) Map<String, Object?>.from(entry as Map)];
  }
  throw FormatException('$field must be an array of objects');
}

String _string(Object? value, String field) {
  if (value is String) return value;
  throw FormatException('$field must be a string');
}

String? _optionalString(Object? value, String field) =>
    value == null ? null : _string(value, field);

num _number(Object? value, String field) {
  if (value is num && value.isFinite) return value;
  throw FormatException('$field must be a finite number');
}

num? _optionalNumber(Object? value, String field) =>
    value == null ? null : _number(value, field);

int? _positiveInt(Object? value, String field) {
  if (value == null) return null;
  if (value is int && value > 0) return value;
  throw FormatException('$field must be a positive integer');
}

bool _bool(Object? value, String field) {
  if (value is bool) return value;
  throw FormatException('$field must be a boolean');
}

bool? _optionalBool(Object? value, String field) =>
    value == null ? null : _bool(value, field);

String? _repoSegment(Object? value, String field) {
  final result = _optionalString(value, field);
  if (result != null && !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(result)) {
    throw FormatException('$field must be a repository segment');
  }
  return result;
}
