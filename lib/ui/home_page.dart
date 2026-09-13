import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import '../main.dart';
import '../state/app_controller.dart';
import '../ui/tabs/ic_tab.dart';
import '../ui/tabs/id_tab.dart';
import '../ui/tabs/library_tab.dart';
import '../ui/tabs/settings_tab.dart';
import 'widgets/common.dart';

/// 主框架：蓝底标题栏 + 胶囊按钮、三 Tab（IC卡/ID卡/设置）、右下角 FAB
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  late final AppController _app;
  late final TabController _tabController;
  bool _discovering = false;
  StreamSubscription<dynamic>? _overlaySub;

  @override
  void initState() {
    super.initState();
    _app = AppScope.instance.controller;
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      _app.setTab(_tabController.index);
    });
    _overlaySub = FlutterOverlayWindow.overlayListener.listen(_onOverlayEvent);
  }

  @override
  void dispose() {
    _overlaySub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _onOverlayEvent(dynamic event) {
    if (event == 'restore' || event == 'close') {
      FlutterOverlayWindow.closeOverlay();
      if (!mounted) return;
      _app.geofence.setOverlayActive(false);
      _tabController.animateTo(2);
    } else if (event is Map) {
      final type = event['type'];
      if (type == 'overlay_error' || type == 'overlay_info') {
        final msg = event['message']?.toString() ?? 'unknown error';
        try {
          _app.geofence
              .addLog('悬浮窗${type == 'overlay_error' ? '错误' : '信息'}: $msg');
        } catch (_) {}
      }
    }
  }

  Future<void> _connect() async {
    if (_discovering) return;
    setState(() => _discovering = true);
    try {
      if (_app.connected) {
        await _app.disconnect();
        _toast('已断开连接');
        return;
      }
      final device = await _app.scanAndPick();
      if (device == null) {
        _toast('未选择设备');
        return;
      }
      await _app.connect(device);
      if (mounted) _toast('连接成功');
    } catch (e) {
      if (mounted) _toast('连接失败:\n$e');
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
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
      backgroundColor: AppTheme.bg,
      body: Column(
        children: [
          // 应用标题
          Container(
            color: primary,
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Transform.translate(
                offset: const Offset(0, 5),
                child: Text('NFCAPP',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ),
          // TabBar
          Container(
            color: Colors.white,
            child: TabBar(
              controller: _tabController,
              indicatorColor: primary,
              indicatorSize: TabBarIndicatorSize.label,
              labelColor: primary,
              unselectedLabelColor: const Color(0xFF666666),
              labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              tabs: const [
                Tab(text: 'IC卡'),
                Tab(text: 'ID卡'),
                Tab(text: '卡库'),
                Tab(text: '设置'),
              ],
            ),
          ),
          // 内容区
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                IcTab(),
                IdTab(),
                LibraryTab(),
                SettingsTab(),
              ],
            ),
          ),
        ],
      ),
      // 右下角蓝色 FAB
      floatingActionButton: FloatingActionButton(
        onPressed: _discovering ? null : _connect,
        backgroundColor: primary,
        foregroundColor: Colors.white,
        child: _discovering
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.white),
              )
            : Icon(
                _app.connected ? Icons.link : Icons.bluetooth,
                size: 26,
              ),
      ),
    );
  }
}
