import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知服务（对齐 CU notification_service.dart）
///
/// 当前用于看门狗的后台告警；围栏进出的通知通道一并建立，便于后续接入。
class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'geofence_alerts';
  static const String _channelName = '围栏提醒';
  static const int _notificationId = 1001;

  Future<void> init() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings);

    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: '进入/离开电子围栏时提醒',
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  Future<void> showGeofenceEnter(String name) async {
    await _show('进入围栏', '已进入围栏"$name"');
  }

  Future<void> showGeofenceExit(String name) async {
    await _show('离开围栏', '已离开围栏"$name"');
  }

  Future<void> showWatchdogWarning() async {
    await _show(
      '后台服务异常',
      '看门狗检测到后台服务长时间无响应，请检查应用状态',
      id: 2001,
    );
  }

  Future<void> showWatchdogStarted() async {
    await _show(
      '后台看门狗',
      '后台看门狗已启动，正在监控后台服务状态',
      id: 2002,
    );
  }

  Future<void> _show(String title, String body,
      {int id = _notificationId}) async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: '进入/离开电子围栏时提醒',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(id, title, body, details);
  }
}
