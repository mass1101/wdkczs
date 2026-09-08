import 'package:flutter/foundation.dart';

/// 日志服务：收集调试日志，供设置页面查看
class LogService {
  static final LogService instance = LogService._();
  LogService._();

  final List<String> _logs = [];
  static const int _maxLogs = 200;

  /// 添加日志
  void log(String msg) {
    final timestamp = DateTime.now().toIso8601String();
    final entry = '[$timestamp] $msg';
    _logs.add(entry);
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
    debugPrint(entry);
  }

  /// 获取所有日志
  List<String> get logs => List.from(_logs);

  /// 清除日志
  void clear() {
    _logs.clear();
  }
}
