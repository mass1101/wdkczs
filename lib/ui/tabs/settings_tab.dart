import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../main.dart';
import '../../models/enums.dart';
import '../../services/device_service.dart';
import '../../services/log_service.dart';
import '../../state/app_controller.dart';
import '../screens/card_subscription_screen.dart';
import '../screens/fence_subscription_screen.dart';
import '../widgets/common.dart';

/// 设置 Tab：设备信息、全局设置、右侧操作按钮
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  AppController get _app => AppScope.instance.controller;
  DeviceService get _dev => _app.device;
  String? _cloudFirmwareVersion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _loadCloudFirmwareVersion();
    });
  }

  Future<void> _loadCloudFirmwareVersion() async {
    try {
      final resp = await http
          .get(Uri.parse(
              'https://raw.giteeusercontent.com/zzx1101/JL-version/raw/master/80lx-version.json'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return;
      final lines = resp.body.split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('version:')) {
          final v = trimmed.substring('version:'.length).trim();
          if (mounted) setState(() => _cloudFirmwareVersion = v);
          return;
        }
      }
    } catch (_) {}
  }

  Future<void> _refresh() async {
    try {
      await _app.loadDeviceSettings();
      await _app.loadEnabledSlots();
      final active = await _dev.cmdSlotGetActive();
      _app.currentSlot = active;
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  // ========== 全局设置 ==========
  Future<void> _saveSettings() async {
    try {
      final s = _app.settings;
      await _dev.cmdSetAnimationMode(s.animation);
      await _dev.cmdSetButtonPressAction(0, s.pressBtnA);
      await _dev.cmdSetButtonPressAction(1, s.pressBtnB);
      await _dev.cmdSetButtonLongPressAction(0, s.longPressBtnA);
      await _dev.cmdSetButtonLongPressAction(1, s.longPressBtnB);
      if (s.blePairing) {
        await _dev.cmdBleSetPairingMode(true);
        if (s.blePairingKey != '0000') {
          await _dev.cmdBleSetPairingKey(s.blePairingKey);
        }
      } else {
        await _dev.cmdBleSetPairingMode(false);
      }
      await _dev.cmdSlotSaveSettings();
      _toast('设置已保存');
    } catch (e) {
      _toast('保存失败: $e');
    }
  }

  Future<void> _resetSettings() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复出厂设置', style: TextStyle(fontSize: 16)),
        content: const Text('将清除所有卡槽数据与配置，确定继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _dev.cmdResetSettings();
      _toast('已恢复出厂设置');
      await _refresh();
    } catch (e) {
      _toast('操作失败: $e');
    }
  }

  Future<void> _wipeFds() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除模拟卡数据', style: TextStyle(fontSize: 16)),
        content: const Text('将清除所有模拟卡槽的扇区数据，确定继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _dev.cmdWipeFds();
      _toast('已清除');
    } catch (e) {
      _toast('操作失败: $e');
    }
  }

  Future<void> _deleteBonds() async {
    try {
      await _dev.cmdBleDeleteAllBonds();
      _toast('已清除蓝牙配对信息');
    } catch (e) {
      _toast('操作失败: $e');
    }
  }

  // ========== 固件刷写 ==========
  Future<void> _dfuUpdate() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('固件刷写', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请输入固件包 zip 的下载地址\n（nRF DFU 格式，含 manifest.json）',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'https://.../firmware.zip',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('开始刷写'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    if (!_app.connected) {
      _toast('设备未连接');
      return;
    }
    try {
      // 进入 DFU 模式
      await _dev.cmdDfuEnter();
      _toast('已进入 DFU 模式，正在连接 bootloader...');
      // bootloader 重连由扫描选择
      final found = await _app.ble.scan(timeout: const Duration(seconds: 8));
      final target = found.firstWhere(
        (d) {
          final n = d.platformName;
          return n.isNotEmpty && (n.contains('DFU') || n.contains('CU-'));
        },
        orElse: () => found.isNotEmpty ? found.first : (throw Exception('未发现 DFU 设备，请确认设备已重启到 bootloader')),
      );
      await _app.ble.connect(target);

      // 刷写
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const AlertDialog(
          title: Text('固件刷写中...', style: TextStyle(fontSize: 16)),
          content: Text('正在传输固件，请勿断开设备'),
        ),
      );
      try {
        await _app.dfuUpdateFromUrl(url);
      } finally {
        if (mounted) Navigator.of(context).pop();
      }
      _toast('刷写成功，设备将自动重启');
    } catch (e) {
      _toast('刷写失败: $e');
    }
  }

  // ========== 配对密钥编辑 ==========
  Future<void> _editPairingKey() async {
    final controller = TextEditingController(text: _app.settings.blePairingKey);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('配对密钥', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(hintText: '6 位数字'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      _app.setBlePairingKey(result);
      _toast('已设置配对密钥');
    }
  }

  // ========== 订阅入口（弹窗显示） ==========
  Future<void> _showFenceSubscription() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (_) => Dialog.fullscreen(child: const FenceSubscriptionScreen()),
    );
  }

  Future<void> _showCardSubscription() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (_) => Dialog.fullscreen(child: const CardSubscriptionScreen()),
    );
  }

  /// 查看日志
  void _showLogs() {
    final logs = LogService.instance.logs;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Text('调试日志', style: TextStyle(fontSize: 16)),
            const Spacer(),
            TextButton(
              onPressed: () async {
                final allLogs = logs.join('\n');
                await Clipboard.setData(ClipboardData(text: allLogs));
                if (mounted) {
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(SnackBar(content: const Text('已复制全部日志'), duration: const Duration(seconds: 2)));
                }
              },
              child: const Text('复制全部'),
            ),
            TextButton(
              onPressed: () {
                LogService.instance.clear();
                Navigator.pop(ctx);
                _showLogs();
              },
              child: const Text('清除'),
            ),
          ],
        ),
        content: SizedBox(
          width: 400,
          height: 500,
          child: logs.isEmpty
              ? const Center(child: Text('暂无日志'))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (_, i) => SelectableText(
                    logs[i],
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ========== UI ==========
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: _app,
      builder: (context, _) {
        final info = _app.deviceInfo;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  // 设备信息
                  SectionCard(
                    title: '设备信息',
                    child: Column(
                      children: [
                        _infoRow('云端固件版本', _cloudFirmwareVersion ?? '加载中...'),
                        _infoRow('固件版本', info.version.isEmpty ? '--' : info.version),
                        _infoRow('芯片编号', info.chipId.isEmpty ? '--' : info.chipId),
                        _infoRow('蓝牙地址', info.bleAddress.isEmpty ? '--' : info.bleAddress),
                        _infoRow('电量',
                            info.batteryLevel < 0 ? '--' : '${info.batteryLevel}%'),
                      ],
                    ),
                  ),
                  // 全局设置
                  SectionCard(
                    title: '全局设置',
                    child: Column(
                      children: [
                        _dropdownRow<bool>('蓝牙配对', _app.settings.blePairing,
                            const [false, true], (v) => v ? '需要密码' : '无需密码',
                            _app.setBlePairing),
                        _infoRow('蓝牙密码', _app.settings.blePairingKey,
                            onTap: _editPairingKey),
                        _animationRow(),
                        _actionRow('短按按钮A', _app.settings.pressBtnA, (v) {
                          _app.setPressBtnA(v);
                        }),
                        _actionRow('短按按钮B', _app.settings.pressBtnB, (v) {
                          _app.setPressBtnB(v);
                        }),
                        _actionRow('长按按钮A', _app.settings.longPressBtnA, (v) {
                          _app.setLongPressBtnA(v);
                        }),
                        _actionRow('长按按钮B', _app.settings.longPressBtnB, (v) {
                          _app.setLongPressBtnB(v);
                        }),
                      ],
                    ),
                  ),
                  // 调试日志
                    SectionCard(
                      title: '调试',
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '查看应用调试日志',
                            style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
                          ),
                          ActionButton(
                            label: '查看日志',
                            icon: Icons.article,
                            color: primary,
                            onTap: _showLogs,
                          ),
                        ],
                      ),
                    ),
                    // 关于
                  SectionCard(
                    title: '关于',
                    child: Column(
                      children: [
                        _infoRow('应用名称', 'NFC Tool'),
                        _infoRow('适用设备', 'Chameleon Ultra / CU- 系列'),
                        const SizedBox(height: 8),
                        const Text(
                          '仅用于学习与研究目的，请遵守当地法律法规。',
                          style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 右侧按钮
            Container(
              width: 96,
              margin: const EdgeInsets.fromLTRB(0, 8, 6, 0),
              child: Column(
                children: [
                  _sideBtn('读取设置', Icons.download, _refresh, primary),
                  _sideBtn('保存设置', Icons.save, _saveSettings, primary),
                  _sideBtn('恢复出厂', Icons.refresh, _resetSettings, primary),
                  _sideBtn('清除数据', Icons.cleaning_services, _wipeFds, primary),
                  _sideBtn('清除配对', Icons.link_off, _deleteBonds, primary),
                  _sideBtn('固件刷写', Icons.system_update_alt, _dfuUpdate, primary),
                  _sideBtn('围栏订阅', Icons.fence, _showFenceSubscription, primary),
                  _sideBtn('卡片订阅', Icons.credit_card, _showCardSubscription, primary),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sideBtn(String label, IconData icon, VoidCallback? onTap, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ActionButton(
          label: label,
          icon: icon,
          color: color,
          onTap: onTap,
          enabled: _app.connected || label == '保存设置'),
    );
  }

  Widget _infoRow(String label, String value, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
                width: 72,
                child: Text(label,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF666666)))),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF333333))),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right, size: 16, color: Color(0xFFBBBBBB)),
          ],
        ),
      ),
    );
  }

  /// 下拉选择行：label + 下拉菜单（value 默认显示读取到的当前选项）
  Widget _dropdownRow<T>(String label, T value, List<T> options,
      String Function(T) itemLabel, ValueChanged<T> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
              width: 72,
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)))),
          Expanded(
            child: DropdownButton<T>(
              value: value,
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: const TextStyle(
                  fontSize: 13, color: Color(0xFF333333)),
              icon: const Icon(Icons.arrow_drop_down,
                  color: Color(0xFFBBBBBB)),
              items: options.map((o) => DropdownMenuItem(
                    value: o,
                    child: Text(itemLabel(o),
                        style: const TextStyle(fontSize: 13)),
                  )).toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 动画模式下拉
  Widget _animationRow() {
    return _dropdownRow<AnimationMode>(
      '动画模式',
      _app.settings.animation,
      AnimationMode.values,
      (m) => m.label,
      _app.setAnimationMode,
    );
  }

  /// 按钮动作下拉（短按/长按按钮A/B）
  Widget _actionRow(String label, ButtonAction value, ValueChanged<ButtonAction> onChanged) {
    return _dropdownRow<ButtonAction>(
      label,
      value,
      ButtonAction.values,
      (a) => a.label,
      onChanged,
    );
  }
}

