import 'package:flutter/material.dart';

import '../main.dart';
import '../state/app_controller.dart';
import '../ui/tabs/ic_tab.dart';
import '../ui/tabs/id_tab.dart';
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

  @override
  void initState() {
    super.initState();
    _app = AppScope.instance.controller;
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      _app.setTab(_tabController.index);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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

  void _showAbout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关于 NFC Tool'),
        content: const Text(
          'NFC Tool\n\n'
          '适用于 Chameleon Ultra / CU- 系列读卡器\n'
          '支持 IC 卡（MIFARE Classic）读写破解与 ID 卡（EM4100/HID）模拟。\n\n'
          '仅用于学习与研究目的，请遵守当地法律法规。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于'),
              onTap: () {
                Navigator.pop(ctx);
                _showAbout();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('云端设置'),
              onTap: () {
                Navigator.pop(ctx);
                _showCloudSettings();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('退出应用'),
              onTap: () => Navigator.pop(ctx),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showCloudSettings() {
    final controller = TextEditingController(text: '');
    AppScope.instance.controller.cloud.getCloudEndpoint().then((ep) {
      controller.text = ep;
    });
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('云端服务地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'https://...',
                labelText: '云端 API 地址',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '默认使用作者提供的云端服务。可修改为自建后端。',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final ep = controller.text.trim();
              if (ep.isNotEmpty) {
                await AppScope.instance.controller.storage.setCloudEndpoint(ep);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Column(
        children: [
          // 蓝底标题栏 + 胶囊按钮
          Container(
            decoration: BoxDecoration(
              color: primary,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(0)),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text(
                        'NFC Tool',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    // 胶囊按钮（…/×）
                    _CapsuleButton(
                      icon: Icons.more_horiz,
                      onTap: _showMenu,
                    ),
                    const SizedBox(width: 6),
                    _CapsuleButton(
                      icon: Icons.close,
                      onTap: _showAbout,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 连接横幅
          ConnectionBanner(
            connected: _app.connected,
            deviceName: _app.ble.device?.platformName,
            onConnect: _connect,
            onDisconnect: _connect,
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

/// 标题栏胶囊按钮
class _CapsuleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _CapsuleButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 24,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }
}
