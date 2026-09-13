import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'storage_service.dart';

/// 字典（密钥字典）模型 + 持久化
///
/// 内部按 nfcapp 约定存储（id 用时间戳生成，不引入 uuid 依赖）；
/// 序列化采用 CU 兼容格式（`#RRGGBB` 颜色、keys 为字节数组），
/// 因此导出的 .dic 文件与文件夹 Bundle 可被 ChameleonUltra 直接导入，
/// 反之亦可导入 CU 导出的字典。

/// 校验是否为合法 16 进制字符串
bool isValidHexString(String hex) =>
    hex.isNotEmpty && RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex);

/// ARGB Color → `#RRGGBB`（对齐 CU colorToHex，丢弃 alpha）
String colorToHex(Color color) =>
    '#${color.toARGB32().toRadixString(16).substring(2)}';

/// `#RRGGBB` → ARGB int（对齐 CU hexToColor）
int colorHexToValue(String hex) {
  final raw = hex.startsWith('#') ? hex.substring(1) : hex;
  try {
    return int.parse(raw, radix: 16) | 0xFF000000;
  } catch (_) {
    return 0xFFFF5722; // deepOrange
  }
}

/// 允许导入的密钥长度（hex 字符数）
/// 12 = 6 字节 Mifare Classic，8 = 4 字节 T55XX，32 = 16 字节 AES/ULC
const List<int> allowedKeySizes = [12, 8, 32];

class Dictionary {
  String id;
  String name;
  List<String> keys; // 每行一个 hex 字符串
  int colorValue;
  int keyLength; // hex 字符数（12/8/32）
  String? folderId;

  Dictionary({
    String? id,
    this.name = '',
    this.keys = const [],
    this.colorValue = 0xFFFF5722,
    this.keyLength = 0,
    this.folderId,
  }) : id = id ?? _genId();

  Color get color => Color(colorValue);
  set color(Color c) => colorValue = c.toARGB32();

  static int _seq = 0;

  /// 生成唯一 id：时间戳 + 自增序号，避免紧凑循环中同微秒碰撞
  static String _genId() {
    _seq = (_seq + 1) & 0xFF;
    return 'd${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}'
        '${_seq.toRadixString(16).padLeft(2, '0')}';
  }

  /// CU 兼容的 Map（keys 为字节数组）
  Map<String, dynamic> cuMap() => {
        'id': id,
        'name': name,
        'color': colorToHex(color),
        'keys': keys.map((k) => StorageService.hexToBytes(k).toList()).toList(),
        'keyLength': keyLength,
        if (folderId != null) 'folderId': folderId,
      };

  String toJson() => jsonEncode(cuMap());

  factory Dictionary.fromJson(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    final encodedKeys = data['keys'] as List<dynamic>? ?? [];
    final keys = <String>[];
    for (final key in encodedKeys) {
      if (key is List) {
        keys.add(
            StorageService.bytesToHex(Uint8List.fromList(List<int>.from(key))));
      } else if (key is String && isValidHexString(key)) {
        keys.add(key);
      }
    }
    return Dictionary(
      id: data['id'] as String? ?? _genId(),
      name: data['name'] as String? ?? '',
      colorValue: data['color'] == null
          ? 0xFFFF5722
          : colorHexToValue(data['color'].toString()),
      keyLength: data['keyLength'] == null ? 12 : data['keyLength'] as int,
      keys: keys,
      folderId: data['folderId'] as String?,
    );
  }

  /// 解析纯文本字典文件（每行一个密钥，`#` 注释，允许 `key  备注` 格式）
  factory Dictionary.fromString(String input,
      {String name = '', int colorValue = 0xFFFF5722}) {
    final keys = <String>[];
    var currentKeySize = 0;
    for (var line in input.split('\n')) {
      var key = line.trim().replaceAll('#', ' ');
      if (key.contains(' ')) {
        key = key.split(' ')[0];
      }
      if (allowedKeySizes.contains(key.length) &&
          isValidHexString(key) &&
          (currentKeySize == 0 || currentKeySize == key.length)) {
        if (currentKeySize == 0) currentKeySize = key.length;
        keys.add(key.toUpperCase());
      }
    }
    return Dictionary(
      name: name,
      keys: keys,
      colorValue: colorValue,
      keyLength: currentKeySize,
    );
  }

  /// 纯文本导出内容
  String toText() {
    final buf = StringBuffer();
    for (final key in keys) {
      buf.write(key.toUpperCase());
      buf.write('\n');
    }
    return buf.toString();
  }

  /// 纯文本导出字节（.dic 文件内容）
  Uint8List toFile() => Uint8List.fromList(Utf8Encoder().convert(toText()));

  /// 密钥数
  int get keyCount => keys.length;

  @override
  String toString() =>
      'Dictionary(name: $name, keys: ${keys.length}, len: $keyLength)';
}

/// 字典文件夹
class DictionaryFolder {
  String id;
  String name;
  int colorValue;
  String? parentId;

  DictionaryFolder({
    String? id,
    required this.name,
    this.colorValue = 0xFFFF5722,
    this.parentId,
  }) : id = id ?? _genId();

  Color get color => Color(colorValue);
  set color(Color c) => colorValue = c.toARGB32();

  static int _seq = 0;

  static String _genId() {
    _seq = (_seq + 1) & 0xFF;
    return 'df${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}'
        '${_seq.toRadixString(16).padLeft(2, '0')}';
  }

  Map<String, dynamic> cuMap() => {
        'id': id,
        'name': name,
        'color': colorToHex(color),
        if (parentId != null) 'parentId': parentId,
      };

  String toJson() => jsonEncode(cuMap());

  factory DictionaryFolder.fromJson(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    return DictionaryFolder(
      id: data['id'] as String,
      name: data['name'] as String,
      colorValue: data['color'] == null
          ? 0xFFFF5722
          : colorHexToValue(data['color'].toString()),
      parentId: data['parentId'] as String?,
    );
  }
}

/// 字典文件夹导出包（CU 兼容，Bundle 格式）
class DictionaryFolderBundle {
  static const String format = 'chameleon-ultra-gui-dictionary-folder';
  static const int version = 1;

  final String rootFolderId;
  final List<DictionaryFolder> folders;
  final List<Dictionary> dictionaries;

  DictionaryFolderBundle({
    required this.rootFolderId,
    required this.folders,
    required this.dictionaries,
  });

  factory DictionaryFolderBundle.fromJson(String source) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    if (data['format'] != format || (data['version'] ?? 0) != version) {
      throw const FormatException('Unsupported dictionary folder file');
    }
    return DictionaryFolderBundle(
      rootFolderId: data['rootFolderId'] as String,
      folders: (data['folders'] as List<dynamic>?)
              ?.map((item) =>
                  DictionaryFolder.fromJson(jsonEncode(item)))
              .toList() ??
          const [],
      dictionaries: (data['dictionaries'] as List<dynamic>?)
              ?.map((item) => Dictionary.fromJson(jsonEncode(item)))
              .toList() ??
          const [],
    );
  }

  String toJson() => jsonEncode({
        'format': format,
        'version': version,
        'rootFolderId': rootFolderId,
        'folders': folders.map((f) => jsonDecode(f.toJson())).toList(),
        'dictionaries':
            dictionaries.map((d) => jsonDecode(d.toJson())).toList(),
      });

  /// CU Bundle 文件（.dic.bundle）字节 → Bundle
  factory DictionaryFolderBundle.fromBytes(List<int> bytes) =>
      DictionaryFolderBundle.fromJson(Utf8Decoder().convert(bytes));

  /// 序列化为 Bundle JSON 字符串
  String bundleJson() => toJson();

  /// 包名（取根文件夹名称，无根文件夹时退回包内首个文件夹名）
  String get name {
    for (final f in folders) {
      if (f.id == rootFolderId) return f.name;
    }
    return folders.isNotEmpty ? folders.first.name : '字典包';
  }
}

/// 字典持久化（对齐 CU getDictionaryFolders / dictionaries 存取）
class DictionaryStorage {
  static const String _kDictionaries = 'nfctool_dict_entries';
  static const String _kFolders = 'nfctool_dict_folders';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  // ========== 字典 ==========

  Future<List<Dictionary>> getDictionaries() async {
    final p = await _p;
    final raw = p.getStringList(_kDictionaries) ?? const [];
    final result = <Dictionary>[];
    for (final entry in raw) {
      try {
        result.add(Dictionary.fromJson(entry));
      } catch (_) {}
    }
    return result;
  }

  Future<Dictionary?> getDictionaryById(String id) async {
    final all = await getDictionaries();
    for (final d in all) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<void> saveDictionaries(List<Dictionary> dictionaries) async {
    final p = await _p;
    await p.setStringList(
        _kDictionaries, dictionaries.map((d) => d.toJson()).toList());
  }

  Future<void> upsertDictionary(Dictionary dictionary) async {
    final all = await getDictionaries();
    final i = all.indexWhere((d) => d.id == dictionary.id);
    if (i >= 0) {
      all[i] = dictionary;
    } else {
      all.add(dictionary);
    }
    await saveDictionaries(all);
  }

  Future<bool> deleteDictionary(String id) async {
    final all = await getDictionaries();
    final before = all.length;
    all.removeWhere((d) => d.id == id);
    await saveDictionaries(all);
    return all.length != before;
  }

  /// 移动字典到文件夹
  Future<void> moveDictionary(String id, String? folderId) async {
    final all = await getDictionaries();
    var changed = false;
    for (final d in all) {
      if (d.id == id) {
        d.folderId = folderId;
        changed = true;
        break;
      }
    }
    if (changed) await saveDictionaries(all);
  }

  /// 文件夹子树内字典数
  int countDictionariesInFolder(
      String folderId, List<Dictionary> dictionaries) =>
      dictionaries.where((d) => d.folderId == folderId).length;

  // ========== 文件夹 ==========

  Future<List<DictionaryFolder>> getFolders() async {
    final p = await _p;
    final raw = p.getStringList(_kFolders) ?? const [];
    final result = <DictionaryFolder>[];
    for (final entry in raw) {
      try {
        result.add(DictionaryFolder.fromJson(entry));
      } catch (_) {}
    }
    return result;
  }

  Future<void> saveFolders(List<DictionaryFolder> folders) async {
    final p = await _p;
    await p.setStringList(
        _kFolders, folders.map((f) => f.toJson()).toList());
  }

  Future<void> upsertFolder(DictionaryFolder folder) async {
    final all = await getFolders();
    final i = all.indexWhere((f) => f.id == folder.id);
    if (i >= 0) {
      all[i] = folder;
    } else {
      all.add(folder);
    }
    await saveFolders(all);
  }

  /// 删除文件夹：递归收集子树，删除所有文件夹并把子树下字典移回根
  Future<int> deleteFolder(String id) async {
    final folders = await getFolders();
    final subtreeIds = folderSubtreeIds(id, folders);
    folders.removeWhere((f) => subtreeIds.contains(f.id));
    await saveFolders(folders);

    final dicts = await getDictionaries();
    var moved = 0;
    for (final d in dicts) {
      if (d.folderId != null && subtreeIds.contains(d.folderId!)) {
        d.folderId = null;
        moved++;
      }
    }
    await saveDictionaries(dicts);
    return moved;
  }

  /// 获取文件夹子树 ID 集合
  Set<String> folderSubtreeIds(String rootId, List<DictionaryFolder> folders) {
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

  // ========== Bundle 导入 ==========

  /// 导入 CU Bundle：重写全部 id 避免与本地冲突，
  /// 原根文件夹挂到 targetFolderId（null 即挂到根目录）
  Future<int> importBundle(String bundleJson, {String? targetFolderId}) async {
    final bundle = DictionaryFolderBundle.fromJson(bundleJson);

    final idMap = <String, String>{};
    for (final f in bundle.folders) {
      idMap[f.id] = DictionaryFolder(name: '').id;
    }

    final newFolders = bundle.folders
        .map((f) => DictionaryFolder(
              id: idMap[f.id]!,
              name: f.name,
              colorValue: f.colorValue,
              parentId: f.parentId == null
                  ? targetFolderId
                  : idMap[f.parentId],
            ))
        .toList();

    final newDicts = bundle.dictionaries
        .map((d) => Dictionary(
              id: Dictionary(name: '').id,
              name: d.name,
              keys: List<String>.from(d.keys),
              colorValue: d.colorValue,
              keyLength: d.keyLength,
              folderId: d.folderId == null
                  ? targetFolderId
                  : idMap[d.folderId] ?? targetFolderId,
            ))
        .toList();

    final folders = await getFolders();
    await saveFolders([...folders, ...newFolders]);
    final dicts = await getDictionaries();
    await saveDictionaries([...dicts, ...newDicts]);

    return newDicts.length;
  }

  /// 导入 Bundle 字节（.dic.bundle）
  Future<int> importBundleBytes(List<int> bytes, {String? targetFolderId}) async {
    final bundle = DictionaryFolderBundle.fromBytes(bytes);
    return importBundle(bundle.toJson(), targetFolderId: targetFolderId);
  }

  /// 导入纯文本字典内容到指定文件夹
  /// 返回导入的字典个数（内容无有效密钥时返回 0）
  Future<int> importText(String content, {String? folderId, String? name}) async {
    final dict = Dictionary.fromString(content, name: name ?? '');
    if (dict.keys.isEmpty) return 0;
    if (dict.name.isEmpty) dict.name = '导入字典';
    dict.folderId = folderId;
    await upsertDictionary(dict);
    return 1;
  }

  /// 导出单个字典为 .dic 文件内容（纯文本）
  String dictionaryText(Dictionary dictionary) => dictionary.toText();

  /// 构建文件夹包（含子文件夹及其字典），对齐 CU 文件夹导出
  static DictionaryFolderBundle buildFolderBundle(
    List<DictionaryFolder> folders,
    List<Dictionary> dictionaries,
    String rootId,
  ) {
    final subtree = DictionaryStorage().folderSubtreeIds(rootId, folders);
    return DictionaryFolderBundle(
      rootFolderId: rootId,
      folders: folders
          .where((f) => subtree.contains(f.id))
          .map((f) => DictionaryFolder(
                id: f.id,
                name: f.name,
                colorValue: f.colorValue,
                parentId: subtree.contains(f.parentId ?? '') ? f.parentId : null,
              ))
          .toList(),
      dictionaries: dictionaries
          .where((d) => d.folderId != null && subtree.contains(d.folderId!))
          .map((d) => Dictionary(
                id: d.id,
                name: d.name,
                keys: List<String>.from(d.keys),
                colorValue: d.colorValue,
                keyLength: d.keyLength,
                folderId: d.folderId,
              ))
          .toList(),
    );
  }

  /// 文件夹子树内字典数（含所有层级）
  int countDictionariesInSubtree(String folderId, List<DictionaryFolder> folders,
      List<Dictionary> dictionaries) {
    final subtree = folderSubtreeIds(folderId, folders);
    return dictionaries.where((d) => subtree.contains(d.folderId ?? '')).length;
  }
}
