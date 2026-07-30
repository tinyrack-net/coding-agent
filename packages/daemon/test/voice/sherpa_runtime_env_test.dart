import 'dart:ffi';
import 'dart:io';

import 'package:agent_daemon/src/voice/local/sherpa/runtime_env.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('uses host defaults and configures the isolated Windows loader', () {
    expect(sherpaLibraryFileName(), isNotEmpty);
    expect(sherpaLoaderEnvironmentKey(), isNotNull);
    expect(
      applySherpaLoaderEnvironment(
        environment: Platform.environment,
        libraryDirectory: 'host-sherpa',
      )[sherpaLibraryDirectoryEnvironment],
      'host-sherpa',
    );
    configureSherpaNativeLoader(null);
    configureSherpaNativeLoader(' ');
    configureSherpaNativeLoader('/not-used', operatingSystem: 'linux');

    if (Platform.isWindows) {
      final directory = resolveSherpaLibraryDirectory();
      expect(directory, isNotNull);
      configureSherpaNativeLoader(directory);
    }
  });

  test('maps platform library names and rejects unsupported systems', () {
    expect(sherpaLibraryFileName('windows'), 'sherpa-onnx-c-api.dll');
    expect(sherpaLibraryFileName('macos'), 'libsherpa-onnx-c-api.dylib');
    expect(sherpaLibraryFileName('linux'), 'libsherpa-onnx-c-api.so');
    expect(
      () => sherpaLibraryFileName('freebsd'),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test(
    'explicit and executable-adjacent Sherpa directories take precedence',
    () {
      final explicit = resolveSherpaLibraryDirectory(
        environment: const {
          sherpaLibraryDirectoryEnvironment: r'C:\native\sherpa',
          'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
        },
        resolvedExecutable: r'C:\app\coding-agent-voice.exe',
        operatingSystem: 'windows',
        fileExists: (path) =>
            path == p.join(r'C:\native\sherpa', 'sherpa-onnx-c-api.dll'),
      );
      expect(explicit, p.normalize(r'C:\native\sherpa'));

      final sibling = resolveSherpaLibraryDirectory(
        environment: const {},
        resolvedExecutable: r'C:\app\coding-agent-voice.exe',
        operatingSystem: 'windows',
        fileExists: (path) =>
            path == p.join(r'C:\app', 'sherpa-onnx-c-api.dll'),
      );
      expect(sibling, p.normalize(r'C:\app'));
    },
  );

  test(
    'prepends loader directories without duplicating case-insensitive PATH',
    () {
      final windows = applySherpaLoaderEnvironment(
        environment: const {'Path': r'C:\Windows;C:\tools'},
        libraryDirectory: r'C:\sherpa',
        operatingSystem: 'windows',
      );
      expect(windows['Path'], r'C:\sherpa;C:\Windows;C:\tools');
      expect(windows.containsKey('PATH'), isFalse);
      expect(
        applySherpaLoaderEnvironment(
          environment: windows,
          libraryDirectory: r'C:\sherpa',
          operatingSystem: 'windows',
        )['Path'],
        windows['Path'],
      );
      final linux = applySherpaLoaderEnvironment(
        environment: const {'LD_LIBRARY_PATH': '/lib:/usr/lib'},
        libraryDirectory: '/sherpa',
        operatingSystem: 'linux',
      );
      expect(linux['LD_LIBRARY_PATH'], '/sherpa:/lib:/usr/lib');
      expect(linux[sherpaLibraryDirectoryEnvironment], '/sherpa');
      expect(
        applySherpaLoaderEnvironment(
          environment: const {'A': 'b'},
          libraryDirectory: '/ignored',
          operatingSystem: 'freebsd',
        ),
        {'A': 'b'},
      );
    },
  );

  test('resolves pinned pub cache fallbacks on Windows, Linux, and macOS', () {
    final windows = resolveSherpaLibraryDirectory(
      environment: const {'LocalAppData': r'C:\Local'},
      resolvedExecutable: r'C:\app\worker.exe',
      operatingSystem: 'windows',
      fileExists: (path) => path.endsWith(
        p.join(
          'sherpa_onnx_windows-$sherpaOnnxVersion',
          'windows',
          'sherpa-onnx-c-api.dll',
        ),
      ),
    );
    expect(windows, contains('sherpa_onnx_windows-$sherpaOnnxVersion'));

    final linux = resolveSherpaLibraryDirectory(
      environment: const {'HOME': '/home/me'},
      resolvedExecutable: '/app/worker',
      operatingSystem: 'linux',
      abi: Abi.linuxArm64,
      fileExists: (path) =>
          path.endsWith(p.join('linux', 'aarch64', 'libsherpa-onnx-c-api.so')),
    );
    expect(linux, endsWith(p.join('linux', 'aarch64')));

    final mac = resolveSherpaLibraryDirectory(
      environment: const {'PUB_CACHE': '/cache'},
      resolvedExecutable: '/app/worker',
      operatingSystem: 'macos',
      fileExists: (path) =>
          path.endsWith(p.join('macos', 'libsherpa-onnx-c-api.dylib')),
    );
    expect(
      mac,
      p.join(
        '/cache',
        'hosted',
        'pub.dev',
        'sherpa_onnx_macos-$sherpaOnnxVersion',
        'macos',
      ),
    );
  });

  test('finds Sherpa libraries in Nix-style package library layouts', () {
    final nixPaths = p.Context(style: p.Style.posix);
    const executable = '/nix/store/tinyrack/bin/coding-agent';
    final expected = nixPaths.join('/nix/store/tinyrack', 'lib', 'tinyrack');
    final resolved = resolveSherpaLibraryDirectory(
      environment: const {},
      resolvedExecutable: executable,
      operatingSystem: 'linux',
      abi: Abi.linuxX64,
      fileExists: (path) =>
          path == nixPaths.join(expected, 'libsherpa-onnx-c-api.so'),
    );

    expect(resolved, nixPaths.normalize(expected));
  });

  test('returns null without a usable library and resolves Silero assets', () {
    expect(
      resolveSherpaLibraryDirectory(
        environment: const {},
        resolvedExecutable: '/app/worker',
        operatingSystem: 'linux',
        fileExists: (_) => false,
      ),
      isNull,
    );

    expect(
      resolveBundledSileroVadModelPath(
        environment: const {sileroVadAssetEnvironment: '/models/vad.onnx'},
        resolvedExecutable: '/app/worker',
        fileExists: (path) => path == '/models/vad.onnx',
      ),
      p.normalize('/models/vad.onnx'),
    );
    expect(
      resolveBundledSileroVadModelPath(
        environment: const {},
        resolvedExecutable: '/app/worker',
        fileExists: (path) => path == p.join('/app', 'silero_vad.onnx'),
      ),
      p.join('/app', 'silero_vad.onnx'),
    );
    expect(
      () => resolveBundledSileroVadModelPath(
        environment: const {},
        resolvedExecutable: '/app/worker',
        fileExists: (_) => false,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains(sileroVadAssetEnvironment),
        ),
      ),
    );
  });
}
