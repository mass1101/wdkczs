import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// 本地存储：密钥文件、dump 文件、设置持久化（对应逆向 nI/iI）
class StorageService {
  static const _kKeys = 'nfctool_ic_keys';
  static const _kCards = 'nfctool_ic_cards';
  static const _kIdCards = 'nfctool_id_cards';
  static const _kIdCardKeys = 'nfctool_id_card_keys';
  static const _kCurrentUid = 'nfctool_current_uid';
  static const _kCurrentSlot = 'nfctool_current_slot';
  static const _kCloudEndpoint = 'nfctool_cloud_endpoint';
  static const _kDefaultCloudEndpoint =
      'https://fc-mp-25581e18-9b6b-41d7-a1c9-69bb4c0020f7.next.bspapp.com';
  static const _kCrackResume = 'nfctool_crack_resume';
  static const _kChipId = 'nfctool_chip_id';
  static const _kBackupChipId = 'nfctool_backup_chip_id';
  static const _kBackupToken = 'nfctool_backup_token';
  static const _kBackupLastMap = 'nfctool_backup_last_map';
  static const _kBackupEndpoint = 'nfctool_backup_endpoint';
  static const _kDefaultBackupEndpoint = 'https://card.zzx1101.tk:6363';
  static const _kWatchdog = 'nfctool_watchdog';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// 暴露底层 SharedPreferences 实例（供围栏等模块持久化）
  Future<SharedPreferences> get prefs => _p;

  // ========== 密钥文件 ==========

  /// 获取所有密钥文件名（对应逆向 getKeyNames）
  Future<Map<String, String>> getKeyNames() async {
    final p = await _p;
    final raw = p.getString(_kKeys) ?? '{}';
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(k, v.toString()));
  }

  /// 获取指定密钥文件内容
  Future<String> getKey(String name) async {
    final all = await getKeyNames();
    return all[name] ?? '';
  }

  /// 保存密钥文件
  Future<void> saveKey(String name, String content) async {
    final all = await getKeyNames();
    all[name] = content;
    final p = await _p;
    await p.setString(_kKeys, jsonEncode(all));
  }

  /// 删除密钥文件
  Future<bool> delKey(String name) async {
    final all = await getKeyNames();
    if (all.containsKey(name)) {
      all.remove(name);
      final p = await _p;
      await p.setString(_kKeys, jsonEncode(all));
      return true;
    }
    return false;
  }

  // ========== dump 文件 ==========

  Future<Map<String, String>> getCardNames() async {
    final p = await _p;
    final raw = p.getString(_kCards) ?? '{}';
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(k, v.toString()));
  }

  Future<String> getCard(String name) async {
    final all = await getCardNames();
    return all[name] ?? '';
  }

  Future<void> saveCard(String name, String content) async {
    final all = await getCardNames();
    all[name] = content;
    final p = await _p;
    await p.setString(_kCards, jsonEncode(all));
  }

  Future<bool> delCard(String name) async {
    final all = await getCardNames();
    if (all.containsKey(name)) {
      all.remove(name);
      final p = await _p;
      await p.setString(_kCards, jsonEncode(all));
      return true;
    }
    return false;
  }

  // ========== ID 卡 ==========

  Future<List<IdCardItem>> getIdCards() async {
    final p = await _p;
    final raw = p.getString(_kIdCards);
    if (raw == null) return [IdCardItem(id: '1122334455', name: '未命名')];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => IdCardItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveIdCards(List<IdCardItem> cards) async {
    final p = await _p;
    await p.setString(
        _kIdCards, jsonEncode(cards.map((c) => c.toJson()).toList()));
  }

  Future<String> getIdCardKeys() async {
    final p = await _p;
    return p.getString(_kIdCardKeys) ?? '19920427\n1dd00a11\n20206666\n51243648';
  }

  Future<void> saveIdCardKeys(String keys) async {
    final p = await _p;
    await p.setString(_kIdCardKeys, keys);
  }

  // ========== 当前状态 ==========

  Future<String> getCurrentUid() async {
    final p = await _p;
    return p.getString(_kCurrentUid) ?? 'deadbeef';
  }

  Future<void> setCurrentUid(String uid) async {
    final p = await _p;
    await p.setString(_kCurrentUid, uid);
  }

  Future<int> getCurrentSlot() async {
    final p = await _p;
    return p.getInt(_kCurrentSlot) ?? 0;
  }

  Future<void> setCurrentSlot(int slot) async {
    final p = await _p;
    await p.setInt(_kCurrentSlot, slot);
  }

  // ========== 云配置 ==========

  Future<String> getCloudEndpoint() async {
    final p = await _p;
    final v = p.getString(_kCloudEndpoint);
    // 作者旧域名已失效(DNS 解析失败), 自动迁移到小程序同款端点
    if (v == null || v == 'https://cloud.geektoy.com') {
      return _kDefaultCloudEndpoint;
    }
    return v;
  }

  Future<void> setCloudEndpoint(String endpoint) async {
    final p = await _p;
    await p.setString(_kCloudEndpoint, endpoint);
  }

  // ========== 云端卡库备份（对齐 CU backup.dart，接 card.zzx1101.tk 服务器） ==========

  /// 设备芯片编号（连接设备时自动缓存，对齐 CU app_last_chip_id）
  Future<String> getChipId() async {
    final p = await _p;
    return p.getString(_kChipId) ?? '';
  }

  Future<void> saveChipId(String chipId) async {
    if (chipId.isEmpty) return;
    final p = await _p;
    await p.setString(_kChipId, chipId);
  }

  /// 手动填写的备份设备标识（离线兜底，仅在设备缓存为空时使用）
  Future<String> getBackupChipId() async {
    final p = await _p;
    return p.getString(_kBackupChipId) ?? '';
  }

  Future<void> setBackupChipId(String chipId) async {
    final p = await _p;
    await p.setString(_kBackupChipId, chipId);
  }

  /// 每次备份生成的设备 Token
  Future<String> getBackupToken() async {
    final p = await _p;
    return p.getString(_kBackupToken) ?? '';
  }

  Future<void> saveBackupToken(String token) async {
    final p = await _p;
    await p.setString(_kBackupToken, token);
  }

  /// 各卡最近一次成功备份时间
  Future<Map<String, DateTime>> getCardLastBackupMap() async {
    final p = await _p;
    final raw = p.getString(_kBackupLastMap);
    if (raw == null) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) =>
          MapEntry(k, DateTime.tryParse(v.toString()) ?? DateTime.fromMillisecondsSinceEpoch(0)));
    } catch (_) {
      return {};
    }
  }

  Future<void> setCardsLastBackupMap(Map<String, DateTime> map) async {
    final p = await _p;
    final enc = map.map((k, v) => MapEntry(k, v.toIso8601String()));
    await p.setString(_kBackupLastMap, jsonEncode(enc));
  }

  /// 备份服务器端点（默认 CU 服务器）
  Future<String> getBackupEndpoint() async {
    final p = await _p;
    return p.getString(_kBackupEndpoint) ?? _kDefaultBackupEndpoint;
  }

  Future<void> setBackupEndpoint(String endpoint) async {
    final p = await _p;
    await p.setString(_kBackupEndpoint, endpoint);
  }

  // ========== 解卡断点续破（对齐小程序破解任务：恢复即删，逐块写回） ==========

  Future<Map<String, dynamic>?> getCrackResume() async {
    final p = await _p;
    final raw = p.getString(_kCrackResume);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveCrackResume(Map<String, dynamic> data) async {
    final p = await _p;
    await p.setString(_kCrackResume, jsonEncode(data));
  }

  Future<void> clearCrackResume() async {
    final p = await _p;
    await p.remove(_kCrackResume);
  }

  // ========== 后台看门狗（对齐 CU watchdog.dart） ==========

  Future<bool> getWatchdogEnabled() async {
    final p = await _p;
    return p.getBool(_kWatchdog) ?? false;
  }

  Future<void> setWatchdogEnabled(bool value) async {
    final p = await _p;
    await p.setBool(_kWatchdog, value);
  }

  /// 解析 16 进制字符串为字节
  static Uint8List hexToBytes(String hex) {
    final clean = hex.replaceAll(RegExp(r'[\s-]'), '');
    final bytes = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  static String bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
