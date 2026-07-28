import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

const String sherpaOnnxVersion = '1.12.28';
const String sherpaLibraryDirectoryEnvironment = 'TINYRACK_SHERPA_LIB_DIR';
const String sileroVadAssetEnvironment = 'TINYRACK_SILERO_VAD_ASSET';

typedef _SetDllDirectoryWNative = Int32 Function(Pointer<Utf16>);
typedef _SetDllDirectoryWDart = int Function(Pointer<Utf16>);

void configureSherpaNativeLoader(
  String? libraryDirectory, {
  String? operatingSystem,
}) {
  if (libraryDirectory == null ||
      libraryDirectory.trim().isEmpty ||
      (operatingSystem ?? Platform.operatingSystem) != 'windows') {
    return;
  }
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDirectory = kernel32
      .lookupFunction<_SetDllDirectoryWNative, _SetDllDirectoryWDart>(
        'SetDllDirectoryW',
      );
  using((arena) {
    final directory = libraryDirectory.toNativeUtf16(allocator: arena);
    if (setDllDirectory(directory) == 0) {
      throw StateError(
        'Failed to register the Sherpa native library directory',
      );
    }
  });
}

String sherpaLibraryFileName([String? operatingSystem]) =>
    switch (operatingSystem ?? Platform.operatingSystem) {
      'windows' => 'sherpa-onnx-c-api.dll',
      'macos' => 'libsherpa-onnx-c-api.dylib',
      'linux' => 'libsherpa-onnx-c-api.so',
      final os => throw UnsupportedError('Sherpa ONNX is unsupported on $os'),
    };

String? sherpaLoaderEnvironmentKey([String? operatingSystem]) =>
    switch (operatingSystem ?? Platform.operatingSystem) {
      'windows' => 'PATH',
      'macos' => 'DYLD_LIBRARY_PATH',
      'linux' => 'LD_LIBRARY_PATH',
      _ => null,
    };

Map<String, String> applySherpaLoaderEnvironment({
  required Map<String, String> environment,
  required String libraryDirectory,
  String? operatingSystem,
}) {
  final result = Map<String, String>.from(environment);
  final os = operatingSystem ?? Platform.operatingSystem;
  final canonicalKey = sherpaLoaderEnvironmentKey(os);
  if (canonicalKey == null) return result;
  var actualKey = canonicalKey;
  if (os == 'windows') {
    for (final key in result.keys) {
      if (key.toLowerCase() == canonicalKey.toLowerCase()) {
        actualKey = key;
        break;
      }
    }
  }
  final delimiter = os == 'windows' ? ';' : ':';
  final parts = (result[actualKey] ?? '')
      .split(delimiter)
      .where((entry) => entry.isNotEmpty)
      .toList();
  if (!parts.contains(libraryDirectory)) {
    parts.insert(0, libraryDirectory);
  }
  result[actualKey] = parts.join(delimiter);
  result[sherpaLibraryDirectoryEnvironment] = libraryDirectory;
  return result;
}

String? resolveSherpaLibraryDirectory({
  Map<String, String>? environment,
  String? resolvedExecutable,
  String? operatingSystem,
  Abi? abi,
  bool Function(String path)? fileExists,
}) {
  final env = environment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;
  final exists = fileExists ?? (path) => File(path).existsSync();
  final library = sherpaLibraryFileName(os);
  final explicit = env[sherpaLibraryDirectoryEnvironment]?.trim();
  if (explicit != null &&
      explicit.isNotEmpty &&
      exists(p.join(explicit, library))) {
    return p.normalize(explicit);
  }

  final executableDirectory = p.dirname(
    resolvedExecutable ?? Platform.resolvedExecutable,
  );
  if (exists(p.join(executableDirectory, library))) {
    return executableDirectory;
  }

  final cacheRoot = _pubCacheRoot(env, os);
  if (cacheRoot == null) return null;
  final platform = switch (os) {
    'windows' => 'windows',
    'macos' => 'macos',
    'linux' => 'linux',
    _ => null,
  };
  if (platform == null) return null;
  var candidate = p.join(
    cacheRoot,
    'hosted',
    'pub.dev',
    'sherpa_onnx_${platform}-$sherpaOnnxVersion',
    platform,
  );
  if (os == 'linux') {
    candidate = p.join(candidate, _linuxArchitecture(abi ?? Abi.current()));
  }
  return exists(p.join(candidate, library)) ? candidate : null;
}

String resolveBundledSileroVadModelPath({
  Map<String, String>? environment,
  String? resolvedExecutable,
  bool Function(String path)? fileExists,
}) {
  final env = environment ?? Platform.environment;
  final exists = fileExists ?? (path) => File(path).existsSync();
  final explicit = env[sileroVadAssetEnvironment]?.trim();
  if (explicit != null && explicit.isNotEmpty && exists(explicit)) {
    return p.normalize(explicit);
  }
  final sibling = p.join(
    p.dirname(resolvedExecutable ?? Platform.resolvedExecutable),
    'silero_vad.onnx',
  );
  if (exists(sibling)) return sibling;
  for (final development in [
    p.join(
      Directory.current.path,
      'lib',
      'src',
      'voice',
      'local',
      'sherpa',
      'assets',
      'silero_vad.onnx',
    ),
    p.join(
      Directory.current.path,
      'packages',
      'daemon',
      'lib',
      'src',
      'voice',
      'local',
      'sherpa',
      'assets',
      'silero_vad.onnx',
    ),
  ]) {
    if (exists(development)) return development;
  }
  throw StateError(
    'Bundled Silero VAD model not found. '
    'Set $sileroVadAssetEnvironment to silero_vad.onnx.',
  );
}

String? _pubCacheRoot(Map<String, String> environment, String os) {
  final explicit = environment['PUB_CACHE']?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  if (os == 'windows') {
    final localAppData = environment.entries
        .where((entry) => entry.key.toLowerCase() == 'localappdata')
        .map((entry) => entry.value)
        .firstOrNull;
    return localAppData == null ? null : p.join(localAppData, 'Pub', 'Cache');
  }
  final home = environment['HOME']?.trim();
  return home == null || home.isEmpty ? null : p.join(home, '.pub-cache');
}

String _linuxArchitecture(Abi abi) {
  final value = abi.toString().toLowerCase();
  return value.contains('arm64') ? 'aarch64' : 'x64';
}
