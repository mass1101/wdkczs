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
/// 设备错误状态码集合（对应逆向 rk：HF 1-8 / LF 65-67 / 通用错误）
/// 成功码：0 (HF), 64 (LF), 104 (Device) 均不在该集合中
final Set<int> _errorStatuses = {1, 2, 3, 4, 5, 6, 7, 8, 65, 66, 67, 96, 102, 103, 105, 112, 113, 114};

bool _isErrStatus(int s) => _errorStatuses.contains(s);

/// 设备命令层：封装 UltraFrame 协议的全部命令（对应逆向 Kk 类）
class DeviceService {
  final BleService _ble;
  bool _ready = false;
  final _pending = <int, Completer<Uint8List>>{};
  final _dfuPending = <int, Completer<Uint8List>>{};
  StreamSubscription? _sub;
  Future<void> _txQueue = Future.value();

  DeviceService(this._ble);

  /// 初始化（监听接收流，解析响应帧，支持 BLE 粘包/分片重组）
  void init() {
    if (_ready) return;
    _ready = true;
    var buf = Uint8List(0);
    _sub = _ble.rx.listen((bytes) {
      if (bytes.isEmpty) return;
      if (bytes[0] == 0x60) {
        _handleDfuFrame(bytes);
        return;
      }
      buf = _concat(buf, bytes);
      try {
        for (;;) {
          if (buf.length < 10) break;
          // 查找帧 magic（0x11EF 大端）
          var magicAt = -1;
          for (var i = 0; i + 2 <= buf.length; i++) {
            if (buf[i] == 0x11 && buf[i + 1] == 0xEF) {
              magicAt = i;
              break;
            }
          }
          if (magicAt < 0) {
            buf = Uint8List(0);
            break;
          }
          if (magicAt > 0) buf = buf.sublist(magicAt);
          if (buf.length < 10) break;
          // 头 LRC 校验（第 0..7 字节，第 8 字节为 LRC）
          if (!UltraFrame.checkHeadLrc(buf)) {
            buf = buf.sublist(1);
            continue;
          }
          final bd = ByteData.sublistView(buf);
          final len = bd.getUint16(6);
          final total = len + 10;
          if (buf.length < total) break; // 等待后续分片
          final frame = buf.sublist(0, total);
          buf = buf.sublist(total);
          if (!UltraFrame.checkLrc(frame)) continue;
          final (cmd, status, data) = UltraFrame.decode(frame);
          final completer = _pending.remove(cmd);
          if (completer != null) {
            if (_isErrStatus(status)) {
              completer.completeError(DeviceException(status, ''));
            } else {
              completer.complete(data);
            }
          }
        }
      } catch (e) {
        debugPrint('frame decode error: $e');
      }
    });
  }

  static Uint8List _concat(Uint8List a, Uint8List b) {
    final out = Uint8List(a.length + b.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, out.length, b);
    return out;
  }

  bool isConnected() => _ble.isConnected;

  Future<void> ensureConnected() async {
    if (!isConnected()) {
      throw DeviceException(-1, '设备未连接');
    }
  }

  /// 底层发送请求并等待响应（命令串行化，避免并发导致响应错乱）
  Future<Uint8List> _request(int cmd, Uint8List? data,
      {int timeout = UltraFrame.defaultTimeoutMs}) {
    final task = _txQueue
        .then((_) => _requestRaw(cmd, data, timeout: timeout));
    _txQueue = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<Uint8List> _requestRaw(int cmd, Uint8List? data,
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

  // ========== DFU 固件刷写（对应逆向 DfuFrame / DfuZip） ==========

  /// 进入 DFU 模式（cmd 1010），设备随后断开进入 bootloader
  Future<void> cmdDfuEnter() async {
    await _request(Cmd.enterBootloader.value, null);
  }

  /// DFU 模式下向 bootloader 发送协议帧（op + data），返回响应数据
  Future<Uint8List> _dfuRequest(int op, [Uint8List? data]) async {
    final d = data ?? Uint8List(0);
    final buf = Uint8List(1 + d.length);
    buf[0] = op;
    if (d.isNotEmpty) buf.setRange(1, 1 + d.length, d);
    final completer = Completer<Uint8List>();
    _dfuPending[op] = completer;
    try {
      await _ble.dfuWrite(buf);
      return await completer.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _dfuPending.remove(op);
      throw DeviceException(-2, 'DFU 响应超时');
    } catch (e) {
      _dfuPending.remove(op);
      rethrow;
    }
  }

  Future<int> cmdDfuGetProtocol() async {
    final r = await _dfuRequest(0);
    return r.isEmpty ? 0 : r[0];
  }

  Future<void> cmdDfuCreateObject(int type, int size) async {
    final b = Uint8List(5);
    b[0] = type;
    ByteData.sublistView(b).setUint32(1, size, Endian.little);
    await _dfuRequest(1, b);
  }

  Future<void> cmdDfuSetPrn(int prn) async {
    final b = Uint8List(4);
    ByteData.sublistView(b).setUint32(0, prn, Endian.little);
    await _dfuRequest(2, b);
  }

  Future<(int, int)> cmdDfuGetObjectCrc() async {
    final r = await _dfuRequest(3);
    final bd = ByteData.sublistView(r);
    return (bd.getUint32(0, Endian.little), bd.getUint32(4, Endian.little));
  }

  Future<void> cmdDfuExecuteObject() async {
    await _dfuRequest(4);
  }

  Future<({int offset, int crc, int maxSize})> cmdDfuSelectObject(
      int type) async {
    final r = await _dfuRequest(6, Uint8List.fromList([type]));
    final bd = ByteData.sublistView(r);
    return (
      offset: bd.getUint32(1, Endian.little),
      crc: bd.getUint32(5, Endian.little),
      maxSize: bd.getUint32(9, Endian.little),
    );
  }

  Future<int> cmdDfuGetMtu() async {
    final r = await _dfuRequest(7);
    if (r.length < 2) return 0;
    return ByteData.sublistView(r).getUint16(0, Endian.little);
  }

  Future<int> cmdDfuPing(int id) async {
    final r = await _dfuRequest(9, Uint8List.fromList([id]));
    return r.isEmpty ? 0 : r[0];
  }

  Future<void> cmdDfuAbort() async {
    await _dfuRequest(12);
  }

  /// 更新单个对象（对应逆向 dfuUpdateObject：select→分段 create/write→crc 校验→execute）
  Future<void> dfuUpdateObject(
      int type, Uint8List data, void Function(int offset, int size)? onProgress) async {
    var selected = await cmdDfuSelectObject(type);
    if (selected.offset == data.length) {
      // 对象已完整上传
      if (onProgress != null) onProgress(data.length, data.length);
      return;
    }
    if (selected.offset > 0) {
      // 已存在部分对象：校验已上传偏移的 CRC，不一致则中止重建
      final expected = _crc32(data.sublist(0, selected.offset));
      if (selected.crc != expected) {
        await cmdDfuAbort();
        selected = await cmdDfuSelectObject(type);
      }
    }
    if (onProgress != null) onProgress(0, data.length);
    final mtu = await cmdDfuGetMtu();
    final chunkSize = mtu > 0 ? mtu : 20;
    var offset = selected.offset > 0 ? selected.offset : 0;
    var failures = 0;
    while (offset < data.length) {
      final size = (data.length - offset) < chunkSize
          ? (data.length - offset)
          : chunkSize;
      final chunk = data.sublist(offset, offset + size);
      await cmdDfuCreateObject(type, chunk.length);
      await _ble.dfuWrite(chunk);
      final (crcOff, crcVal) = await cmdDfuGetObjectCrc();
      final expected = _crc32(data.sublist(0, offset + chunk.length));
      if (crcOff == offset + chunk.length && crcVal == expected) {
        await cmdDfuExecuteObject();
        offset += chunk.length;
        failures = 0;
        if (onProgress != null) onProgress(offset, data.length);
      } else {
        failures++;
        if (failures > 10) throw DeviceException(-1, 'crc32 check failed 10 times');
        await cmdDfuSelectObject(type);
      }
    }
  }

  /// 刷写固件镜像（header 对象 + body 对象）
  Future<void> dfuUpdateImage({
    required Uint8List header,
    required Uint8List body,
    void Function(int offset, int size)? onProgress,
  }) async {
    await dfuUpdateObject(1, header, onProgress);
    await dfuUpdateObject(2, body, onProgress);
    // 等待重启（逆向等待最多 5000ms 后断开）
    for (var t = 0; t < 50 && isConnected(); t++) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  /// CRC32（IEEE，对应逆向 db()）
  static final Uint8List _crcTable = _buildCrcTable();
  static Uint8List _buildCrcTable() {
    final table = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[i] = c & 0xFF;
    }
    return table;
  }

  static int _crc32(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc = (crc >> 8) ^ _crcTable[(crc ^ b) & 0xFF];
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  // DFU 响应帧监听（qk：buf[0]==0x60 表示响应）
  void _handleDfuFrame(Uint8List bytes) {
    if (bytes.isEmpty) return;
    if (bytes[0] != 0x60) {
      debugPrint('DFU frame: not resp: ${bytes.map((b) => b.toRadixString(16)).join()}');
      return;
    }
    if (bytes.length < 3) return;
    final op = bytes[1];
    final result = bytes.length > 2 ? bytes[2] : 0;
    final completer = _dfuPending.remove(op);
    if (completer == null) return;
    if (result != 1) {
      completer.completeError(DeviceException(result, 'DFU 操作失败 (op=$op)'));
      return;
    }
    completer.complete(bytes.sublist(3));
  }

  Future<int> cmdGetDeviceModel() async {
    final r = await _request(Cmd.getDeviceModel.value, null);
    return r[0];
  }

  Future<DeviceSettings> cmdGetDeviceSettings() async {
    final r = await _request(Cmd.getDeviceSettings.value, null);
    // 布局（对应逆向 `!6B?6s`）：version[0] animation[1] press[2..3] longPress[4..5] pairing[6] key[7..12]
    return DeviceSettings(
      animation: AnimationMode.from(r[1]),
      pressBtnA: ButtonAction.from(r[2]),
      pressBtnB: ButtonAction.from(r[3]),
      longPressBtnA: ButtonAction.from(r[4]),
      longPressBtnB: ButtonAction.from(r[5]),
      blePairing: r[6] == 1,
      blePairingKey: String.fromCharCodes(r.sublist(7, 13)),
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
  ///
  /// 请求体布局（对应逆向 `!xHH{len}s` + 标志位写第 0 字节 MSB）：
  ///   [0]      标志位 bit7-2（activateRfField/waitResponse/appendCrc/autoSelect/keepRfField/checkResponseCrc）
  ///   [1..2]   timeout  UInt16BE
  ///   [3..4]   bitLen   UInt16BE
  ///   [5..]    data
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
    final u = Uint8List(1 + 2 + 2 + d.length);
    final bd = ByteData.sublistView(u);
    // 标志位：bit7=activateRfField bit6=waitResponse bit5=appendCrc bit4=autoSelect bit3=keepRfField bit2=checkResponseCrc
    u[0] = (activateRfField ? 0x80 : 0) |
        (waitResponse ? 0x40 : 0) |
        (appendCrc ? 0x20 : 0) |
        (autoSelect ? 0x10 : 0) |
        (keepRfField ? 0x08 : 0) |
        (checkResponseCrc ? 0x04 : 0);
    bd.setUint16(1, timeout);
    bd.setUint16(3, bitLen);
    if (d.isNotEmpty) u.setRange(5, 5 + d.length, d);
    await assureDeviceMode(DeviceMode.reader);
    return _request(Cmd.hf14aRaw.value, u, timeout: UltraFrame.defaultTimeoutMs + timeout);
  }

  /// 后门卡探测（对齐 CU mfClassicHasBackdoor：0x64 后门认证原始帧，
  /// 后门卡响应 4 字节 nonce，普通卡无响应）
  Future<bool> mf1HasBackdoor() async {
    await assureDeviceMode(DeviceMode.reader);
    final r = await cmdHf14aRaw(
        data: Uint8List.fromList([0x64, 0x00]),
        activateRfField: true,
        autoSelect: true,
        appendCrc: true,
        checkResponseCrc: false,
        timeout: 300);
    return r.length == 4;
  }

  /// MIFARE Halt 指令（对应逆向 mf1Halt：`xw.pack("!H", 20480)`）
  Future<void> mf1Halt() async {
    await cmdHf14aRaw(
        appendCrc: true, data: Uint8List.fromList([0x50, 0x00]), waitResponse: false);
  }

  /// Gen1a 免密认证包裹：halt → 0x40(7bit) → 0x43 → 执行回调 → halt
  Future<T> _mf1Gen1aAuth<T>(Future<T> Function() cb) async {
    await mf1Halt();
    try {
      final r1 = await cmdHf14aRaw(dataBitLength: 7, data: Uint8List.fromList([0x40]), keepRfField: true)
          .catchError((e) => throw DeviceException(-1, 'Gen1a auth failed 1: $e'));
      if (r1.isEmpty || r1[0] != 10) throw DeviceException(-1, 'Gen1a auth failed 1');
      final r2 = await cmdHf14aRaw(data: Uint8List.fromList([0x43]), keepRfField: true)
          .catchError((e) => throw DeviceException(-1, 'Gen1a auth failed 2: $e'));
      if (r2.isEmpty || r2[0] != 10) throw DeviceException(-1, 'Gen1a auth failed 2');
      return await cb();
    } finally {
      if (isConnected()) {
        try {
          await mf1Halt();
        } catch (_) {}
      }
    }
  }

  /// Gen1a 免密读块（对应逆向 mf1Gen1aReadBlocks）
  Future<Uint8List> mf1Gen1aReadBlocks(int offset, [int length = 1]) async {
    return _mf1Gen1aAuth(() async {
      final out = Uint8List(16 * length);
      for (var i = 0; i < length; i++) {
        final r = await cmdHf14aRaw(
            appendCrc: true,
            checkResponseCrc: true,
            data: Uint8List.fromList([0x30, offset + i]),
            keepRfField: true);
        out.setRange(16 * i, 16 * i + 16, r);
      }
      return out;
    });
  }

  /// Gen1a 免密写块（对应逆向 mf1Gen1aWriteBlocks）
  Future<void> mf1Gen1aWriteBlocks(int offset, Uint8List data) async {
    if (data.length % 16 != 0) throw DeviceException(96, 'data must be multiples of 16');
    await _mf1Gen1aAuth(() async {
      for (var i = 0; i < data.length ~/ 16; i++) {
        final cmd = await cmdHf14aRaw(
            appendCrc: true,
            data: Uint8List.fromList([0xA0, offset + i]),
            keepRfField: true);
        if (cmd.isEmpty || cmd[0] != 10) throw DeviceException(-1, 'Gen1a write failed 1');
        final body = await cmdHf14aRaw(
            appendCrc: true,
            data: data.sublist(16 * i, 16 * i + 16),
            keepRfField: true);
        if (body.isEmpty || body[0] != 10) throw DeviceException(-1, 'Gen1a write failed 2');
      }
    });
  }

  /// 检查扇区密钥，返回命中的密钥（对应逆向 mf1CheckSectorKeys）
  Future<Map<int, Uint8List>> mf1CheckSectorKeys(int sector, List<Uint8List> keys) async {
    final mask = Uint8List(10);
    for (var i = 0; i < 10; i++) {
      mask[i] = 0xFF;
    }
    mask[sector >> 2] ^= (3 << (6 - (sector % 4) * 2));
    final res = await cmdMf1CheckKeysOfSectors(keys: keys, mask: mask);
    final out = <int, Uint8List>{};
    // 扇区 sector 的 keyA（块 4*sector）与 keyB（块 4*sector+1）
    final a = res.sectorKeys[sector * 2];
    final b = res.sectorKeys[sector * 2 + 1];
    if (a != null) out[KeyType.keyA.value] = a;
    if (b != null) out[KeyType.keyB.value] = b;
    return out;
  }

  /// 空卡体（对应逆向 jT()：16 扇区 × 4 块，含块0 UID、ACL 默认密钥）
  static List<String> emptyCardBody() {
    const block0 = 'deadbeef220804000177a2cc35afa51d';
    const empty = '00000000000000000000000000000000';
    const acl = 'ffffffffffffff078069ffffffffffff';
    return List.generate(16, (s) {
      return List.generate(4, (b) {
        if (s == 0 && b == 0) return block0;
        if (b == 3) return acl;
        return empty;
      }).join('\n');
    });
  }

  /// 空卡体（保留当前 UID，对应逆向 getEmptyCardBodyWithoutUID）
  Future<List<String>> getEmptyCardBodyWithoutUID() async {
    var factory = 'deadbeef220804000177a2cc35afa51d';
    if ((await cmdHf14aScan()).isNotEmpty) {
      try {
        factory = (await mf1Gen1aReadBlocks(0))
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
      } catch (_) {
        // 非 UID 卡后门读 block0 失败：保留默认块，错误留给后续认证环节报出
      }
    }
    const empty = '00000000000000000000000000000000';
    const acl = 'ffffffffffffff078069ffffffffffff';
    return List.generate(16, (s) {
      return List.generate(4, (b) {
        if (s == 0 && b == 0) return factory;
        if (b == 3) return acl;
        return empty;
      }).join('\n');
    });
  }

  /// 格式化卡片（对应逆向 formatCard：空卡体逐块 Gen1a 写入）
  Future<void> formatCard() async {
    final body = await getEmptyCardBodyWithoutUID();
    await _mf1Gen1aAuth(() async {
      for (var s = 0; s < 16; s++) {
        for (var b = 0; b < 4; b++) {
          final data = _hexToBytes(body[s].split('\n')[b]);
          final cmd = await cmdHf14aRaw(
              appendCrc: true, data: Uint8List.fromList([0xA0, 4 * s + b]), keepRfField: true);
          if (cmd.isEmpty || cmd[0] != 10) throw DeviceException(-1, 'Gen1a write failed 1');
          final bodyRes = await cmdHf14aRaw(appendCrc: true, data: data, keepRfField: true);
          if (bodyRes.isEmpty || bodyRes[0] != 10) throw DeviceException(-1, 'Gen1a write failed 2');
        }
      }
    });
  }

  /// 重置 UID（对应逆向 wipeUID：空卡体逐块 Gen1a 写入）
  Future<void> wipeUid() async {
    final body = emptyCardBody();
    await _mf1Gen1aAuth(() async {
      for (var s = 0; s < 16; s++) {
        for (var b = 0; b < 4; b++) {
          final data = _hexToBytes(body[s].split('\n')[b]);
          final cmd = await cmdHf14aRaw(
              appendCrc: true, data: Uint8List.fromList([0xA0, 4 * s + b]), keepRfField: true);
          if (cmd.isEmpty || cmd[0] != 10) throw DeviceException(-1, 'Gen1a write failed 1');
          final bodyRes = await cmdHf14aRaw(appendCrc: true, data: data, keepRfField: true);
          if (bodyRes.isEmpty || bodyRes[0] != 10) throw DeviceException(-1, 'Gen1a write failed 2');
        }
      }
    });
  }

  /// 修改卡号（对应逆向 writeUID：Gen1a 免密写 block0，失败则普通卡密钥写）
  Future<void> writeUid({
    required String uid,
    required String sak,
    required String atqa,
    String keysText = '',
  }) async {
    if (!RegExp(r'^([\dA-Fa-f]{8}\s*)+$').hasMatch(uid)) {
      throw DeviceException(96, '卡号有误，IC卡号应为8位16进制数');
    }
    if (!RegExp(r'^([\dA-Fa-f]{2}\s*)+$').hasMatch(sak)) {
      throw DeviceException(96, 'SAK有误，SAK应为2位16进制数');
    }
    if (!RegExp(r'^([\dA-Fa-f]{4}\s*)+$').hasMatch(atqa)) {
      throw DeviceException(96, 'ATQA有误，ATQA应为4位16进制数');
    }
    final uidClean = uid.replaceAll(' ', '');
    final atqaClean = atqa.replaceAll(' ', '');
    final bcc = int.parse(uidClean.substring(0, 2), radix: 16) ^
        int.parse(uidClean.substring(2, 4), radix: 16) ^
        int.parse(uidClean.substring(4, 6), radix: 16) ^
        int.parse(uidClean.substring(6, 8), radix: 16);
    final block0Hex = '$uidClean${bcc.toRadixString(16).padLeft(2, '0')}08'
        '${atqaClean.substring(2, 4)}${atqaClean.substring(0, 2)}0177a2cc35afa51d';
    final block0 = _hexToBytes(block0Hex);

    await cmdHf14aScan();
    try {
      await _mf1Gen1aAuth(() async {
        final cmd = await cmdHf14aRaw(
            appendCrc: true, data: Uint8List.fromList([0xA0, 0]), keepRfField: true);
        if (cmd.isEmpty || cmd[0] != 10) throw DeviceException(-1, 'Gen1a write failed 1');
        final body = await cmdHf14aRaw(appendCrc: true, data: block0, keepRfField: true);
        if (body.isEmpty || body[0] != 10) throw DeviceException(-1, 'Gen1a write failed 2');
      });
    } catch (e) {
      // 普通卡：使用密钥写 block0（默认密钥 + 编辑框密钥，去重截 40 上限）
      final seen = <String>{};
      final merged = <String>[];
      for (final k in [..._defaultKeysText, ...keysText.split('\n')]) {
        final t = k.trim().toLowerCase();
        if (t.length == 12 && seen.add(t)) merged.add(t);
      }
      final keys = merged.take(40).map(_hexToBytes).toList();
      final found = await mf1CheckSectorKeys(0, keys);
      if (found.isEmpty) {
        throw DeviceException(6, '卡片有加密，请先使用 解卡片 功能获取密钥！');
      }
      var wrote = false;
      final a = found[KeyType.keyA.value];
      if (a != null) {
        try {
          await cmdMf1WriteBlock(block: 0, keyType: KeyType.keyA, key: a, data: block0);
          wrote = true;
        } catch (_) {}
      }
      if (!wrote) {
        final b = found[KeyType.keyB.value];
        if (b == null) throw DeviceException(6, '没有可用 keyB');
        await cmdMf1WriteBlock(block: 0, keyType: KeyType.keyB, key: b, data: block0);
      }
    }
  }

  /// 锁 UFUID 卡（对应逆向 lockUFUID：固定 5 段指令流）
  Future<void> lockUfuid() async {
    await cmdHf14aScan();
    try {
      await mf1Halt();
    } catch (e) {
      throw DeviceException(-1, 'failed 0，不支持锁卡指令');
    }
    final r1 = await cmdHf14aRaw(dataBitLength: 7, data: Uint8List.fromList([0x40]), keepRfField: true)
        .catchError((e) => throw DeviceException(-1, 'failed 1，不支持锁卡指令'));
    if (r1.isEmpty || r1[0] != 10) throw DeviceException(-1, 'failed 1，不支持锁卡指令');
    final r2 = await cmdHf14aRaw(data: Uint8List.fromList([0x43]), keepRfField: true)
        .catchError((e) => throw DeviceException(-1, 'failed 2，不支持锁卡指令'));
    if (r2.isEmpty || r2[0] != 10) throw DeviceException(-1, 'failed 2，不支持锁卡指令');
    final r3 = await cmdHf14aRaw(data: _hexToBytes('e100e1ee'), keepRfField: true)
        .catchError((e) => throw DeviceException(-1, 'failed 3，不支持锁卡指令'));
    if (r3.isEmpty || r3[0] != 10) throw DeviceException(-1, 'failed 3，不支持锁卡指令');
    final r4 = await cmdHf14aRaw(data: _hexToBytes('850000000000000000000000000000081847'), keepRfField: true)
        .catchError((e) => throw DeviceException(-1, 'failed 4，不支持锁卡指令'));
    if (r4.isEmpty || r4[0] != 10) throw DeviceException(-1, 'failed 4，不支持锁卡指令');
  }

  /// 默认密钥表（用于普通卡写卡）
  static final List<String> _defaultKeysText = [
    'FFFFFFFFFFFF',
    '000000000000',
    'A0A1A2A3A4A5',
    'B0B1B2B3B4B5',
    'AABBCCDDEEFF',
    '4D3A99C351DD',
    '1A982C7E459A',
    'D3F7D3F7D3F7',
    '000000000000',
    'FFFFFFFFFFFF',
  ];

  /// 检查多扇区密钥
  /// onChunk：每块响应解析完成后回调，参数为累积结果（已命中的 found 位与 sectorKeys）
  /// 与已处理的 key 数量游标（断点续破），不影响最终返回值
  Future<Mf1CheckKeysOfSectorsRes> cmdMf1CheckKeysOfSectors({
    required List<Uint8List> keys,
    required Uint8List mask,
    // 32 把/块（对齐 CU BLE）：32×32 槽位×~30ms ≈ 31s < 60s 超时
    int chunkSize = 32,
    void Function(Mf1CheckKeysOfSectorsRes partial, int processedKeys)? onChunk,
  }) async {
    await assureDeviceMode(DeviceMode.reader);
    final foundAll = Uint8List(10);
    final sectorKeysAll = List<Uint8List?>.filled(80, null);
    // 动态收缩的掩码副本：已命中槽位不再重复认证（字典/候选量大时单命令耗时可控）
    final liveMask = Uint8List.fromList(mask);
    for (var off = 0; off < keys.length; off += chunkSize) {
      final end = (off + chunkSize > keys.length) ? keys.length : off + chunkSize;
      final chunk = keys.sublist(off, end);
      final n = Uint8List(10 + chunk.length * 6);
      n.setRange(0, 10, liveMask);
      for (var i = 0; i < chunk.length; i++) {
        n.setRange(10 + i * 6, 10 + i * 6 + 6, chunk[i]);
      }
      final r = await _request(Cmd.mf1CheckKeysOfSectors.value, n,
          timeout: 60000);
      final found = Uint8List(10);
      found.setRange(0, 10, r.sublist(0, 10));
      var allDone = true;
      for (var i = 0; i < 10; i++) {
        foundAll[i] |= found[i];
        liveMask[i] &= ~found[i];
        if (liveMask[i] != 0) allDone = false;
      }
      for (var i = 0; i < 80; i++) {
        final bit = (found[i >> 3] >> (7 - (i & 7))) & 1;
        if (bit == 1 && sectorKeysAll[i] == null) {
          sectorKeysAll[i] = r.sublist(10 + i * 6, 10 + i * 6 + 6);
        }
      }
      if (onChunk != null) {
        onChunk(
            Mf1CheckKeysOfSectorsRes(
                found: Uint8List.fromList(foundAll), sectorKeys: sectorKeysAll),
            off + chunk.length);
      }
      if (allDone) break;
    }
    return Mf1CheckKeysOfSectorsRes(found: foundAll, sectorKeys: sectorKeysAll);
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
  /// 设备返回数据前 2 字节为状态/长度前缀，实际卡号在之后的 5 字节中
  Future<Uint8List> cmdEm410xGetEmuId() async {
    final r = await _request(Cmd.em410xGetEmuId.value, null);
    return r.length > 2 ? r.sublist(2) : r;
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
