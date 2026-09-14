import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../helpers/coordinate_converter.dart';
import '../../main.dart';
import '../../models/enums.dart';
import '../../services/card_library.dart';
import '../../services/geofence.dart';
import '../../services/geofence_provider.dart';
import 'geofence_logs_screen.dart';

const _overlayChannel = MethodChannel('com.z.nfc/overlay');

/// 瓦片离线降级：探测瓦片服务可达性，不可达时改用本地坐标网格底图
/// （围栏多边形与标记点是本地几何，离线时依然可见可操作）
mixin OfflineMap<T extends StatefulWidget> on State<T> {
  bool _tilesOnline = true;
  StreamSubscription<MapEvent>? _mapSub;
  Timer? _gridTimer;
  (LatLng, double, Size)? _baseCamera;

  bool get tilesOnline => _tilesOnline;

  (LatLng, double, Size)? get baseCamera => _baseCamera;

  Color offlineBase(bool isDark) =>
      isDark ? const Color(0xFF1B2733) : const Color(0xFFEEF3F7);

  Color offlineGridLine(bool isDark) =>
      isDark ? const Color(0xFF35485C) : const Color(0xFFBCCEDC);

  String tileHostUrl(bool satellite) => satellite
      ? 'https://webst01.is.autonavi.com/appmaptile?style=6&x=0&y=0&z=0'
      : 'https://webrd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x=0&y=0&z=0';

  /// 相机视口对应的经纬度范围（Web Mercator，纬度限 ±85）
  (double, double, double, double) _visibleBox(
    LatLng center,
    double zoom,
    Size size,
  ) {
    final world = 256.0 * pow(2, zoom).toDouble();
    double px(double lng) => (lng + 180) / 360 * world;
    double py(double lat) =>
        (0.5 - log(tan(pi / 4 + lat * pi / 360)) / (2 * pi)) * world;
    double unpx(double x) => x / world * 360 - 180;
    double unpy(double y) => atan(_sinh(pi - 2 * pi * y / world)) * 180 / pi;

    final cx = px(center.longitude);
    final cy = py(center.latitude.clamp(-85.0, 85.0));
    return (
      unpx(cx - size.width / 2),
      unpx(cx + size.width / 2),
      unpy(cy + size.height / 2),
      unpy(cy - size.height / 2),
    );
  }

  /// 当前 SDK 的 dart:math 未导出 sinh，这里按定义实现
  double _sinh(double x) => (exp(x) - exp(-x)) / 2;

  /// 选一个接近 raw 的「1/2/5 × 10^n」步长，保证网格线间隔可读
  double _niceStep(double raw) {
    if (raw <= 0 || !raw.isFinite) return 1;
    final p = pow(10, (log(raw) / ln10).floor()).toDouble();
    final n = raw / p;
    final m = n <= 1 ? 1.0 : (n <= 2 ? 2.0 : (n <= 5 ? 5.0 : 10.0));
    return m * p;
  }

  /// 坐标读数：离线底图没有地名与比例尺，补一个中心点读数
  String coordinateText(LatLng p) =>
      '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

  /// 挂接地图控制器：瓦片不可达时随平移/缩放刷新网格底图
  void attachOfflineMap(
    MapController controller,
    LatLng initialCenter, {
    double zoom = 15.0,
  }) {
    _baseCamera = (initialCenter, zoom, const Size(400, 700));
    _mapSub?.cancel();
    _mapSub = controller.mapEventStream.listen(_onMapEvent);
  }

  void disposeOfflineMap() {
    _mapSub?.cancel();
    _mapSub = null;
    _gridTimer?.cancel();
    _gridTimer = null;
  }

  void _onMapEvent(MapEvent event) {
    if (_tilesOnline) return;
    final s = event.camera.nonRotatedSize;
    if (s.x > 0 && s.y > 0) {
      _baseCamera = (event.camera.center, event.camera.zoom, Size(s.x, s.y));
    }
    _scheduleGridRefresh();
  }

  /// 地图事件高频触发，节流后再重建底图
  void _scheduleGridRefresh() {
    if (_gridTimer?.isActive ?? false) return;
    _gridTimer = Timer(const Duration(milliseconds: 120), () {
      _gridTimer = null;
      if (mounted && !_tilesOnline) setState(() {});
    });
  }

  /// 探测瓦片服务可达性，结果回调后切换底图
  Future<void> probeTiles({
    required bool satellite,
    required void Function(bool online) onChanged,
  }) async {
    final client = http.Client();
    bool ok = false;
    try {
      final res = await client
          .get(Uri.parse(tileHostUrl(satellite)))
          .timeout(const Duration(seconds: 4));
      ok = res.statusCode >= 200 && res.statusCode < 500;
    } catch (_) {
      ok = false;
    } finally {
      client.close();
    }
    onChanged(ok);
  }

  /// 切换瓦片在线状态；owner 通过 [onTileAvailability] 更新提示文案
  void setTilesOnline(bool online) {
    if (!mounted || _tilesOnline == online) return;
    setState(() => _tilesOnline = online);
    onTileAvailability(online);
    if (!online) _scheduleGridRefresh();
  }

  /// 瓦片不可达时的本地底图：坐标网格线
  List<Polyline> offlineGridLines({required Color line}) {
    final cam = _baseCamera;
    if (cam == null) return const [];
    final box = _visibleBox(cam.$1, cam.$2, cam.$3);
    final lonStep = _niceStep((box.$2 - box.$1) / 6);
    final latStep = _niceStep((box.$4 - box.$3) / 8);
    final lines = <Polyline>[];
    var lng = (box.$1 / lonStep).floor() * lonStep;
    while (lng <= box.$2) {
      lines.add(
        Polyline(
          points: [LatLng(box.$3, lng), LatLng(box.$4, lng)],
          color: line,
          strokeWidth: 1,
        ),
      );
      lng += lonStep;
    }
    var lat = (box.$3 / latStep).floor() * latStep;
    while (lat <= box.$4) {
      lines.add(
        Polyline(
          points: [LatLng(lat, box.$1), LatLng(lat, box.$2)],
          color: line,
          strokeWidth: 1,
        ),
      );
      lat += latStep;
    }
    return lines;
  }

  /// 底图填充面：瓦片缺失时铺底色，避免地图区域整体空白
  List<Polygon> offlineBaseFill({required Color fill}) {
    final cam = _baseCamera;
    if (cam == null) return const [];
    final box = _visibleBox(cam.$1, cam.$2, cam.$3);
    final pad = ((box.$2 - box.$1) * 0.15).clamp(0.001, 10.0);
    return [
      Polygon(
        points: [
          LatLng(box.$3, box.$1 - pad),
          LatLng(box.$4, box.$1 - pad),
          LatLng(box.$4, box.$2 + pad),
          LatLng(box.$3, box.$2 + pad),
        ],
        color: fill,
        borderColor: fill,
      ),
    ];
  }

  void onTileAvailability(bool online);
}

/// 电子围栏列表页：全屏地图 + 浮动控件 + 底部可拖拽围栏列表（对齐 CU geofence_list.dart）
class GeofenceScreen extends StatefulWidget {
  const GeofenceScreen({super.key});

  @override
  State<GeofenceScreen> createState() => _GeofenceScreenState();
}

class _GeofenceScreenState extends State<GeofenceScreen>
    with OfflineMap<GeofenceScreen> {
  late final GeofenceProvider _geo;
  final MapController _mapController = MapController();
  bool _useSatellite = false;
  LatLng _currentPosition = const LatLng(39.9042, 116.4074);
  bool _positionLoaded = false;
  bool _followMe = true;
  String _statusMessage = '';

  String? _dragFenceId;
  LatLng? _dragStartLatLng;
  LatLng? _dragHandleLatLng;
  final Map<String, List<LatLng>> _liveDragPoints = {};
  String? _selectedFenceId;
  final _mapReadyCompleter = Completer<void>();

  @override
  void initState() {
    super.initState();
    _geo = AppScope.instance.controller.geofence;
    _geo.addListener(_onChange);
    attachOfflineMap(_mapController, _currentPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _locateMe();
      _probeTiles();
    });
  }

  @override
  void dispose() {
    _geo.removeListener(_onChange);
    disposeOfflineMap();
    _mapController.dispose();
    super.dispose();
  }

  /// 探测瓦片服务可达性，失败则切到本地底图
  Future<void> _probeTiles() async {
    await probeTiles(satellite: _useSatellite, onChanged: setTilesOnline);
  }

  @override
  void onTileAvailability(bool online) {
    if (mounted) {
      setState(() => _statusMessage = online ? '瓦片服务已恢复' : '瓦片不可达，已切换本地底图');
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  Future<LatLng?> _getGcjPosition() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      return CoordinateConverter.wgs84ToGcj02(
        LatLng(position.latitude, position.longitude),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _locateMe() async {
    final target = _geo.lastPosition ?? await _getGcjPosition();
    if (!mounted || target == null) return;
    setState(() {
      _currentPosition = target;
      _positionLoaded = true;
      _statusMessage = '已定位到当前位置';
    });
    await _mapReadyCompleter.future;
    if (!mounted) return;
    _mapController.move(target, 16.0);
  }

  Future<void> _enterFloatingWindow() async {
    if (_geo.overlayActive) {
      await FlutterOverlayWindow.closeOverlay();
      _geo.setOverlayActive(false);
      return;
    }
    final granted = await Permission.systemAlertWindow.isGranted;
    if (!granted) {
      final status = await Permission.systemAlertWindow.request();
      if (status != PermissionStatus.granted) {
        _toast('需要悬浮窗权限');
        return;
      }
    }
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    _geo.setOverlayActive(true);
    try {
      await FlutterOverlayWindow.showOverlay(
        height: 130,
        width: 210,
        alignment: OverlayAlignment.topRight,
        enableDrag: true,
        positionGravity: PositionGravity.none,
        overlayTitle: 'NFC围栏',
        overlayContent: '围栏悬浮窗运行中',
      );
    } catch (e) {
      _geo.addLog('悬浮窗启动异常: $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    try {
      final active = await FlutterOverlayWindow.isActive();
      _geo.addLog('悬浮窗自检: 服务运行=$active');
    } catch (e) {
      _geo.addLog('悬浮窗自检异常: $e');
    }
    try {
      final status = await _overlayChannel.invokeMethod<String>(
        'getOverlayStatus',
      );
      _geo.addLog('悬浮窗状态:${status ?? '(空)'}');
    } catch (e) {
      _geo.addLog('悬浮窗状态获取异常: $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      await _overlayChannel.invokeMethod('moveToBack');
    } catch (_) {}
  }

  List<LatLng> _pointsForFence(Geofence fence) {
    return _liveDragPoints[fence.id] ?? fence.points;
  }

  Geofence? _fenceById(String id) {
    for (final f in _geo.fences) {
      if (f.id == id) return f;
    }
    return null;
  }

  List<Polygon> _buildPolygons() {
    final polygons = <Polygon>[];
    for (final fence in _geo.fences) {
      final points = _pointsForFence(fence);
      if (points.length < 3) continue;
      final color = fence.enabled ? Color(fence.colorValue) : Colors.grey;
      polygons.add(
        Polygon(
          points: points,
          color: color.withValues(alpha: 0.2),
          borderColor: color,
          borderStrokeWidth: 2,
        ),
      );
    }
    return polygons;
  }

  List<Marker> _buildFenceCenterMarkers() {
    final markers = <Marker>[];
    for (final fence in _geo.fences) {
      final points = _pointsForFence(fence);
      if (points.isEmpty) continue;
      final isActive = fence.id == _selectedFenceId;
      final center = (isActive && _dragHandleLatLng != null)
          ? _dragHandleLatLng!
          : _polygonCenter(points);
      markers.add(
        Marker(
          point: center,
          width: 44,
          height: 44,
          child: _FenceDragHandle(
            fence: fence,
            active: isActive,
            onDragStart: () => _startFenceDrag(fence.id, center),
            onDragDelta: _updateFenceDrag,
            onDragEnd: _endFenceDrag,
          ),
        ),
      );
    }
    return markers;
  }

  void _startFenceDrag(String fenceId, LatLng handleStart) {
    setState(() {
      _dragFenceId = fenceId;
      _selectedFenceId = fenceId;
      _dragStartLatLng = handleStart;
      _dragHandleLatLng = handleStart;
    });
  }

  void _updateFenceDrag(Offset cumulativeDelta) {
    final fenceId = _dragFenceId;
    final start = _dragStartLatLng;
    if (fenceId == null || start == null) return;
    final fence = _fenceById(fenceId);
    if (fence == null) return;
    final camera = _mapController.camera;
    final startScreen = camera.latLngToScreenPoint(start);
    final newScreen = Point(
      startScreen.x + cumulativeDelta.dx,
      startScreen.y + cumulativeDelta.dy,
    );
    final newLatLng = camera.pointToLatLng(newScreen);
    final latDelta = newLatLng.latitude - start.latitude;
    final lngDelta = newLatLng.longitude - start.longitude;
    setState(() {
      _dragHandleLatLng = newLatLng;
      _liveDragPoints[fenceId] = fence.points
          .map((p) => LatLng(p.latitude + latDelta, p.longitude + lngDelta))
          .toList();
    });
  }

  void _endFenceDrag() {
    final fenceId = _dragFenceId;
    if (fenceId != null) {
      final moved = _liveDragPoints[fenceId];
      final fence = _fenceById(fenceId);
      if (fence != null && moved != null) {
        _geo.updateFence(fence.copyWith(points: moved));
      }
    }
    setState(() {
      _dragFenceId = null;
      _dragStartLatLng = null;
      _dragHandleLatLng = null;
      _liveDragPoints.clear();
    });
  }

  void _onMapTap(TapPosition tapPosition, LatLng point) {
    Geofence? hit;
    for (final fence in _geo.fences) {
      if (fence.points.length >= 3 &&
          GeofenceMatcher.isPointInPolygon(point, fence.points)) {
        hit = fence;
      }
    }
    setState(() {
      _selectedFenceId = hit?.id;
      _dragHandleLatLng = hit != null ? point : null;
    });
  }

  LatLng _polygonCenter(List<LatLng> points) {
    var lat = 0.0;
    var lng = 0.0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final latest = _geo.lastPosition;
    if (latest != null && latest != _currentPosition) {
      _currentPosition = latest;
      _positionLoaded = true;
      if (_followMe) {
        final zoom = _mapController.camera.zoom;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _mapController.move(latest, zoom);
        });
      }
    }

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentPosition,
              initialZoom: 15.0,
              backgroundColor: tilesOnline
                  ? const Color(0xFFE0E0E0)
                  : offlineBase(isDark),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onMapReady: () {
                if (!_mapReadyCompleter.isCompleted) {
                  _mapReadyCompleter.complete();
                }
              },
              onTap: _onMapTap,
            ),
            children: [
              if (!tilesOnline)
                PolygonLayer(
                  polygons: offlineBaseFill(fill: offlineBase(isDark)),
                ),
              if (!tilesOnline)
                PolylineLayer(
                  polylines: offlineGridLines(line: offlineGridLine(isDark)),
                ),
              if (tilesOnline)
                TileLayer(
                  urlTemplate: _useSatellite
                      ? 'https://webst0{s}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}'
                      : 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                  subdomains: const ['1', '2', '3', '4'],
                  userAgentPackageName: 'com.z.nfc',
                ),
              PolygonLayer(polygons: _buildPolygons()),
              MarkerLayer(markers: _buildFenceCenterMarkers()),
              if (_positionLoaded)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentPosition,
                      width: 24,
                      height: 24,
                      child: const Icon(
                        Icons.my_location,
                        color: Colors.blue,
                        size: 24,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: (isDark ? Colors.black87 : Colors.white).withValues(
                  alpha: 0.9,
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.fence, size: 18, color: primary),
                      const SizedBox(width: 6),
                      const Text(
                        '电子围栏',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (!tilesOnline) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: (isDark
                                ? Colors.white12
                                : Colors.orange.shade100),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.cloud_off, size: 11),
                              SizedBox(width: 3),
                              Text('离线底图', style: TextStyle(fontSize: 10)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            coordinateText(baseCamera?.$1 ?? _currentPosition),
                            style: TextStyle(
                              fontSize: 10,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ] else if (_statusMessage.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _statusMessage,
                            style: TextStyle(
                              fontSize: 10,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('总开关', style: TextStyle(fontSize: 12)),
                      Switch(
                        value: _geo.userEnabled,
                        onChanged: (v) {
                          _geo.setEnabled(v);
                          setState(
                            () => _statusMessage = v ? '围栏已开启' : '围栏已关闭',
                          );
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Positioned(top: 8, right: 8, child: _buildDiagnostics(isDark)),
          Positioned(
            right: 8,
            bottom: 120,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'mapType',
                  onPressed: () {
                    setState(() {
                      _useSatellite = !_useSatellite;
                      _statusMessage = _useSatellite ? '已切换卫星地图' : '已切换普通地图';
                    });
                    if (tilesOnline) _probeTiles();
                  },
                  child: Icon(
                    _useSatellite
                        ? Icons.map_outlined
                        : Icons.satellite_alt_outlined,
                  ),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'overlay',
                  backgroundColor: Colors.indigo,
                  onPressed: _enterFloatingWindow,
                  tooltip: '悬浮窗模式',
                  child: const Icon(Icons.picture_in_picture_alt, size: 18),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'follow',
                  backgroundColor: _followMe ? Colors.blue : null,
                  onPressed: () {
                    setState(() {
                      _followMe = !_followMe;
                      _statusMessage = _followMe ? '地图跟随已开启' : '地图跟随未开启';
                    });
                    if (_followMe) _locateMe();
                  },
                  child: Icon(
                    _followMe ? Icons.gps_fixed : Icons.gps_not_fixed,
                  ),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'locate',
                  onPressed: _locateMe,
                  child: const Icon(Icons.my_location),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'logs',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const GeofenceLogsScreen(),
                    ),
                  ),
                  tooltip: '围栏日志',
                  child: const Icon(Icons.receipt_long, size: 18),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'addFence',
                  onPressed: () async {
                    await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            FenceEditPage(provider: _geo, fence: null),
                      ),
                    );
                  },
                  child: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          _buildBottomSheet(isDark),
        ],
      ),
    );
  }

  Widget _buildDiagnostics(bool isDark) {
    final connected = _geo.connected;
    final time = _geo.lastPositionTime;
    final pos = _geo.lastPosition;
    final matched = _geo.lastMatchedFenceName;
    final bg = (isDark ? Colors.black87 : Colors.white).withValues(alpha: 0.9);
    final textStyle = TextStyle(
      fontSize: 11,
      color: isDark ? Colors.white : Colors.black87,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _diagRow(
            connected ? Icons.link : Icons.link_off,
            connected ? '设备已连接' : '设备未连接',
            connected ? Colors.green : Colors.grey,
            textStyle,
          ),
          _diagRow(
            _geo.monitoring ? Icons.my_location : Icons.location_off,
            time != null ? '定位 ${_fmtTime(time)}' : '暂无定位',
            time != null ? Colors.blue : Colors.grey,
            textStyle,
          ),
          if (pos != null)
            _diagRow(
              Icons.pin_drop,
              '坐标 ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}',
              Colors.blueGrey,
              textStyle,
            ),
          _diagRow(
            matched != null ? Icons.fence : Icons.help_outline,
            matched != null ? '命中: $matched' : '未命中围栏',
            matched != null ? Colors.orange : Colors.grey,
            textStyle,
          ),
          if (_geo.uploadStatus != null)
            _diagRow(
              _geo.uploadStatus == '卡片上传成功'
                  ? Icons.check_circle
                  : Icons.error_outline,
              _geo.uploadStatus!,
              _geo.uploadStatus == '卡片上传成功' ? Colors.green : Colors.red,
              textStyle,
            ),
          if (_geo.rollingCodeStatus != null)
            _diagRow(
              Icons.sync,
              _geo.rollingCodeStatus!,
              Colors.teal,
              textStyle,
            ),
        ],
      ),
    );
  }

  Widget _diagRow(IconData icon, String text, Color color, TextStyle style) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(text, style: style.copyWith(color: color)),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Widget _buildBottomSheet(bool isDark) {
    final fences = _geo.fences;
    return DraggableScrollableSheet(
      initialChildSize: 0.12,
      minChildSize: 0.12,
      maxChildSize: 0.45,
      snap: true,
      snapSizes: const [0.12, 0.45],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        '已添加围栏 (${fences.length})',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _showIntervalDialog,
                        icon: const Icon(Icons.timer_outlined, size: 16),
                        label: Text(
                          '间隔 ${_geo.checkInterval}s',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: Divider(height: 1)),
              if (fences.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.fence,
                          size: 40,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '暂无围栏，点击右下角 + 新建',
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final fence = fences[index];
                    return _GeofenceTile(
                      fence: fence,
                      onToggle: (v) => _geo.toggleFence(fence.id, v),
                      onTap: () async {
                        await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                FenceEditPage(provider: _geo, fence: fence),
                          ),
                        );
                      },
                      onDelete: () => _confirmDelete(fence),
                    );
                  }, childCount: fences.length),
                ),
            ],
          ),
        );
      },
    );
  }

  void _showIntervalDialog() {
    final controller = TextEditingController(
      text: _geo.checkInterval.toString(),
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置检测间隔'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '间隔（秒）',
            helperText: '最小 5 秒',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              if (value != null && value >= 5) {
                _geo.setCheckInterval(value);
              }
              Navigator.pop(ctx);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(Geofence fence) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除围栏'),
        content: Text('确定删除围栏"${fence.name}"吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              _geo.deleteFence(fence.id);
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

class _GeofenceTile extends StatelessWidget {
  final Geofence fence;
  final void Function(bool) onToggle;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _GeofenceTile({
    required this.fence,
    required this.onToggle,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = fence.enabled ? Color(fence.colorValue) : Colors.grey;
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: color,
        child: const Icon(Icons.fence, size: 18, color: Colors.white),
      ),
      title: Text(
        fence.name,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        '卡槽 ${fence.slotNumber}  |  ${fence.points.length} 个点',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: fence.enabled,
            onChanged: onToggle,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            onPressed: onTap,
            tooltip: '编辑',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
            onPressed: onDelete,
            tooltip: '删除',
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _FenceDragHandle extends StatefulWidget {
  final Geofence fence;
  final bool active;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragDelta;
  final VoidCallback onDragEnd;

  const _FenceDragHandle({
    required this.fence,
    required this.active,
    required this.onDragStart,
    required this.onDragDelta,
    required this.onDragEnd,
  });

  @override
  State<_FenceDragHandle> createState() => _FenceDragHandleState();
}

class _FenceDragHandleState extends State<_FenceDragHandle> {
  Offset _cumulativeDelta = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: {
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              () => EagerGestureRecognizer(),
              (recognizer) {},
            ),
      },
      behavior: HitTestBehavior.opaque,
      child: Listener(
        onPointerDown: (event) {
          _cumulativeDelta = Offset.zero;
          widget.onDragStart();
        },
        onPointerMove: (event) {
          _cumulativeDelta += event.delta;
          widget.onDragDelta(_cumulativeDelta);
        },
        onPointerUp: (event) => widget.onDragEnd(),
        onPointerCancel: (event) => widget.onDragEnd(),
        child: Container(
          decoration: BoxDecoration(
            color: widget.active
                ? Colors.orange
                : (widget.fence.enabled
                      ? Color(widget.fence.colorValue)
                      : Colors.grey),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            widget.active ? Icons.open_with : Icons.fence,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}

/// 围栏编辑页：全屏地图 + 表单（对齐 CU geofence_edit.dart）
class FenceEditPage extends StatefulWidget {
  final GeofenceProvider provider;
  final Geofence? fence;

  const FenceEditPage({super.key, required this.provider, this.fence});

  @override
  State<FenceEditPage> createState() => _FenceEditPageState();
}

class _FenceEditPageState extends State<FenceEditPage>
    with OfflineMap<FenceEditPage> {
  final _nameController = TextEditingController();
  final _labelController = TextEditingController();
  int _slotNumber = 1;
  int _colorValue = 0xFF2196F3;
  List<LatLng> _points = [];
  final MapController _mapController = MapController();
  bool _useSatellite = false;
  bool _cardLibraryMode = false;
  String? _icCardId;
  String? _idCardId;
  bool _rollingCode = false;
  List<SaveCard> _libraryCards = [];
  final _mapReadyCompleter = Completer<void>();

  static const _presetColors = [
    0xFF2196F3,
    0xFFF44336,
    0xFF4CAF50,
    0xFFFF9800,
    0xFF9C27B0,
    0xFF00BCD4,
    0xFFFF5722,
    0xFF607D8B,
    0xFFE91E63,
    0xFF795548,
  ];

  @override
  void initState() {
    super.initState();
    if (widget.fence != null) {
      _nameController.text = widget.fence!.name;
      _labelController.text = widget.fence!.label;
      _slotNumber = widget.fence!.slotNumber;
      _colorValue = widget.fence!.colorValue;
      _points = List.from(widget.fence!.points);
      _cardLibraryMode = widget.fence!.cardLibraryMode;
      _icCardId = widget.fence!.icCardId;
      _idCardId = widget.fence!.idCardId;
      _rollingCode = widget.fence!.rollingCode;
    }
    // 同步缓存卡库，供 _selectedICCard/_selectedIDCard 同步查询
    // （CU 用同步 SharedPreferences，这里用一次性缓存等价实现）
    CardLibraryStorage().getCards().then((cards) {
      if (mounted && cards.isNotEmpty) {
        setState(() => _libraryCards = cards);
      }
    });
    attachOfflineMap(
      _mapController,
      _points.isNotEmpty ? _points.first : const LatLng(39.9042, 116.4074),
    );
    if (widget.fence == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _locateMe());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeTiles());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _labelController.dispose();
    disposeOfflineMap();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _probeTiles() async {
    await probeTiles(satellite: _useSatellite, onChanged: setTilesOnline);
  }

  @override
  void onTileAvailability(bool online) {}

  void _addPoint(LatLng point) => setState(() => _points.add(point));

  void _removePoint(int index) => setState(() => _points.removeAt(index));

  void _clear() => setState(() => _points.clear());

  void _cancel() => Navigator.pop(context);

  void _save() {
    if (_points.length < 3) {
      _toast('至少需要 3 个点才能形成围栏');
      return;
    }
    if (_nameController.text.trim().isEmpty) {
      _toast('请输入围栏名称');
      return;
    }
    final fence = Geofence(
      id: widget.fence?.id ?? newGeofenceId(),
      name: _nameController.text.trim(),
      label: _labelController.text.trim(),
      slotNumber: _slotNumber,
      enabled: widget.fence?.enabled ?? true,
      points: List.from(_points),
      colorValue: _colorValue,
      cardLibraryMode: _cardLibraryMode,
      icCardId: _cardLibraryMode ? _icCardId : null,
      idCardId: _cardLibraryMode ? _idCardId : null,
      rollingCode: _cardLibraryMode && _icCardId != null ? _rollingCode : false,
    );
    if (widget.fence != null) {
      widget.provider.updateFence(fence);
    } else {
      widget.provider.addFence(fence);
    }
    Navigator.pop(context, true);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  Future<LatLng?> _getGcjPosition() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      return CoordinateConverter.wgs84ToGcj02(
        LatLng(position.latitude, position.longitude),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _locateMe() async {
    final target = widget.provider.lastPosition ?? await _getGcjPosition();
    if (!mounted || target == null) return;
    await _mapReadyCompleter.future;
    if (!mounted) return;
    _mapController.move(target, 16.0);
  }

  Future<void> _pickLibraryCard({required bool ic}) async {
    final all = await CardLibraryStorage().getCards();
    if (!mounted) return;
    _libraryCards = all;
    final cards = all.where((c) => ic ? isHfCard(c.tag) : isLf(c.tag)).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (cards.isEmpty) {
      _toast('卡库为空，请先添加卡片');
      return;
    }
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _CardPickerDialog(
        cards: cards,
        title: ic ? '选择 IC 卡' : '选择 ID 卡',
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      setState(() {
        if (ic) {
          _icCardId = result;
        } else {
          _idCardId = result;
        }
        if (ic && !isHfCard(_selectedICCard?.tag ?? TagType.mifare1K)) {
          _rollingCode = false;
        }
      });
    }
  }

  SaveCard? get _selectedICCard {
    if (_icCardId == null) return null;
    return _libraryCardById(_icCardId);
  }

  SaveCard? get _selectedIDCard {
    if (_idCardId == null) return null;
    return _libraryCardById(_idCardId);
  }

  SaveCard? _libraryCardById(String? id) {
    if (id == null) return null;
    for (final c in _libraryCards) {
      if (c.id == id) return c;
    }
    return null;
  }

  bool get _selectedICCardIsIC =>
      _selectedICCard != null && isHfCard(_selectedICCard!.tag);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultCenter = _points.isNotEmpty
        ? _points.first
        : const LatLng(39.9042, 116.4074);
    final maxSlots = widget.provider.fences.isNotEmpty ? 80 : 8;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.fence != null ? '编辑围栏' : '新建围栏'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: _cancel),
        actions: [
          TextButton(
            onPressed: _clear,
            child: const Text('清除', style: TextStyle(color: Colors.red)),
          ),
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: defaultCenter,
                    initialZoom: 15.0,
                    backgroundColor: tilesOnline
                        ? const Color(0xFFE0E0E0)
                        : offlineBase(isDark),
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all,
                    ),
                    onMapReady: () {
                      if (!_mapReadyCompleter.isCompleted) {
                        _mapReadyCompleter.complete();
                      }
                    },
                    onTap: (tapPosition, point) => _addPoint(point),
                  ),
                  children: [
                    if (!tilesOnline)
                      PolygonLayer(
                        polygons: offlineBaseFill(fill: offlineBase(isDark)),
                      ),
                    if (!tilesOnline)
                      PolylineLayer(
                        polylines: offlineGridLines(
                          line: offlineGridLine(isDark),
                        ),
                      ),
                    if (tilesOnline)
                      TileLayer(
                        urlTemplate: _useSatellite
                            ? 'https://webst0{s}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}'
                            : 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                        subdomains: const ['1', '2', '3', '4'],
                        userAgentPackageName: 'com.z.nfc',
                      ),
                    if (_points.length >= 3)
                      PolygonLayer(
                        polygons: [
                          Polygon(
                            points: _points,
                            color: Color(_colorValue).withValues(alpha: 0.2),
                            borderColor: Color(_colorValue),
                            borderStrokeWidth: 2,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: List.generate(_points.length, (index) {
                        final point = _points[index];
                        return Marker(
                          point: point,
                          width: 32,
                          height: 32,
                          child: GestureDetector(
                            onTap: () => _removePoint(index),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Color(_colorValue),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: FloatingActionButton.small(
                    heroTag: 'editMapType',
                    onPressed: () {
                      setState(() => _useSatellite = !_useSatellite);
                      if (tilesOnline) _probeTiles();
                    },
                    child: Icon(
                      _useSatellite
                          ? Icons.map_outlined
                          : Icons.satellite_alt_outlined,
                    ),
                  ),
                ),
                Positioned(
                  top: 60,
                  right: 8,
                  child: FloatingActionButton.small(
                    heroTag: 'editLocate',
                    onPressed: _locateMe,
                    child: const Icon(Icons.my_location),
                  ),
                ),
                if (_points.isNotEmpty)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: (isDark ? Colors.black87 : Colors.white)
                            .withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${_points.length} 个点',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '围栏名称',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _labelController,
                          decoration: const InputDecoration(
                            labelText: '标签名称',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _slotNumber.clamp(1, maxSlots),
                          decoration: const InputDecoration(
                            labelText: '卡槽编号',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: List.generate(maxSlots, (i) {
                            return DropdownMenuItem(
                              value: i + 1,
                              child: Text('卡槽 ${i + 1}'),
                            );
                          }),
                          onChanged: (v) {
                            if (v != null) setState(() => _slotNumber = v);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildCardLibraryModeSection(isDark),
                  const SizedBox(height: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '围栏颜色',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: _presetColors.map((cv) {
                          final selected = _colorValue == cv;
                          return GestureDetector(
                            onTap: () => setState(() => _colorValue = cv),
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: Color(cv),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selected
                                      ? Colors.white
                                      : Colors.transparent,
                                  width: 3,
                                ),
                                boxShadow: selected
                                    ? [
                                        BoxShadow(
                                          color: Color(
                                            cv,
                                          ).withValues(alpha: 0.5),
                                          blurRadius: 6,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: selected
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 18,
                                    )
                                  : null,
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _clear,
                          icon: const Icon(Icons.clear_all),
                          label: const Text('清除'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _cancel,
                          icon: const Icon(Icons.cancel),
                          label: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.save),
                          label: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardLibraryModeSection(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.grey.shade300,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '卡库模式',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '进入围栏时自动上传 IC/ID 卡到选中的卡槽',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _cardLibraryMode,
                onChanged: (v) {
                  setState(() {
                    _cardLibraryMode = v;
                    if (!v) _rollingCode = false;
                  });
                },
              ),
            ],
          ),
          if (_cardLibraryMode) ...[
            const SizedBox(height: 8),
            _buildCardSelector(
              title: 'IC 卡',
              slotHint: '上传到卡槽 $_slotNumber',
              selectedCard: _selectedICCard,
              onPick: () => _pickLibraryCard(ic: true),
              onClear: () => setState(() => _icCardId = null),
            ),
            const SizedBox(height: 8),
            _buildCardSelector(
              title: 'ID 卡',
              slotHint: '上传到卡槽 $_slotNumber',
              selectedCard: _selectedIDCard,
              onPick: () => _pickLibraryCard(ic: false),
              onClear: () => setState(() => _idCardId = null),
            ),
            if (_selectedICCardIsIC) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '滚动码',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '刷卡后数据自动同步回卡库',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _rollingCode,
                    onChanged: (v) => setState(() => _rollingCode = v),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildCardSelector({
    required String title,
    required String slotHint,
    required SaveCard? selectedCard,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) {
    final isIC = selectedCard != null && isHfCard(selectedCard.tag);
    final isID = selectedCard != null && isLf(selectedCard.tag);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                slotHint,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        InkWell(
          onTap: onPick,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade400),
            ),
            child: Row(
              children: [
                Icon(
                  selectedCard == null
                      ? Icons.credit_card_off_outlined
                      : (isIC
                            ? Icons.credit_card
                            : (isID ? Icons.wifi : Icons.credit_card)),
                  size: 18,
                  color: selectedCard != null
                      ? Color(_colorValue)
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    selectedCard?.name.isEmpty ?? true
                        ? (selectedCard?.uid ?? '未选择')
                        : (selectedCard?.name ?? '未选择'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: selectedCard == null ? Colors.grey.shade500 : null,
                    ),
                  ),
                ),
                if (selectedCard != null)
                  GestureDetector(
                    onTap: onClear,
                    child: Icon(
                      Icons.close,
                      size: 18,
                      color: Colors.grey.shade500,
                    ),
                  )
                else
                  const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ),
        ),
        if (selectedCard != null) ...[
          const SizedBox(height: 4),
          Text(
            selectedCard.tag.label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
        ],
      ],
    );
  }
}

/// 卡库卡片选择对话框（对齐 CU showSearch + CardSearchDelegate：
/// 带搜索过滤、颜色与卡类型展示）
class _CardPickerDialog extends StatefulWidget {
  const _CardPickerDialog({required this.cards, required this.title});

  final List<SaveCard> cards;
  final String title;

  @override
  State<_CardPickerDialog> createState() => _CardPickerDialogState();
}

class _CardPickerDialogState extends State<_CardPickerDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<SaveCard> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.cards;
    return widget.cards
        .where(
          (c) =>
              c.name.toLowerCase().contains(q) ||
              c.uid.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final cards = _filtered;
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v),
            decoration: const InputDecoration(
              hintText: '搜索名称或 UID',
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 20),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          if (cards.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('没有匹配的卡片'),
            )
          else
            SizedBox(
              height: 320,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: cards.length,
                itemBuilder: (context, i) {
                  final c = cards[i];
                  return SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, c.id),
                    child: Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: c.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c.name.isEmpty ? c.uid : c.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${c.tag.label}  ${c.uid}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                  fontFamily: 'monospace',
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
