import 'dart:typed_data';

import 'card_library.dart';
import 'storage_service.dart';

/// Mifare Classic dump 本地分析引擎（对齐 CU dump_analyzer，纯本地无网络）
/// ACL / 访问条件 / Value Block 冗余 / ASCII 视图
class DumpAnalyzer {
  static const int _printableStart = 32;
  static const int _printableEnd = 126;

  // ACL 条件 → [读, 写, inc, dec]，语义：0=禁止 1=KeyA 2=KeyB 3=KeyA或B
  static const List<List<int>> dataAccessPermissions = [
    [3, 3, 3, 3],
    [3, 2, 0, 0],
    [3, 0, 0, 0],
    [3, 2, 2, 3],
    [3, 0, 0, 3],
    [2, 0, 0, 0],
    [2, 2, 0, 0],
    [0, 0, 0, 0],
  ];

  static const _permMeaning = {
    0: '-',
    1: 'A',
    2: 'B',
    3: 'A/B',
  };

  static const String defaultKeyHex = 'FFFFFFFFFFFF';
  static const String factoryAclHex = '078069';

  /// hex → ASCII（不可打印字符显示为 .）
  static String hexToAscii(String hex) {
    final clean = _normalize(hex);
    if (clean.isEmpty) return '';
    if (clean.length.isOdd) return 'Invalid hex string';
    final buf = StringBuffer();
    for (int i = 0; i < clean.length; i += 2) {
      int v;
      try {
        v = int.parse(clean.substring(i, i + 2), radix: 16);
      } catch (_) {
        buf.write('?');
        continue;
      }
      buf.write(v >= _printableStart && v <= _printableEnd
          ? String.fromCharCode(v)
          : '.');
    }
    return buf.toString();
  }

  /// 访问条件解码：接受 4 字符（byte7,8）或 6 字符（byte6,7,8 含倒冗余）
  /// 返回 [c1, c2, c3]，倒冗余校验失败或长度非法返回 null
  static List<int>? accessConditionValues(String accessConditions) {
    final clean = _normalize(accessConditions);
    if (clean.length != 4 && clean.length != 6) return null;
    final bytes = StorageService.hexToBytes(clean);
    if (bytes.length < 2) return null;

    final offset = bytes.length == 3 ? 1 : 0;
    final c1 = (bytes[offset] >> 4) & 0x0F;
    final c2 = bytes[offset + 1] & 0x0F;
    final c3 = (bytes[offset + 1] >> 4) & 0x0F;

    // 仅完整 3 字节时校验倒冗余
    if (bytes.length == 3) {
      final invertedC1 = bytes[0] & 0x0F;
      final invertedC2 = (bytes[0] >> 4) & 0x0F;
      final invertedC3 = bytes[1] & 0x0F;
      if (invertedC1 != ((~c1) & 0x0F) ||
          invertedC2 != ((~c2) & 0x0F) ||
          invertedC3 != ((~c3) & 0x0F)) {
        return null;
      }
    }
    return [c1, c2, c3];
  }

  /// 4 个块访问值（块 0-2 + 扇区尾）编码为 6 字符 ACL hex（含倒冗余）
  static String encodeAccessConditions(List<int> values) {
    if (values.length != 4) {
      throw ArgumentError.value(values, 'values', '需要 4 个块访问值');
    }
    var c1 = 0;
    var c2 = 0;
    var c3 = 0;
    for (int block = 0; block < 4; block++) {
      final v = values[block];
      if (v < 0 || v > 7) {
        throw ArgumentError.value(v, 'value', '访问值需在 0-7');
      }
      c1 |= (v & 1) << block;
      c2 |= ((v >> 1) & 1) << block;
      c3 |= ((v >> 2) & 1) << block;
    }
    final byte6 = (((~c2) & 0x0F) << 4) | ((~c1) & 0x0F);
    final byte7 = (c1 << 4) | ((~c3) & 0x0F);
    final byte8 = (c3 << 4) | c2;
    return '${byte6.toRadixString(16).padLeft(2, '0')}'
        '${byte7.toRadixString(16).padLeft(2, '0')}'
        '${byte8.toRadixString(16).padLeft(2, '0')}'.toUpperCase();
  }

  /// 数据块访问条件描述
  static String dataAccessDescription(int condition) {
    if (condition < 0 || condition >= dataAccessPermissions.length) return '未知';
    final p = dataAccessPermissions[condition];
    return '读:${_permMeaning[p[0]]}  写:${_permMeaning[p[1]]}  '
        '充值:${_permMeaning[p[2]]}  扣款:${_permMeaning[p[3]]}';
  }

  /// 扇区尾访问条件描述（对齐 CU _decodeSectorTrailerAccess 文案）
  static String trailerAccessDescription(int condition) {
    switch (condition) {
      case 0:
        return 'KeyA: 读-, 写A; ACL: 读A, 写-; KeyB: 读A, 写A';
      case 1:
        return 'KeyA: 读-, 写B; ACL: 读A/B, 写-; KeyB: 读-, 写B';
      case 2:
        return 'KeyA: 读-, 写-; ACL: 读A, 写-; KeyB: 读A, 写-';
      case 3:
        return 'KeyA: 读-, 写-; ACL: 读A/B, 写-; KeyB: 读-, 写-';
      case 4:
        return 'KeyA: 读-, 写A; ACL: 读A, 写A; KeyB: 读A, 写A';
      case 5:
        return 'KeyA: 读-, 写B; ACL: 读A/B, 写B; KeyB: 读-, 写B';
      case 6:
        return 'KeyA: 读-, 写-; ACL: 读A/B, 写B; KeyB: 读-, 写-';
      case 7:
        return 'KeyA: 读-, 写-; ACL: 读A/B, 写-; KeyB: 读-, 写-';
      default:
        return '未知';
    }
  }

  /// Value Block 冗余校验（高 4 == 低 4，中 4 == 反码，地址段冗余）
  static bool isValidValueBlock(String valueBlock) {
    final bytes = StorageService.hexToBytes(_normalize(valueBlock));
    if (bytes.length != 16) return false;
    for (int i = 0; i < 4; i++) {
      if (bytes[i] != bytes[i + 8]) return false;
      if (bytes[i + 4] != (0xFF - bytes[i])) return false;
    }
    if (bytes[12] != bytes[14]) return false;
    if (bytes[13] != bytes[15]) return false;
    if (bytes[12] != (0xFF - bytes[13])) return false;
    return true;
  }

  /// Value Block 解析为有符号 32 位整数（小端），非 value block 返回 null
  static int? valueBlockToInt(String valueBlock) {
    final bytes = StorageService.hexToBytes(_normalize(valueBlock));
    if (bytes.length != 16 || !isValidValueBlock(valueBlock)) return null;
    int value = 0;
    for (int i = 0; i < 4; i++) {
      value |= bytes[i] << (i * 8);
    }
    if (value & 0x80000000 != 0) value -= 0x100000000;
    return value;
  }

  /// Value Block 地址字节
  static int? valueBlockAddress(String valueBlock) {
    final bytes = StorageService.hexToBytes(_normalize(valueBlock));
    if (bytes.length != 16 || !isValidValueBlock(valueBlock)) return null;
    return bytes[12];
  }

  /// 生成完整 Value Block（含全部冗余）
  static String intToValueBlock(int value, int address) {
    if (address < 0 || address > 0xFF) {
      throw RangeError.range(address, 0, 0xFF, 'address');
    }
    final b0 = value & 0xFF;
    final b1 = (value >> 8) & 0xFF;
    final b2 = (value >> 16) & 0xFF;
    final b3 = (value >> 24) & 0xFF;
    final inv = [0xFF - b0, 0xFF - b1, 0xFF - b2, 0xFF - b3];
    final bytes = [
      b0, b1, b2, b3,
      inv[0], inv[1], inv[2], inv[3],
      b0, b1, b2, b3,
      address, 0xFF - address, address, 0xFF - address,
    ];
    return StorageService.bytesToHex(Uint8List.fromList(bytes)).toUpperCase();
  }

  static String _normalize(String hex) =>
      hex.replaceAll(RegExp(r'[\s-]'), '');
}

// ========== 分析结果模型 ==========

/// 单个数据块分析结果
class BlockAnalysis {
  final int blockIndex;
  final String hex;
  final bool isTrailer;
  final int? condition;
  final String accessDescription;
  final bool isValueBlock;
  final int? valueInt;
  final int? valueAddress;
  final String ascii;

  BlockAnalysis({
    required this.blockIndex,
    required this.hex,
    required this.isTrailer,
    required this.condition,
    required this.accessDescription,
    required this.isValueBlock,
    required this.valueInt,
    required this.valueAddress,
    required this.ascii,
  });
}

/// 单个扇区分析结果
class SectorAnalysis {
  final int sector;
  final String keyA;
  final String keyB;
  final String aclHex;
  final List<int>? acl;
  final bool aclValid;
  final String sectorTrailerDescription;
  final List<BlockAnalysis> blocks;
  final bool allZero;

  SectorAnalysis({
    required this.sector,
    required this.keyA,
    required this.keyB,
    required this.aclHex,
    required this.acl,
    required this.aclValid,
    required this.sectorTrailerDescription,
    required this.blocks,
    required this.allZero,
  });

  bool get hasDefaultKeyA =>
      keyA.replaceAll(' ', '').toLowerCase() ==
      DumpAnalyzer.defaultKeyHex.toLowerCase();

  bool get hasDefaultKeyB =>
      keyB.replaceAll(' ', '').toLowerCase() ==
      DumpAnalyzer.defaultKeyHex.toLowerCase();
}

/// 整卡分析结果
class DumpAnalysis {
  final SaveCard card;
  final String uidHex;
  final String sakHex;
  final String atqaHex;
  final List<SectorAnalysis> sectors;

  DumpAnalysis({
    required this.card,
    required this.uidHex,
    required this.sakHex,
    required this.atqaHex,
    required this.sectors,
  });

  int get totalSectors => sectors.length;

  int get defaultKeyASectors => sectors.where((s) => s.hasDefaultKeyA).length;

  int get defaultKeyBSectors => sectors.where((s) => s.hasDefaultKeyB).length;

  int get factoryAclSectors => sectors
      .where((s) =>
          s.aclHex.replaceAll(' ', '').toLowerCase() ==
          DumpAnalyzer.factoryAclHex.toLowerCase())
      .length;

  int get invalidAclSectors => sectors.where((s) => !s.aclValid).length;

  int get valueBlockCount =>
      sectors.expand((s) => s.blocks).where((b) => b.isValueBlock).length;

  int get emptyBlocks => sectors
      .expand((s) => s.blocks)
      .where((b) => !b.isTrailer && _isZero(b.hex))
      .length;

  static bool _isZero(String hex) {
    final clean = hex.replaceAll(RegExp(r'\s'), '');
    if (clean.isEmpty) return true;
    return clean.replaceAll('0', '').isEmpty;
  }
}

/// 分析器：解析 Mifare Classic dump
class DumpAnalysisRunner {
  /// 分析一张卡（仅 Mifare Classic 支持；其它返回 null）
  static DumpAnalysis? analyze(SaveCard card) {
    if (!isMifareClassic(card.tag) || card.data.isEmpty) return null;

    final mfcType = tagTypeToMfClassicType(card.tag);
    final sectorCount = mfClassicGetSectorCount(mfcType);
    final sectors = <SectorAnalysis>[];

    for (int sector = 0; sector < sectorCount; sector++) {
      final firstBlock = mfClassicGetFirstBlockBySector(sector);
      final blockCount = mfClassicGetBlockCountBySector(sector);
      final trailerIdx = firstBlock + blockCount - 1;
      sectors.add(_analyzeSector(sector, firstBlock, blockCount, trailerIdx,
          card.data));
    }

    final block0 = card.data.isNotEmpty ? card.data[0] : '';
    final b0Bytes = StorageService.hexToBytes(block0);
    final uidHex = b0Bytes.length >= 4
        ? StorageService.bytesToHex(b0Bytes.sublist(0, 4))
        : '';
    final sakHex = b0Bytes.length >= 6
        ? b0Bytes[5].toRadixString(16).padLeft(2, '0')
        : '';
    final atqaHex = b0Bytes.length >= 8
        ? StorageService.bytesToHex(Uint8List.fromList([b0Bytes[7], b0Bytes[6]]))
        : '';

    return DumpAnalysis(
      card: card,
      uidHex: uidHex,
      sakHex: sakHex,
      atqaHex: atqaHex,
      sectors: sectors,
    );
  }

  static SectorAnalysis _analyzeSector(
      int sector, int firstBlock, int blockCount, int trailerIdx,
      List<String> data) {
    final String? trailerHex = trailerIdx < data.length ? data[trailerIdx] : null;
    final bytes = trailerHex != null
        ? StorageService.hexToBytes(trailerHex)
        : Uint8List(0);

    String keyA = '不可用';
    String keyB = '不可用';
    if (bytes.length >= 16) {
      keyA = _spacedHex(bytes.sublist(0, 6));
      keyB = _spacedHex(bytes.sublist(10, 16));
    }

    var aclHex = '';
    List<int>? acl;
    var aclValid = false;
    var trailerDescription = '无扇区尾数据';
    if (bytes.length >= 9) {
      final raw = '${bytes[6].toRadixString(16).padLeft(2, '0')}'
          '${bytes[7].toRadixString(16).padLeft(2, '0')}'
          '${bytes[8].toRadixString(16).padLeft(2, '0')}';
      aclHex = _spacedHex(
          Uint8List.fromList([bytes[6], bytes[7], bytes[8]]));
      acl = DumpAnalyzer.accessConditionValues(raw);
      if (acl != null) {
        aclValid = true;
        final trailerCondition =
            ((acl[0] >> 3) & 1) | (((acl[1] >> 3) & 1) << 1) | (((acl[2] >> 3) & 1) << 2);
        trailerDescription = DumpAnalyzer.trailerAccessDescription(trailerCondition);
      } else {
        trailerDescription = 'ACL 倒冗余校验失败（密钥/ACL 可能被误改）';
      }
    }

    final blocks = <BlockAnalysis>[];
    for (int i = 0; i < blockCount; i++) {
      final blockIdx = firstBlock + i;
      if (blockIdx >= data.length) break;
      blocks.add(_analyzeBlock(blockIdx, data[blockIdx],
          isTrailer: i == blockCount - 1, acl: acl));
    }

    final allZero = blocks
        .where((b) => !b.isTrailer)
        .every((b) => b.hex.replaceAll(RegExp(r'\s'), '').replaceAll('0', '').isEmpty);

    return SectorAnalysis(
      sector: sector,
      keyA: keyA,
      keyB: keyB,
      aclHex: aclHex,
      acl: acl,
      aclValid: aclValid,
      sectorTrailerDescription: trailerDescription,
      blocks: blocks,
      allZero: allZero,
    );
  }

  static BlockAnalysis _analyzeBlock(
      int blockIdx, String hex,
      {required bool isTrailer, List<int>? acl}) {
    int? condition;
    var accessDescription = '-';
    if (!isTrailer && acl != null) {
      final local = blockIdx - mfClassicGetFirstBlockBySector(
          mfClassicGetSectorByBlock(blockIdx));
      condition = local < 3
          ? ((acl[0] >> local) & 1) |
              (((acl[1] >> local) & 1) << 1) |
              (((acl[2] >> local) & 1) << 2)
          : null;
      if (condition != null) {
        accessDescription = DumpAnalyzer.dataAccessDescription(condition);
      }
    }

    final isValidValue = !isTrailer && DumpAnalyzer.isValidValueBlock(hex);
    return BlockAnalysis(
      blockIndex: blockIdx,
      hex: hex,
      isTrailer: isTrailer,
      condition: condition,
      accessDescription: accessDescription,
      isValueBlock: isValidValue,
      valueInt: isValidValue ? DumpAnalyzer.valueBlockToInt(hex) : null,
      valueAddress: isValidValue ? DumpAnalyzer.valueBlockAddress(hex) : null,
      ascii: isTrailer ? '' : DumpAnalyzer.hexToAscii(hex),
    );
  }

  static String _spacedHex(Uint8List bytes) =>
      bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
}
