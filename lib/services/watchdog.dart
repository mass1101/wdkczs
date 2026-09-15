import 'dart:io';

import 'package:flutter/services.dart';

import 'notification_service.dart';

/// 后台看门狗（对齐 CU helpers/watchdog.dart）
///
/// Dart 端每 15 秒向原生 WatchdogService 发一次心跳；原生侧每 15 秒检查
/// 上次心跳，超过 60 秒未收到即认为后台服务失联，回调 onTimeout，
/// 由此处弹出告警通知。用于在系统杀死围栏/BLE 服务时提醒用户。
class Watchdog {
  static const _channel = MethodChannel('watchdog_channel');
  static bool _started = false;

  static Future<void> start() async {
    if (_started) return;
    if (!Platform.isAndroid) return;
    _started = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onTimeout') {
        await NotificationService.instance.showWatchdogWarning();
      }
    });

    try {
      await _channel.invokeMethod('start');
    } catch (_) {
      _started = false;
      return;
    }

    await NotificationService.instance.showWatchdogStarted();
    _startHeartbeat();
  }

  static Future<void> stop() async {
    if (!_started) return;
    _started = false;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  static void _startHeartbeat() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 15));
      if (!_started) return false;
      try {
        await _channel.invokeMethod('heartbeat');
      } catch (_) {
        if (!_started) return false;
      }
      return _started;
    });
  }

  static Future<bool> isRunning() async {
    try {
      final result = await _channel.invokeMethod<bool>('isRunning');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
