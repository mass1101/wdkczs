import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// 位置服务（对齐 CU location_service.dart，geolocator 封装）
class LocationService {
  StreamSubscription<Position>? _subscription;
  Timer? _timer;
  bool _running = false;
  void Function(double latitude, double longitude)? _onPosition;

  bool get running => _running;

  Future<bool> requestPermission() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      return (await Geolocator.requestPermission()) !=
          LocationPermission.denied;
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  Future<void> start({
    required int intervalSeconds,
    required void Function(double latitude, double longitude) onPosition,
  }) async {
    if (_running) return;
    _onPosition = onPosition;
    _running = true;

    final granted = await requestPermission();
    if (!granted) return;

    final settings = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 0,
        intervalDuration: Duration(seconds: intervalSeconds),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: '电子围栏',
          notificationText: '正在后台获取位置信息',
          enableWakeLock: true,
        ),
      ),
    );
    _subscription = settings.listen(
      (position) =>
          _onPosition?.call(position.latitude, position.longitude),
      onError: (Object error) {
        // 位置流错误
      },
    );

    _timer = Timer.periodic(Duration(seconds: intervalSeconds), (_) async {
      try {
        final current = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            distanceFilter: 0,
          ),
        );
        _onPosition?.call(current.latitude, current.longitude);
      } catch (_) {}
    });
  }

  void stop() {
    _running = false;
    _subscription?.cancel();
    _subscription = null;
    _timer?.cancel();
    _timer = null;
    _onPosition = null;
  }
}