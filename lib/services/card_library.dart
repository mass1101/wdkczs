import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/enums.dart';
import 'storage_service.dart';

/// 本地方案库：已保存卡片模型 + 持久化（对齐 CU savedCards / folders）
/// 采用 nfcapp 原生约定：atqa/sak/ats 以 hex 字符串存储、data 为 16 进制行，
/// 不引入 uuid/crypto 依赖（id 用时间戳生成）。

/// 判断是否 MIFARE Classic 卡（对齐 CU isMifareClassic）
bool isMifareClassic(TagType tag) => _mifareClassicTypes.contains(tag);

/// 判断是否 EM410X 家族（含 Electra，对齐 CU isEM410X）
bool isEM410X(TagType tag) => _em410XTypes.contains(tag);

/// 判断是否 MIFARE Ultralight 家族（对齐 CU isMifareUltralight）
bool isMifareUltralight(TagType tag) => _ultralightTypes.contains(tag);

/// 判断是否 LF 卡（对齐 CU getTagTypesByFrequency(TagFrequency.lf)）
bool isLfTag(TagType tag) => lfTagTypes().contains(tag);

/// 判断是否 HF 卡（对齐 CU chameleonTagToFrequency == hf）
bool isHfTag(TagType tag) => hfTagTypes().contains(tag);

const List<TagType> _mifareClassicTypes = [
  TagType.mifare1K,
  TagType.mifare2K,
  TagType.mifare4K,
  TagType.mifareMini,
];

const List<TagType> _em410XTypes = [
  TagType.em410X,
  TagType.em410X16,
  TagType.em410X32,
  TagType.em410X64,
  TagType.em410XElectra,
];

const List<TagType> _ultralightTypes = [
  TagType.ntag210,
  TagType.ntag212,
  TagType.ntag213,
  TagType.ntag215,
  TagType.ntag216,
  TagType.ultralight,
  TagType.ultralightC,
  TagType.ultralight11,
  TagType.ultralight21,
];

/// HF 卡类型（顺序对齐 CU getTagTypesByFrequency(hf)）
List<TagType> hfTagTypes() => [
  TagType.mifare1K,
  TagType.mifare2K,
  TagType.mifare4K,
  TagType.mifareMini,
  TagType.ntag210,
  TagType.ntag212,
  TagType.ntag213,
  TagType.ntag215,
  TagType.ntag216,
  TagType.ultralight,
  TagType.ultralightC,
  TagType.ultralight11,
  TagType.ultralight21,
];

/// LF 卡类型（顺序对齐 CU getTagTypesByFrequency(lf)）
List<TagType> lfTagTypes() => [
  TagType.em410X,
  TagType.em410X16,
  TagType.em410X32,
  TagType.em410X64,
  TagType.em410XElectra,
  TagType.hidProx,
  TagType.viking,
  TagType.pac,
  TagType.ioProx,
  TagType.idteck,
];

/// LF 卡 UID 字节数（对齐 CU uidSizeForLfTag）
int lfUidSize(TagType tag) {
  switch (tag) {
    case TagType.em410XElectra:
      return 13;
    case TagType.em410X:
    case TagType.em410X16:
    case TagType.em410X32:
    case TagType.em410X64:
    case TagType.hidProx:
      return 5;
    case TagType.viking:
      return 4;
    case TagType.pac:
      return 8;
    case TagType.ioProx:
      return 16;
    case TagType.idteck:
      return 8;
    default:
      return 0;
  }
}

/// HID Prox 类型名称（对齐 CU getNameForHIDProxType，1-30）
String getNameForHIDProxType(int type) => _hidProxTypeNames[type - 1];

/// 由 HID Prox 字段生成 13 字节 UID 字符串（对齐 CU HIDCard.toString，大端）
String hidProxUidFromParts(
  int hidType,
  int facilityCode,
  Uint8List uid,
  int issueLevel,
  int oem,
) {
  return bytesToHexSpace(
    Uint8List.fromList([
      hidType & 0xFF,
      (facilityCode >> 24) & 0xFF,
      (facilityCode >> 16) & 0xFF,
      (facilityCode >> 8) & 0xFF,
      facilityCode & 0xFF,
      ...uid,
      issueLevel & 0xFF,
      (oem >> 8) & 0xFF,
      oem & 0xFF,
    ]),
  );
}

const List<String> _hidProxTypeNames = [
  'HID H10301 26-bit',
  'Indala 26-bit',
  'Indala 27-bit',
  'Indala ASC 27-bit',
  'Tecom 27-bit',
  '2804 Wiegand 28-bit',
  'Indala 29-bit',
  'ATS Wiegand 30-bit',
  'HID ADT 31-bit',
  'HID Check Point 32-bit',
  'HID Hewlett-Packard 32-bit',
  'Kastle 32-bit',
  'Indala/Kantech KFS 32-bit',
  'Wiegand 32-bit',
  'HID D10202 33-bit',
  'HID H10306 34-bit',
  'Honeywell/Northern N10002 34-bit',
  'Indala Optus 34-bit',
  'Cardkey Smartpass 34-bit',
  'BQT 34-bit',
  'HID Corporate 1000 35-bit Std',
  'HID KeyScan 36-bit',
  'HID Simplex 36-bit',
  'HID 36-bit Siemens',
  'HID H10320 37-bit BCD',
  'HID H10302 37-bit huge ID',
  'HID H10304 37-bit',
  'HID P10004 37-bit PCSC',
  'HID Generic 37-bit',
  'PointGuard MDI 37-bit',
];

// ========== Mifare Classic helpers (对齐 CU mifare_classic/general.dart) ==========

/// Mifare Classic 卡类型枚举
enum MfClassicType { none, mini, m1k, m2k, m4k }

/// TagType -> MfClassicType（对齐 CU chameleonTagTypeGetMfClassicType）
MfClassicType tagTypeToMfClassicType(TagType type) {
  switch (type) {
    case TagType.mifare1K:
      return MfClassicType.m1k;
    case TagType.mifare2K:
      return MfClassicType.m2k;
    case TagType.mifare4K:
      return MfClassicType.m4k;
    case TagType.mifareMini:
      return MfClassicType.mini;
    default:
      return MfClassicType.none;
  }
}

/// 获取扇区数
int mfClassicGetSectorCount(MfClassicType type) {
  switch (type) {
    case MfClassicType.m1k:
      return 16;
    case MfClassicType.m2k:
      return 32;
    case MfClassicType.m4k:
      return 40;
    case MfClassicType.mini:
      return 5;
    default:
      return 0;
  }
}

/// 每扇区块数（0-31 扇区 4 块，32+ 扇区 16 块）
int mfClassicGetBlockCountBySector(int sector) => sector < 32 ? 4 : 16;

/// 扇区对应的首块号
int mfClassicGetFirstBlockBySector(int sector) =>
    sector < 32 ? sector * 4 : 32 * 4 + (sector - 32) * 16;

/// 块号对应的扇区号
int mfClassicGetSectorByBlock(int block) =>
    block < 128 ? block ~/ 4 : 32 + (block - 128) ~/ 16;

/// 扇区尾块（sector trailer）号
int mfClassicGetSectorTrailerBlockBySector(int sector) =>
    sector < 32 ? sector * 4 + 3 : 32 * 4 + (sector - 32) * 16 + 15;

/// 计算 BCC（XOR 校验）
int calculateBcc(Uint8List data) {
  int bcc = 0;
  for (final b in data) {
    bcc ^= b;
  }
  return bcc;
}

/// 生成 Mifare Classic 块 0（制造商块）
Uint8List mfClassicGenerateFirstBlock(Uint8List uid, int sak, Uint8List atqa) {
  final block0 = Uint8List(16);
  if (uid.length == 4) {
    block0.setAll(0, uid);
    block0[4] = calculateBcc(uid);
    block0[5] = sak + 0x80;
    block0.setAll(6, atqa);
    block0.setAll(8, [0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69]);
  } else if (uid.length == 7) {
    block0.setAll(0, uid);
    block0[7] = sak + 0x80;
    block0.setAll(8, atqa);
    block0.setAll(10, [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
  }
  return block0;
}

/// 生成 Mifare Classic 默认扇区块（含 sector trailer）
List<String> generateMfClassicBlocks(TagType type) {
  final mfcType = tagTypeToMfClassicType(type);
  final sectorCount = mfClassicGetSectorCount(mfcType);
  final List<String> blocks = [];
  final sectorTrailerHex = _bytesToHexString(
    Uint8List.fromList([
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0x07,
      0x80,
      0x69,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
    ]),
  );
  for (int sector = 0; sector < sectorCount; sector++) {
    final blockCount = mfClassicGetBlockCountBySector(sector);
    for (int block = 0; block < blockCount - 1; block++) {
      blocks.add(_bytesToHexString(Uint8List(16)));
    }
    blocks.add(sectorTrailerHex);
  }
  return blocks;
}

// ========== Mifare Ultralight helpers (对齐 CU mifare_ultralight/general.dart) ==========

/// 获取卡类型的页数（对齐 CU getBlockCountForTagType）
int getBlockCountForTagType(TagType tagType) {
  switch (tagType) {
    case TagType.mifareMini:
      return 20;
    case TagType.mifare1K:
      return 64;
    case TagType.mifare2K:
      return 128;
    case TagType.mifare4K:
      return 256;
    case TagType.ultralight:
    case TagType.ultralightC:
      return 16;
    case TagType.ultralight11:
    case TagType.ultralight21:
      return 20;
    case TagType.ntag210:
      return 16;
    case TagType.ntag212:
      return 41;
    case TagType.ntag213:
      return 45;
    case TagType.ntag215:
      return 135;
    case TagType.ntag216:
      return 231;
    default:
      return 64;
  }
}

/// 获取卡类型内存大小（字节，对齐 CU getMemorySizeForTagType）
int getMemorySizeForTagType(TagType tagType) {
  switch (tagType) {
    case TagType.ultralight:
    case TagType.ultralightC:
      return 64;
    case TagType.ultralight11:
    case TagType.ultralight21:
      return 80;
    case TagType.ntag210:
      return 64;
    case TagType.ntag212:
      return 164;
    case TagType.ntag213:
      return 180;
    case TagType.ntag215:
      return 540;
    case TagType.ntag216:
      return 924;
    default:
      return 64;
  }
}

/// Ultralight 可寻址页数（对齐 CU mfUltralightGetPagesCount）
int mfUltralightGetPagesCount(TagType type) {
  switch (type) {
    case TagType.ultralight:
      return 16;
    case TagType.ultralightC:
      return 48;
    case TagType.ultralight11:
      return 20;
    case TagType.ultralight21:
      return 41;
    case TagType.ntag210:
      return 20;
    case TagType.ntag212:
      return 41;
    case TagType.ntag213:
      return 45;
    case TagType.ntag215:
      return 135;
    case TagType.ntag216:
      return 231;
    default:
      return 0;
  }
}

/// Ultralight 密码页号（对齐 CU mfUltralightGetPasswordPage，无密码支持返回 0）
int mfUltralightGetPasswordPage(TagType type) {
  switch (type) {
    case TagType.ultralight:
    case TagType.ultralightC:
      return 0;
    case TagType.ultralight11:
    case TagType.ntag210:
      return 18;
    case TagType.ultralight21:
    case TagType.ntag212:
      return 39;
    case TagType.ntag213:
      return 43;
    case TagType.ntag215:
      return 133;
    case TagType.ntag216:
      return 229;
    default:
      return 0;
  }
}

/// 是否有计数器（对齐 CU mfUltralightHasCounters）
bool mfUltralightHasCounters(TagType type) => [
  TagType.ultralight11,
  TagType.ultralight21,
  TagType.ntag210,
  TagType.ntag212,
  TagType.ntag213,
  TagType.ntag215,
  TagType.ntag216,
].contains(type);

/// 计数器数量（对齐 CU mfUltralightGetCounterCount）
int mfUltralightGetCounterCount(TagType type) {
  switch (type) {
    case TagType.ultralight11:
    case TagType.ultralight21:
      return 3;
    case TagType.ntag210:
    case TagType.ntag212:
    case TagType.ntag213:
    case TagType.ntag215:
    case TagType.ntag216:
      return 1;
    default:
      return 0;
  }
}

/// 生成 Ultralight 前三页
List<Uint8List> mfUltralightGenerateFirstBlocks(Uint8List uid) {
  final List<Uint8List> blocks = [];
  final block0 = Uint8List(4);
  block0.setAll(0, uid.sublist(0, 3));
  block0[3] = calculateBcc(Uint8List.fromList([0x88, uid[0], uid[1], uid[2]]));
  blocks.add(block0);

  final block1 = Uint8List(4);
  block1.setAll(0, uid.sublist(3, 7));
  blocks.add(block1);

  final block2 = Uint8List(4);
  block2[0] = calculateBcc(uid.sublist(3, 7));
  block2[1] = 0x48;
  block2[2] = 0x00;
  block2[3] = 0x00;
  blocks.add(block2);

  return blocks;
}

/// 生成 Ultralight 全部页
List<String> generateMfUltralightBlocks(TagType type, Uint8List uid) {
  final firstBlocks = mfUltralightGenerateFirstBlocks(uid);
  final totalBlocks = getBlockCountForTagType(type);
  final List<String> blocks = firstBlocks
      .map((b) => _bytesToHexString(b))
      .toList();

  // CC (Capability Container) at page 3
  final cc = Uint8List(4);
  cc[0] = 0xE1;
  cc[1] = 0x10;
  cc[2] = (getMemorySizeForTagType(type) ~/ 8) & 0xFF;
  cc[3] = 0x00;
  blocks.add(_bytesToHexString(cc));

  for (int i = 4; i < totalBlocks; i++) {
    blocks.add(_bytesToHexString(Uint8List(4)));
  }
  return blocks;
}

String _bytesToHexString(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String bytesToHexSpace(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// hex 字符串转 Uint8List
Uint8List hexToUint8List(String hex) => StorageService.hexToBytes(hex);

/// hex 字符串格式化输入（只允许 0-9 a-f A-F 和空格）
String formatHexInput(String input) =>
    input.replaceAll(RegExp(r'[^0-9a-fA-F\s]'), '');

/// 已保存卡片（对应 CU CardSave，data 语义按卡类型：Classic=扇区块/UL=页）
class SaveCard {
  String id;
  String uid;
  int sak;
  String atqa;
  String ats;
  String name;
  TagType tag;
  List<String> data; // 每行 16 进制（Classic 16 字节块 / UL 4 字节页）
  String ultralightVersion; // hex
  String ultralightSignature; // hex
  List<int> ultralightCounters;
  String? folderId;
  DateTime? updatedAt;
  int colorValue; // ARGB color value

  SaveCard({
    String? id,
    required this.uid,
    required this.name,
    required this.tag,
    this.sak = 0,
    this.atqa = '',
    this.ats = '',
    this.data = const [],
    this.ultralightVersion = '',
    this.ultralightSignature = '',
    this.ultralightCounters = const [],
    this.folderId,
    this.updatedAt,
    this.colorValue = 0xFFFF5722, // deepOrange
  }) : id = id ?? _genId();

  Color get color => Color(colorValue);
  set color(Color c) => colorValue = c.toARGB32();

  static String _genId() =>
      'c${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

  SaveCard copy() => SaveCard(
    id: id,
    uid: uid,
    sak: sak,
    atqa: atqa,
    ats: ats,
    name: name,
    tag: tag,
    data: List<String>.from(data),
    ultralightVersion: ultralightVersion,
    ultralightSignature: ultralightSignature,
    ultralightCounters: List<int>.from(ultralightCounters),
    folderId: folderId,
    updatedAt: updatedAt,
    colorValue: colorValue,
  );

  Map<String, dynamic> toMap({bool includeUpdatedAt = true}) => {
    'id': id,
    'uid': uid,
    'sak': sak,
    'atqa': atqa,
    'ats': ats,
    'name': name,
    'tag': tag.value,
    'data': data,
    'ultralightVersion': ultralightVersion,
    'ultralightSignature': ultralightSignature,
    'ultralightCounters': ultralightCounters,
    if (folderId != null) 'folderId': folderId,
    'color': colorValue,
    if (includeUpdatedAt && updatedAt != null)
      'updatedAt': updatedAt!.toIso8601String(),
  };

  String toJson() => jsonEncode(toMap());

  bool contentEquals(SaveCard other) =>
      jsonEncode(toMap(includeUpdatedAt: false)) ==
      jsonEncode(other.toMap(includeUpdatedAt: false));

  factory SaveCard.fromJson(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    return SaveCard(
      id: data['id'] as String,
      uid: data['uid'] as String,
      name: data['name'] as String,
      tag: TagType.from(
        (data['tag'] as num?)?.toInt() ?? TagType.mifare1K.value,
      ),
      sak: data['sak'] ?? 0,
      atqa: data['atqa'] ?? '',
      ats: data['ats'] ?? '',
      data: (data['data'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      ultralightVersion: data['ultralightVersion'] ?? '',
      ultralightSignature: data['ultralightSignature'] ?? '',
      ultralightCounters: (data['ultralightCounters'] as List<dynamic>? ?? [])
          .map((e) => e as int)
          .toList(),
      folderId: data['folderId'] as String?,
      colorValue: data['color'] ?? 0xFFFF5722,
      updatedAt: data['updatedAt'] == null
          ? null
          : DateTime.tryParse(data['updatedAt'] as String),
    );
  }
}

/// 卡库文件夹（对应 CU CardFolder）
class SaveFolder {
  String id;
  String name;
  String? parentId;
  int colorValue;

  SaveFolder({
    String? id,
    required this.name,
    this.parentId,
    this.colorValue = 0xFFFF5722,
  }) : id = id ?? 'f${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

  Color get color => Color(colorValue);
  set color(Color c) => colorValue = c.toARGB32();

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    if (parentId != null) 'parentId': parentId,
    'color': colorValue,
  };

  String toJson() => jsonEncode(toMap());

  factory SaveFolder.fromJson(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    return SaveFolder(
      id: data['id'] as String,
      name: data['name'] as String,
      parentId: data['parentId'] as String?,
      colorValue: data['color'] ?? 0xFFFF5722,
    );
  }
}

/// 卡库持久化（对齐 CU SharedPreferencesProvider.savedCards/folders）
class CardLibraryStorage {
  /// 卡库写入后的回调（由启动时注册，用于触发云端增量备份）
  static Future<void> Function()? onCardsChanged;

  static const _kCards = 'nfctool_lib_cards';
  static const _kFolders = 'nfctool_lib_folders';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<List<SaveCard>> getCards() async {
    final p = await _p;
    final raw = p.getStringList(_kCards) ?? const [];
    return raw.map(SaveCard.fromJson).toList();
  }

  Future<SaveCard?> getCardById(String id) async {
    final cards = await getCards();
    for (final c in cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> saveCards(List<SaveCard> cards) async {
    final p = await _p;
    await p.setStringList(_kCards, cards.map((c) => c.toJson()).toList());
    await onCardsChanged?.call();
  }

  Future<void> upsertCard(SaveCard card) async {
    final cards = await getCards();
    final i = cards.indexWhere((c) => c.id == card.id);
    // 内容未变则沿用旧时间戳，避免增量备份把未改动的卡当成变更
    card.updatedAt = (i >= 0 && cards[i].contentEquals(card))
        ? cards[i].updatedAt
        : DateTime.now();
    if (i >= 0) {
      cards[i] = card;
    } else {
      cards.add(card);
    }
    await saveCards(cards);
  }

  Future<bool> deleteCard(String id) async {
    final cards = await getCards();
    final before = cards.length;
    cards.removeWhere((c) => c.id == id);
    await saveCards(cards);
    return cards.length != before;
  }

  /// 导入 CU 卡片文件夹包（chameleon-ultra-gui-folder）
  /// 对齐 CU _importFolderSource：重建文件夹树并重映射卡片 folderId
  /// 返回导入卡片数，非该格式抛 FormatException
  Future<int> importCuBundle(String source, {String? targetFolderId}) async {
    final raw = jsonDecode(source) as Map<String, dynamic>;
    if (raw['format'] != 'chameleon-ultra-gui-folder' || raw['version'] != 1) {
      throw const FormatException('不是 CU 卡片文件夹包');
    }
    final rootFolderId = raw['rootFolderId'] as String? ?? '';
    final cuFolders = (raw['folders'] as List<dynamic>? ?? const [])
        .map((e) => e as Map<String, dynamic>)
        .toList();
    final cuCards = (raw['cards'] as List<dynamic>? ?? const [])
        .map((e) => e as Map<String, dynamic>)
        .toList();

    int cuColor(dynamic v) {
      if (v is String && v.isNotEmpty) {
        final hex = v.replaceAll('#', '').replaceAll(' ', '');
        if (hex.length == 6) return (0xFF << 24) | int.parse(hex, radix: 16);
      }
      return 0xFFFF5722;
    }

    final folders = await getFolders();
    final cards = await getCards();
    final idMap = <String, String>{};

    // 占位生成新 id，保证同批次内唯一（对齐 CU 的 CardFolder(name: '').id）
    var seq = DateTime.now().microsecondsSinceEpoch;
    for (final f in cuFolders) {
      idMap[f['id'] as String] = 'f${(seq++).toRadixString(16)}';
    }
    for (final f in cuFolders) {
      final oldId = f['id'] as String;
      folders.add(
        SaveFolder(
          id: idMap[oldId],
          name: f['name'] as String? ?? '',
          colorValue: cuColor(f['color']),
          parentId: oldId == rootFolderId
              ? targetFolderId
              : (f['parentId'] as String?) != null
              ? idMap[f['parentId'] as String]
              : null,
        ),
      );
    }
    for (final c in cuCards) {
      final copy = SaveCard.fromJson(jsonEncode(c));
      copy.id = SaveCard._genId();
      final oldFolder = c['folderId'] as String?;
      copy.folderId = oldFolder != null ? idMap[oldFolder] : null;
      copy.updatedAt = DateTime.now();
      cards.add(copy);
    }

    await saveFolders(folders);
    await saveCards(cards);
    return cuCards.length;
  }

  Future<List<SaveFolder>> getFolders() async {
    final p = await _p;
    final raw = p.getStringList(_kFolders) ?? const [];
    return raw.map(SaveFolder.fromJson).toList();
  }

  Future<void> saveFolders(List<SaveFolder> folders) async {
    final p = await _p;
    await p.setStringList(_kFolders, folders.map((f) => f.toJson()).toList());
  }

  Future<void> upsertFolder(SaveFolder folder) async {
    final folders = await getFolders();
    final i = folders.indexWhere((f) => f.id == folder.id);
    if (i >= 0) {
      folders[i] = folder;
    } else {
      folders.add(folder);
    }
    await saveFolders(folders);
  }

  Future<bool> deleteFolder(String id) async {
    final folders = await getFolders();
    final before = folders.length;
    // 递归查找子树
    final subtreeIds = <String>{id};
    var changed = true;
    while (changed) {
      changed = false;
      for (final f in folders) {
        if (f.parentId != null &&
            subtreeIds.contains(f.parentId) &&
            subtreeIds.add(f.id)) {
          changed = true;
        }
      }
    }
    folders.removeWhere((f) => subtreeIds.contains(f.id));
    await saveFolders(folders);
    // 清空该目录子树下所有卡片的 folderId 引用
    final cards = await getCards();
    var cardChanged = false;
    for (final c in cards) {
      if (c.folderId != null && subtreeIds.contains(c.folderId!)) {
        c.folderId = null;
        cardChanged = true;
      }
    }
    if (cardChanged) await saveCards(cards);
    return folders.length != before;
  }

  /// 获取文件夹子树 ID 集合
  Set<String> folderSubtreeIds(String rootId, List<SaveFolder> folders) {
    final result = <String>{rootId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final f in folders) {
        if (f.parentId != null &&
            result.contains(f.parentId) &&
            result.add(f.id)) {
          changed = true;
        }
      }
    }
    return result;
  }
}
