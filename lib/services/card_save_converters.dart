import 'dart:convert';
import 'dart:typed_data';

import '../models/enums.dart';
import 'card_library.dart';
import 'storage_service.dart';

/// 导入转换器：PM3/Flipper/MCT（对齐 CU card_save_converters，输出 nfcapp SaveCard）

/// 由块数推断 MIFARE Classic 卡型（对齐 CU mfClassicGetChameleonTagType）
TagType _tagTypeByBlockCount(int blockCount) {
  switch (blockCount) {
    case 20:
      return TagType.mifareMini;
    case 64:
    case 72: // EV1
      return TagType.mifare1K;
    case 128:
      return TagType.mifare2K;
    case 256:
      return TagType.mifare4K;
    default:
      return TagType.unknown;
  }
}

/// 从 atqa hex 字符串解析为小端 2 字节（CU 约定 [lo, hi]）
List<int> _parseAtqa(String hex) {
  if (hex.length < 4) return [0, 0];
  return [
    int.parse(hex.substring(0, 2), radix: 16),
    int.parse(hex.substring(2, 4), radix: 16),
  ];
}

/// PM3 导出 JSON（Proxmark3 .json）
SaveCard pm3JsonToSaveCard(String json) {
  final data = jsonDecode(json) as Map<String, dynamic>;
  final card = data['Card'] as Map<String, dynamic>;
  final uid = card['UID'] as String;
  final sakString = card['SAK'] as String;
  final sak = StorageService.hexToBytes(sakString).isNotEmpty
      ? StorageService.hexToBytes(sakString)[0]
      : 0;
  final atqaHex = card['ATQA'] as String;
  final atqaList = _parseAtqa(atqaHex);
  final atqa = [atqaList[1], atqaList[0]];

  final blocks = <String>[];
  final blockData = data['blocks'] as Map<String, dynamic>;
  for (var i = 0; blockData.containsKey(i.toString()); i++) {
    blocks.add(blockData[i.toString()] as String);
  }

  final TagType tag;
  if (blocks.isNotEmpty && blocks[0].replaceAll(' ', '').length > 32) {
    tag = TagType.ultralight;
  } else {
    tag = _tagTypeByBlockCount(blocks.length);
  }

  return SaveCard(
    uid: uid,
    name: uid,
    tag: tag,
    sak: sak,
    atqa:
        '${atqa[0].toRadixString(16).padLeft(2, '0')}${atqa[1].toRadixString(16).padLeft(2, '0')}',
    data: blocks,
  );
}

/// Flipper .nfc
SaveCard flipperNfcToSaveCard(String data) {
  final uidMatch = RegExp(r'UID:\s+([\dA-Fa-f ]+)').firstMatch(data);
  final sakMatch = RegExp(r'SAK:\s+([\dA-Fa-f ]+)').firstMatch(data);
  final atqaMatch = RegExp(r'ATQA:\s+([\dA-Fa-f ]+)').firstMatch(data);

  final uid = uidMatch?.group(1)?.trim() ?? '';
  final sakBytes = StorageService.hexToBytes(sakMatch?.group(1)?.trim() ?? '');
  final sak = sakBytes.isNotEmpty ? sakBytes[0] : 0;
  final atqaHex = (atqaMatch?.group(1)?.trim() ?? '').replaceAll(' ', '');
  final atqaList = _parseAtqa(atqaHex);

  final blocks = <String>[];
  for (var block in data.split('\n')) {
    if (block.startsWith('Block')) {
      blocks.add(block.split(':')[1].trim().replaceAll('?', '0'));
    }
  }

  final TagType tag;
  if (blocks.isNotEmpty && blocks[0].replaceAll(' ', '').length > 32) {
    tag = TagType.ultralight;
  } else {
    tag = _tagTypeByBlockCount(blocks.length);
  }

  return SaveCard(
    uid: uid,
    name: uid,
    tag: tag,
    sak: sak,
    atqa:
        '${atqaList[1].toRadixString(16).padLeft(2, '0')}${atqaList[0].toRadixString(16).padLeft(2, '0')}',
    data: blocks,
  );
}

/// MCT（磁卡工具，+Sector 格式，与 nfcapp toDumpFileText 一致）
SaveCard mctToSaveCard(String data) {
  final lines = data.split('\n');
  if (lines.length < 2) throw const FormatException('无效的 MCT 文件');
  final header = lines[1];
  final uid = header.length >= 8 ? header.substring(0, 8) : '';
  final sak = header.length >= 12
      ? StorageService.hexToBytes(header.substring(10, 12)).isNotEmpty
            ? StorageService.hexToBytes(header.substring(10, 12))[0]
            : 0
      : 0;
  final atqaList = header.length >= 16
      ? _parseAtqa(header.substring(12, 16))
      : [0, 0];

  final blocks = <String>[];
  for (var block in data.split('\n')) {
    if (!block.startsWith('+Sector') && block.trim().isNotEmpty) {
      blocks.add(block.trim());
    }
  }

  final TagType tag;
  if (blocks.isNotEmpty && blocks[0].replaceAll(' ', '').length > 32) {
    tag = TagType.ultralight;
  } else {
    tag = _tagTypeByBlockCount(blocks.length);
  }

  return SaveCard(
    uid: uid,
    name: uid,
    tag: tag,
    sak: sak,
    atqa:
        '${atqaList[1].toRadixString(16).padLeft(2, '0')}${atqaList[0].toRadixString(16).padLeft(2, '0')}',
    data: blocks,
  );
}

/// Flipper .rfid
SaveCard flipperRfidToSaveCard(String data) {
  final typeMatch = RegExp(r'Key type:\s+(.*)').firstMatch(data);
  final type = typeMatch?.group(1)?.trim() ?? '';

  final uidMatch = RegExp(r'Data:\s+([\dA-Fa-f ]+)').firstMatch(data);
  var uid = uidMatch?.group(1)?.trim() ?? '';

  TagType tag;
  switch (type) {
    case 'EM4100':
      tag = TagType.em410X64;
      break;
    case 'EM4100/32':
      tag = TagType.em410X32;
      break;
    case 'EM4100/16':
      tag = TagType.em410X16;
      break;
    case 'H10301':
      tag = TagType.hidProx;
      // HID 10 字节编码：hidType=1, fc=uid byte0, uid=3 bytes, il=0, oem=0
      final ub = StorageService.hexToBytes(uid);
      if (ub.length >= 3) {
        final hid = <int>[1, ub[0], 0, 0, 0, ...ub.sublist(1, 3), 0, 0, 0, 0];
        uid = StorageService.bytesToHex(Uint8List.fromList(hid));
      }
      break;
    default:
      tag = TagType.unknown;
  }

  return SaveCard(uid: uid, name: uid, tag: tag);
}

/// 按 dump 字节数推断卡型（对齐 CU getTagTypeByDumpSize）
TagType? tagTypeByDumpSize(int size) {
  switch (size) {
    case 320:
      return TagType.mifareMini;
    case 1024:
      return TagType.mifare1K;
    case 1088: // EV1
    case 1152: // EV1
      return TagType.mifare1K;
    case 2048:
      return TagType.mifare2K;
    case 4096:
      return TagType.mifare4K;
    case 64:
      return TagType.ultralight;
    case 192:
      return TagType.ultralightC;
    case 80:
      return TagType.ultralight11; // also NTAG210
    case 164:
      return TagType.ultralight21; // also NTAG212
    case 180:
      return TagType.ntag213;
    case 540:
      return TagType.ntag215;
    case 924:
      return TagType.ntag216;
    default:
      return null;
  }
}

/// 可识别的二进制 dump 尺寸提示文案
const supportedBinSizes =
    '320 / 64 / 80 / 164 / 180 / 192 / 540 / 924 / 1024 / 1088 / 1152 / 2048 / 4096 字节';

/// 二进制 dump（.bin）导入：按字节数推断卡型并提取 UID/SAK/ATQA
/// 对齐 CU saved_cards 的二进制分支（无扩展名判断，纯按内容推断）
SaveCard binToSaveCard(Uint8List bytes, {String? name}) {
  final tag = tagTypeByDumpSize(bytes.length);
  if (tag == null) {
    throw FormatException(
      '无法识别的二进制 dump：${bytes.length} 字节，'
      '支持尺寸 $supportedBinSizes',
    );
  }

  String uid;
  var sak = 0;
  var atqa = '';
  final blocks = <String>[];

  if (isMifareClassic(tag)) {
    if (bytes.length < 16) throw FormatException('Classic dump 至少 16 字节');
    uid = StorageService.bytesToHex(bytes.sublist(0, 4));
    sak = bytes[5];
    // block0 中 ATQA 存为大端 [hi, lo]，转 CU/nfcapp 约定的 [lo, hi]
    atqa = StorageService.bytesToHex(Uint8List.fromList([bytes[7], bytes[6]]));
    for (int i = 0; i + 16 <= bytes.length; i += 16) {
      blocks.add(StorageService.bytesToHex(bytes.sublist(i, i + 16)));
    }
  } else {
    if (bytes.length < 8) throw FormatException('Ultralight dump 至少 8 字节');
    // page0 = [uid0,uid1,uid2,BCC]，跳过 BCC 拼 7 字节 UID
    uid = StorageService.bytesToHex(
      Uint8List.fromList([...bytes.sublist(0, 3), ...bytes.sublist(4, 8)]),
    );
    atqa = '0044';
    for (int i = 0; i + 4 <= bytes.length; i += 4) {
      blocks.add(StorageService.bytesToHex(bytes.sublist(i, i + 4)));
    }
  }

  return SaveCard(
    uid: uid,
    name: name ?? uid,
    tag: tag,
    sak: sak,
    atqa: atqa,
    data: blocks,
  );
}

/// 去除文件扩展名的基名
String baseName(String fileName) {
  final i = fileName.lastIndexOf('.');
  return i > 0 ? fileName.substring(0, i) : fileName;
}

/// 自动识别文件内容并导入（对齐 CU importCard 双阶段：先文本嗅探，失败按字节推断）
/// 返回 null 表示识别失败（调用方提示用户），抛异常表示格式明确但不支持
SaveCard? autoDetectToSaveCard(Uint8List bytes, {String? fileName}) {
  String? text;
  try {
    text = utf8.decode(bytes);
  } catch (_) {
    text = null;
  }

  if (text != null) {
    final t = text.trim();
    if (t.isNotEmpty) {
      // 字典文件夹包（魔数），不属于卡片导入
      try {
        final j = jsonDecode(t);
        if (j is Map<String, dynamic> &&
            j['format'] == 'chameleon-ultra-gui-dictionary-folder') {
          return null;
        }
      } catch (_) {}
      try {
        if (t.contains('"Created": "proxmark3",')) return pm3JsonToSaveCard(t);
        if (t.contains('Filetype: Flipper NFC device')) {
          return flipperNfcToSaveCard(t);
        }
        if (t.contains('+Sector: 0')) return mctToSaveCard(t);
        if (t.contains('Filetype: Flipper RFID key')) {
          return flipperRfidToSaveCard(t);
        }
      } catch (_) {}
    }
  }

  try {
    return binToSaveCard(bytes, name: baseName(fileName ?? ''));
  } catch (_) {
    return null;
  }
}

/// CU 单卡 JSON（CardSave）→ nfcapp SaveCard
/// CU 的 data/atqa/ats 是字节数组、color 是 hex 字符串、extra 装 ultralight 字段
SaveCard cuJsonToSaveCard(String json) {
  final d = jsonDecode(json) as Map<String, dynamic>;
  final extra = (d['extra'] ?? const {}) as Map<String, dynamic>;

  // CU 字节数组 → nfcapp 紧凑 hex 字符串
  String cuHex(List<dynamic>? l) => StorageService.bytesToHex(
    Uint8List.fromList((l ?? const []).map((e) => e as int).toList()),
  );

  var colorValue = 0xFFFF5722;
  final colorRaw = d['color'];
  if (colorRaw is String && colorRaw.isNotEmpty) {
    final hex = colorRaw.replaceAll('#', '').replaceAll(' ', '');
    if (hex.length == 6) {
      colorValue = (0xFF << 24) | int.parse(hex, radix: 16);
    }
  }

  final updatedRaw = d['updatedAt'];
  return SaveCard(
    id: d['id'] is String ? d['id'] as String : null,
    uid: d['uid'] is String ? d['uid'] as String : '',
    name: d['name'] is String ? d['name'] as String : '',
    tag: TagType.from(d['tag'] is int ? d['tag'] : TagType.mifare1K.value),
    sak: d['sak'] is int ? d['sak'] as int : 0,
    atqa: cuHex(d['atqa']),
    ats: cuHex(d['ats']),
    data: (d['data'] as List<dynamic>? ?? const [])
        .map((e) => cuHex(e is List<dynamic> ? e : null))
        .toList(),
    ultralightVersion: cuHex(extra['ultralightVersion']),
    ultralightSignature: cuHex(extra['ultralightSignature']),
    ultralightCounters:
        (extra['ultralightCounters'] as List<dynamic>? ?? const [])
            .map((e) => e is int ? e : 0)
            .toList(),
    folderId: d['folderId'] is String ? d['folderId'] as String : null,
    colorValue: colorValue,
    updatedAt: updatedRaw is String ? DateTime.tryParse(updatedRaw) : null,
  );
}

/// 判断文本是否为 CU 卡片文件夹包（chameleon-ultra-gui-folder）
bool isCuCardBundle(String text) {
  try {
    final j = jsonDecode(text.trim());
    if (j is! Map) return false;
    return j['format'] == 'chameleon-ultra-gui-folder' && j['version'] == 1;
  } catch (_) {
    return false;
  }
}
