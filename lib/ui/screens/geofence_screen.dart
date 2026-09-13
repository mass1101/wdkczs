import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../main.dart';
import '../../services/card_library.dart';
import '../../services/geofence.dart';
import '../../services/geofence_provider.dart';
import '../widgets/common.dart' show ActionButton;

/// 电子围栏管理页：围栏列表 + 新增/编辑 + 启用开关 + 日志
class GeofenceScreen extends StatefulWidget {
  const GeofenceScreen({super.key});

  @override
  State<GeofenceScreen> createState() => _GeofenceScreenState();
}

class _GeofenceScreenState extends State<GeofenceScreen> {
  late final GeofenceProvider _geo;

  @override
  void initState() {
    super.initState();
    _geo = AppScope.instance.controller.geofence;
    _geo.addListener(_onChange);
  }

  @override
  void dispose() {
    _geo.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('电子围栏')),
      backgroundColor: const Color(0xFFF5F6F8),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _switchCard(primary),
          const SizedBox(height: 8),
          Row(
            children: [
              ActionButton(label: '新增围栏', icon: Icons.add, onTap: _addFence),
              const SizedBox(width: 8),
              ActionButton(label: '检查间隔', icon: Icons.timer, onTap: _setInterval),
              const SizedBox(width: 8),
              ActionButton(
                label: _geo.overlayActive ? '关闭悬浮窗' : '开启悬浮窗',
                icon: _geo.overlayActive ? Icons.cancel : Icons.picture_in_picture_alt,
                onTap: _toggleOverlay,
              ),
              const SizedBox(width: 8),
              ActionButton(label: '清空日志', icon: Icons.delete_sweep, onTap: _geo.clearLogs),
            ],
          ),
          const SizedBox(height: 8),
          if (_geo.fences.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                  child: Text('暂无围栏，点击「新增围栏」创建',
                      style: TextStyle(color: Colors.grey))),
            )
          else
            ..._geo.fences.map((f) => _fenceCard(f, primary)),
          const SizedBox(height: 12),
          const Text('运行日志', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          if (_geo.logs.isEmpty)
            const Text('暂无日志', style: TextStyle(color: Colors.grey, fontSize: 12))
          else
            ..._geo.logs.reversed.map(
                (l) => Text(l, style: const TextStyle(fontSize: 12, color: Color(0xFF666666)))),
        ],
      ),
    );
  }

  Widget _switchCard(Color primary) {
    return Card(
      child: SwitchListTile(
        value: _geo.userEnabled,
        onChanged: (v) => _geo.setEnabled(v),
        activeTrackColor: primary,
        title: const Text('启用电子围栏'),
        subtitle: Text(
          _geo.userEnabled
              ? '检测间隔 ${_geo.checkInterval} 秒 | 命中自动切卡槽/上传卡片'
              : '检测间隔 ${_geo.checkInterval} 秒',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Widget _fenceCard(Geofence f, Color primary) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          radius: 6,
          backgroundColor: Color(f.colorValue),
        ),
        title: Text('${f.name}  →  卡槽 ${f.slotNumber}'),
        subtitle: Text(
            '${f.points.length} 个顶点 | ${f.cardLibraryMode ? '卡库模式·' : ''}${f.rollingCode ? '滚动码' : '普通'}',
            style: const TextStyle(fontSize: 12)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: f.enabled,
              onChanged: (v) => _geo.toggleFence(f.id, v),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') _editFence(f);
                if (v == 'delete') _deleteFence(f);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ========== 新增/编辑 ==========
  Future<void> _addFence() async {
    if (_geo.lastPosition == null) {
      _toast('暂无位置，请先启用电子围栏获取定位用于默认坐标');
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _FenceEditPage(provider: _geo, fence: null)),
    );
  }

  Future<void> _editFence(Geofence f) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _FenceEditPage(provider: _geo, fence: f)),
    );
  }

  Future<void> _deleteFence(Geofence f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除围栏'),
        content: Text('确定删除「${f.name}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) _geo.deleteFence(f.id);
  }

  Future<void> _setInterval() async {
    final ctrl = TextEditingController(text: '${_geo.checkInterval}');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('检测间隔（秒）'),
        content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text) ?? 30),
              child: const Text('确定')),
        ],
      ),
    );
    if (v != null && v >= 5) _geo.setCheckInterval(v);
  }

  Future<void> _toggleOverlay() async {
    if (_geo.overlayActive) {
      await FlutterOverlayWindow.closeOverlay();
      _geo.setOverlayActive(false);
      return;
    }
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    if (!granted) {
      final ok = await FlutterOverlayWindow.requestPermission();
      if (ok != true) {
        _toast('需要悬浮窗权限才能开启电子围栏悬浮窗');
        return;
      }
    }
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    await FlutterOverlayWindow.showOverlay(
      overlayTitle: '电子围栏',
      overlayContent: '正在监控围栏位置',
      enableDrag: true,
    );
    _geo.setOverlayActive(true);
  }
}

/// 围栏编辑页：名称/目标卡槽/顶点坐标 + 卡库卡选择
class _FenceEditPage extends StatefulWidget {
  final GeofenceProvider provider;
  final Geofence? fence;
  const _FenceEditPage({required this.provider, this.fence});

  @override
  State<_FenceEditPage> createState() => _FenceEditPageState();
}

class _FenceEditPageState extends State<_FenceEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _slot;
  late final List<TextEditingController> _lat;
  late final List<TextEditingController> _lng;
  late bool _cardLibraryMode;
  late bool _rollingCode;
  String? _icCardId;
  late int _colorValue;
  final MapController _mapController = MapController();

  List<LatLng> get _currentPoints {
    final pts = <LatLng>[];
    for (var i = 0; i < _lat.length; i++) {
      final lat = double.tryParse(_lat[i].text.trim());
      final lng = double.tryParse(_lng[i].text.trim());
      if (lat != null && lng != null) pts.add(LatLng(lat, lng));
    }
    return pts;
  }

  @override
  void initState() {
    super.initState();
    final f = widget.fence;
    _name = TextEditingController(text: f?.name ?? '新围栏');
    _slot = TextEditingController(text: '${f?.slotNumber ?? 1}');
    final pts = f?.points ??
        (widget.provider.lastPosition != null
            ? [widget.provider.lastPosition!]
            : [LatLng(0, 0)]);
    _lat = pts.map((p) => TextEditingController(text: p.latitude.toString())).toList();
    _lng = pts.map((p) => TextEditingController(text: p.longitude.toString())).toList();
    _cardLibraryMode = f?.cardLibraryMode ?? false;
    _rollingCode = f?.rollingCode ?? false;
    _icCardId = f?.icCardId;
    _colorValue = f?.colorValue ?? 0xFF2196F3;
  }

  void _addPoint() {
    setState(() {
      final p = widget.provider.lastPosition ?? LatLng(0, 0);
      _lat.add(TextEditingController(text: p.latitude.toString()));
      _lng.add(TextEditingController(text: p.longitude.toString()));
    });
  }

  void _removePoint(int i) {
    setState(() {
      _lat.removeAt(i);
      _lng.removeAt(i);
    });
  }

  Future<void> _pickCard() async {
    final cards = await CardLibraryStorage().getCards();
    if (!mounted) return;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择绑定的卡库卡片'),
        children: cards.isEmpty
            ? const [Padding(padding: EdgeInsets.all(20), child: Text('卡库为空'))]
            : cards
                .map((c) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, c.id),
                      child: Text('${c.name.isEmpty ? c.uid : c.name}  [${c.tag.label}]'),
                    ))
                .toList(),
      ),
    );
    if (name != null) setState(() => _icCardId = name);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final slot = int.tryParse(_slot.text.trim()) ?? 1;
    if (name.isEmpty) {
      _toast('请输入围栏名称');
      return;
    }
    if (slot < 1 || slot > 8) {
      _toast('卡槽号应在 1-8 之间');
      return;
    }
    final points = <LatLng>[];
    for (var i = 0; i < _lat.length; i++) {
      final lat = double.tryParse(_lat[i].text.trim());
      final lng = double.tryParse(_lng[i].text.trim());
      if (lat == null || lng == null) {
        _toast('请检查第 ${i + 1} 个顶点坐标');
        return;
      }
      points.add(LatLng(lat, lng));
    }
    if (points.length < 3) {
      _toast('围栏至少需要 3 个顶点');
      return;
    }
    final existing = widget.fence;
    if (existing != null) {
      widget.provider.updateFence(existing.copyWith(
        name: name,
        slotNumber: slot,
        points: points,
        colorValue: _colorValue,
        cardLibraryMode: _cardLibraryMode,
        icCardId: _cardLibraryMode ? _icCardId : null,
        rollingCode: _cardLibraryMode && _rollingCode,
      ));
    } else {
      widget.provider.addFence(Geofence(
        id: 'g${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}',
        name: name,
        label: name,
        slotNumber: slot,
        points: points,
        colorValue: _colorValue,
        cardLibraryMode: _cardLibraryMode,
        icCardId: _cardLibraryMode ? _icCardId : null,
        rollingCode: _cardLibraryMode && _rollingCode,
      ));
    }
    if (mounted) Navigator.pop(context);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.fence == null ? '新增围栏' : '编辑围栏')),
      backgroundColor: const Color(0xFFF5F6F8),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  TextField(controller: _name, decoration: const InputDecoration(labelText: '围栏名称')),
                  const SizedBox(height: 8),
                  TextField(
                      controller: _slot,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '目标卡槽（1-8）')),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('卡库模式'),
                        selected: _cardLibraryMode,
                        onSelected: (_) => setState(() => _cardLibraryMode = !_cardLibraryMode),
                      ),
                      if (_cardLibraryMode)
                        ChoiceChip(
                          label: const Text('滚动码'),
                          selected: _rollingCode,
                          onSelected: (_) => setState(() => _rollingCode = !_rollingCode),
                        ),
                      if (_cardLibraryMode)
                        ActionButton(
                          label: _icCardId == null ? '选择卡片' : '已选卡片',
                          icon: Icons.card_membership,
                          onTap: _pickCard,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('地图选点', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  const Text('点击地图添加顶点，拖动调整视角',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 260,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _currentPoints.isNotEmpty
                              ? _currentPoints.first
                              : (widget.provider.lastPosition ?? const LatLng(34.3416, 108.9398)),
                          initialZoom: 15,
                          onTap: (tapPos, latLng) {
                            setState(() {
                              _lat.add(TextEditingController(text: latLng.latitude.toString()));
                              _lng.add(TextEditingController(text: latLng.longitude.toString()));
                            });
                          },
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.z.nfc',
                          ),
                          if (_currentPoints.length >= 3)
                            PolygonLayer(
                              polygons: [
                                Polygon(
                                  points: _currentPoints,
                                  color: Color(_colorValue).withValues(alpha: 0.2),
                                  borderColor: Color(_colorValue),
                                  borderStrokeWidth: 2,
                                ),
                              ],
                            ),
                          MarkerLayer(
                            markers: [
                              for (final p in _currentPoints)
                                Marker(
                                  point: p,
                                  width: 24,
                                  height: 24,
                                  child: const Icon(Icons.location_on,
                                      color: Colors.blue, size: 24),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('围栏顶点', style: TextStyle(fontWeight: FontWeight.w600)),
                      ActionButton(
                          label: '添加顶点',
                          icon: Icons.add_location_alt,
                          onTap: _addPoint),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < _lat.length; i++)
                    Row(
                      children: [
                        SizedBox(
                          width: 150,
                          child: TextField(
                              controller: _lat[i],
                              keyboardType: TextInputType.numberWithOptions(decimal: true),
                              decoration: InputDecoration(labelText: '顶点${i + 1} 纬度')),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                              controller: _lng[i],
                              keyboardType: TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(labelText: '经度')),
                        ),
                        IconButton(
                          onPressed: () => _removePoint(i),
                          icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ActionButton(label: '保存围栏', icon: Icons.check, onTap: _save),
            ],
          ),
        ],
      ),
    );
  }
}