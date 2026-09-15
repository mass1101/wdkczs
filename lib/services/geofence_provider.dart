import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'card_library.dart';
import 'geofence.dart';

/// 电子围栏 Provider（对齐 CU geofence_provider.dart，nfcapp 原生化：
/// 复用 SaveCard/CardLibraryStorage/uploadCardToSlot，CLI 走注入的设备回调）
///
/// 位置唯一来源是原生 geofence_native_channel：原生 GeofenceService 先把
/// WGS84 转 GCJ02 再做围栏匹配，回调的坐标与命中/离开事件都是 GCJ-02。
/// 仅在「总开关开 + 设备已连接」时运行——围栏动作要写卡槽，必须连设备。
///
/// 地图蓝点与围栏判定共用此处的 lastPosition（原生通道位置，已转 GCJ02）。
class GeofenceProvider extends ChangeNotifier {
  List<Geofence> _fences = [];
  bool _userEnabled = false;
  bool _enabled = false;
  int _checkInterval = 30;
  bool _monitoring = false;
  bool _overlayActive = false;
  bool _connected = false;

  final List<String> _logs = <String>[];

  List<String> get logs => List.unmodifiable(_logs);

  /// 围栏进出事件（命中/离开），供诊断栏与事件列表展示
  List<String> get eventLogs => _logs
      .where((l) => l.contains('命中围栏') || l.contains('离开围栏'))
      .toList();
  List<Geofence> get fences => List.unmodifiable(_fences);
  bool get enabled => _enabled;
  bool get userEnabled => _userEnabled;
  int get checkInterval => _checkInterval;
  bool get monitoring => _monitoring;
  bool get overlayActive => _overlayActive;
  bool get connected => _connected;

  DateTime? get lastPositionTime => _lastPositionTime;
  LatLng? get lastPosition => _lastPosition;
  String? get lastMatchedFenceName => _lastMatchedFenceName;
  String? get uploadStatus => _uploadStatus;
  String? get rollingCodeStatus => _rollingCodeStatus;

  DateTime? _lastPositionTime;
  LatLng? _lastPosition;
  String? _lastMatchedFenceName;
  String? _uploadStatus;
  String? _rollingCodeStatus;
  int? _lastActivatedSlot;

  SharedPreferences? _prefs;

  // 注入的设备/卡库回调
  bool Function(int slot)? _activateSlot; // 返回值=是否成功切换
  bool Function()? _isConnected;
  bool Function()? _isActivated;
  Future<void> Function(SaveCard card, int slot)? _uploadCard;
  Future<SaveCard?> Function(int slot)? _readHfSlot; // 读 HF 槽 dump

  void _log(String message) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    _logs.add('[$time] $message');
    if (_logs.length > 500) _logs.removeAt(0);
    debugPrint('GeofenceProvider: $message');
  }

  void addLog(String message) {
    _log(message);
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  void setConnected(bool v) {
    _connected = v;
  }

  void setOverlayActive(bool v) {
    _overlayActive = v;
    notifyListeners();
  }

  static const MethodChannel _nativeChannel =
      MethodChannel('geofence_native_channel');
  bool _channelReady = false;

  void _setupChannel() {
    if (_channelReady) return;
    _channelReady = true;
    _nativeChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPosition':
          final args = Map<dynamic, dynamic>.from(call.arguments as Map);
          final lat = (args['latitude'] as num).toDouble();
          final lng = (args['longitude'] as num).toDouble();
          _handleNativePosition(lat, lng);
          break;
        case 'onFenceEvent':
          final args = Map<dynamic, dynamic>.from(call.arguments as Map);
          final event = args['event'] as String?;
          final fenceId = args['fenceId'] as String?;
          if (event != null && fenceId != null) {
            _handleFenceEvent(event, fenceId);
          }
          break;
      }
    });
  }

  void _pushOverlayData() {
    if (!_overlayActive) return;
    final dt = _lastPositionTime;
    final timeStr = dt != null
        ? '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}'
        : '';
    final pos = _lastPosition;
    final data = jsonEncode({
      'connected': _connected,
      'monitoring': _monitoring,
      'matchedFence': _lastMatchedFenceName ?? '',
      'lastUpdate': timeStr,
      'lat': pos?.latitude.toStringAsFixed(6) ?? '',
      'lng': pos?.longitude.toStringAsFixed(6) ?? '',
      'uploadStatus': _uploadStatus ?? '',
      'rollingCodeStatus': _rollingCodeStatus ?? '',
    });
    try {
      FlutterOverlayWindow.shareData(data);
    } catch (_) {}
  }

  /// 公开方法：推送围栏状态数据到悬浮窗（供 home_page 定时器调用）
  void pushOverlayData() => _pushOverlayData();

  void _handleNativePosition(double lat, double lng) =>
      _updatePosition(LatLng(lat, lng));

  /// 统一的位置更新入口（入参必须已是 GCJ-02，来自原生围栏服务）
  void _updatePosition(LatLng pos) {
    if (_lastPosition == pos) return;
    _lastPosition = pos;
    _lastPositionTime = DateTime.now();
    notifyListeners();
    _pushOverlayData();
  }

  void _handleFenceEvent(String event, String fenceId) {
    final match = _fences.where((f) => f.id == fenceId).toList();
    if (event == 'enter') {
      if (match.isEmpty) return;
      _handleMatchedFence(match.first);
    } else if (event == 'exit') {
      _handleMatchedFence(null);
    }
    notifyListeners();
    _pushOverlayData();
  }

  void setHandlers({
    required bool Function(int slot) activateSlot,
    required bool Function() isConnected,
    bool Function()? isActivated,
    required Future<void> Function(SaveCard card, int slot) uploadCard,
    required Future<SaveCard?> Function(int slot) readHfSlot,
  }) {
    _activateSlot = activateSlot;
    _isConnected = isConnected;
    _isActivated = isActivated;
    _uploadCard = uploadCard;
    _readHfSlot = readHfSlot;
  }

  Future<void> load(SharedPreferences prefs) async {
    _prefs = prefs;
    _userEnabled = prefs.getBool('geofence_user_enabled') ?? false;
    _enabled = prefs.getBool('geofence_enabled') ?? false;
    _checkInterval = prefs.getInt('geofence_check_interval') ?? 30;
    final jsonStr = prefs.getString('geofence_list');
    if (jsonStr != null) {
      try {
        final list = jsonDecode(jsonStr) as List;
        _fences = list
            .map((e) => Geofence.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    _syncEnabledState();
    if (_enabled) _startMonitoring();
  }

  Future<void> _save() async {
    if (_prefs == null) return;
    await _prefs!.setString(
        'geofence_list', jsonEncode(_fences.map((f) => f.toJson()).toList()));
    await _prefs!.setBool('geofence_enabled', _enabled);
    await _prefs!.setBool('geofence_user_enabled', _userEnabled);
    await _prefs!.setInt('geofence_check_interval', _checkInterval);
    if (_monitoring) {
      try {
        _nativeChannel.invokeMethod('reload');
      } catch (_) {}
    }
  }

  void addFence(Geofence fence) {
    _fences.add(fence);
    _save();
    notifyListeners();
  }

  void updateFence(Geofence fence) {
    final i = _fences.indexWhere((f) => f.id == fence.id);
    if (i != -1) {
      _fences[i] = fence;
      _save();
      notifyListeners();
    }
  }

  void deleteFence(String id) {
    _fences.removeWhere((f) => f.id == id);
    _save();
    notifyListeners();
  }

  void toggleFence(String id, bool enabled) {
    final i = _fences.indexWhere((f) => f.id == id);
    if (i != -1) {
      _fences[i].enabled = enabled;
      _save();
      notifyListeners();
    }
  }

  void _syncEnabledState() {
    final connected = _isConnected?.call() ?? false;
    final activated = _isActivated?.call() ?? false;
    _enabled = _userEnabled && connected && activated;
  }

  /// 设备连接状态变化后调用：连接态参与围栏总开关的实际生效判定
  void refreshEnabledState() {
    _syncEnabledState();
    if (_enabled) {
      _startMonitoring();
    } else {
      _stopMonitoring();
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    _userEnabled = v;
    _syncEnabledState();
    await _save();
    if (_enabled) {
      _startMonitoring();
    } else {
      _stopMonitoring();
    }
    notifyListeners();
  }

  Future<void> setCheckInterval(int seconds) async {
    if (seconds < 5) seconds = 5;
    _checkInterval = seconds;
    await _save();
    if (_monitoring) {
      await _stopMonitoring();
      await _startMonitoring();
    }
    notifyListeners();
  }

  Future<void> _startMonitoring() async {
    if (_monitoring) return;
    _monitoring = true;
    _setupChannel();
    try {
      _nativeChannel.invokeMethod('start');
    } catch (_) {}
  }

  Future<void> _stopMonitoring() async {
    _monitoring = false;
    try {
      _nativeChannel.invokeMethod('stop');
    } catch (_) {}
    _lastActivatedSlot = null;
    _stopRollingCodePolling();
  }

  void _handleMatchedFence(Geofence? match) {
    final prevId = _lastMatchedFenceNameFromId;
    if (match != null) {
      final entering = prevId != match.id;
      if (entering) _log('命中围栏 ${match.name}');
      _lastMatchedFenceName = match.name;
      if (_activateSlot != null && match.slotNumber != _lastActivatedSlot) {
        final switched = _activateSlot!(match.slotNumber);
        _log('激活卡槽 ${match.slotNumber} switched=$switched');
        if (switched) _lastActivatedSlot = match.slotNumber;
      }
      if (match.cardLibraryMode && entering) {
        _uploadCardsToSlots(match);
      }
      if (entering && match.rollingCode && match.icCardId != null) {
        _startRollingCodePolling(match);
      } else if (entering && !match.rollingCode) {
        _stopRollingCodePolling();
      }
      _lastMatchedId = match.id;
    } else {
      if (prevId != null) {
        final prev = _fences.where((f) => f.id == prevId).toList();
        if (prev.isNotEmpty) _log('离开围栏 ${prev.first.name}');
      }
      _lastMatchedFenceName = null;
      _lastMatchedId = null;
      _stopRollingCodePolling();
      _uploadStatus = null;
      _rollingCodeStatus = null;
    }
    _pushOverlayData();
  }

  String? _lastMatchedId;
  String? get _lastMatchedFenceNameFromId => _lastMatchedId;

  // ========== 卡库自动上传 ==========
  bool _uploading = false;

  Future<void> _uploadCardsToSlots(Geofence match) async {
    if (_uploading) return;
    _uploading = true;
    await Future.delayed(const Duration(seconds: 1));
    if (match.icCardId == null && match.idCardId == null) {
      _uploadStatus = '未配置卡片';
      _log('围栏 ${match.name} 未配置卡片');
      notifyListeners();
      _pushOverlayData();
      _uploading = false;
      return;
    }
    _uploadStatus = '正在上传卡片...';
    _log('正在上传卡片...');
    notifyListeners();
    _pushOverlayData();

    Future<void> uploadOne(String? cardId) async {
      if (cardId == null) return;
      for (var attempt = 0; attempt < 4; attempt++) {
        if (attempt > 0) {
          _uploadStatus = '卡片上传失败，3秒后重试...';
          _log('卡片上传失败，3秒后重试...');
          notifyListeners();
          _pushOverlayData();
          await Future.delayed(const Duration(seconds: 3));
        }
        final result = await _uploadLibraryCardToSlot(cardId, match.slotNumber);
        if (result == 0 || result == 2) {
          _uploadStatus = '卡片上传成功';
          _log('卡片上传成功');
          notifyListeners();
          _pushOverlayData();
          return;
        }
      }
      _uploadStatus = '卡片上传失败，已放弃';
      _log('卡片上传失败，已放弃');
      notifyListeners();
      _pushOverlayData();
    }

    await uploadOne(match.icCardId);
    await uploadOne(match.idCardId);

    _uploading = false;
    notifyListeners();
  }

  Future<int> _uploadLibraryCardToSlot(String cardId, int slot) async {
    final card = await CardLibraryStorage().getCardById(cardId);
    if (card == null) {
      _log('卡片 $cardId 不在卡库中，跳过上传');
      return 2;
    }
    try {
      _log('开始上传卡片 $cardId 到卡槽 $slot');
      await _uploadCard!.call(card, slot - 1);
      _log('卡片 $cardId 上传成功');
      return 0;
    } catch (e) {
      _log('卡片 $cardId 上传失败: $e');
      return 1;
    }
  }

  // ========== 滚动码轮询 ==========
  static const _pollInterval = Duration(seconds: 15);
  Timer? _rollingCodeTimer;
  String? _rollingCardId;
  int? _rollingSlot;
  bool _rollingUploading = false;

  void _startRollingCodePolling(Geofence fence) {
    _stopRollingCodePolling();
    if (!fence.rollingCode || fence.icCardId == null) return;
    _rollingCardId = fence.icCardId;
    _rollingSlot = fence.slotNumber;
    _rollingCodeTimer = Timer.periodic(
        _pollInterval, (_) => _pollRollingCode());
  }

  void _stopRollingCodePolling() {
    _rollingCodeTimer?.cancel();
    _rollingCodeTimer = null;
    _rollingCardId = null;
    _rollingSlot = null;
    _rollingUploading = false;
  }

  Future<void> _pollRollingCode() async {
    final cardId = _rollingCardId;
    final slot = _rollingSlot;
    if (cardId == null || slot == null || _rollingUploading) return;
    if (_isConnected?.call() != true) return;
    _rollingUploading = true;
    try {
      final card = await CardLibraryStorage().getCardById(cardId);
      if (card == null || card.data.isEmpty) return;
      if (isLf(card.tag)) return; // 仅 HF 可读回

      SaveCard? dump;
      try {
        dump = await _readHfSlot?.call(slot - 1);
      } catch (_) {
        return;
      }
      if (dump == null || dump.data.isEmpty || dump.uid != card.uid) return;
      if (_sameContent(card, dump)) return;

      dump.id = card.id;
      dump.name = card.name;
      dump.folderId = card.folderId;
      await CardLibraryStorage().upsertCard(dump);
      _log('滚动码已更新');
      _rollingCodeStatus = '滚动码已更新';
      notifyListeners();
      _pushOverlayData();
    } finally {
      _rollingUploading = false;
    }
  }

  bool _sameContent(SaveCard a, SaveCard b) {
    if (a.tag != b.tag || a.uid != b.uid) return false;
    if (a.data.length != b.data.length) return false;
    for (var i = 0; i < a.data.length; i++) {
      if (a.data[i] != b.data[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _stopMonitoring();
    super.dispose();
  }
}