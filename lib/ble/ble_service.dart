import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// 连接状态
enum BleState { disconnected, connecting, connected }

/// BLE 连接事件
class BleStatus {
  final BleState state;
  final String? error;
  BleStatus(this.state, [this.error]);
}

/// BLE 服务：扫描/连接/收发（适配 ChameleonUltra 与 CU- 两类设备）
///
/// 契约（逆向确认）：
///  - ChameleonUltra: 服务 6E400001，notify=6E400003，write=6E400002（writeNoResponse，20B 分块）
///  - CU-: 服务 fe59，特征 8ec90001（write 类型），DFU 写入 8ec90002
class BleService {
  static const String _mt = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String _ot = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String _rt = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String _ft = '8EC90002-F315-4F60-9FB8-838830DAEA50';
  static const String _cuChar = '8EC90001-F315-4F60-9FB8-838830DAEA50';

  static const int _chunk = 20;

  final ValueNotifier<BleStatus> status =
      ValueNotifier(BleStatus(BleState.disconnected));

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  BluetoothCharacteristic? _dfuWriteChar;
  bool _isCu = false;

  final _rxController = StreamController<Uint8List>.broadcast();
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  bool _autoReconnect = false;

  /// 是否 ChameleonUltra（非 CU- 系列）
  bool get isChameleonUltra => !_isCu;

  /// 接收数据流（设备 notify 回调）
  Stream<Uint8List> get rx => _rxController.stream;

  bool get isConnected =>
      _device != null && _device!.isConnected && _writeChar != null;

  BluetoothDevice? get device => _device;

  /// 扫描设备（ChameleonUltra* / CU-* 前缀或带 fe59 广播）
  Future<List<BluetoothDevice>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    final devices = <BluetoothDevice>{};
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName;
        final services = r.advertisementData.serviceUuids;
        final isCu = (name.isNotEmpty && name.startsWith('CU-')) ||
            services.any((u) => u.toString().toLowerCase().startsWith('fe59'));
        final isUltra = name.isNotEmpty && name.contains('ChameleonUltra');
        if (isCu || isUltra) {
          devices.add(r.device);
        }
      }
    });
    await FlutterBluePlus.startScan(timeout: timeout);
    // 等待扫描结束（startScan 带 timeout 会自动停止）
    await Future.delayed(timeout + const Duration(milliseconds: 300));
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    await sub.cancel();
    return devices.toList();
  }

  /// 连接指定设备
  Future<void> connect(BluetoothDevice device) async {
    if (isConnected) await disconnect();
    _device = device;
    status.value = BleStatus(BleState.connecting);
    try {
      await _establish();
      _autoReconnect = true;
    } catch (_) {
      status.value = BleStatus(BleState.disconnected);
      rethrow;
    }
  }

  /// 建立连接：连接重试 + 服务/特征发现重试（对齐小程序 adapter 层）
  Future<void> _establish() async {
    final device = _device!;

    // 断连监听：订阅一次，断开时广播状态并自动重连（对齐小程序 need_reconnect）
    _connSub ??= device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _rxController.add(Uint8List(0));
        status.value = BleStatus(BleState.disconnected);
        if (_autoReconnect && _device != null) {
          _reconnect();
        }
      }
    });

    // 连接重试 5 次，每次 2s（对齐小程序 createBLEConnection 5×2000ms）
    Object? lastErr;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await device.connect(
            license: License.nonprofit, timeout: const Duration(seconds: 2));
        lastErr = null;
        break;
      } catch (e) {
        lastErr = e;
        try {
          await device.disconnect();
        } catch (_) {}
      }
    }
    if (lastErr != null) {
      throw Exception('连接失败（已重试 5 次）: $lastErr');
    }

    // 服务/特征发现重试 5 次，间隔 400ms（对齐小程序 getBLEDeviceServices/Characteristics）
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await _discoverChars(device);
        break;
      } catch (e) {
        if (attempt == 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }

    await _notifyChar!.setNotifyValue(true);
    await _notifySub?.cancel();
    _notifySub = _notifyChar!.lastValueStream.listen((value) {
      if (value.isNotEmpty) {
        _rxController.add(Uint8List.fromList(value));
      }
    });

    status.value = BleStatus(BleState.connected);
  }

  /// 发现服务并按设备分型确定特征（ChameleonUltra: NUS / CU-: fe59）
  Future<void> _discoverChars(BluetoothDevice device) async {
    final services = await device.discoverServices();
    final name = device.platformName;

    BluetoothService? nus;
    if (name.contains('ChameleonUltra')) {
      nus = services.firstWhere(
        (s) => s.uuid.toString().toUpperCase() == _mt,
        orElse: () => throw Exception('未找到 NUS 服务'),
      );
      _notifyChar = nus.characteristics.firstWhere(
        (c) => c.uuid.toString().toUpperCase() == _ot,
      );
      _writeChar = nus.characteristics.firstWhere(
        (c) => c.uuid.toString().toUpperCase() == _rt,
      );
      _isCu = false;
    } else {
      // CU- 系列
      _isCu = true;
      BluetoothService? cu;
      for (final s in services) {
        final su = s.uuid.toString().toLowerCase();
        if (su.startsWith('fe59') || su.startsWith('0000fe59')) {
          cu = s;
          break;
        }
      }
      if (cu == null) {
        for (final s in services) {
          final has = s.characteristics.any(
              (c) => c.uuid.toString().toUpperCase() == _cuChar);
          if (has) {
            cu = s;
            break;
          }
        }
      }
      if (cu == null) throw Exception('未找到 CU- 服务');
      _notifyChar = cu.characteristics.firstWhere(
        (c) => c.uuid.toString().toUpperCase() == _cuChar,
      );
      _writeChar = _notifyChar;
      BluetoothCharacteristic? dfu;
      try {
        dfu = cu.characteristics.firstWhere(
          (c) => c.uuid.toString().toUpperCase() == _ft,
        );
      } catch (_) {}
      _dfuWriteChar = dfu;
    }
  }

  /// 断连自动重连（对齐小程序 need_reconnect/btnAdapterCon）：最多尝试 5 次
  Future<void> _reconnect() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      if (!_autoReconnect || _device == null) return;
      try {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!_autoReconnect) return;
        status.value = BleStatus(BleState.connecting);
        await _establish();
        return;
      } catch (_) {}
    }
    // 重连失败：停止自动重连，等待用户手动连接
    _autoReconnect = false;
    status.value = BleStatus(BleState.disconnected);
  }

  /// 单块写入，失败等 50ms 重试一次（对齐小程序 write fail 回调）
  Future<void> _writeWithRetry(BluetoothCharacteristic char, List<int> chunk,
      {required bool withoutResponse}) async {
    try {
      await char.write(chunk, withoutResponse: withoutResponse);
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      try {
        await char.write(chunk, withoutResponse: withoutResponse);
      } catch (e) {
        // BLE 断连原始 PlatformException 透传不友好，转译提示（自动重连已在后台进行）
        final msg = e.toString().toLowerCase();
        if (msg.contains('disconnected')) {
          throw Exception('设备已断开连接，正在自动重连，请稍后重试');
        }
        rethrow;
      }
    }
  }

  /// 发送数据（自动按 20B 分块，块间小间隔避免缓冲区溢出）
  Future<void> send(Uint8List data) async {
    if (_writeChar == null) {
      throw Exception('未连接');
    }
    for (var i = 0; i < data.length; i += _chunk) {
      final end = (i + _chunk < data.length) ? i + _chunk : data.length;
      final chunk = data.sublist(i, end);
      await _writeWithRetry(_writeChar!, chunk, withoutResponse: !_isCu);
      if (end < data.length) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  /// DFU 数据写入（CU- 系列）
  Future<void> dfuWrite(Uint8List data) async {
    if (_dfuWriteChar == null) {
      throw Exception('当前设备不支持 DFU 写入');
    }
    for (var i = 0; i < data.length; i += _chunk) {
      final end = (i + _chunk < data.length) ? i + _chunk : data.length;
      final chunk = data.sublist(i, end);
      await _writeWithRetry(_dfuWriteChar!, chunk, withoutResponse: true);
    }
  }

  Future<void> disconnect() async {
    // 主动断开：取消自动重连，避免断连事件触发 _reconnect
    _autoReconnect = false;
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _writeChar = null;
    _notifyChar = null;
    _dfuWriteChar = null;
    status.value = BleStatus(BleState.disconnected);
  }

  void dispose() {
    disconnect();
    _rxController.close();
    status.dispose();
  }
}
