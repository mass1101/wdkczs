import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:http/http.dart' as http;

const _activationPublicKeyHex =
    '3400f7b19be9f732166a76936999495584f50d745a2621ed7bf80c1f0b0bac35';

const _salt = 'CHAMELEON_ULTRA_2024';

const _activationCheckServerUrl = 'https://card.zzx1101.tk:6363';

/// Returns (max_boot_count, signature) parsed from an activation code.
/// max_boot_count = 0 means unlimited (permanent).
/// Returns null if the code is invalid.
(int, List<int>)? parseActivationCode(String inputCode) {
  final cleaned = inputCode.replaceAll(RegExp(r'[^A-Za-z2-7]'), '');
  if (cleaned.length < 8) return null;
  List<int> decoded;
  try {
    decoded = _base32Decode(cleaned);
  } catch (_) {
    return null;
  }
  if (decoded.length == 64) {
    return (0, decoded);
  } else if (decoded.length == 65) {
    return (decoded[0], decoded.sublist(1));
  }
  return null;
}

Uint8List _activationHash(String chipId, {int maxBootCount = 0}) {
  return Uint8List.fromList(
      sha256.convert(utf8.encode('$chipId:$maxBootCount:$_salt')).bytes);
}

bool validateActivationCode(String chipId, String inputCode) {
  final parsed = parseActivationCode(inputCode);
  if (parsed == null) return false;
  final (maxBootCount, sig) = parsed;
  if (sig.length != 64) return false;
  final publicKey = ed.PublicKey(_hexToBytes(_activationPublicKeyHex));
  return ed.verify(
      publicKey,
      _activationHash(chipId, maxBootCount: maxBootCount),
      Uint8List.fromList(sig));
}

Future<bool> checkChipRevokedOnline(String chipId) async {
  try {
    final resp = await http
        .get(
          Uri.parse('$_activationCheckServerUrl/api/activation/revoked')
              .replace(queryParameters: {'chip_id': chipId}),
        )
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) return false;
    final data = jsonDecode(resp.body) as Map<String, dynamic>?;
    if (data == null) return false;
    return data['revoked'] == true;
  } catch (_) {
    return false;
  }
}

Future<String?> checkActivationOnline(String chipId, String inputCode) async {
  try {
    final resp = await http
        .post(
          Uri.parse('$_activationCheckServerUrl/api/activation/check'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'chip_id': chipId, 'code': inputCode}),
        )
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) return '服务端暂时不可用，请稍后重试';
    final data = jsonDecode(resp.body) as Map<String, dynamic>?;
    if (data == null) return '服务端暂时不可用，请稍后重试';
    if (data['valid'] == false) return '激活码无效';
    if (data['revoked'] == true) return '激活码已被撤销';
    return null;
  } catch (_) {
    return '需要联网后才能激活';
  }
}

List<int> _base32Decode(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final clean = input.toUpperCase();
  final result = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final c in clean.codeUnits) {
    final index = alphabet.indexOf(String.fromCharCode(c));
    if (index == -1) throw FormatException('invalid base32 char: $c');
    buffer = (buffer << 5) | index;
    bits += 5;
    if (bits >= 8) {
      result.add((buffer >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
  }
  return result;
}

List<int> _hexToBytes(String hex) {
  final result = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    result.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return result;
}
