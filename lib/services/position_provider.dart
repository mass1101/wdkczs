import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../helpers/coordinate_converter.dart';

/// 独立定位源：只给地图/坐标显示提供位置。
///
/// 不检查围栏总开关、不检查设备连接、不参与围栏判定。围栏页一打开就可用，
/// 与电子围栏功能完全解耦。
///
/// 坐标系不变量：geolocator 回调的是原始 WGS84，必须在这里转成 GCJ-02 再发布，
/// 否则蓝点会落在高德瓦片的错误位置并周期性回跳数百米。围栏判定只走原生
/// GeofenceService（它也先转 GCJ-02 再匹配），两条链路互不写对方的状态。
///
/// 可靠性（历史上「定位一直不动且没有任何提示」的三个来源）：
/// 1. Android 默认走 Google FusedLocationProvider，国产无 GMS 设备静默不回调，
///    故强制 `forceLocationManager: true` 走系统 LocationManager；
/// 2. `distanceFilter` 设 0 + `intervalDuration` 2s，避免静止时流完全不回调；
/// 3. 错误不再被吞掉，统一暴露到 [lastError]；另外定位服务总闸关闭时
///    直接判失败，并用定时轮询 getCurrentPosition 兜底长时间无回调的流。
class PositionProvider extends ChangeNotifier {
  static const _pollInterval = Duration(seconds: 5);
  static const _staleAfter = Duration(seconds: 10);

  StreamSubscription<Position>? _sub;
  Timer? _pollTimer;
  int _refs = 0;
  bool _polling = false;

  LatLng? _lastPosition;
  DateTime? _lastPositionTime;
  bool _permissionGranted = false;
  String? _lastError;

  /// 最近的 GCJ-02 位置
  LatLng? get lastPosition => _lastPosition;

  /// 最近一次位置的时间
  DateTime? get lastPositionTime => _lastPositionTime;

  /// 位置流是否在跑
  bool get running => _sub != null;

  /// 定位权限是否已授予
  bool get permissionGranted => _permissionGranted;

  /// 最近一次失败原因（权限/定位服务/流错误），成功拿到位置即清空
  String? get lastError => _lastError;

  /// 开启位置流（引用计数）。返回是否已成功建立定位。
  ///
  /// 多次 start 需等对应次数的 stop 才会真正停止，避免页面 A 退出时
  /// 取消掉页面 B 仍在使用的订阅。
  Future<bool> start() async {
    _refs++;
    if (_sub != null) return _permissionGranted;

    final granted = await _ensurePermission();
    _permissionGranted = granted;
    if (!granted) {
      _refs--;
      _fail('未获得定位权限');
      return false;
    }
    // 系统定位总闸关闭时，位置流与 getCurrentPosition 都不会返回数据
    if (!await Geolocator.isLocationServiceEnabled()) {
      _refs--;
      _fail('系统定位服务未开启');
      return false;
    }
    // 权限确认（含系统弹窗）期间页面可能已退出，此时不再建订阅，
    // 否则残留订阅既不会被取消，也会在无人监听时持续回调
    if (_refs == 0) return false;

    _sub = Geolocator.getPositionStream(
      locationSettings: _locationSettings,
    ).listen(
      _onStream,
      onError: (Object e) => _fail(_describe(e)),
      onDone: () => _sub = null,
    );
    _pollTimer ??= Timer.periodic(_pollInterval, (_) => _poll());
    return true;
  }

  /// 关闭位置流，与 [start] 配对。
  void stop() {
    if (_refs == 0) return;
    _refs--;
    if (_refs > 0) return;
    _sub?.cancel();
    _sub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 写入一次 GCJ-02 位置（同值不重复通知）
  void update(LatLng pos) {
    _lastError = null;
    if (_lastPosition == pos) return;
    _lastPosition = pos;
    _lastPositionTime = DateTime.now();
    notifyListeners();
  }

  /// 主动取一次当前位置（供「定位我」在流尚无数据时兜底），返回 GCJ-02 坐标
  Future<LatLng?> refresh() async {
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: _locationSettings,
      );
      update(CoordinateConverter.wgs84ToGcj02(LatLng(p.latitude, p.longitude)));
      return _lastPosition;
    } catch (e) {
      _fail(_describe(e));
      return null;
    }
  }

  LocationSettings get _locationSettings {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 2),
        forceLocationManager: true,
        timeLimit: const Duration(seconds: 10),
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );
  }

  void _onStream(Position p) {
    update(CoordinateConverter.wgs84ToGcj02(LatLng(p.latitude, p.longitude)));
  }

  /// 流长时间无回调时补一次 getCurrentPosition
  Future<void> _poll() async {
    if (_sub == null || _polling) return;
    final last = _lastPositionTime;
    if (last != null && DateTime.now().difference(last) < _staleAfter) return;
    _polling = true;
    await refresh();
    _polling = false;
  }

  Future<bool> _ensurePermission() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission != LocationPermission.denied &&
          permission != LocationPermission.deniedForever;
    } catch (_) {
      return false;
    }
  }

  String _describe(Object e) {
    if (e is LocationServiceDisabledException) return '系统定位服务未开启';
    if (e is PermissionDeniedException) return '未获得定位权限';
    if (e is TimeoutException) return '定位超时：请在开阔处重试';
    return '定位失败：$e';
  }

  void _fail(String message) {
    _lastError = message;
    if (hasListeners) notifyListeners();
  }

  @override
  void dispose() {
    _refs = 0;
    _sub?.cancel();
    _sub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }
}
