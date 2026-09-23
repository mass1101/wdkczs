import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../helpers/activation.dart';
import '../../main.dart';
import '../../models/enums.dart';
import '../../services/device_service.dart';
import '../../services/log_service.dart';
import '../../state/app_controller.dart';
import '../screens/card_subscription_screen.dart';
import '../widgets/common.dart';
import '../widgets/qr_code_scanner.dart';

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
  String _chipId = '';
  late final TextEditingController _activationCodeController = TextEditingController();
  late final TextEditingController _pollingDelayController = TextEditingController();
  int? _pollingDelay;
  bool _pollingEnabled = false;
  bool _pollingAdaptive = false;
  List<bool> _pollingSlots = List.filled(80, false);

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
      if (mounted) setState(() => _chipId = _app.deviceInfo.chipId);
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
      // ButtonType: A=65, B=66（对齐固件 ASCII ord，CU ButtonType.a(65)/b(66)）
      await _dev.cmdSetButtonPressAction(65, s.pressBtnA);
      await _dev.cmdSetButtonPressAction(66, s.pressBtnB);
      await _dev.cmdSetButtonLongPressAction(65, s.longPressBtnA);
      await _dev.cmdSetButtonLongPressAction(66, s.longPressBtnB);
      if (s.blePairing) {
        await _dev.cmdBleSetPairingMode(true);
        if (s.blePairingKey != '0000') {
          await _dev.cmdBleSetPairingKey(s.blePairingKey);
        }
      } else {
        await _dev.cmdBleSetPairingMode(false);
      }
      await _dev.cmdSaveSettings();
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
      await _dev.cmdFactoryReset();
      _toast('已恢复出厂设置');
      await _app.disconnect();
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

  // ========== 固件刷写（对齐 CU flashFile 流程） ==========
  static const _firmwareUrls = [
    'https://raw.giteeusercontent.com/zzx1101/JL-version/raw/master/80LXWL-dfu-full.zip',
  ];

  Future<void> _dfuUpdate() async {
    if (!_app.connected) {
      _toast('设备未连接');
      return;
    }
    await _performDfuFlash(
      title: '正在下载固件...',
      prepare: () => _app.dfuDownloadAndParse(_firmwareUrls),
    );
  }

  Future<void> _dfuUpdateFromLocal() async {
    if (!_app.connected) {
      _toast('设备未连接');
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: '选择固件包',
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final zipBytes = Uint8List.fromList(await File(file.path!).readAsBytes());
    await _performDfuFlash(
      title: '正在准备本地固件...',
      prepare: () async => _app.dfuParseFile(zipBytes),
    );
  }

  /// 执行 DFU 刷写流程（对齐 CU flashFile）
  /// 顺序：下载+解析+校验 → enterDFU → disconnect → 扫描 → 连接 → 禁重连 → 刷写
  Future<void> _performDfuFlash({
    required String title,
    required Future<({Uint8List header, Uint8List body})> Function() prepare,
  }) async {
    if (!mounted) return;
    final dfuKey = GlobalKey<_DfuDialogState>();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return _DfuDialog(key: dfuKey, title: title);
      },
    );

    try {
      // 0. 下载 + 解析 + 校验（进 DFU 之前完成，避免 bootloader 期间下载断连）
      final image = await prepare();

      // 1. 进入 DFU 模式
      dfuKey.currentState?.setStage('正在进入 DFU 模式...');
      await _dev.cmdDfuEnter();

      // 2. 断开当前连接
      dfuKey.currentState?.setStage('正在断开连接...');
      await _app.ble.disconnect();

      // 3. Android 延迟（BLE 比 USB 出现稍早）
      if (Platform.isAndroid) {
        await Future.delayed(const Duration(seconds: 1));
      }

      // 4. 扫描直到发现 DFU 设备
      dfuKey.currentState?.setStage('正在扫描 DFU 设备...');
      final target = await _scanForDfuDevice();
      if (!mounted) return;

      // 5. 连接 bootloader 并禁用自动重连（DFU 传输中断不应后台重连）
      dfuKey.currentState?.setStage('正在连接设备...');
      await _app.ble.connect(target);
      _app.ble.setAutoReconnect(false);

      // 6. 刷写固件
      dfuKey.currentState?.setStage('正在刷写固件...');
      await _dev.dfuUpdateImage(
        header: image.header,
        body: image.body,
        onProgress: (p) => dfuKey.currentState?.setProgress(p),
        onStage: (s) =>
            dfuKey.currentState?.setStage('正在刷写固件...阶段 $s'),
      );

      // 7. 完成：弹窗切换完成态，由用户点确认关闭
      dfuKey.currentState?.setCompleted();
    } catch (e) {
      dfuKey.currentState?.setFailed('$e');
    }
  }

  /// 扫描 DFU 设备（对齐 CU：CU-/CL- 前缀为 DFU bootloader）
  Future<BluetoothDevice> _scanForDfuDevice() async {
    for (var attempt = 0; attempt < 60; attempt++) {
      await Future.delayed(const Duration(milliseconds: 250));
      final found = await _app.ble.scan(timeout: const Duration(milliseconds: 500));
      final targets = found
          .where((d) {
            final n = d.platformName;
            return n.startsWith('CU-') ||
                n.startsWith('CL-') ||
                n.contains('DFU');
          })
          .toList();

      // 多设备检查（对齐 CU）
      if (targets.length > 1) {
        throw Exception('发现多个 DFU 设备，请只连接一个设备');
      }
      if (targets.length == 1) return targets[0];

      // 兜底：bootloader 广播名可能读取为空，等待 1s 后唯一候选即视为 DFU 设备
      if (attempt >= 4 && found.length == 1) return found[0];
    }
    throw Exception('未发现 DFU 设备，请确认设备已进入 DFU 模式');
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
      try {
        await _app.setBlePairingKey(result);
        _toast('已设置配对密钥');
      } catch (e) {
        _toast('设置失败: $e');
      }
    }
  }

  // ========== 订阅入口（弹窗显示） ==========
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
                        _infoRow('固件版本', info.gitVersion.isEmpty ? '--' : info.gitVersion),
                        _infoRow('芯片编号', info.chipId.isEmpty ? '--' : info.chipId),
                        _infoRow('蓝牙地址', info.bleAddress.isEmpty ? '--' : info.bleAddress),
                        _infoRow('电量',
                            info.batteryLevel < 0 ? '--' : '${info.batteryLevel}%'),
                      ],
                    ),
                  ),
                  // 关于
                  SectionCard(
                    title: '关于',
                    child: Column(
                      children: [
                        _infoRow('应用名称', '无感卡槽管理助手'),
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
                  _sideBtn(
                    _app.isActivated ? '已激活' : '激活功能',
                    _app.isActivated ? Icons.verified : Icons.verified_user,
                    _showActivationDialog,
                    primary,
                    iconColor: _app.isActivated ? const Color(0xFFFFD700) : null,
                  ),
                  _sideBtn('本地刷入', Icons.upload_file, _dfuUpdateFromLocal, primary),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ========== 激活功能弹窗 ==========
  Future<void> _showActivationDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, sbSetState) => AlertDialog(
          title: const Text('激活功能'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_chipId.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(ctx).colorScheme.outline,
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        Text('芯片 ID: ',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(ctx)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.6),
                            )),
                        Expanded(
                          child: Text(
                            _chipId,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 16),
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: _chipId));
                          },
                          tooltip: '复制',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _activationCodeController,
                        decoration: const InputDecoration(
                          labelText: '激活码:',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                        ),
                        enabled: !_app.isActivated,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.qr_code_scanner),
                      tooltip: '扫码输入',
                      onPressed: _app.isActivated
                          ? null
                          : () async {
                              final result = await showDialog<String>(
                                context: ctx,
                                builder: (scanCtx) =>
                                    const QrCodeScanner(),
                              );
                              if (result != null &&
                                  result.isNotEmpty) {
                                sbSetState(() {
                                  _activationCodeController.text =
                                      result;
                                });
                              }
                            },
                    ),
                    ElevatedButton(
                      onPressed: _app.isActivated
                          ? null
                          : () async {
                              final code =
                                  _activationCodeController.text;
                              if (code.isEmpty) return;
                              if (validateActivationCode(
                                  _chipId, code)) {
                                final rejectMsg =
                                    await checkActivationOnline(
                                        _chipId, code);
                                if (rejectMsg != null) {
                                  if (mounted) {
                                    showDialog<void>(
                                      context: context,
                                      builder: (dialogContext) =>
                                          AlertDialog(
                                        title: const Text('无法激活'),
                                        content: Text(rejectMsg),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(
                                                    dialogContext),
                                            child: const Text('好'),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                  return;
                                }
                              }
                              final result = await _app.device
                                  .cmdSetActivationDebug(_chipId, code);
                              final status = result[0] as int;
                              final dataHex = result[1] as String;
                              if (status == 0x68) {
                                await _app.setActivated(true,
                                    chipId: _chipId);
                                _toast('激活成功');
                                sbSetState(() {});
                              } else {
                                var msg = '激活码无效 (status=0x${status.toRadixString(16).padLeft(2, '0')})';
                                if (dataHex.isNotEmpty) {
                                  msg += ' hash=$dataHex';
                                }
                                if (mounted) {
                                  showDialog<void>(
                                    context: context,
                                    builder: (dialogContext) =>
                                        AlertDialog(
                                      title: const Text('无法激活'),
                                      content: Text(msg),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(
                                                  dialogContext),
                                          child: const Text('好'),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                              }
                            },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _app.isActivated
                                ? (_app.remainingBoots > 0
                                    ? '试用版 (剩余${_app.remainingBoots}次)'
                                    : '已激活')
                                : '激活',
                            style: TextStyle(
                              color: _app.isActivated
                                  ? (_app.remainingBoots > 0
                                      ? const Color(0xFFC0C0C0)
                                      : null)
                                  : null,
                            ),
                          ),
                          if (_app.isActivated) ...[
                            const SizedBox(width: 6),
                            Icon(
                              _app.remainingBoots > 0
                                  ? Icons.schedule
                                  : Icons.verified,
                              size: 18,
                              color: _app.remainingBoots > 0
                                  ? const Color(0xFFC0C0C0)
                                  : const Color(0xFFFFD700),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  // ========== 轮询设置弹窗 ==========
  Future<void> _showPollingSettings() async {
    try {
      _pollingDelay = await _dev.cmdGetPollingDelay();
      _pollingEnabled = await _dev.cmdGetPollingEnable();
      _pollingAdaptive = await _dev.cmdGetPollingAdaptive();
      _pollingSlots = await _dev.cmdGetPollingSlots();
    } catch (_) {}
    _pollingDelayController.text = (_pollingDelay ?? 0).toString();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, sbSetState) => AlertDialog(
          title: const Text('轮询设置', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 450,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 轮询延迟
                  const Text('轮询延迟:', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  if (_pollingDelay != null)
                    Text(
                      _pollingEnabled
                          ? '当前轮询延迟: ${_pollingDelay}ms'
                          : '轮询已关闭',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(ctx)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _pollingDelayController,
                          keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '轮询延迟 (ms)',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () async {
                        final value =
                            int.tryParse(_pollingDelayController.text);
                        if (value == null || value < 0) return;
                        try {
                          await _dev.cmdSetPollingDelay(value);
                          await _dev.cmdSetPollingEnable(true);
                          await _dev.cmdSaveSettings();
                          sbSetState(() {
                            _pollingDelay = value;
                            _pollingEnabled = true;
                          });
                        } catch (_) {}
                      },
                      child: const Text('保存'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () async {
                        try {
                          if (_pollingEnabled) {
                            await _dev.cmdSetPollingEnable(false);
                            await _dev.cmdSaveSettings();
                            sbSetState(() => _pollingEnabled = false);
                          } else {
                            await _dev.cmdSetPollingEnable(true);
                            await _dev.cmdSaveSettings();
                            sbSetState(() => _pollingEnabled = true);
                          }
                        } catch (_) {}
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _pollingEnabled
                            ? Colors.red.shade50
                            : Colors.green.shade50,
                        foregroundColor: _pollingEnabled
                            ? Colors.red.shade700
                            : Colors.green.shade700,
                      ),
                      child: Text(_pollingEnabled
                          ? '关闭轮询'
                          : '恢复轮询'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 智能自适应延迟
                Row(
                  children: [
                    const Expanded(child: Text('智能自适应延迟')),
                    Switch(
                      value: _pollingAdaptive,
                      onChanged: (value) async {
                        sbSetState(() => _pollingAdaptive = value);
                        try {
                          await _dev.cmdSetPollingAdaptive(value);
                          await _dev.cmdSaveSettings();
                        } catch (_) {}
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '开启后会自动调整卡槽的轮询延迟',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 16),
                // 参与轮询的卡槽
                const Text('参与轮询的卡槽:', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < _pollingSlots.length; i++)
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => sbSetState(() {
                          _pollingSlots[i] = !_pollingSlots[i];
                        }),
                        child: Container(
                          width: 36,
                          height: 26,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _pollingSlots[i]
                                ? Theme.of(ctx)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.18)
                                : Theme.of(ctx)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: _pollingSlots[i]
                                  ? Theme.of(ctx).colorScheme.primary
                                  : Theme.of(ctx)
                                      .colorScheme
                                      .outlineVariant,
                            ),
                          ),
                          child: Text(
                            (i + 1).toString(),
                            style: TextStyle(
                              fontSize: 12,
                              color: _pollingSlots[i]
                                  ? Theme.of(ctx).colorScheme.primary
                                  : Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => sbSetState(() {
                        _pollingSlots = List.filled(80, true);
                      }),
                      child: const Text('全选'),
                    ),
                    TextButton(
                      onPressed: () => sbSetState(() {
                        _pollingSlots = List.filled(80, false);
                      }),
                      child: const Text('清空'),
                    ),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: () async {
                        try {
                          await _dev.cmdSetPollingSlots(_pollingSlots);
                          await _dev.cmdSaveSettings();
                        } catch (_) {}
                      },
                      child: const Text('保存槽位'),
                    ),
                  ],
                ),
              ],
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
      ),
    );
  }

  Widget _sideBtn(String label, IconData icon, VoidCallback? onTap, Color color, {Color? iconColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ActionButton(
          label: label,
          icon: icon,
          color: color,
          iconColor: iconColor,
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

/// DFU 刷写进度对话框（带进度百分比显示）
class _DfuDialog extends StatefulWidget {
  final String title;
  const _DfuDialog({super.key, required this.title});

  @override
  State<_DfuDialog> createState() => _DfuDialogState();
}

class _DfuDialogState extends State<_DfuDialog> {
  int _progress = 0;
  late String _stageText = widget.title;
  bool _completed = false;
  bool _failed = false;
  String _failMsg = '';

  void setProgress(int progress) {
    if (!mounted) return;
    setState(() {
      _progress = progress;
    });
  }

  void setStage(String stageText) {
    if (!mounted) return;
    setState(() {
      _stageText = stageText;
    });
  }

  void setCompleted() {
    if (!mounted) return;
    setState(() {
      _completed = true;
      _progress = 100;
      _stageText = '更新已完成，双击 B 键开机。';
    });
  }

  void setFailed(String msg) {
    if (!mounted) return;
    setState(() {
      _failed = true;
      _failMsg = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        _failed ? '刷写失败' : (_completed ? '更新完成' : widget.title),
        style: const TextStyle(fontSize: 16),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _failed ? _failMsg : _stageText,
              style: TextStyle(
                fontSize: 13,
                color: _failed
                    ? const Color(0xFFE53935)
                    : const Color(0xFF666666),
              ),
            ),
            const SizedBox(height: 12),
            if (!_completed && !_failed) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 6,
                  width: double.infinity,
                  child: Stack(
                    children: [
                      Container(color: const Color(0xFFE8E8E8)),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: (_progress / 100).clamp(0.0, 1.0),
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.white, Color(0xFF4A90E2)],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _progress > 0 ? '$_progress%' : '准备中...',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '请勿断开设备',
                style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
            ],
          ],
        ),
      ),
      actions: (_completed || _failed)
          ? [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_completed ? '确定' : '关闭'),
              ),
            ]
          : null,
    );
  }
}

