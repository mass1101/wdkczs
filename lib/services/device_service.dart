import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble_service.dart';
import '../models/enums.dart';
import '../models/models.dart';
import '../protocol/frame.dart';

/// 设备异常（携带状态码）
class DeviceException implements Exception {
  final int status;
  final String message;
  DeviceException(this.status, this.message);

  @override
  String toString() =>
      '${DeviceStatus.message(status)} (status=$status) $message';
}

/// 是否错误状态码
bool _isErrStatus(int s) => s != 0 && s != 104;

/// 设备命令层：封装 UltraFrame 协议的全部命令（对应逆向 Kk 类）
class DeviceService {
  final BleService _ble;
  bool _ready = false;
  final _pending = <int, Completer<Uint8List>>{};
  StreamSubscription? _sub;

  DeviceService(this._ble);

  /// 初始化（监听接收流，解析响应帧）
  void init() {
    if (_ready) return;
    _ready = true;
    _sub = _ble.rx.listen((bytes) {
      if (bytes.isEmpty) return;
      try {
        final (cmd, status, data) = UltraFrame.decode(bytes);
        final completer = _pending.remove(cmd);
        if (completer != null) {
          if (_isErrStatus(status)) {
            completer.completeError(DeviceException(status, ''));
          } else {
            completer.complete(data);
          }
        }
      } catch (e) {
        debugPrint('frame decode error: $e');
      }
    });
  }

  bool isConnected() => _ble.isConnected;

  Future<void> ensureConnected() async {
    if (!isConnected()) {
      throw DeviceException(-1, '设备未连接');
    }
  }

  /// 底层发送请求并等待响应
  Future<Uint8List> _request(int cmd, Uint8List? data,
      {int timeout = UltraFrame.defaultTimeoutMs}) async {
    await ensureConnected();
    init();
    final completer = Completer<Uint8List>();
    _pending[cmd] = completer;
    final frame = UltraFrame.encode(cmd: cmd, data: data ?? Uint8List(0));
    try {
      await _ble.send(frame);
      return await completer.future.timeout(Duration(milliseconds: timeout));
    } on TimeoutException {
      _pending.remove(cmd);
      throw DeviceException(-2, '读取响应超时($timeout ms)');
    } catch (e) {
      _pending.remove(cmd);
      rethrow;
    }
  }

  // ========== 设备基础命令（cmd 1000-1038） ==========

  /// 固件版本（如 "1.3"）
  Future<String> cmdGetAppVersion() async {
    final r = await _request(Cmd.getAppVersion.value, null);
    if (r.length >= 2 && r[0] == 1 && r[1] == 1) {
      throw DeviceException(0, 'Unsupported protocol. Firmware update is required.');
    }
    return r.length >= 2 ? '${r[0]}.${r[1]}' : '';
  }

  Future<void> cmdChangeDeviceMode(DeviceMode mode) async {
    final b = Uint8List(1);
    b[0] = mode.value;
    await _request(Cmd.changeDeviceMode.value, b);
  }

  Future<DeviceMode> cmdGetDeviceMode() async {
    final r = await _request(Cmd.getDeviceMode.value, null);
    return DeviceMode.from(r[0]);
  }

  Future<void> assureDeviceMode(DeviceMode mode) async {
    final current = await cmdGetDeviceMode();
    if (current != mode) {
      await cmdChangeDeviceMode(mode);
    }
  }

  Future<void> cmdSlotSetActive(int slot) async {
    await _request(Cmd.setActiveSlot.value, Uint8List.fromList([slot]));
  }

  Future<void> cmdSlotChangeTagType(int slot, int tagType) async {
    final b = Uint8List(3);
    final bd = ByteData.sublistView(b);
    b[0] = slot;
    bd.setUint16(1, tagType);
    await _request(Cmd.setSlotTagType.value, b);
  }

  Future<void> cmdSlotResetTagType(int slot, int tagType) async {
    final b = Uint8List(3);
    final bd = ByteData.sublistView(b);
    b[0] = slot;
    bd.setUint16(1, tagType);
    await _request(Cmd.setSlotDataDefault.value, b);
  }

  /// freq: 1=LF 2=HF
  Future<void> cmdSlotSetEnable(int slot, int freq, bool enable) async {
    final b = Uint8List(3);
    b[0] = slot;
    b[1] = freq;
    b[2] = enable ? 1 : 0;
    await _request(Cmd.setSlotEnable.value, b);
  }

  Future<void> cmdSlotSetFreqName(int slot, int freq, String name) async {
    final nb = Uint8List.fromList(name.codeUnits);
    final b = Uint8List(2 + nb.length);
    b[0] = slot;
    b[1] = freq;
    b.setRange(2, 2 + nb.length, nb);
    await _request(Cmd.setSlotTagNick.value, b);
  }

  /// 返回 null 表示未设置
  Future<String?> cmdSlotGetFreqName(int slot, int freq) async {
    try {
      final r = await _request(Cmd.getSlotTagNick.value,
          Uint8List.fromList([slot, freq]));
      return String.fromCharCodes(r);
    } on DeviceException catch (e) {
      if (e.status == 113) return null;
      rethrow;
    }
  }

  Future<void> cmdSlotSaveSettings() async {
    await _request(Cmd.slotDataConfigSave.value, null);
  }

  Future<void> cmdSaveSettings() async {
    await _request(Cmd.saveSettings.value, null);
  }

  Future<void> cmdResetSettings() async {
    await _request(Cmd.resetSettings.value, null);
  }

  Future<String> cmdGetDeviceChipId() async {
    final r = await _request(Cmd.getDeviceChipId.value, null);
    return r.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<String> cmdBleGetAddress() async {
    final r = await _request(Cmd.getDeviceAddress.value, null);
    return r.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  }

  Future<void> cmdSetAnimationMode(AnimationMode mode) async {
    await _request(Cmd.setAnimationMode.value, Uint8List.fromList([mode.value]));
  }

  Future<AnimationMode> cmdGetAnimationMode() async {
    final r = await _request(Cmd.getAnimationMode.value, null);
    return AnimationMode.from(r[0]);
  }

  Future<String> cmdGetGitVersion() async {
    final r = await _request(Cmd.getGitVersion.value, null);
    return String.fromCharCodes(r);
  }

  Future<int> cmdSlotGetActive() async {
    final r = await _request(Cmd.getActiveSlot.value, null);
    return r[0];
  }

  /// 卡槽信息：8 项 {hfTagType, lfTagType}
  Future<List<(int, int)>> cmdSlotGetInfo() async {
    final r = await _request(Cmd.getSlotInfo.value, null);
    final list = <(int, int)>[];
    final bd = ByteData.sublistView(r);
    for (var i = 0; i < r.length; i += 4) {
      list.add((bd.getUint16(i), bd.getUint16(i + 2)));
    }
    return list;
  }

  Future<void> cmdWipeFds() async {
    await _request(Cmd.wipeFds.value, null);
  }

  Future<bool> cmdSlotDeleteFreqName(int slot, int freq) async {
    try {
      await _request(Cmd.deleteSlotTagNick.value,
          Uint8List.fromList([slot, freq]));
      return true;
    } on DeviceException catch (e) {
      if (e.status == 112) return false;
      rethrow;
    }
  }

  /// 8 项 {hf, lf} 启用状态
  Future<List<(bool, bool)>> cmdSlotGetIsEnable() async {
    final r = await _request(Cmd.getEnabledSlots.value, null);
    final list = <(bool, bool)>[];
    for (var i = 0; i < r.length; i += 2) {
      list.add((r[i] == 1, r[i + 1] == 1));
    }
    return list;
  }

  Future<void> cmdSlotDeleteFreqType(int slot, int freq) async {
    await _request(Cmd.deleteSlotSenseType.value,
        Uint8List.fromList([slot, freq]));
  }

  /// 电量信息
  Future<BatteryInfo> cmdGetBatteryInfo() async {
    final r = await _request(Cmd.getBatteryInfo.value, null);
    final bd = ByteData.sublistView(r);
    return BatteryInfo(voltage: bd.getUint16(0), level: r[2]);
  }

  Future<ButtonAction> cmdGetButtonPressAction(int btn) async {
    final r = await _request(Cmd.getButtonPressConfig.value,
        Uint8List.fromList([btn]));
    return ButtonAction.from(r[0]);
  }

  Future<void> cmdSetButtonPressAction(int btn, ButtonAction action) async {
    await _request(Cmd.setButtonPressConfig.value,
        Uint8List.fromList([btn, action.value]));
  }

  Future<ButtonAction> cmdGetButtonLongPressAction(int btn) async {
    final r = await _request(Cmd.getLongButtonPressConfig.value,
        Uint8List.fromList([btn]));
    return ButtonAction.from(r[0]);
  }

  Future<void> cmdSetButtonLongPressAction(int btn, ButtonAction action) async {
    await _request(Cmd.setLongButtonPressConfig.value,
        Uint8List.fromList([btn, action.value]));
  }

  Future<void> cmdBleSetPairingKey(String key) async {
    if (!RegExp(r'^\d{6}$').hasMatch(key)) {
      throw DeviceException(96, 'Invalid key, must be 6 digits');
    }
    await _request(Cmd.setBlePairingKey.value,
        Uint8List.fromList(key.codeUnits));
  }

  Future<String> cmdBleGetPairingKey() async {
    final r = await _request(Cmd.getBlePairingKey.value, null);
    return String.fromCharCodes(r);
  }

  Future<void> cmdBleDeleteAllBonds() async {
    await _request(Cmd.deleteAllBleBonds.value, null);
  }

  Future<int> cmdGetDeviceModel() async {
    final r = await _request(Cmd.getDeviceModel.value, null);
    return r[0];
  }

  Future<DeviceSettings> cmdGetDeviceSettings() async {
    final r = await _request(Cmd.getDeviceSettings.value, null);
    // 布局：version[6] animation btnPress[2] longPress[2] pairingMode? pairingKey[6]
    final key = String.fromCharCodes(r.sublist(7));
    return DeviceSettings(
      animation: AnimationMode.from(r[6]),
      pressBtnA: ButtonAction.from(r[7]),
      pressBtnB: ButtonAction.from(r[8]),
      longPressBtnA: ButtonAction.from(r[9]),
      longPressBtnB: ButtonAction.from(r[10]),
      blePairing: r[11] == 1,
      blePairingKey: key,
    );
  }

  Future<Set<int>> cmdGetSupportedCmds() async {
    final r = await _request(Cmd.getDeviceCapabilities.value, null);
    final s = <int>{};
    final bd = ByteData.sublistView(r);
    for (var i = 0; i < r.length; i += 2) {
      s.add(bd.getUint16(i));
    }
    return s;
  }

  Future<bool> cmdBleGetPairingMode() async {
    final r = await _request(Cmd.getBlePairingEnable.value, null);
    return r[0] == 1;
  }

  Future<void> cmdBleSetPairingMode(bool enable) async {
    await _request(Cmd.setBlePairingEnable.value,
        Uint8List.fromList([enable ? 1 : 0]));
  }

  /// 8 项 {hfName, lfName}
  Future<List<(String?, String?)>> cmdSlotGetFreqNames() async {
    final r = await _request(Cmd.getAllSlotNicks.value, null);
    final list = <(String?, String?)>[];
    var pos = 0;
    for (var n = 0; n < 8; n++) {
      String? hf;
      String? lf;
      for (final freq in [2, 1]) {
        String? name;
        if (r.length > pos) {
          final len = r[pos];
          if (len > 0 && pos + 1 + len <= r.length) {
            name = String.fromCharCodes(r.sublist(pos + 1, pos + 1 + len));
          }
          pos += 1 + len;
        }
        if (freq == 2) {
          hf = name;
        } else {
          lf = name;
        }
      }
      list.add((hf, lf));
    }
    return list;
  }

  // ========== HF 命令（cmd 2000-2201） ==========

  /// HF14A 扫描，返回反碰撞数据列表
  Future<List<Hf14aAntiColl>> cmdHf14aScan() async {
    await assureDeviceMode(DeviceMode.reader);
    final r = await _request(Cmd.hf14aScan.value, null);
    return _parseAntiCollList(r);
  }

  /// 解析反碰撞数据（对应逆向 vk.fromBuffer）
  static List<Hf14aAntiColl> _parseAntiCollList(Uint8List e) {
    final list = <Hf14aAntiColl>[];
    var pos = 0;
    while (pos < e.length) {
      final t = e[pos];
      if (e.length < pos + t + 5) break;
      final uid = e.sublist(pos + 1, pos + 1 + t);
      final atqa = e.sublist(pos + 1 + t, pos + 3 + t);
      final sak = e[pos + 3 + t];
      final r = e[pos + 4 + t];
      final ats = e.sublist(pos + 5 + t, pos + 5 + t + r);
      list.add(Hf14aAntiColl(uid: uid, atqa: atqa, sak: sak, ats: ats));
      pos += t + r + 5;
    }
    return list;
  }

  Future<bool> cmdMf1IsSupport() async {
    try {
      await assureDeviceMode(DeviceMode.reader);
      await _request(Cmd.mf1DetectSupport.value, null);
      return true;
    } on DeviceException catch (e) {
      if (e.status == 2) return false;
      rethrow;
    }
  }

  /// PRNG 类型：0 静态 1 弱随机 2 强随机
  Future<int> cmdMf1TestPrngType() async {
    await assureDeviceMode(DeviceMode.reader);
    final r = await _request(Cmd.mf1DetectPrng.value, null);
    return r[0];
  }

  /// 静态嵌套采集
  Future<Mf1AcquireStaticNestedRes> cmdMf1AcquireStaticNested(
      {required int block,
      required KeyType keyType,
      required Uint8List key,
      required int targetBlock,
      required KeyType targetKeyType}) async {
    await assureDeviceMode(DeviceMode.reader);
    final b = Uint8List(10);
    b[0] = keyType.value;
    b[1] = block;
    b.setRange(2, 8, key);
    b[8] = targetKeyType.value;
    b[9] = targetBlock;
    final r = await _request(Cmd.mf1StaticNestedAcquire.value, b);
    final uid = r.sublist(0, 4);
    final atks = <(Uint8List, Uint8List)>[];
    for (var i = 4; i + 8 <= r.length; i += 8) {
      atks.add((r.sublist(i, i + 4), r.sublist(i + 4, i + 8)));
    }
    return Mf1AcquireStaticNestedRes(uid: uid, atks: atks);
  }

  /// Darkside 采集
  Future<Mf1DarksideRes> cmdMf1AcquireDarkside({
    required int block,
    required KeyType keyType,
    required bool isFirst,
    int syncMax = 30,
  }) async {
    await assureDeviceMode(DeviceMode.reader);
    final b = Uint8List(4);
    b[0] = keyType.value;
    b[1] = block;
    b[2] = isFirst ? 1 : 0;
    b[3] = syncMax;
    final r = await _request(Cmd.mf1DarksideAcquire.value, b,
        timeout: 10000 * syncMax); // ignore: strict_raw_type
    if (r.length == 1) {
      return Mf1DarksideRes(status: r[0], uid: null, nt: null, par: null, ks: null, nr: null, ar: null);
    }
    return Mf1DarksideRes(
      status: r[0],
      uid: r.sublist(1, 5),
      nt: r.sublist(5, 9),
      par: r.sublist(9, 17),
      ks: r.sublist(17, 25),
      nr: r.sublist(25, 29),
      ar: r.sublist(29, 33),
    );
  }

  /// 检测 NT 距离
  Future<Mf1NtDistanceRes> cmdMf1TestNtDistance({
    required int block,
    required KeyType keyType,
    required Uint8List key,
  }) async {
    await assureDeviceMode(DeviceMode.reader);
    final b = Uint8List(8);
    b[0] = keyType.value;
    b[1] = block;
    b.setRange(2, 8, key);
    final r = await _request(Cmd.mf1DetectNtDist.value, b);
    return Mf1NtDistanceRes(uid: r.sublist(0, 4), dist: r.sublist(4, 8));
  }

  /// 嵌套采集
  Future<List<Mf1NestedRes>> cmdMf1AcquireNested({
    required int block,
    required KeyType keyType,
    required Uint8List key,
    required int targetBlock,
    required KeyType targetKeyType,
  }) async {
    await assureDeviceMode(DeviceMode.reader);
    final b = Uint8List(10);
    b[0] = keyType.value;
    b[1] = block;
    b.setRange(2, 8, key);
    b[8] = targetKeyType.value;
    b[9] = targetBlock;
    final r = await _request(Cmd.mf1NestedAcquire.value, b,
        timeout: 30000);
    final list = <Mf1NestedRes>[];
    for (var i = 0; i + 9 <= r.length; i += 9) {
      list.add(Mf1NestedRes(
        nt1: r.sublist(i, i + 4),
        nt2: r.sublist(i + 4, i + 8),
        par: r[i + 8],
      ));
    }
    return list;
  }

  /// 校验块密钥，返回是否匹配
  Future<bool> cmdMf1CheckBlockKey({
    required int block,
    required KeyType keyType,
    required Uint8List key,
  }) async {
    try {
      await assureDeviceMode(DeviceMode.reader);
      final b = Uint8List(8);
      b[0] = keyType.value;
      b[1] = block;
      b.setRange(2, 8, key);
      await _request(Cmd.mf1AuthOneKeyBlock.value, b);
      return true;
    } on DeviceException catch (e) {
      if (e.status == 6) return false;
      rethrow;
    }
  }

  /// 读取一个块（16 字节）
  Future<Uint8List> cmdMf1ReadBlock({
    required int block,
    required KeyType keyType,
    required Uint8List key,
  }) async {
    await assureDeviceMode(DeviceMode.reader);
    final b = Uint8List(8);
    b[0] = keyType.value;
    b[1] = block;
    b.setRange(2, 8, key);
    return _request(Cmd.mf1ReadOneBlock.value, b);
  }

  /// 写入一个块（16 字节）
  Future<void> cmdMf1WriteBlock({
    required int block,
    required KeyType keyType,
    required Uint8List key,
    required Uint8List data,
  }) async {
    if (data.length != 16) throw DeviceException(96, 'data must be 16 bytes');
    await assureDeviceMode(DeviceMode.reader);
    final b = Uint8List(24);
    b[0] = keyType.value;
    b[1] = block;
    b.setRange(2, 8, key);
    b.setRange(8, 24, data);
    await _request(Cmd.mf1WriteOneBlock.value, b);
  }

  /// HF14A 透传
  Future<Uint8List> cmdHf14aRaw({
    Uint8List? data,
    bool activateRfField = false,
    bool waitResponse = true,
    bool appendCrc = false,
    bool autoSelect = false,
    bool keepRfField = false,
    bool checkResponseCrc = false,
    int dataBitLength = 0,
    int timeout = 1000,
  }) async {
    final d = data ?? Uint8List(0);
    final l = d.isEmpty ? 1 : d.length;
    final bitLen = 8 * (l - 1) + ((dataBitLength + 7) % 8) + 1;
    final u = Uint8List(2 + 2 + d.length + 1);
    final bd = ByteData.sublistView(u);
    bd.setUint16(0, timeout);
    bd.setUint16(2, bitLen);
    if (d.isNotEmpty) u.setRange(4, 4 + d.length, d);
    // 第 4 字节起为标志位（bit0-5），后续填充
    u[4 + d.length] = 0;
    await assureDeviceMode(DeviceMode.reader);
    return _request(Cmd.hf14aRaw.value, u, timeout: UltraFrame.defaultTimeoutMs + timeout);
  }

  /// 检查多扇区密钥
  Future<Mf1CheckKeysOfSectorsRes> cmdMf1CheckKeysOfSectors({
    required List<Uint8List> keys,
    required Uint8List mask,
  }) async {
    await assureDeviceMode(DeviceMode.reader);
    final n = Uint8List(10 + keys.length * 6);
    n.setRange(0, 10, mask);
    for (var i = 0; i < keys.length; i++) {
      n.setRange(10 + i * 6, 10 + i * 6 + 6, keys[i]);
    }
    final r = await _request(Cmd.mf1CheckKeysOfSectors.value, n,
        timeout: 30000);
    final found = Uint8List(10);
    found.setRange(0, 10, r.sublist(0, 10));
    final sectorKeys = <Uint8List?>[];
    for (var i = 0; i < 80; i++) {
      final bit = (found[i >> 3] >> (7 - (i & 7))) & 1;
      sectorKeys.add(bit == 1 ? r.sublist(10 + i * 6, 10 + i * 6 + 6) : null);
    }
    return Mf1CheckKeysOfSectorsRes(found: found, sectorKeys: sectorKeys);
  }

  /// HardNested 采集
  Future<List<Mf1AcquireHardNestedRes>> cmdMf1AcquireHardNested({
    required int block,
    required KeyType keyType,
    required Uint8List key,
    required int targetBlock,
    required KeyType targetKeyType,
    bool slow = false,
  }) async {
    await assureDeviceMode(DeviceMode.reader);
    final b = Uint8List(11);
    b[0] = slow ? 1 : 0;
    b[1] = keyType.value;
    b[2] = block;
    b.setRange(3, 9, key);
    b[9] = targetKeyType.value;
    b[10] = targetBlock;
    final r = await _request(Cmd.mf1HardnestedAcquire.value, b,
        timeout: 30000);
    final list = <Mf1AcquireHardNestedRes>[];
    for (var i = 0; i + 9 <= r.length; i += 9) {
      list.add(Mf1AcquireHardNestedRes(
        nt: r.sublist(i, i + 4),
        ntEnc: r.sublist(i + 4, i + 8),
        par: r[i + 8],
      ));
    }
    return list;
  }

  /// 加密静态嵌套采集（默认用破解专用密钥表）
  Future<Mf1AcquireStaticEncryptedNestedDecoder> cmdMf1AcquireStaticEncryptedNested({
    Uint8List? key,
    int startSector = 0,
    int maxSectors = 16,
  }) async {
    final k = key ?? _hexToBytes('A396EFA4E24F');
    await assureDeviceMode(DeviceMode.reader);
    final b = Uint8List(8);
    b.setRange(0, 6, k);
    b[6] = startSector;
    b[7] = maxSectors;
    final r = await _request(Cmd.mf1EncNestedAcquire.value, b, timeout: 30000);
    final uid = r.sublist(0, 4);
    final atks = <(int sector, KeyType keyType, int nt, int ntEnc, int par)>[];
    for (var i = 4; i + 14 <= r.length; i += 14) {
      final chunk = r.sublist(i, i + 14);
      atks.add((startSector + (i - 4) ~/ 14, KeyType.keyA, chunk[0] | (chunk[1] << 8),
          ByteData.sublistView(chunk).getUint32(3), chunk[2]));
      atks.add((startSector + (i - 4) ~/ 14, KeyType.keyB, chunk[7] | (chunk[8] << 8),
          ByteData.sublistView(chunk).getUint32(10), chunk[9]));
    }
    return Mf1AcquireStaticEncryptedNestedDecoder(uid: uid, atks: atks);
  }

  /// 批量校验块密钥
  Future<Uint8List?> cmdMf1CheckKeysOfBlock({
    required int block,
    required KeyType keyType,
    required List<Uint8List> keys,
  }) async {
    await assureDeviceMode(DeviceMode.reader);
    final n = Uint8List(3 + keys.length * 6);
    n[0] = block;
    n[1] = keyType.value;
    n[2] = keys.length;
    for (var i = 0; i < keys.length; i++) {
      n.setRange(3 + i * 6, 3 + i * 6 + 6, keys[i]);
    }
    final r = await _request(Cmd.mf1CheckKeysOnBlock.value, n);
    return r.length > 1 ? r.sublist(1) : null;
  }

  // ========== 模拟命令（cmd 4000-4039） ==========

  /// 设置 EM4100 模拟 ID（5 字节）
  Future<void> cmdEm410xSetEmuId(Uint8List id) async {
    if (id.length != 5) throw DeviceException(96, 'id must be 5 bytes');
    await assureDeviceMode(DeviceMode.tag);
    await _request(Cmd.em410xSetEmuId.value, id);
  }

  /// 读取 EM4100 模拟 ID
  Future<Uint8List> cmdEm410xGetEmuId() async {
    final r = await _request(Cmd.em410xGetEmuId.value, null);
    return r;
  }

  Future<void> cmdMf1EmuWriteBlock(int offset, Uint8List data) async {
    if (data.length % 16 != 0) {
      throw DeviceException(96, 'data length must be multiple of 16');
    }
    final b = Uint8List(1 + data.length);
    b[0] = offset;
    b.setRange(1, 1 + data.length, data);
    await _request(Cmd.mf1WriteEmuBlockData.value, b);
  }

  Future<void> cmdHf14aSetAntiCollData({
    required Uint8List uid,
    required Uint8List atqa,
    required Uint8List sak,
    Uint8List? ats,
  }) async {
    final atsD = ats ?? Uint8List(0);
    final b = Uint8List(uid.length + 1 + 2 + 1 + atsD.length + 1);
    var p = 0;
    b[p++] = uid.length;
    b.setRange(p, p + uid.length, uid);
    p += uid.length;
    b.setRange(p, p + 2, atqa);
    p += 2;
    b[p++] = sak[0];
    b[p++] = atsD.length;
    b.setRange(p, p + atsD.length, atsD);
    p += atsD.length;
    await _request(Cmd.hf14aSetAntiCollData.value, b);
  }

  Future<void> cmdMf1SetDetectionEnable(bool enable) async {
    await _request(Cmd.mf1SetDetectionEnable.value,
        Uint8List.fromList([enable ? 1 : 0]));
  }

  Future<int> cmdMf1GetDetectionCount() async {
    final r = await _request(Cmd.mf1GetDetectionCount.value, null);
    return ByteData.sublistView(r).getUint32(0);
  }

  Future<List<Mf1DetectionLog>> cmdMf1GetDetectionLogs(int offset) async {
    final b = Uint8List(4);
    ByteData.sublistView(b).setUint32(0, offset);
    final r = await _request(Cmd.mf1GetDetectionLog.value, b);
    final list = <Mf1DetectionLog>[];
    for (var i = 0; i + 18 <= r.length; i += 18) {
      final c = r.sublist(i, i + 18);
      list.add(Mf1DetectionLog(
        block: c[0],
        flags: c[1],
        uid: c.sublist(2, 6),
        nt: c.sublist(6, 10),
        nr: c.sublist(10, 14),
        ar: c.sublist(14, 18),
      ));
    }
    return list;
  }

  Future<bool> cmdMf1GetDetectionEnable() async {
    final r = await _request(Cmd.mf1GetDetectionEnable.value, null);
    return r[0] == 1;
  }

  Future<Uint8List> cmdMf1EmuReadBlock(int offset, int length) async {
    final r = await _request(Cmd.mf1ReadEmuBlockData.value,
        Uint8List.fromList([offset, length]));
    return r;
  }

  Future<Mf1EmuSettings> cmdMf1GetEmuSettings() async {
    final r = await _request(Cmd.mf1GetEmulatorConfig.value, null);
    return Mf1EmuSettings(
      detection: r[0] == 1,
      gen1a: r[1] == 1,
      gen2: r[2] == 1,
      antiColl: r[3] == 1,
      write: r[4],
    );
  }

  Future<bool> cmdMf1GetGen1aMode() async {
    final r = await _request(Cmd.mf1GetGen1aMode.value, null);
    return r[0] == 1;
  }

  Future<void> cmdMf1SetGen1aMode(bool enable) async {
    await _request(Cmd.mf1SetGen1aMode.value,
        Uint8List.fromList([enable ? 1 : 0]));
  }

  Future<bool> cmdMf1GetGen2Mode() async {
    final r = await _request(Cmd.mf1GetGen2Mode.value, null);
    return r[0] == 1;
  }

  Future<void> cmdMf1SetGen2Mode(bool enable) async {
    await _request(Cmd.mf1SetGen2Mode.value,
        Uint8List.fromList([enable ? 1 : 0]));
  }

  Future<bool> cmdMf1GetAntiCollMode() async {
    final r = await _request(Cmd.mf1GetBlockAntiCollMode.value, null);
    return r[0] == 1;
  }

  Future<void> cmdMf1SetAntiCollMode(bool enable) async {
    await _request(Cmd.mf1SetBlockAntiCollMode.value,
        Uint8List.fromList([enable ? 1 : 0]));
  }

  Future<int> cmdMf1GetWriteMode() async {
    final r = await _request(Cmd.mf1GetWriteMode.value, null);
    return r[0];
  }

  Future<void> cmdMf1SetWriteMode(int mode) async {
    await _request(Cmd.mf1SetWriteMode.value, Uint8List.fromList([mode]));
  }

  Future<Hf14aAntiColl?> cmdHf14aGetAntiCollData() async {
    final r = await _request(Cmd.hf14aGetAntiCollData.value, null);
    if (r.isEmpty) return null;
    return _parseAntiCollList(r).isNotEmpty ? _parseAntiCollList(r).first : null;
  }

  // ========== LF 命令（cmd 3000-3009） ==========

  Future<Em410xScanRes> cmdEm410xScan() async {
    await assureDeviceMode(DeviceMode.reader);
    final r = await _request(Cmd.em410xScan.value, null);
    if (r.length == 5) {
      return Em410xScanRes(tagType: 103, id: r);
    }
    return Em410xScanRes(tagType: r[0] | (r[1] << 8), id: r.sublist(2));
  }

  Future<void> cmdEm410xWriteToT55xx(
      Uint8List id, Uint8List newKey, List<Uint8List> oldKeys) async {
    await assureDeviceMode(DeviceMode.reader);
    final n = Uint8List(5 + 4 + oldKeys.length * 4);
    n.setRange(0, 5, id);
    n.setRange(5, 9, newKey);
    for (var i = 0; i < oldKeys.length; i++) {
      n.setRange(9 + i * 4, 9 + i * 4 + 4, oldKeys[i]);
    }
    await _request(Cmd.em410xWriteToT55xx.value, n);
  }

  /// LF 写 T55xx（EM4100/HID/维根）
  Future<void> cmdLfWriteToT55xx(int cmd, Uint8List id, Uint8List newKey, List<Uint8List> oldKeys) async {
    await assureDeviceMode(DeviceMode.reader);
    final n = Uint8List(id.length + 4 + oldKeys.length * 4);
    n.setRange(0, id.length, id);
    n.setRange(id.length, id.length + 4, newKey);
    for (var i = 0; i < oldKeys.length; i++) {
      n.setRange(id.length + 4 + i * 4, id.length + 4 + i * 4 + 4, oldKeys[i]);
    }
    await _request(cmd, n);
  }

  Future<HidProxScanRes> cmdHidProxScan() async {
    await assureDeviceMode(DeviceMode.reader);
    final r = await _request(Cmd.hidproxScan.value, null);
    final bd = ByteData.sublistView(r);
    return HidProxScanRes(
      format: r[0],
      fc: bd.getUint32(1),
      cn: (bd.getUint32(5) * 4294967296) + bd.getUint32(5) == 0
          ? bd.getUint32(5)
          : 0,
      il: r[9],
      oem: bd.getUint16(11),
    );
  }

  // ========== 组合操作（与逆向 hf14aInfo 等一致） ==========

  /// 扫描并获取卡片信息列表
  Future<List<Map<String, dynamic>>> hf14aInfo() async {
    final tags = await cmdHf14aScan();
    final list = <Map<String, dynamic>>[];
    for (final tag in tags) {
      final t = <String, dynamic>{
        'antiColl': tag,
        'nxpTypeBySak': _sakType(tag.sak),
      };
      list.add(t);
    }
    if (list.length == 1 && await cmdMf1IsSupport()) {
      list[0]['prngType'] = await cmdMf1TestPrngType();
    }
    return list;
  }

  static String? _sakType(int sak) {
    const map = {
      0: 'MIFARE Ultralight Classic/C/EV1/Nano | NTAG 2xx',
      8: 'MIFARE Classic 1K | Plus SE 1K | Plug S 2K | Plus X 2K',
      9: 'MIFARE Mini 0.3k',
      16: 'MIFARE Plus 2K',
      17: 'MIFARE Plus 4K',
      24: 'MIFARE Classic 4K | Plus S 4K | Plus X 4K',
      25: 'MIFARE Classic 2K',
      32: 'MIFARE Plus EV1/EV2 | DESFire EV1/EV2/EV3 | DESFire Light | NTAG 4xx | MIFARE Plus S 2/4K | MIFARE Plus X 2/4K | MIFARE Plus SE 1K',
      40: 'SmartMX with MIFARE Classic 1K',
      56: 'SmartMX with MIFARE Classic 4K',
    };
    return map[sak];
  }

  /// 扫描并设置反碰撞数据到模拟卡
  Future<void> scanAndSetAntiColl() async {
    await assureDeviceMode(DeviceMode.reader);
    final tags = await cmdHf14aScan();
    if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
    final tag = tags.first;
    await cmdHf14aSetAntiCollData(
        uid: tag.uid,
        atqa: tag.atqa,
        sak: Uint8List.fromList([tag.sak]),
        ats: tag.ats);
  }

  /// 释放设备（切回标签模式）
  Future<void> release() async {
    if (isConnected()) {
      try {
        await cmdChangeDeviceMode(DeviceMode.tag);
      } catch (_) {}
    }
  }

  void dispose() {
    _sub?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(DeviceException(-1, '设备已断开'));
      }
    }
    _pending.clear();
  }
}

// ========== 结果模型（对应逆向响应解析） ==========

class BatteryInfo {
  final int voltage; // 单位 mV
  final int level; // 0-100
  BatteryInfo({required this.voltage, required this.level});
}

class Hf14aAntiColl {
  final Uint8List uid;
  final Uint8List atqa;
  final int sak;
  final Uint8List ats;
  Hf14aAntiColl({required this.uid, required this.atqa, required this.sak, required this.ats});

  String get uidHex => uid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  String get atqaHex => atqa.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  String get sakHex => sak.toRadixString(16).padLeft(2, '0');
  String get atsHex => ats.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class Mf1AcquireStaticNestedRes {
  final Uint8List uid;
  final List<(Uint8List nt1, Uint8List nt2)> atks;
  Mf1AcquireStaticNestedRes({required this.uid, required this.atks});
}

class Mf1DarksideRes {
  final int status;
  final Uint8List? uid;
  final Uint8List? nt;
  final Uint8List? par;
  final Uint8List? ks;
  final Uint8List? nr;
  final Uint8List? ar;
  Mf1DarksideRes({required this.status, this.uid, this.nt, this.par, this.ks, this.nr, this.ar});
}

class Mf1NtDistanceRes {
  final Uint8List uid;
  final Uint8List dist;
  Mf1NtDistanceRes({required this.uid, required this.dist});
}

class Mf1NestedRes {
  final Uint8List nt1;
  final Uint8List nt2;
  final int par;
  Mf1NestedRes({required this.nt1, required this.nt2, required this.par});
}

class Mf1AcquireHardNestedRes {
  final Uint8List nt;
  final Uint8List ntEnc;
  final int par;
  Mf1AcquireHardNestedRes({required this.nt, required this.ntEnc, required this.par});
}

class Mf1AcquireStaticEncryptedNestedDecoder {
  final Uint8List uid;
  final List<(int sector, KeyType keyType, int nt, int ntEnc, int par)> atks;
  Mf1AcquireStaticEncryptedNestedDecoder({required this.uid, required this.atks});
}

class Mf1CheckKeysOfSectorsRes {
  final Uint8List found; // 10 bytes mask
  final List<Uint8List?> sectorKeys;
  Mf1CheckKeysOfSectorsRes({required this.found, required this.sectorKeys});
}

class Mf1DetectionLog {
  final int block;
  final int flags; // bit0=isKeyB bit1=isNested
  final Uint8List uid;
  final Uint8List nt;
  final Uint8List nr;
  final Uint8List ar;
  Mf1DetectionLog({required this.block, required this.flags, required this.uid, required this.nt, required this.nr, required this.ar});

  bool get isKeyB => (flags & 1) == 1;
  bool get isNested => (flags & 2) == 2;
}

class Mf1EmuSettings {
  final bool detection;
  final bool gen1a;
  final bool gen2;
  final bool antiColl;
  final int write;
  Mf1EmuSettings({required this.detection, required this.gen1a, required this.gen2, required this.antiColl, required this.write});
}

class Em410xScanRes {
  final int tagType;
  final Uint8List id;
  Em410xScanRes({required this.tagType, required this.id});
}

class HidProxScanRes {
  final int format;
  final int fc;
  final int cn;
  final int il;
  final int oem;
  HidProxScanRes({required this.format, required this.fc, required this.cn, required this.il, required this.oem});
}

Uint8List _hexToBytes(String hex) {
  final clean = hex.replaceAll(' ', '');
  final bytes = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}
