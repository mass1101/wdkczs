import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:wgkczs/protobuf/dfu-cc.pb.dart';

/// nRF DFU 固件包解析（对应逆向 DfuZip）
///
/// zip 内需包含 manifest.json，其 `manifest` 对象声明各镜像的 bin_file/dat_file。
class DfuZip {
  final Uint8List bytes;

  DfuZip(this.bytes);

  /// 解析 zip 内 manifest.json 的 manifest 对象
  Map<String, dynamic>? getManifest() {
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    for (final file in archive.files) {
      if (file.name == 'manifest.json') {
        final content = utf8.decode(file.content as List<int>);
        final json = jsonDecode(content);
        if (json is Map && json['manifest'] is Map) {
          return (json['manifest'] as Map).cast<String, dynamic>();
        }
      }
    }
    return null;
  }

  /// 读取包内指定文件原始数据
  Uint8List? _fileBytes(String name) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    for (final file in archive.files) {
      if (file.name == name) {
        return Uint8List.fromList(file.content as List<int>);
      }
    }
    return null;
  }

  /// 获取镜像（对应逆向 getImage：从 dat_file/bin_file 读取）
  ({String type, Uint8List header, Uint8List body})? getImage(
      List<String> keys) {
    final manifest = getManifest();
    if (manifest == null) return null;
    for (final key in keys) {
      final entry = manifest[key];
      if (entry == null) continue;
      final dat = _fileBytes(entry['dat_file']);
      final bin = _fileBytes(entry['bin_file']);
      if (dat == null || bin == null) {
        throw Exception('Failed to read ${entry['dat_file']}/${entry['bin_file']} from DFU package');
      }
      validateImage(dat, bin);
      return (type: key, header: dat, body: bin);
    }
    return null;
  }

  /// 验证镜像（对齐 CU validateFiles：签名检查 + 哈希校验）
  static void validateImage(Uint8List dat, Uint8List bin) {
    if (dat.isEmpty || bin.isEmpty) {
      throw Exception('Empty firmware file');
    }

    final metadata = Packet.fromBuffer(dat);
    if (!metadata.hasSignedCommand()) {
      throw Exception('Package isn\'t signed');
    }

    final command = metadata.signedCommand.command;
    if (!command.hasInit()) {
      throw Exception('Package command doesn\'t have init');
    }

    final hash = command.init.hash;
    final expectedHash = hash.hash.reversed;
    final actualHash = switch (hash.hashType) {
      HashType.SHA128 => sha1,
      HashType.SHA256 => sha256,
      HashType.SHA512 => sha512,
      _ => throw Exception('Unsupported hash type ${hash.hashType}'),
    }.convert(bin).bytes;

    if (!const IterableEquality().equals(expectedHash, actualHash)) {
      throw Exception('Hashes don\'t match!');
    }
  }

  /// 获取应用镜像（application）
  /// 优先读 manifest.json；缺失时 fallback 直接读 application.dat/bin（对齐 CU unpackFirmware）
  ({String type, Uint8List header, Uint8List body})? getAppImage() {
    final image = getImage(['application']);
    if (image != null) return image;

    // fallback：包内无 manifest.json，直接按固定文件名读取（CU 固件包格式）
    final dat = _fileBytes('application.dat');
    final bin = _fileBytes('application.bin');
    if (dat == null || bin == null) return null;
    validateImage(dat, bin);
    return (type: 'application', header: dat, body: bin);
  }
}
