import 'dart:convert';
import 'dart:typed_data';

import '../models/enums.dart';
import 'card_library.dart';
import 'storage_service.dart';

/// 导入转换器：PM3/Flipper/MCT（对齐 CU card_save_converters，输出 nfcapp SaveCard）

/// 由块数推断 MIFARE Classic 卡型
TagType _tagTypeByBlockCount(int blockCount) {
  if (blockCount == 256) return TagType.mifareClassic4k;
  // 64/72 = 1K，128 = 2K，20 = Mini（nfcapp 仅 1K/4K，2K/Mini 就近映射）
  return TagType.mifareClassic1k;
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
  final atqa = [
    atqaList[1],
    atqaList[0],
  ];

  final blocks = <String>[];
  final blockData = data['blocks'] as Map<String, dynamic>;
  for (var i = 0; blockData.containsKey(i.toString()); i++) {
    blocks.add(blockData[i.toString()] as String);
  }

  final TagType tag;
  if (blocks.isNotEmpty && blocks[0].replaceAll(' ', '').length > 32) {
    tag = TagType.mifareUltralight;
  } else {
    tag = _tagTypeByBlockCount(blocks.length);
  }

  return SaveCard(
    uid: uid,
    name: uid,
    tag: tag,
    sak: sak,
    atqa: '${atqa[0].toRadixString(16).padLeft(2, '0')}${atqa[1].toRadixString(16).padLeft(2, '0')}',
    data: blocks,
  );
}

/// Flipper .nfc
SaveCard flipperNfcToSaveCard(String data) {
  final uidMatch = RegExp(r'UID:\s+([\dA-Fa-f ]+)').firstMatch(data);
  final sakMatch = RegExp(r'SAK:\s+([\dA-Fa-f ]+)').firstMatch(data);
  final atqaMatch = RegExp(r'ATQA:\s+([\dA-Fa-f ]+)').firstMatch(data);

  final uid = uidMatch?.group(1)?.trim() ?? '';
  final sakBytes =
      StorageService.hexToBytes(sakMatch?.group(1)?.trim() ?? '');
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
    tag = TagType.mifareUltralight;
  } else {
    tag = _tagTypeByBlockCount(blocks.length);
  }

  return SaveCard(
    uid: uid,
    name: uid,
    tag: tag,
    sak: sak,
    atqa: '${atqaList[1].toRadixString(16).padLeft(2, '0')}${atqaList[0].toRadixString(16).padLeft(2, '0')}',
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
    tag = TagType.mifareUltralight;
  } else {
    tag = _tagTypeByBlockCount(blocks.length);
  }

  return SaveCard(
    uid: uid,
    name: uid,
    tag: tag,
    sak: sak,
    atqa: '${atqaList[1].toRadixString(16).padLeft(2, '0')}${atqaList[0].toRadixString(16).padLeft(2, '0')}',
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
      tag = TagType.em4100;
      break;
    case 'EM4100/32':
      tag = TagType.em4100;
      break;
    case 'EM4100/16':
      tag = TagType.em4100;
      break;
    case 'H10301':
      tag = TagType.hidProx;
      // HID 10 字节编码：hidType=1, fc=uid byte0, uid=3 bytes, il=0, oem=0
      final ub = StorageService.hexToBytes(uid);
      if (ub.length >= 3) {
        final hid = <int>[
          1,
          ub[0],
          0,
          0,
          0,
          ...ub.sublist(1, 3),
          0,
          0,
          0,
          0,
        ];
        uid = StorageService.bytesToHex(Uint8List.fromList(hid));
      }
      break;
    default:
      tag = TagType.em4100;
  }

  return SaveCard(uid: uid, name: uid, tag: tag);
}