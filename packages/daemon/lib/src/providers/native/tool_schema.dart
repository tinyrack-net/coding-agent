/// Tool definitions advertised to the model by [NativeSession]. Kept in one
/// place since [ToolExecutor] must implement exactly this set.
library;

import 'llm_backend.dart';

final List<LlmToolSchema> nativeToolSchemas = [
  const LlmToolSchema(
    name: 'read_file',
    description: 'Read the full contents of a file in the working directory.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Path relative to the working directory.',
        },
      },
      'required': ['path'],
    },
  ),
  const LlmToolSchema(
    name: 'write_file',
    description: 'Create a file or overwrite it entirely with new content.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'content': {'type': 'string'},
      },
      'required': ['path', 'content'],
    },
  ),
  const LlmToolSchema(
    name: 'edit_file',
    description:
        'Replace one exact, unique occurrence of old_string with new_string '
        'in an existing file.',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'old_string': {'type': 'string'},
        'new_string': {'type': 'string'},
      },
      'required': ['path', 'old_string', 'new_string'],
    },
  ),
  const LlmToolSchema(
    name: 'bash',
    description:
        'Run a shell command in the working directory and return its '
        'combined stdout/stderr and exit code.',
    parameters: {
      'type': 'object',
      'properties': {
        'command': {'type': 'string'},
        'timeout_seconds': {
          'type': 'integer',
          'description': 'Defaults to 120.',
        },
      },
      'required': ['command'],
    },
  ),
  const LlmToolSchema(
    name: 'grep',
    description:
        'Search files under the working directory for a regular expression.',
    parameters: {
      'type': 'object',
      'properties': {
        'pattern': {'type': 'string'},
        'path': {
          'type': 'string',
          'description': 'Optional subdirectory to restrict the search to.',
        },
      },
      'required': ['pattern'],
    },
  ),
  const LlmToolSchema(
    name: 'glob',
    description:
        'List files under the working directory matching a glob pattern '
        '(e.g. "**/*.dart").',
    parameters: {
      'type': 'object',
      'properties': {
        'pattern': {'type': 'string'},
      },
      'required': ['pattern'],
    },
  ),
];
