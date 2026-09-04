import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/ble_service.dart';
import '../models/models.dart';
import '../services/cloud_service.dart';
import '../services/device_service.dart';
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
    device.init();
    ble.status.addListener(_onBleStatus);
  }

  bool get connected => ble.isConnected;

  // IC 卡状态
  CardState card = CardState();

  // ID 卡状态
  IdCardState idCard = IdCardState();

  // 设置页状态
  DeviceSettings settings = DeviceSettings();
  DeviceInfo deviceInfo = DeviceInfo();
  List<(bool, bool)> enabledSlots = List.generate(8, (_) => (false, false));
  List<(String?, String?)> slotNames = List.generate(8, (_) => (null, null));
  List<(int, int)> slotTypes = List.generate(8, (_) => (0, 4));
  List<Mf1EmuSettings> slotEmuSettings =
      List.generate(8, (_) => Mf1EmuSettings(
            detection: false,
            gen1a: false,
            gen2: false,
            antiColl: true,
            write: 0,
          ));

  int tabIndex = 0;
  int currentSlot = 0;
  bool _processing = false;

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
    notifyListeners();
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
      deviceInfo.bleAddress = await this.device.cmdBleGetAddress();
      deviceInfo.model = (await this.device.cmdGetDeviceModel()).toString();
      final battery = await this.device.cmdGetBatteryInfo();
      deviceInfo.batteryVoltage = '${battery.voltage}mV';
      deviceInfo.batteryLevel = battery.level;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> disconnect() async {
    await ble.disconnect();
    notifyListeners();
  }

  Future<void> loadDeviceSettings() async {
    settings = await device.cmdGetDeviceSettings();
    notifyListeners();
  }

  Future<void> loadEnabledSlots() async {
    enabledSlots = await device.cmdSlotGetIsEnable();
    slotNames = await device.cmdSlotGetFreqNames();
    slotTypes = await device.cmdSlotGetInfo();
    notifyListeners();
  }

  void setBlePairing(bool v) {
    settings.blePairing = v;
    notifyListeners();
  }

  void setButtonModePairing(bool v) {
    settings.buttonModePairing = v;
    notifyListeners();
  }

  Future<void> loadSlotEmuSettings(int slot) async {
    if (slot < enabledSlots.length &&
        enabledSlots[slot].$1 /* hf */) {
      await device.cmdSlotSetActive(slot);
      final s = await device.cmdMf1GetEmuSettings();
      slotEmuSettings[slot] = s;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    ble.status.removeListener(_onBleStatus);
    device.dispose();
    ble.dispose();
    super.dispose();
  }
}
