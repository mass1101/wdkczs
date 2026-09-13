import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/enums.dart';
import 'card_library.dart';
import 'storage_service.dart';

/// 云端卡库备份/还原（对齐 CU helpers/backup.dart，接 card.zzx1101.tk 服务器）。
/// 序列化采用 CU CardSave JSON 形状 + bin_data，保证与 CU 服务器/客户端互操作。

/// nfcapp TagType → CU TagType.name（服务器 `tag_type` 字段用 CU 枚举名）
String _cuTagName(TagType tag) {
  switch (tag) {
    case TagType.em4100:
      return 'em410X';
    case TagType.electra:
      return 'em410XElectra';
    case TagType.pac:
      return 'pac';
    case TagType.viking:
      return 'viking';
    case TagType.hidProx:
      return 'hidProx';
    case TagType.ioProx:
      return 'ioProx';
    case TagType.idteck:
      return 'idteck';
    case TagType.mifareClassic1k:
      return 'mifare1K';
    case TagType.mifareClassic4k:
      return 'mifare4K';
    case TagType.mifareUltralight:
      return 'ultralight';
    case TagType.ntag215:
      return 'ntag215';
  }
}

/// CU TagType.name → nfcapp TagType（还原时不带 tag 值时用）
TagType? _tagByName(String? name) {
  switch (name) {
    case 'em410X':
    case 'em410X16':
    case 'em410X32':
    case 'em410X64':
      return TagType.em4100;
    case 'em410XElectra':
      return TagType.electra;
    case 'pac':
      return TagType.pac;
    case 'viking':
      return TagType.viking;
    case 'hidProx':
      return TagType.hidProx;
    case 'ioProx':
      return TagType.ioProx;
    case 'idteck':
      return TagType.idteck;
    case 'mifareMini':
    case 'mifare1K':
    case 'mifare2K':
      return TagType.mifareClassic1k;
    case 'mifare4K':
      return TagType.mifareClassic4k;
    case 'ultralight':
    case 'ultralightC':
    case 'ultralight11':
    case 'ultralight21':
      return TagType.mifareUltralight;
    case 'ntag210':
    case 'ntag212':
    case 'ntag213':
    case 'ntag215':
    case 'ntag216':
      return TagType.ntag215;
  }
  return null;
}

/// 将 nfcapp SaveCard 序列化为 CU CardSave JSON 形状（字节数组版），并附 bin_data。
Map<String, dynamic> _saveCardToCuJson(SaveCard card) {
  final atqa = card.atqa.isEmpty ? <int>[] : StorageService.hexToBytes(card.atqa).toList();
  final ats = card.ats.isEmpty ? <int>[] : StorageService.hexToBytes(card.ats).toList();
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
      final tag = TagType.from((map['tag'] as num?)?.toInt() ?? 0);
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
        ultralightCounters:
            counters.map((e) => (e as num).toInt()).toList(),
        folderId: map['folderId'] as String?,
        updatedAt:
            map['updatedAt'] == null ? null : DateTime.tryParse(map['updatedAt'] as String),
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
    );
  } catch (_) {
    return null;
  }
}

String _bytesToHex(List<dynamic> bytes) =>
    bytes.map((b) => (b as num).toInt().toRadixString(16).padLeft(2, '0')).join();

/// 生成备份 Token（对齐 CU generateBackupToken）
String generateBackupToken() {
  final rnd = _Random();
  final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class _Random {
  int _state = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
  int nextInt(int max) {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state % max;
  }
}

Future<String> _resolveChipId(StorageService storage, {String? chipId}) async {
  if (chipId != null && chipId.isNotEmpty) return chipId;
  return storage.getBackupChipId();
}

/// 单卡上传到服务器返回是否成功
Future<bool> uploadCards(
  StorageService storage,
  List<SaveCard> cards, {
  String? chipId,
}) async {
  final id = await _resolveChipId(storage, chipId: chipId);
  if (id.isEmpty) return false;

  final cardsPayload = cards.map(saveCardToJsonForUpload).toList();
  final payload = <String, dynamic>{
    'chip_id': id,
    'cards': cardsPayload,
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

/// 增量备份：仅上传有改动的卡片（对齐 CU backupCards）
Future<int> backupCards(
  StorageService storage, {
  required List<SaveCard> all,
  required Map<String, DateTime> lastBackup,
  String? chipId,
  bool Function(int uploaded)? onComplete,
}) async {
  final toUpload = all.where((card) {
    final last = lastBackup[card.id];
    if (last == null) return true;
    final updated = card.updatedAt;
    if (updated == null) return true;
    return updated.isAfter(last);
  }).toList();

  if (toUpload.isEmpty) return 0;

  final ok = await uploadCards(storage, toUpload, chipId: chipId);
  if (ok) {
    final now = DateTime.now();
    final updated = Map<String, DateTime>.from(lastBackup);
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
}) async {
  final id = await _resolveChipId(storage, chipId: chipId);
  if (id.isEmpty) return const BackupResult(success: false, uploaded: 0);
  if (all.isEmpty) return const BackupResult(success: true, uploaded: 0);

  final ok = await uploadCards(storage, all, chipId: chipId);
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
    List<SaveCard> local, List<CloudCard> cloud, int failed) {
  final localById = {for (final c in local) c.id: c};
  final cloudIds = {for (final c in cloud) c.card.id};
  final merged = <SaveCard>[];
  var added = 0;
  var updated = 0;
  var kept = 0;

  for (final lc in local) {
    if (cloudIds.contains(lc.id)) continue;
    merged.add(lc);
    kept++;
  }
  for (final cc in cloud) {
    final c = cc.card;
    if (localById.containsKey(c.id)) {
      updated++;
    } else {
      added++;
    }
    merged.add(c);
  }

  return MergeResult(
      cards: merged, added: added, updated: updated, kept: kept, failed: failed);
}