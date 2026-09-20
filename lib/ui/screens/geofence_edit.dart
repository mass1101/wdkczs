import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../models/enums.dart';
import '../../services/card_library.dart';
import '../../services/geofence.dart';
import '../../services/geofence_provider.dart';
import '../../helpers/coordinate_converter.dart';

/// 围栏编辑页：全屏地图 + 表单
/// （严格对齐 CU geofence_edit.dart，纯在线高德瓦片，无离线底图增强）
class FenceEditPage extends StatefulWidget {
  final GeofenceProvider provider;
  final Geofence? fence;

  const FenceEditPage({
    super.key,
    required this.provider,
    this.fence,
  });

  @override
  State<FenceEditPage> createState() => _FenceEditPageState();
}

class _FenceEditPageState extends State<FenceEditPage> {
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
    // 同步缓存卡包，供 _selectedICCard/_selectedIDCard 同步查询
    // （CU 用同步 SharedPreferences，这里用一次性缓存等价实现）
    CardLibraryStorage().getCards().then((cards) {
      if (mounted && cards.isNotEmpty) {
        setState(() => _libraryCards = cards);
      }
    });
    if (widget.fence == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _locateMe());
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _labelController.dispose();
    _mapController.dispose();
    super.dispose();
  }

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
          LatLng(position.latitude, position.longitude));
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
      _toast('卡包为空，请先添加卡片');
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
                    backgroundColor: const Color(0xFFE0E0E0),
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
                    TileLayer(
                      urlTemplate: _useSatellite
                          ? 'https://webst0{s}.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}'
                          : 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                      subdomains: const ['1', '2', '3', '4'],
                      userAgentPackageName: 'com.z.wgkczs',
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
                      '卡包模式',
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
                          '刷卡后数据自动同步回卡包',
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
                    onChanged: (v) {
                      setState(() => _rollingCode = v);
                    },
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

/// 卡包卡片选择对话框（对齐 CU showSearch + CardSearchDelegate：
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
