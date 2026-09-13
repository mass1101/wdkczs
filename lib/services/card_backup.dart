import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/enums.dart';
import 'card_library.dart';
import 'storage_service.dart';

/// 云端卡库备份/还原（对齐 CU helpers/backup.dart，接 card.zzx1101.tk 服务器）。
/// 序列化采用 CU CardSave JSON 形状 + bin_data，保证与 CU 服务器/客户端互操作。

/// nfcapp TagType → CU TagType.name（服务器 `tag_type` 字段用 CU 枚举名）
/// 两者成员命名已完全对齐，直接取 name
String _cuTagName(TagType tag) => tag.name;

/// CU TagType.name → nfcapp TagType
TagType? _tagByName(String? name) {
  if (name == null) return null;
  return TagType.values.where((e) => e.name == name).firstOrNull;
}

/// 将 nfcapp SaveCard 序列化为 CU CardSave JSON 形状（字节数组版），并附 bin_data。
Map<String, dynamic> _saveCardToCuJson(SaveCard card) {
  final atqa = card.atqa.isEmpty
      ? <int>[]
      : StorageService.hexToBytes(card.atqa).toList();
  final ats = card.ats.isEmpty
      ? <int>[]
      : StorageService.hexToBytes(card.ats).toList();
  final data = card.data
      .map((hex) => StorageService.hexToBytes(hex).toList())
      .toList();
  final signature = card.ultralightSignature.isEmpty
      ? <int>[]
      : StorageService.hexToBytes(card.ultralightSignature).toList();
  final version = card.ultralightVersion.isEmpty
      ? <int>[]
      : StorageService.hexToBytes(card.ultralightVersion).toList();

  final json = <String, dynamic>{
    'id': card.id,
    'uid': card.uid,
    'sak': card.sak,
    'atqa': atqa,
    'ats': ats,
    'name': card.name,
    'tag': card.tag.value,
    'tag_type': _cuTagName(card.tag),
    'data': data,
    'extra': {
      if (signature.isNotEmpty) 'ultralightSignature': signature,
      if (version.isNotEmpty) 'ultralightVersion': version,
      if (card.ultralightCounters.isNotEmpty)
        'ultralightCounters': card.ultralightCounters,
    },
    if (card.folderId != null) 'folderId': card.folderId,
    'color': colorToHex(card.colorValue),
    if (card.updatedAt != null) 'updatedAt': card.updatedAt!.toIso8601String(),
  };

  final binBytes = cardSaveToBin(card);
  if (binBytes.isNotEmpty) json['bin_data'] = base64Encode(binBytes);
  return json;
}

/// 导出整卡二进制（与 CU cardSaveToBin 对齐：Classic 用连续块，其余按行拼接）
Uint8List cardSaveToBin(SaveCard card) {
  final bytes = <int>[];
  for (final hex in card.data) {
    bytes.addAll(StorageService.hexToBytes(hex));
  }
  return Uint8List.fromList(bytes);
}

/// 备份结果
class BackupResult {
  final bool success;
  final int uploaded;
  const BackupResult({required this.success, required this.uploaded});
}

/// 云端卡片包装
class CloudCard {
  final SaveCard card;
  final Map<String, dynamic> raw;
  const CloudCard({required this.card, required this.raw});
}

/// 将 nfcapp SaveCard 转成字节：Classic 需按块导出同 CU，这里统一按行拼接。
Map<String, dynamic> saveCardToJsonForUpload(SaveCard card) =>
    _saveCardToCuJson(card);

/// 云端条目还原为 nfcapp SaveCard（兼容 CU CardSave JSON 与 nfcapp 两种形状）
SaveCard? cloudJsonToSaveCard(Map<String, dynamic> map) {
  try {
    // 兼容 CU 返回：含 id 且 data 为 List 时按 CU 形状解析
    if (map.containsKey('id') && map['data'] is List) {
      final data = map['data'] as List<dynamic>;
      final tag =
          _tagByName(map['tag_type'] as String?) ??
          TagType.from((map['tag'] as num?)?.toInt() ?? TagType.mifare1K.value);
      final extra = (map['extra'] as Map<String, dynamic>?) ?? const {};
      final sign = (extra['ultralightSignature'] as List<dynamic>? ?? []);
      final ver = (extra['ultralightVersion'] as List<dynamic>? ?? []);
      final counters = (extra['ultralightCounters'] as List<dynamic>? ?? []);
      return SaveCard(
        id: map['id'] as String,
        uid: map['uid'] as String? ?? '',
        name: map['name'] as String? ?? '',
        tag: tag,
        sak: (map['sak'] as num?)?.toInt() ?? 0,
        atqa: _bytesToHex(map['atqa'] as List<dynamic>? ?? []),
        ats: _bytesToHex(map['ats'] as List<dynamic>? ?? []),
        data: (data).map((e) {
          final row = e as List<dynamic>;
          return row.map((b) {
            final n = (b as num).toInt();
            return n.toRadixString(16).padLeft(2, '0');
          }).join();
        }).toList(),
        ultralightVersion: _bytesToHex(ver),
        ultralightSignature: _bytesToHex(sign),
        ultralightCounters: counters.map((e) => (e as num).toInt()).toList(),
        folderId: map['folderId'] as String?,
        colorValue: _colorToInt(map['color']),
        updatedAt: map['updatedAt'] == null
            ? null
            : DateTime.tryParse(map['updatedAt'] as String),
      );
    }
    // 仅含 tag_type 的基础条目
    final tag = map.containsKey('tag')
        ? TagType.from((map['tag'] as num).toInt())
        : _tagByName(map['tag_type'] as String?);
    if (tag == null) return null;
    return SaveCard(
      uid: map['uid'] as String? ?? '',
      name: map['name'] as String? ?? '',
      tag: tag,
      id: map['id'] as String?,
      folderId: map['folderId'] as String?,
      colorValue: (map['color'] as num?)?.toInt() ?? 0xFFFF5722,
    );
  } catch (_) {
    return null;
  }
}

String _bytesToHex(List<dynamic> bytes) => bytes
    .map((b) => (b as num).toInt().toRadixString(16).padLeft(2, '0'))
    .join();

/// 卡库 int 颜色 → CU 的 `#RRGGBB` 字符串（CU 上传/还原都用 hex 串）
String colorToHex(int color) =>
    '#${(color & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// 解析 CU hex 串或本地 int 两种颜色写法
int _colorToInt(Object? value) {
  if (value is num) return value.toInt();
  final s = (value as String?)?.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  if (s != null && s.length >= 6) {
    return 0xFF000000 | int.parse(s.substring(s.length - 6), radix: 16);
  }
  return 0xFFFF5722;
}

/// 生成备份 Token（对齐 CU generateBackupToken：安全随机 32 字节）
String generateBackupToken() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Future<String> _resolveChipId(StorageService storage, {String? chipId}) async {
  if (chipId != null && chipId.isNotEmpty) return chipId;
  final cached = await storage.getChipId();
  if (cached.isNotEmpty) return cached;
  return storage.getBackupChipId();
}

/// 单卡上传到服务器返回是否成功
Future<bool> uploadCards(
  StorageService storage,
  List<SaveCard> cards, {
  String? chipId,
  Map<String, dynamic>? deviceStatus,
}) async {
  final id = await _resolveChipId(storage, chipId: chipId);
  if (id.isEmpty) return false;

  final cardsPayload = cards.map(saveCardToJsonForUpload).toList();
  final payload = <String, dynamic>{
    'chip_id': id,
    'cards': cardsPayload,
    if (deviceStatus != null && deviceStatus.isNotEmpty)
      'device_status': deviceStatus,
  };

  var backupToken = await storage.getBackupToken();
  if (backupToken.isEmpty) {
    backupToken = generateBackupToken();
    await storage.saveBackupToken(backupToken);
  }
  final endpoint = await storage.getBackupEndpoint();
  try {
    final response = await http
        .post(
          Uri.parse('$endpoint/api/backup'),
          headers: {
            'Content-Type': 'application/json',
            if (backupToken.isNotEmpty) 'X-Device-Token': backupToken,
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 10));
    return response.statusCode == 201;
  } catch (_) {
    return false;
  }
}

Timer? _autoBackupTimer;

/// 卡库写入后调度增量备份（2 秒防抖，对齐 CU setCards 自动备份）
Future<void> scheduleAutoBackup([StorageService? storage]) async {
  _autoBackupTimer?.cancel();
  _autoBackupTimer = Timer(const Duration(seconds: 2), () async {
    await backupCards(storage ?? StorageService());
  });
}

/// 注册卡库写入后自动增量备份（启动时调用一次）
void installAutoBackupHook() {
  CardLibraryStorage.onCardsChanged = () => scheduleAutoBackup();
}

/// 增量备份：仅上传有改动的卡片（对齐 CU backupCards）
Future<int> backupCards(
  StorageService storage, {
  List<SaveCard>? all,
  Map<String, DateTime>? lastBackup,
  String? chipId,
  Map<String, dynamic>? deviceStatus,
  bool Function(int uploaded)? onComplete,
}) async {
  // 未显式传入时自读卡库与上次备份时间（供自动增量备份复用）
  final cards = all ?? await CardLibraryStorage().getCards();
  final last = lastBackup ?? await storage.getCardLastBackupMap();
  final toUpload = cards.where((card) {
    final lb = last[card.id];
    if (lb == null) return true;
    final updated = card.updatedAt;
    if (updated == null) return true;
    return updated.isAfter(lb);
  }).toList();

  if (toUpload.isEmpty) return 0;

  final ok = await uploadCards(
    storage,
    toUpload,
    chipId: chipId,
    deviceStatus: deviceStatus,
  );
  if (ok) {
    final now = DateTime.now();
    final updated = <String, DateTime>{...last};
    for (final card in toUpload) {
      updated[card.id] = now;
    }
    await storage.setCardsLastBackupMap(updated);
    onComplete?.call(toUpload.length);
  }
  return ok ? toUpload.length : 0;
}

/// 手动一键备份全部（不经增量过滤）
Future<BackupResult> backupAllCardsToCloud(
  StorageService storage, {
  required List<SaveCard> all,
  String? chipId,
  Map<String, dynamic>? deviceStatus,
}) async {
  final id = await _resolveChipId(storage, chipId: chipId);
  if (id.isEmpty) return const BackupResult(success: false, uploaded: 0);
  if (all.isEmpty) return const BackupResult(success: true, uploaded: 0);

  final ok = await uploadCards(
    storage,
    all,
    chipId: chipId,
    deviceStatus: deviceStatus,
  );
  if (ok) {
    final now = DateTime.now();
    final updated = await storage.getCardLastBackupMap();
    for (final card in all) {
      updated[card.id] = now;
    }
    await storage.setCardsLastBackupMap(updated);
  }
  return BackupResult(success: ok, uploaded: all.length);
}

/// 从云端拉取完整卡库。返回 (卡列表, 无法解析条数)；无数据或失败返回 null。
Future<(List<CloudCard>, int)?> fetchCloudCards(
  StorageService storage, {
  String? chipId,
}) async {
  final id = await _resolveChipId(storage, chipId: chipId);
  if (id.isEmpty) return null;

  final token = await storage.getBackupToken();
  if (token.isEmpty) return null;

  final endpoint = await storage.getBackupEndpoint();
  try {
    final response = await http
        .get(
          Uri.parse('$endpoint/api/backup'),
          headers: {'X-Device-Token': token},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final items = List<dynamic>.from(body['cards'] ?? []);
    final out = <CloudCard>[];
    var failed = 0;
    for (final item in items) {
      final map = item as Map<String, dynamic>;
      final card = cloudJsonToSaveCard(map);
      if (card == null) {
        failed++;
        continue;
      }
      out.add(CloudCard(card: card, raw: map));
    }
    return (out, failed);
  } catch (_) {
    return null;
  }
}

/// 合并云端与本地卡库（云端优先，保留本地独有卡）
class MergeResult {
  final List<SaveCard> cards;
  final int added;
  final int updated;
  final int kept;
  final int failed;
  const MergeResult({
    required this.cards,
    required this.added,
    required this.updated,
    required this.kept,
    required this.failed,
  });
}

MergeResult mergeCloudCards(
  List<SaveCard> local,
  List<CloudCard> cloud,
  int failed,
) {
  final merged = <SaveCard>[];
  final usedLocal = <String>{};
  var added = 0;
  var updated = 0;
  var kept = 0;

  for (final cc in cloud) {
    final c = cc.card;
    var match = local
        .where((lc) => !usedLocal.contains(lc.id) && lc.id == c.id)
        .firstOrNull;
    if (match == null) {
      final key = _uidKey(c);
      if (key.isNotEmpty) {
        match = local
            .where((lc) => !usedLocal.contains(lc.id) && _uidKey(lc) == key)
            .firstOrNull;
      }
    }
    if (match != null) {
      usedLocal.add(match.id);
      merged.add(c.copy()..id = match.id);
      updated++;
    } else {
      merged.add(c);
      added++;
    }
  }
  for (final lc in local) {
    if (usedLocal.contains(lc.id)) continue;
    merged.add(lc);
    kept++;
  }

  return MergeResult(
    cards: merged,
    added: added,
    updated: updated,
    kept: kept,
    failed: failed,
  );
}

/// 卡身份键：卡型 + 去空白 UID。云端与本地 id 不同（CU 用 uuid）时按此识别同一张卡
String _uidKey(SaveCard c) {
  final uid = c.uid.replaceAll(RegExp(r'[\s-]'), '').toLowerCase();
  if (uid.isEmpty) return '';
  return '${c.tag.name}:$uid';
}
