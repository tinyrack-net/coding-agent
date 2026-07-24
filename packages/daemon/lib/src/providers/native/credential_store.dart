/// Disk persistence for per-provider API keys.
///
/// Layout: `<dataDir>/credentials.json`, `{providerId: base64(DPAPI-blob)}`.
/// Keys are encrypted at rest with Windows DPAPI (`CryptProtectData`, scoped
/// to the current user) so the plaintext key never touches disk — mirrors
/// the atomic tmp+rename write pattern used by `AgentStore`/`ProjectStore`.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// Windows SDK constant; not exported by package:win32. Suppresses any OS
/// prompt UI — encryption/decryption must fail rather than block on one.
const _cryptProtectUiForbidden = 0x1;

class CredentialStore {
  CredentialStore({String? dataDir}) : dataDir = dataDir ?? _defaultDataDir();

  final String dataDir;
  Map<String, String>? _cache;

  static String _defaultDataDir() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    return p.join(home, '.tinyrack-agent');
  }

  String get _file => p.join(dataDir, 'credentials.json');

  Future<Map<String, String>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final file = File(_file);
    if (!file.existsSync()) return _cache = {};
    try {
      final encoded =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final result = <String, String>{};
      for (final entry in encoded.entries) {
        final plain = _unprotect(base64Decode(entry.value as String));
        if (plain != null) result[entry.key] = plain;
      }
      return _cache = result;
    } catch (_) {
      return _cache = {};
    }
  }

  /// Returns the stored API key for [providerId], or null if unconfigured.
  Future<String?> get(String providerId) async => (await _load())[providerId];

  Future<void> set(String providerId, String apiKey) async {
    final all = Map<String, String>.of(await _load());
    all[providerId] = apiKey;
    await _persist(all);
  }

  Future<void> clear(String providerId) async {
    final all = Map<String, String>.of(await _load());
    all.remove(providerId);
    await _persist(all);
  }

  Future<void> _persist(Map<String, String> all) async {
    _cache = all;
    final encoded = <String, String>{
      for (final entry in all.entries)
        entry.key: base64Encode(_protect(entry.value)),
    };
    final file = File(_file);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(encoded), flush: true);
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    await tmp.rename(file.path);
  }

  // --- DPAPI (current-user scoped) ---

  static final _localFree = DynamicLibrary.open('kernel32.dll').lookupFunction<
      Pointer Function(Pointer),
      Pointer Function(Pointer)>('LocalFree');

  static Uint8List _protect(String plaintext) {
    final bytes = utf8.encode(plaintext);
    return using((arena) {
      final inBuf = arena<Uint8>(bytes.length);
      inBuf.asTypedList(bytes.length).setAll(0, bytes);
      final inBlob = arena<CRYPT_INTEGER_BLOB>()
        ..ref.cbData = bytes.length
        ..ref.pbData = inBuf;
      final outBlob = arena<CRYPT_INTEGER_BLOB>();
      final ok = CryptProtectData(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _cryptProtectUiForbidden,
        outBlob,
      );
      if (ok == 0) {
        throw StateError('CryptProtectData failed (${GetLastError()})');
      }
      try {
        return Uint8List.fromList(
          outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
        );
      } finally {
        _localFree(outBlob.ref.pbData.cast());
      }
    });
  }

  static String? _unprotect(Uint8List ciphertext) {
    return using((arena) {
      final inBuf = arena<Uint8>(ciphertext.length);
      inBuf.asTypedList(ciphertext.length).setAll(0, ciphertext);
      final inBlob = arena<CRYPT_INTEGER_BLOB>()
        ..ref.cbData = ciphertext.length
        ..ref.pbData = inBuf;
      final outBlob = arena<CRYPT_INTEGER_BLOB>();
      final ok = CryptUnprotectData(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _cryptProtectUiForbidden,
        outBlob,
      );
      if (ok == 0) return null;
      try {
        return utf8.decode(
          outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
        );
      } finally {
        _localFree(outBlob.ref.pbData.cast());
      }
    });
  }
}
