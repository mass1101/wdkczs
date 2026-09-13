import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// 电子围栏悬浮窗（对齐 CU overlay_window.dart）
class OverlayWindowApp extends StatefulWidget {
  const OverlayWindowApp({super.key});

  @override
  State<OverlayWindowApp> createState() => _OverlayWindowAppState();
}

class _OverlayWindowAppState extends State<OverlayWindowApp> {
  bool _connected = false;
  bool _monitoring = false;
  String _matchedFence = '';
  String _lastUpdate = '';
  String _lat = '';
  String _lng = '';
  String _uploadStatus = '';
  String _rollingCodeStatus = '';

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen(_onData);
    Future.delayed(const Duration(seconds: 1), () {
      FlutterOverlayWindow.shareData('overlay_ready');
    });
  }

  void _onData(dynamic data) {
    if (data == 'ping') {
      FlutterOverlayWindow.shareData('pong');
      return;
    }
    try {
      final map = jsonDecode(data as String) as Map<String, dynamic>;
      setState(() {
        _connected = map['connected'] as bool? ?? false;
        _monitoring = map['monitoring'] as bool? ?? false;
        _matchedFence = map['matchedFence'] as String? ?? '';
        _lastUpdate = map['lastUpdate'] as String? ?? '';
        _lat = map['lat'] as String? ?? '';
        _lng = map['lng'] as String? ?? '';
        _uploadStatus = map['uploadStatus'] as String? ?? '';
        _rollingCodeStatus = map['rollingCodeStatus'] as String? ?? '';
      });
    } catch (_) {}
  }

  void _onTap() {
    FlutterOverlayWindow.shareData('restore');
  }

  void _onClose() {
    FlutterOverlayWindow.shareData('close');
  }

  Widget _diagRow(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(color: color, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPos = _lat.isNotEmpty && _lng.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: _onTap,
        child: Container(
          width: 200,
          height: 220,
          decoration: BoxDecoration(
            color: const Color(0x4DC0C0C0),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white24, width: 1),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _connected ? Icons.link : Icons.link_off,
                    size: 12,
                    color: _connected ? Colors.greenAccent : Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _connected ? '设备已连接' : '设备未连接',
                    style: TextStyle(
                      color: _connected ? Colors.greenAccent : Colors.grey,
                      fontSize: 11,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _onClose,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _diagRow(
                _monitoring ? Icons.my_location : Icons.location_off,
                _lastUpdate.isNotEmpty ? '定位 $_lastUpdate' : '暂无定位',
                _lastUpdate.isNotEmpty ? Colors.blueAccent : Colors.grey,
              ),
              if (hasPos)
                _diagRow(
                  Icons.pin_drop,
                  '坐标 $_lat, $_lng',
                  Colors.blueGrey,
                ),
              _diagRow(
                _matchedFence.isNotEmpty ? Icons.fence : Icons.help_outline,
                _matchedFence.isNotEmpty ? '命中: $_matchedFence' : '未命中围栏',
                _matchedFence.isNotEmpty ? Colors.orangeAccent : Colors.grey,
              ),
              if (_uploadStatus.isNotEmpty)
                _diagRow(
                  _uploadStatus == '卡片上传成功'
                      ? Icons.check_circle
                      : Icons.error_outline,
                  _uploadStatus,
                  _uploadStatus == '卡片上传成功'
                      ? Colors.greenAccent
                      : Colors.redAccent,
                ),
              if (_rollingCodeStatus.isNotEmpty)
                _diagRow(
                  Icons.sync,
                  _rollingCodeStatus,
                  Colors.tealAccent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}