import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/enums.dart';

/// 本地方案库：已保存卡片模型 + 持久化（对齐 CU savedCards / folders）
/// 采用 nfcapp 原生约定：atqa/sak/ats 以 hex 字符串存储、data 为 16 进制行，
/// 不引入 uuid/crypto 依赖（id 用时间戳生成）。

/// 判断是否 MIFARE Classic 卡
bool isMifareClassic(TagType tag) =>
    tag == TagType.mifareClassic1k ||
    tag == TagType.mifareClassic4k;

/// 判断是否 EM4100 家族（含 Electra）
bool isEM410X(TagType tag) =>
    tag == TagType.em4100 || tag == TagType.electra;

/// 判断是否 MIFARE Ultralight 家族
bool isMifareUltralight(TagType tag) =>
    tag == TagType.mifareUltralight || tag == TagType.ntag215;

/// 判断是否 LF 卡
bool isLfTag(TagType tag) =>
    tag == TagType.em4100 ||
    tag == TagType.electra ||
    tag == TagType.hidProx ||
    tag == TagType.viking ||
    tag == TagType.pac ||
    tag == TagType.ioProx ||
    tag == TagType.idteck;

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
  }) : id = id ?? _genId();

  static String _genId() =>
      'c${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

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
      tag: TagType.from(data['tag'] ?? 0),
      sak: data['sak'] ?? 0,
      atqa: data['atqa'] ?? '',
      ats: data['ats'] ?? '',
      data: (data['data'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      ultralightVersion: data['ultralightVersion'] ?? '',
      ultralightSignature: data['ultralightSignature'] ?? '',
      ultralightCounters:
          (data['ultralightCounters'] as List<dynamic>? ?? [])
              .map((e) => e as int)
              .toList(),
      folderId: data['folderId'] as String?,
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

  SaveFolder({String? id, required this.name, this.parentId})
      : id = id ?? 'f${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        if (parentId != null) 'parentId': parentId,
      };

  String toJson() => jsonEncode(toMap());

  factory SaveFolder.fromJson(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    return SaveFolder(
      id: data['id'] as String,
      name: data['name'] as String,
      parentId: data['parentId'] as String?,
    );
  }
}

/// 卡库持久化（对齐 CU SharedPreferencesProvider.savedCards/folders）
class CardLibraryStorage {
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
  }

  Future<void> upsertCard(SaveCard card) async {
    final cards = await getCards();
    final i = cards.indexWhere((c) => c.id == card.id);
    if (i >= 0) {
      card.updatedAt = DateTime.now();
      cards[i] = card;
    } else {
      card.updatedAt = DateTime.now();
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
    folders.removeWhere((f) => f.id == id);
    await saveFolders(folders);
    // 同时清空该目录下的卡片引用
    final cards = await getCards();
    var changed = false;
    for (final c in cards) {
      if (c.folderId == id) {
        c.folderId = null;
        changed = true;
      }
    }
    if (changed) await saveCards(cards);
    return folders.length != before;
  }
}