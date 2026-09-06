import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/enums.dart';
import '../../services/device_service.dart';
import '../../state/app_controller.dart';
import '../widgets/common.dart';

/// 设置 Tab：设备信息、全局设置、右侧操作按钮、卡槽设置
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  AppController get _app => AppScope.instance.controller;
  DeviceService get _dev => _app.device;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
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

  Future<void> _showSlotSettings() async {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      builder: (ctx) => _SlotSettingsSheet(app: _app),
    );
  }

  Future<void> _saveSlots() async {
    try {
      for (var i = 0; i < 8; i++) {
        final (hf, lf) = _app.enabledSlots[i];
        await _dev.cmdSlotSetEnable(i, 2, hf);
        await _dev.cmdSlotSetEnable(i, 1, lf);
        final hfName = _app.slotNames[i].$1;
        final lfName = _app.slotNames[i].$2;
        if (hfName != null && hfName.isNotEmpty) {
          await _dev.cmdSlotSetFreqName(i, 2, hfName);
        }
        if (lfName != null && lfName.isNotEmpty) {
          await _dev.cmdSlotSetFreqName(i, 1, lfName);
        }
      }
      await _dev.cmdSlotSaveSettings();
      _toast('卡槽配置已保存');
    } catch (e) {
      _toast('保存失败: $e');
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

  // ========== 读取卡槽（仅刷新卡槽相关） ==========
  Future<void> _readSlotsOnly() async {
    try {
      await _app.loadEnabledSlots();
      final active = await _dev.cmdSlotGetActive();
      _app.currentSlot = active;
      _toast('已读取卡槽配置');
    } catch (e) {
      _toast('读取卡槽失败: $e');
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
                        _infoRow('固件版本', info.version.isEmpty ? '--' : info.version),
                        _infoRow('Git 版本', info.gitVersion.isEmpty ? '--' : info.gitVersion),
                        _infoRow('芯片编号', info.chipId.isEmpty ? '--' : info.chipId),
                        _infoRow('蓝牙地址', info.bleAddress.isEmpty ? '--' : info.bleAddress),
                        _infoRow('设备型号', info.model.isEmpty ? '--' : info.model),
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
                        _switchRow('蓝牙配对',
                            _app.settings.blePairing, (v) {
                          _app.setBlePairing(v);
                        }),
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
                        _switchRow('恢复出厂设置', false, (v) {}),
                      ],
                    ),
                  ),
                  // 卡槽设置入口
                  SectionCard(
                    title: '卡槽设置',
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '当前卡槽：卡槽${_app.currentSlot + 1}',
                          style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
                        ),
                        ActionButton(
                          label: '卡槽设置',
                          icon: Icons.tune,
                          color: primary,
                          onTap: _showSlotSettings,
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
                  _sideBtn('读取卡槽', Icons.memory, _readSlotsOnly, primary),
                  _sideBtn('保存设置', Icons.save, _saveSettings, primary),
                  _sideBtn('恢复出厂', Icons.refresh, _resetSettings, primary),
                  _sideBtn('清除数据', Icons.cleaning_services, _wipeFds, primary),
                  _sideBtn('清除配对', Icons.link_off, _deleteBonds, primary),
                  _sideBtn('固件刷写', Icons.system_update_alt, _dfuUpdate, primary),
                  _sideBtn('卡槽设置', Icons.tune, _showSlotSettings, primary),
                  _sideBtn('保存卡槽', Icons.save, _saveSlots, primary),
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

  Widget _animationRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(
              width: 72,
              child: Text('动画模式',
                  style: TextStyle(fontSize: 13, color: Color(0xFF666666)))),
          Expanded(
            child: Wrap(
              spacing: 6,
              children: AnimationMode.values.map((m) {
                final selected = _app.settings.animation == m;
                return ChoiceChip(
                  label: Text(m.label,
                      style: const TextStyle(fontSize: 12)),
                  selected: selected,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => _app.setAnimationMode(m),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(String label, ButtonAction value, ValueChanged<ButtonAction> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
              width: 72,
              child: Text('',
                  style: TextStyle(fontSize: 13, color: Color(0xFF666666)))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF666666))),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: ButtonAction.values.map((a) {
                    final selected = value == a;
                    return ChoiceChip(
                      label: Text(a.label,
                          style: const TextStyle(fontSize: 12)),
                      selected: selected,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => onChanged(a),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF333333))),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// 卡槽设置底部弹窗
class _SlotSettingsSheet extends StatefulWidget {
  final AppController app;
  const _SlotSettingsSheet({required this.app});

  @override
  State<_SlotSettingsSheet> createState() => _SlotSettingsSheetState();
}

class _SlotSettingsSheetState extends State<_SlotSettingsSheet> {
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('卡槽设置',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: 8,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 56,
                        child: Text('卡槽${i + 1}',
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFF666666))),
                      ),
                      _slotChip('HF', widget.app.enabledSlots[i].$1, (v) {
                        setState(() {
                          widget.app.enabledSlots[i] = (v, widget.app.enabledSlots[i].$2);
                        });
                      }),
                      const SizedBox(width: 8),
                      _slotChip('LF', widget.app.enabledSlots[i].$2, (v) {
                        setState(() {
                          widget.app.enabledSlots[i] = (widget.app.enabledSlots[i].$1, v);
                        });
                      }),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: TextEditingController(
                              text: widget.app.slotNames[i].$1 ?? ''),
                          style: const TextStyle(fontSize: 12),
                          decoration: InputDecoration(
                            hintText: '名称',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                vertical: 6, horizontal: 8),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6)),
                          ),
                          onChanged: (v) {
                            widget.app.slotNames[i] = (v.isEmpty ? null : v,
                                widget.app.slotNames[i].$2);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ActionButton(
                      label: '关闭',
                      icon: Icons.close,
                      color: Colors.grey,
                      onTap: () => Navigator.pop(context)),
                  const SizedBox(width: 8),
                  ActionButton(
                      label: '保存',
                      icon: Icons.save,
                      color: primary,
                      onTap: () async {
                        for (var i = 0; i < 8; i++) {
                          await widget.app.device
                              .cmdSlotSetEnable(i, 2, widget.app.enabledSlots[i].$1);
                          await widget.app.device
                              .cmdSlotSetEnable(i, 1, widget.app.enabledSlots[i].$2);
                        }
                        if (context.mounted) Navigator.pop(context);
                      }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slotChip(String label, bool selected, ValueChanged<bool> onChanged) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      visualDensity: VisualDensity.compact,
      onSelected: onChanged,
    );
  }
}
