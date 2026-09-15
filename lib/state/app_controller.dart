import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../ble/ble_service.dart';
import '../models/enums.dart';
import '../models/models.dart';
import '../services/card_backup.dart';
import '../services/card_library.dart';
import '../services/cloud_service.dart';
import '../services/device_service.dart';
import '../services/dfu_zip.dart';
import '../services/geofence_provider.dart';
import '../services/position_provider.dart';
import '../services/slot_writer.dart';
import '../services/storage_service.dart';

/// 全局应用状态（设备连接、卡数据、设置）
class AppController extends ChangeNotifier {
  final BleService ble = BleService();
  late final DeviceService device;
  late final StorageService storage;
  late final CloudService cloud;

  AppController() {
    device = DeviceService(ble);
    storage = StorageService();
    cloud = CloudService(storage);
    final geo = GeofenceProvider();
    geofence = geo;
    position = PositionProvider();
    device.init();
    installAutoBackupHook();
    ble.status.addListener(_onBleStatus);
    _initGeofence();
  }

  bool get connected => ble.isConnected;

  // 电子围栏
  late final GeofenceProvider geofence;

  // 定位源（独立于围栏：不检查总开关与设备连接）
  late final PositionProvider position;

  // IC 卡状态
  CardState card = CardState.withDefaultData();

  // ID 卡状态
  IdCardState idCard = IdCardState();

  // 设置页状态
  DeviceSettings settings = DeviceSettings();
  DeviceInfo deviceInfo = DeviceInfo();
  List<(bool, bool)> enabledSlots = List.generate(8, (_) => (false, false));
  List<(String?, String?)> slotNames = List.generate(8, (_) => (null, null));
  List<(int, int)> slotTypes = List.generate(8, (_) => (0, 4));
  List<Mf1EmuSettings> slotEmuSettings = List.generate(
    8,
    (_) => Mf1EmuSettings(
      detection: false,
      gen1a: false,
      gen2: false,
      antiColl: true,
      write: 0,
    ),
  );

  int tabIndex = 0;
  int currentSlot = 0;
  bool _processing = false;

  /// 每槽的 UID/SAK/ATQA 展示数据（读卡槽时刷新）
  final List<({String uid, String sak, String atqa})> slotCardIds =
      List.generate(8, (_) => (uid: '', sak: '', atqa: ''));

  bool get processing => _processing;

  /// 通用异步包装：设置 busy 状态并通知
  Future<void> run(Future<void> Function() task, {String? errorHint}) async {
    if (_processing) return;
    _processing = true;
    notifyListeners();
    try {
      await task();
    } catch (e) {
      rethrow;
    } finally {
      _processing = false;
      notifyListeners();
    }
  }

  void _onBleStatus() {
    if (connected) {
      scheduleAutoBackup(storage);
    }
    notifyListeners();
  }

  Future<void> _initGeofence() async {
    final prefs = await storage.prefs;
    geofence.setHandlers(
      activateSlot: (slot) {
        try {
          device.cmdSlotSetActive(slot - 1);
          currentSlot = slot - 1;
          return true;
        } catch (_) {
          return false;
        }
      },
      isConnected: () => connected,
      uploadCard: (card, slot) async {
        await slotWriterUpload(card, slot);
      },
      readHfSlot: (slot) => readHfSlot(slot),
    );
    geofence.setConnected(connected);
    await geofence.load(prefs);
    ble.status.addListener(_syncGeofenceConnected);
  }

  void _syncGeofenceConnected() {
    geofence.setConnected(connected);
    geofence.refreshEnabledState();
  }

  /// 卡库卡片写入某槽（供围栏自动上传复用，与卡库页同一实现）
  Future<void> slotWriterUpload(SaveCard card, int slot) {
    return uploadCardToSlot(device, card, slot);
  }

  /// 读取某 HF 槽的完整数据为 SaveCard（供围栏滚动码轮询遍历比对）
  Future<SaveCard?> readHfSlot(int slot) async {
    await device.cmdSlotSetActive(slot);
    final anti = await device.cmdHf14aGetAntiCollData();
    if (anti == null) return null;
    final uid = anti.uidHex;
    // 先按 Mifare Classic 读取（16 块 × 每扇区逐块）
    final blocks = <String>[];
    try {
      for (var sector = 0; sector < 16; sector++) {
        final raw = await device.cmdMf1EmuReadBlock(sector * 4, 4);
        if (raw.length < 64) return null;
        for (var b = 0; b < 4; b++) {
          blocks.add(
            raw
                .sublist(b * 16, b * 16 + 16)
                .map((x) => x.toRadixString(16).padLeft(2, '0'))
                .join(),
          );
        }
      }
    } catch (_) {
      return null;
    }
    return SaveCard(
      uid: uid,
      name: '',
      tag: TagType.mifare1K,
      sak: anti.sak,
      atqa: anti.atqaHex,
      ats: anti.atsHex,
      data: blocks,
    );
  }

  void setTab(int index) {
    tabIndex = index;
    notifyListeners();
  }

  /// 扫描并弹出选择
  Future<BluetoothDevice?> scanAndPick() async {
    await ensureBlePermissions();
    final found = await ble.scan();
    if (found.isEmpty) {
      throw Exception('未发现 Chameleon Ultra 设备，请确保设备已开机');
    }
    return found.first;
  }

  /// 请求 BLE 所需运行时权限（Android 12+ 蓝牙权限；低版本位置权限）
  Future<void> ensureBlePermissions() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final scan = await Permission.bluetoothScan.status;
    if (!scan.isGranted) {
      await Permission.bluetoothScan.request();
    }
    final connect = await Permission.bluetoothConnect.status;
    if (!connect.isGranted) {
      await Permission.bluetoothConnect.request();
    }
  }

  Future<void> connect(BluetoothDevice device) async {
    await ble.connect(device);
    // 连接成功后读取基础信息
    try {
      deviceInfo.version = await this.device.cmdGetAppVersion();
      deviceInfo.gitVersion = await this.device.cmdGetGitVersion();
      deviceInfo.chipId = await this.device.cmdGetDeviceChipId();
      // 连接即缓存芯片编号（对齐 CU verifyActivation → saveChipId）
      if (deviceInfo.chipId.isNotEmpty) {
        await storage.saveChipId(deviceInfo.chipId);
      }
      deviceInfo.bleAddress = await this.device.cmdBleGetAddress();
      deviceInfo.model = (await this.device.cmdGetDeviceModel()).toString();
      final battery = await this.device.cmdGetBatteryInfo();
      deviceInfo.batteryVoltage = '${battery.voltage}mV';
      deviceInfo.batteryLevel = battery.level;
    } catch (_) {}
    notifyListeners();
  }

  /// 云端功能统一取设备标识：设备实时值 → 设备缓存 → 手动填写缓存
  /// 对齐 CU：调用方手上的值优先，否则 getLastChipId() 走 SharedPreferences
  Future<String> resolveChipId() async {
    if (deviceInfo.chipId.isNotEmpty) return deviceInfo.chipId;
    final cached = await storage.getChipId();
    if (cached.isNotEmpty) return cached;
    return storage.getBackupChipId();
  }

  Future<void> disconnect() async {
    await ble.disconnect();
    notifyListeners();
  }

  Future<void> loadDeviceSettings() async {
    settings = await device.cmdGetDeviceSettings();
    try {
      settings.blePairing = await device.cmdBleGetPairingMode();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> loadEnabledSlots() async {
    enabledSlots = await device.cmdSlotGetIsEnable();
    slotNames = await device.cmdSlotGetFreqNames();
    slotTypes = await device.cmdSlotGetInfo();
    notifyListeners();
  }

  /// 读取当前卡槽的模拟设置（需先切到该槽）
  Future<void> loadActiveSlotEmuSettings() async {
    try {
      final active = await device.cmdSlotGetActive();
      currentSlot = active;
      await loadSlotEmuSettings(active);
    } catch (_) {}
  }

  void setAnimationMode(AnimationMode mode) {
    settings.animation = mode;
    notifyListeners();
  }

  void setBlePairingKey(String key) {
    settings.blePairingKey = key;
    notifyListeners();
  }

  void setBlePairing(bool v) {
    settings.blePairing = v;
    notifyListeners();
  }

  void setPressBtnA(ButtonAction a) {
    settings.pressBtnA = a;
    notifyListeners();
  }

  void setPressBtnB(ButtonAction a) {
    settings.pressBtnB = a;
    notifyListeners();
  }

  void setLongPressBtnA(ButtonAction a) {
    settings.longPressBtnA = a;
    notifyListeners();
  }

  void setLongPressBtnB(ButtonAction a) {
    settings.longPressBtnB = a;
    notifyListeners();
  }

  /// DFU 固件刷写（进入 DFU → 解析固件包 → 传输镜像）
  Future<void> dfuUpdateFromUrl(
    String url, {
    void Function(int offset, int size)? onProgress,
  }) async {
    final httpRes = await _httpGetBytes(url);
    final zip = DfuZip(httpRes);
    final image = zip.getAppImage();
    if (image == null) {
      throw Exception('无法从固件包解析 application 镜像');
    }
    await device.dfuUpdateImage(
      header: image.header,
      body: image.body,
      onProgress: onProgress,
    );
  }

  Future<Uint8List> _httpGetBytes(String url) async {
    final res = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw Exception('下载固件失败: HTTP ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  void setButtonModePairing(bool v) {
    settings.buttonModePairing = v;
    notifyListeners();
  }

  /// 数据变更后刷新 UI
  void refreshUi() => notifyListeners();

  Future<void> loadSlotEmuSettings(int slot) async {
    if (slot < enabledSlots.length && enabledSlots[slot].$1 /* hf */ ) {
      await device.cmdSlotSetActive(slot);
      final s = await device.cmdMf1GetEmuSettings();
      slotEmuSettings[slot] = s;
      notifyListeners();
    }
  }

  /// 更新指定槽的模拟配置（Mf1EmuSettings 不可变，复制新对象）
  void updateSlotEmu(
    int slot, {
    bool? detection,
    bool? gen1a,
    bool? gen2,
    bool? antiColl,
    int? write,
  }) {
    final cur = slotEmuSettings[slot];
    slotEmuSettings[slot] = Mf1EmuSettings(
      detection: detection ?? cur.detection,
      gen1a: gen1a ?? cur.gen1a,
      gen2: gen2 ?? cur.gen2,
      antiColl: antiColl ?? cur.antiColl,
      write: write ?? cur.write,
    );
    notifyListeners();
  }

  /// 切换到指定卡槽：设置 active 槽并读取该槽模拟设置与卡片标识
  Future<void> selectSlot(int slot) async {
    if (slot == currentSlot) return;
    try {
      await device.cmdSlotSetActive(slot);
      currentSlot = slot;
      if (enabledSlots[slot].$1 /* hf */ ) {
        final s = await device.cmdMf1GetEmuSettings();
        slotEmuSettings[slot] = s;
        final anti = await device.cmdHf14aGetAntiCollData();
        if (anti != null) {
          slotCardIds[slot] = (
            uid: anti.uidHex,
            sak: anti.sakHex,
            atqa: anti.atqaHex,
          );
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    ble.status.removeListener(_onBleStatus);
    device.dispose();
    ble.dispose();
    super.dispose();
  }
}
