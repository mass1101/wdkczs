import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/ble_service.dart';
import '../models/models.dart';
import '../services/card_library.dart';
import '../helpers/activation.dart';
import '../services/device_service.dart';
import '../services/dfu_zip.dart';
import '../services/storage_service.dart';

/// 全局应用状态（设备连接、卡数据、设置）
class AppController extends ChangeNotifier {
  final BleService ble = BleService();
  late final DeviceService device;
  late final StorageService storage;

  AppController() {
    device = DeviceService(ble);
    storage = StorageService();
    device.init();
    ble.status.addListener(_onBleStatus);
  }

  bool get connected => ble.isConnected;

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

  int tabIndex = 0;
  int currentSlot = 0;
  bool _processing = false;

  // 激活状态（由设备固件实时读取）
  bool _isActivated = false;
  int _remainingBoots = 0;
  bool get isActivated => deviceInfo.chipId.isNotEmpty && _isActivated;
  int get remainingBoots => isActivated ? _remainingBoots : 0;

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
      // 连接即缓存芯片编号，供云端备份取设备标识
      if (deviceInfo.chipId.isNotEmpty) {
        await storage.saveChipId(deviceInfo.chipId);
      }
      deviceInfo.bleAddress = await this.device.cmdBleGetAddress();
      deviceInfo.model = (await this.device.cmdGetDeviceModel()).toString();
      final battery = await this.device.cmdGetBatteryInfo();
      deviceInfo.batteryVoltage = '${battery.voltage}mV';
      deviceInfo.batteryLevel = battery.level;
    } catch (_) {}
    if (deviceInfo.chipId.isNotEmpty) {
      verifyActivation(deviceInfo.chipId);
    }
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

  /// 验证激活状态
  Future<void> verifyActivation(String chipId) async {
    if (chipId.isEmpty) return;
    await storage.saveChipId(chipId);
    await _syncActivationFromFirmware();
    notifyListeners();
  }

  /// 从设备固件同步激活状态
  Future<void> _syncActivationFromFirmware() async {
    if (!connected) return;
    try {
      final (activated, remaining) = await device.cmdGetActivation();
      _isActivated = activated;
      _remainingBoots = remaining;
    } catch (_) {}
  }

  /// 设置激活状态
  Future<void> setActivated(bool value, {String? chipId, int? remainingBoots}) async {
    _isActivated = value;
    _remainingBoots = remainingBoots ?? 0;
    notifyListeners();
  }

  /// 仅解析本地固件包（不刷写），返回 (header, body)
  ({Uint8List header, Uint8List body}) dfuParseFile(Uint8List zipBytes) {
    final zip = DfuZip(zipBytes);
    final image = zip.getAppImage();
    if (image == null) {
      throw Exception('无法从固件包解析 application 镜像');
    }
    return (header: image.header, body: image.body);
  }

  @override
  void dispose() {
    ble.status.removeListener(_onBleStatus);
    device.dispose();
    ble.dispose();
    super.dispose();
  }
}

