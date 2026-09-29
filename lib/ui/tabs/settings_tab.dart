import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../helpers/activation.dart';
import '../../main.dart';
import '../../services/device_service.dart';
import '../../state/app_controller.dart';
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
  String _chipId = '';
  late final TextEditingController _activationCodeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
    });
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

  // ========== 固件刷写（对齐 CU flashFile 流程） ==========
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
                        _infoRow('应用名称', '无感卡槽读取助手'),
                        _infoRow('适用设备', 'Chameleon Ultra 第三方软件“无感刷卡助手”的卡槽数据提取'),
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

