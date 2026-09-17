import 'dart:async';
import 'dart:math' show Point;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../../helpers/coordinate_converter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../main.dart';
import '../../services/geofence.dart';
import '../../services/geofence_provider.dart';
import '../../services/notification_service.dart';
import '../../services/storage_service.dart';
import '../../services/watchdog.dart';
import 'geofence_edit.dart';

const _overlayChannel = MethodChannel('com.z.nfc/overlay');

/// 电子围栏列表页：全屏地图 + 浮动控件 + 底部可拖拽围栏列表
/// （严格对齐 CU geofence_list.dart，纯在线高德瓦片，无离线底图增强）
class GeofenceScreen extends StatefulWidget {
  const GeofenceScreen({super.key});

  @override
  State<GeofenceScreen> createState() => _GeofenceScreenState();
}

class _GeofenceScreenState extends State<GeofenceScreen> {
  late final GeofenceProvider _geo;
  late final StorageService _storage = StorageService();
  bool _watchdogEnabled = false;
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
  Timer? _locationTimer;

  @override
  void initState() {
    super.initState();
    _geo = AppScope.instance.controller.geofence;
    _geo.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _locateMe();
      _watchdogEnabled = await _storage.getWatchdogEnabled();
      if (mounted) setState(() {});
    });
    _locationTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted || !_followMe) return;
      final pos = await _getGcjPosition();
      if (pos == null || pos == _currentPosition) return;
      if (!mounted) return;
      setState(() {
        _currentPosition = pos;
        _positionLoaded = true;
      });
      final zoom = _mapController.camera.zoom;
      _mapController.move(pos, zoom);
    });
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    _geo.removeListener(_onChange);
    _mapController.dispose();
    super.dispose();
  }

  /// 围栏状态变化（命中/离开/上传/总开关等）只需刷新界面
  void _onChange() {
    if (!mounted) return;
    setState(() {});
  }

  /// 一次性获取当前位置（WGS84 → GCJ02），失败返回 null
  Future<LatLng?> _getGcjPosition() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      return CoordinateConverter.wgs84ToGcj02(
          LatLng(pos.latitude, pos.longitude));
    } catch (_) {
      return null;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  Future<void> _locateMe() async {
    final target = _geo.lastPosition ?? await _getGcjPosition();
    if (target == null) {
      _toast('定位失败：请检查定位权限/GPS信号');
      return;
    }
    if (!mounted) return;
    setState(() {
      _currentPosition = target;
      _positionLoaded = true;
    });
    try {
      await _mapReadyCompleter.future;
    } catch (_) {}
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
      // 原生 getOverlayStatus 返回 bool（对齐 FlutterOverlayWindow.isActive），
      // 不能用 String 强类型断言，否则运行期 bool→String 强转抛异常
      final overlayActive =
          await _overlayChannel.invokeMethod('getOverlayStatus') as bool?;
      _geo.addLog('悬浮窗状态: ${overlayActive ?? false}');
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
              backgroundColor: const Color(0xFFE0E0E0),
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
                      const Icon(Icons.fence, size: 18, color: Colors.blue),
                      const SizedBox(width: 6),
                      const Text(
                        '电子围栏',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (_statusMessage.isNotEmpty) ...[
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
                        onChanged: (v) async {
                          await _geo.setEnabled(v);
                          setState(() {
                            final connected = _geo.connected;
                            _statusMessage = v
                                ? (connected
                                    ? '围栏判定已启动'
                                    : '')
                                : '围栏判定已停止';
                          });
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('后台看门狗', style: TextStyle(fontSize: 12)),
                      Switch(
                        value: _watchdogEnabled,
                        onChanged: (v) async {
                          await _storage.setWatchdogEnabled(v);
                          if (v) {
                            await NotificationService.instance.requestPermission();
                            await Watchdog.start();
                          } else {
                            await Watchdog.stop();
                          }
                          setState(() => _watchdogEnabled = v);
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
                      _statusMessage =
                          _useSatellite ? '已切换卫星地图' : '已切换普通地图';
                    });
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
                      _statusMessage =
                          _followMe ? '地图跟随已开启' : '地图跟随未开启';
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
                FloatingActionButton(
                  heroTag: 'addFence',
                  onPressed: () async {
                    await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            FenceEditPage(
                              provider: _geo,
                              fence: null,
                            ),
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
    final pos = _geo.lastPosition;
    final matched = _geo.lastMatchedFenceName;
    final events = _geo.eventLogs;
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
            _geo.monitoring ? Icons.radar : Icons.radar_outlined,
            _geo.monitoring ? '围栏判定中' : '判定未运行',
            _geo.monitoring ? Colors.green : Colors.grey,
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
          if (events.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _showEventLogs,
                icon: const Icon(Icons.history, size: 13),
                label: Text('事件 ${events.length}'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  visualDensity: VisualDensity.compact,
                  textStyle: textStyle.copyWith(color: Colors.purple),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showEventLogs() {
    final events = _geo.eventLogs.reversed.toList();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.history, size: 20),
            SizedBox(width: 8),
            Expanded(child: Text('围栏事件')),
          ],
        ),
        content: events.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Text('暂无围栏进出记录'),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: events.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      events[i],
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
        actions: [
          TextButton(
            onPressed: () {
              _geo.clearLogs();
              Navigator.pop(ctx);
            },
            child: const Text('清空日志'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _diagRow(
    IconData icon,
    String text,
    Color color,
    TextStyle style, {
    double? maxWidth,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth ?? 200),
            child: Text(
              text,
              style: style.copyWith(color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
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
                                FenceEditPage(
                                  provider: _geo,
                                  fence: fence,
                                ),
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
