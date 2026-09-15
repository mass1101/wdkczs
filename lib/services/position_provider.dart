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
class PositionProvider extends ChangeNotifier {
  StreamSubscription<Position>? _sub;
  int _refs = 0;

  LatLng? _lastPosition;
  DateTime? _lastPositionTime;
  bool _permissionGranted = false;

  /// 最近的 GCJ-02 位置
  LatLng? get lastPosition => _lastPosition;

  /// 最近一次位置的时间
  DateTime? get lastPositionTime => _lastPositionTime;

  /// 位置流是否在跑
  bool get running => _sub != null;

  /// 定位权限是否已授予
  bool get permissionGranted => _permissionGranted;

  /// 开启位置流（引用计数）。返回是否已获得定位权限。
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
      return false;
    }
    // 权限确认（含系统弹窗）期间页面可能已退出，此时不再建订阅，
    // 否则残留订阅既不会被取消，也会在无人监听时持续回调
    if (_refs == 0) return false;
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen(
      (p) => update(
        CoordinateConverter.wgs84ToGcj02(LatLng(p.latitude, p.longitude)),
      ),
      onError: (Object _) {},
    );
    return true;
  }

  /// 关闭位置流，与 [start] 配对。
  void stop() {
    if (_refs == 0) return;
    _refs--;
    if (_refs > 0) return;
    _sub?.cancel();
    _sub = null;
  }

  /// 写入一次 GCJ-02 位置（同值不重复通知）
  void update(LatLng pos) {
    if (_lastPosition == pos) return;
    _lastPosition = pos;
    _lastPositionTime = DateTime.now();
    notifyListeners();
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

  @override
  void dispose() {
    _refs = 0;
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
