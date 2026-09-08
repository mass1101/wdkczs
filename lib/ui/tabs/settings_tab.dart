import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/enums.dart';
import '../../services/device_service.dart';
import '../../services/log_service.dart';
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

  // ========== 云端设置 ==========
  Future<void> _showCloudSettings() async {
    final controller = TextEditingController(text: '');
    final ep = await _app.cloud.getCloudEndpoint();
    controller.text = ep;
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('云端服务地址', style: TextStyle(fontSize: 16)),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              final val = controller.text.trim();
              if (val.isNotEmpty) {
                await _app.storage.setCloudEndpoint(val);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
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
                        _infoRow('固件版本', info.version.isEmpty ? '--' : info.version),
                        _infoRow('Git 版本', info.gitVersion.isEmpty ? '--' : info.gitVersion),
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
                        _infoRow('云端服务', '点击设置', onTap: _showCloudSettings),
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
  late final PageController _controller;
  var _current = 0;
  // 每槽两个独立别名输入框：ID 别名(lf/freq1) 与 IC 别名(hf/freq2)
  final _idNameCtrls = List.generate(8, (_) => TextEditingController());
  final _icNameCtrls = List.generate(8, (_) => TextEditingController());

  AppController get _app => widget.app;
  DeviceService get _dev => _app.device;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
    for (var i = 0; i < 8; i++) {
      _idNameCtrls[i].text = _app.slotNames[i].$2 ?? '';
      _icNameCtrls[i].text = _app.slotNames[i].$1 ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    for (final c in _idNameCtrls) {
      c.dispose();
    }
    for (final c in _icNameCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _loadNamesIntoCtrls() {
    for (var i = 0; i < 8; i++) {
      _idNameCtrls[i].text = _app.slotNames[i].$2 ?? '';
      _icNameCtrls[i].text = _app.slotNames[i].$1 ?? '';
    }
  }

  void _syncNames() {
    for (var i = 0; i < 8; i++) {
      final id = _idNameCtrls[i].text.trim();
      final ic = _icNameCtrls[i].text.trim();
      _app.slotNames[i] =
          (ic.isEmpty ? null : ic, id.isEmpty ? null : id);
    }
  }

  /// 读取当前卡槽设置（对齐小程序 btnLoadSlot）
  Future<void> _readSlot(int slot) async {
    try {
      if (!_app.connected) throw Exception('设备未连接');
      await _app.loadEnabledSlots();
      await _dev.cmdSlotSetActive(slot);
      _app.currentSlot = slot;
      await _app.loadSlotEmuSettings(slot);
      _loadNamesIntoCtrls();
      setState(() {});
    } catch (e) {
      _toast('卡槽 ${slot + 1} 读取设置失败: $e');
    }
  }

  /// 保存当前卡槽设置（对齐小程序 btnSaveSlot）
  Future<void> _saveSlot(int slot) async {
    try {
      if (!_app.connected) throw Exception('设备未连接');
      _syncNames();
      await _dev.cmdSlotSetActive(slot);
      _app.currentSlot = slot;
      final (hf, lf) = _app.enabledSlots[slot];
      final s = _app.slotEmuSettings[slot];
      await _dev.cmdSlotSetEnable(slot, 1, lf);
      await _dev.cmdSlotSetEnable(slot, 2, hf);
      final hfName = _app.slotNames[slot].$1;
      final lfName = _app.slotNames[slot].$2;
      if (hfName != null && hfName.isNotEmpty) {
        await _dev.cmdSlotSetFreqName(slot, 2, hfName);
      }
      if (lfName != null && lfName.isNotEmpty) {
        await _dev.cmdSlotSetFreqName(slot, 1, lfName);
      }
      if (hf) {
        await _dev.cmdMf1SetAntiCollMode(s.antiColl);
        await _dev.cmdMf1SetDetectionEnable(s.detection);
        await _dev.cmdMf1SetGen1aMode(s.gen1a);
        await _dev.cmdMf1SetGen2Mode(s.gen2);
        await _dev.cmdMf1SetWriteMode(s.write);
      }
      await _dev.cmdSlotSaveSettings();
      _toast('卡槽 ${slot + 1} 设置已保存');
    } catch (e) {
      _toast('卡槽 ${slot + 1} 保存失败: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.68,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('卡槽设置',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            // 顶部指示点：左右滑动切换卡槽
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('卡槽 ${_current + 1} / 8（左右滑动切换）',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF999999))),
            ),
            const Divider(height: 1),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: 8,
                onPageChanged: (i) => setState(() => _current = i),
                itemBuilder: (_, i) => _buildSlotPanel(i, primary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 单个卡槽面板：顶部读取/保存，内容 ID/IC 功能+别名 与 mf1 配置
  Widget _buildSlotPanel(int i, Color primary) {
    final s = _app.slotEmuSettings[i];
    final (hf, lf) = _app.enabledSlots[i];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('卡槽 ${i + 1}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
              ),
              ActionButton(
                  label: '读取',
                  icon: Icons.download,
                  color: primary,
                  onTap: () => _readSlot(i)),
              const SizedBox(width: 8),
              ActionButton(
                  label: '保存',
                  icon: Icons.save,
                  color: primary,
                  onTap: () => _saveSlot(i)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            children: [
              _freqRow('ID功能', lf, (v) {
                setState(() => _app.enabledSlots[i] = (hf, v));
              }, primary),
              _nameRow('ID别名', _idNameCtrls[i], (v) {
                _app.slotNames[i] = (_app.slotNames[i].$1, v);
              }),
              _freqRow('IC功能', hf, (v) {
                setState(() => _app.enabledSlots[i] = (v, lf));
              }, primary),
              _nameRow('IC别名', _icNameCtrls[i], (v) {
                _app.slotNames[i] = (v, _app.slotNames[i].$2);
              }),
              const Divider(height: 8),
              _switchRow('侦测功能', s.detection, (v) {
                _app.updateSlotEmu(i, detection: v);
              }, primary),
              _switchRow('防冲突', s.antiColl, (v) {
                _app.updateSlotEmu(i, antiColl: v);
              }, primary),
              _dropdownRowInt('UID功能', s.gen1a ? 1 : 0, const [0, 1],
                  (v) => v == 0 ? '关闭UID功能' : '开启UID功能', (v) {
                _app.updateSlotEmu(i, gen1a: v == 1);
              }),
              _dropdownRowInt('CUID功能', s.gen2 ? 1 : 0, const [0, 1],
                  (v) => v == 0 ? '关闭CUID功能' : '开启CUID功能', (v) {
                _app.updateSlotEmu(i, gen2: v == 1);
              }),
              const Divider(height: 8),
              _dropdownRowInt('写卡模式', s.write, const [0, 1, 2, 3], _writeModeLabel,
                  (v) {
                _app.updateSlotEmu(i, write: v);
              }),
              const SizedBox(height: 12),
              ActionButton(
                  label: '保存当前卡槽',
                  icon: Icons.save,
                  color: primary,
                  onTap: () => _saveSlot(i)),
            ],
          ),
        ),
      ],
    );
  }

  String _writeModeLabel(int m) {
    switch (m) {
      case 0:
        return '关闭滚动功能';
      case 1:
        return '拒绝写入数据';
      case 2:
        return '立即复原数据';
      case 3:
        return '下次复原数据';
      default:
        return '关闭滚动功能';
    }
  }

  /// ID/IC 功能开关行
  Widget _freqRow(String label, bool value, ValueChanged<bool> onChanged, Color primary) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
              width: 72,
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)))),
          const Spacer(),
          Switch(value: value, activeThumbColor: primary, onChanged: onChanged),
        ],
      ),
    );
  }

  /// 别名输入行
  Widget _nameRow(String label, TextEditingController ctrl, ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
              width: 72,
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)))),
          Expanded(
            child: TextField(
              controller: ctrl,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(6))),
              ),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  /// 布尔开关行
  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged, Color primary) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
              width: 72,
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)))),
          const Spacer(),
          Switch(value: value, activeThumbColor: primary, onChanged: onChanged),
        ],
      ),
    );
  }

  /// 整数下拉行
  Widget _dropdownRowInt(String label, int value, List<int> options,
      String Function(int) itemLabel, ValueChanged<int> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
              width: 72,
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)))),
          Expanded(
            child: DropdownButton<int>(
              value: options.contains(value) ? value : options.first,
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
              icon: const Icon(Icons.arrow_drop_down, color: Color(0xFFBBBBBB)),
              items: options
                  .map((o) => DropdownMenuItem(
                      value: o,
                      child: Text(itemLabel(o),
                          style: const TextStyle(fontSize: 13))))
                  .toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}
