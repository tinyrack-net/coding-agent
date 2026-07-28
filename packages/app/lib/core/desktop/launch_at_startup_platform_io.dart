// coverage:ignore-file

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:win32_registry/win32_registry.dart';

import 'launch_at_startup_platform.dart';

LaunchAtStartupPlatform createPlatform() => _IoLaunchAtStartup();

final class _IoLaunchAtStartup implements LaunchAtStartupPlatform {
  _AutoStartBackend _backend = const _UnsupportedAutoStart();

  @override
  void setup({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {
    if (Platform.isWindows) {
      _backend = packageName != null && _isRunningInMsix(packageName)
          ? _WindowsMsixAutoStart(
              appName: appName,
              appPath: appPath,
              args: args,
            )
          : _WindowsRegistryAutoStart(
              appName: appName,
              appPath: appPath,
              args: args,
            );
    } else if (Platform.isLinux) {
      _backend = _LinuxAutoStart(
        appName: appName,
        appPath: appPath,
        args: args,
      );
    } else if (Platform.isMacOS) {
      _backend = const _MacOsAutoStart();
    }
  }

  @override
  Future<bool> disable() => _backend.disable();

  @override
  Future<bool> enable() => _backend.enable();

  @override
  Future<bool> isEnabled() => _backend.isEnabled();
}

abstract interface class _AutoStartBackend {
  Future<bool> enable();
  Future<bool> disable();
  Future<bool> isEnabled();
}

final class _UnsupportedAutoStart implements _AutoStartBackend {
  const _UnsupportedAutoStart();

  @override
  Future<bool> disable() async => false;

  @override
  Future<bool> enable() async => false;

  @override
  Future<bool> isEnabled() async => false;
}

final class _WindowsRegistryAutoStart implements _AutoStartBackend {
  _WindowsRegistryAutoStart({
    required this.appName,
    required String appPath,
    required List<String> args,
  }) : registryValue = args.isEmpty ? appPath : '$appPath ${args.join(' ')}';

  static const _runPath = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _approvedPath =
      r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  static const _approvedBytesLength = 12;

  final String appName;
  final String registryValue;

  @override
  Future<bool> isEnabled() async {
    RegistryKey? run;
    try {
      run = CURRENT_USER.open(_runPath);
      if (run.getString(appName) != registryValue) return false;
    } catch (_) {
      return false;
    } finally {
      run?.close();
    }

    RegistryKey? approved;
    try {
      approved = CURRENT_USER.open(_approvedPath);
      final value = approved.getBinary(appName);
      return value == null || value.isEmpty || value.first.isEven;
    } catch (_) {
      return true;
    } finally {
      approved?.close();
    }
  }

  @override
  Future<bool> enable() async {
    final run = CURRENT_USER.create(_runPath);
    try {
      run.setValue(appName, RegistryValue.string(registryValue));
    } finally {
      run.close();
    }
    final approved = CURRENT_USER.create(_approvedPath);
    try {
      final bytes = Uint8List(_approvedBytesLength)..first = 2;
      approved.setValue(appName, RegistryValue.binary(bytes));
    } finally {
      approved.close();
    }
    return true;
  }

  @override
  Future<bool> disable() async {
    _removeValue(_runPath);
    _removeValue(_approvedPath);
    return true;
  }

  void _removeValue(String path) {
    RegistryKey? key;
    try {
      key = CURRENT_USER.open(
        path,
        config: const RegistryOpenConfig(access: RegistryAccess.readWrite),
      );
      if (key.getValue(appName) != null) key.removeValue(appName);
    } catch (_) {
      // A missing key or value is already disabled.
    } finally {
      key?.close();
    }
  }
}

final class _WindowsMsixAutoStart implements _AutoStartBackend {
  const _WindowsMsixAutoStart({
    required this.appName,
    required this.appPath,
    required this.args,
  });

  final String appName;
  final String appPath;
  final List<String> args;

  File get _shortcut => File(
    '${Platform.environment['APPDATA']}\\Microsoft\\Windows\\'
    'Start Menu\\Programs\\Startup\\$appName.lnk',
  );

  @override
  Future<bool> isEnabled() async => _shortcut.existsSync();

  @override
  Future<bool> enable() async {
    final script =
        '''
\$targetPath = ${_powerShellLiteral(appPath)}
\$shortcutFile = ${_powerShellLiteral(_shortcut.path)}
\$shell = New-Object -ComObject WScript.Shell
\$shortcut = \$shell.CreateShortcut(\$shortcutFile)
\$shortcut.TargetPath = \$targetPath
\$shortcut.Arguments = ${_powerShellLiteral(args.join(' '))}
\$shortcut.Save()
''';
    final result = Process.runSync('powershell', ['-Command', script]);
    if (result.exitCode != 0) {
      throw StateError('Failed to create startup shortcut: ${result.stderr}');
    }
    return _shortcut.existsSync();
  }

  @override
  Future<bool> disable() async {
    if (_shortcut.existsSync()) await _shortcut.delete();
    return !_shortcut.existsSync();
  }
}

final class _LinuxAutoStart implements _AutoStartBackend {
  const _LinuxAutoStart({
    required this.appName,
    required this.appPath,
    required this.args,
  });

  final String appName;
  final String appPath;
  final List<String> args;

  File get _desktopFile => File(
    '${Platform.environment['HOME']}/.config/autostart/$appName.desktop',
  );

  @override
  Future<bool> isEnabled() async => _desktopFile.existsSync();

  @override
  Future<bool> enable() async {
    await _desktopFile.parent.create(recursive: true);
    await _desktopFile.writeAsString('''
[Desktop Entry]
Type=Application
Name=$appName
Comment=$appName startup script
Exec=${args.isEmpty ? appPath : '$appPath ${args.join(' ')}'}
StartupNotify=false
Terminal=false
''');
    return true;
  }

  @override
  Future<bool> disable() async {
    if (_desktopFile.existsSync()) await _desktopFile.delete();
    return true;
  }
}

final class _MacOsAutoStart implements _AutoStartBackend {
  const _MacOsAutoStart();

  static const _channel = MethodChannel('launch_at_startup');

  @override
  Future<bool> isEnabled() async {
    final result = await _channel.invokeMethod<bool>(
      'launchAtStartupIsEnabled',
    );
    if (result == null) {
      throw StateError('macOS launch-at-startup returned no state');
    }
    return result;
  }

  @override
  Future<bool> enable() async {
    if (!await isEnabled()) {
      await _channel.invokeMethod<void>('launchAtStartupSetEnabled', {
        'setEnabledValue': true,
      });
    }
    return true;
  }

  @override
  Future<bool> disable() async {
    if (await isEnabled()) {
      await _channel.invokeMethod<void>('launchAtStartupSetEnabled', {
        'setEnabledValue': false,
      });
    }
    return true;
  }
}

bool _isRunningInMsix(String packageName) =>
    Platform.resolvedExecutable.contains('WindowsApps') &&
    Platform.resolvedExecutable.contains(packageName);

String _powerShellLiteral(String value) => "'${value.replaceAll("'", "''")}'";
