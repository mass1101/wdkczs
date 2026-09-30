import 'package:flutter/material.dart';

import '../../main.dart';
import '../../services/card_backup.dart';
import '../../services/card_library.dart';
import '../../state/app_controller.dart';
import '../dialogs/cloud_backup_manager_dialog.dart';
import '../widgets/common.dart' show ActionButton;

/// 卡包 Tab：云端备份上传 + 云端备份管理（列表/刷新/多选/删除/还原）
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  late final AppController _app;
  final CardLibraryStorage _lib = CardLibraryStorage();

  List<SaveCard> _cards = [];
  bool _loading = true;

  bool get _connected => _app.connected;

  @override
  void initState() {
    super.initState();
    _app = AppScope.instance.controller;
    _reload();
  }

  Future<void> _reload() async {
    final cards = await _lib.getCards();
    if (!mounted) return;
    setState(() {
      _cards = cards;
      _loading = false;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 操作区
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ActionButton(
                label: '云端备份',
                icon: Icons.cloud_upload,
                onTap: () {
                  if (!_connected) return _toast('请先连接设备后使用');
                  _cloudBackup();
                },
              ),
              ActionButton(
                label: '云端备份管理',
                icon: Icons.cloud_queue,
                onTap: () {
                  if (!_connected) return _toast('请先连接设备后使用');
                  _cloudBackupManager();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // 卡包列表（只读）
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_cards.isEmpty) {
      return Center(
        child: Text(
          '卡包为空',
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 80),
      itemCount: _cards.length,
      itemBuilder: (_, i) => _cardItem(_cards[i]),
    );
  }

  /// 卡片项（只读展示）
  Widget _cardItem(SaveCard c) {
    final freq = isLfTag(c.tag) ? 'LF' : 'HF';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 34,
            decoration: BoxDecoration(
              color: c.color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.name.isEmpty ? '未命名' : c.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${c.tag.label}  $freq  UID:${c.uid.toUpperCase()}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF666666),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ========== 云端备份/还原 ==========
  Future<String> _ensureChipId() async {
    var chipId = await _app.resolveChipId();
    if (chipId.isNotEmpty) return chipId;
    if (!mounted) return '';
    final ctrl = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置芯片编号'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入芯片编号'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (entered == null || entered.isEmpty) return '';
    chipId = entered;
    await _app.storage.setBackupChipId(chipId);
    return chipId;
  }

  /// 二次确认对话框（对齐 CU backupCardToCloud/backupCardsFromCloud 的 alert）
  Future<bool> _confirm(String title, String message, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(label),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 全屏 loading 遮罩执行任务
  Future<void> _runBusy(String hint, Future<void> Function() task) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.push(
      DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.transparent,
        builder: (_) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(),
              ),
              const SizedBox(height: 12),
              Text(hint),
            ],
          ),
        ),
      ),
    );
    try {
      await task();
    } finally {
      if (navigator.mounted) navigator.pop();
    }
  }

  /// 采集设备状态随备份一起上传（对齐 CU collectDeviceStatus）
  Future<Map<String, dynamic>> _collectDeviceStatus() async {
    final status = <String, dynamic>{};
    try {
      status['firmware_version'] = await _app.device.cmdGetAppVersion();
    } catch (_) {}
    try {
      status['git_version'] = await _app.device.cmdGetGitVersion();
    } catch (_) {}
    return status;
  }

  Future<void> _cloudBackup() async {
    if (_cards.isEmpty) {
      _toast('卡包为空，无需备份');
      return;
    }
    if (!await _confirm(
      '备份到云端',
      '将把卡包中的 ${_cards.length} 张卡片上传到云端服务器。',
      '备份',
    )) {
      return;
    }
    final chipId = await _ensureChipId();
    if (chipId.isEmpty) {
      _toast('未设置芯片编号');
      return;
    }
    final status = await _collectDeviceStatus();
    await _runBusy('正在备份到云端...', () async {
      final result = await backupAllCardsToCloud(
        _app.storage,
        all: _cards,
        chipId: chipId,
        deviceStatus: status,
      );
      if (!mounted) return;
      _toast(
        result.success
            ? '备份成功：${result.uploaded} 张卡片'
            : '备份失败，请检查网络或服务器',
      );
    });
  }

  Future<void> _cloudBackupManager() async {
    final chipId = await _ensureChipId();
    if (chipId.isEmpty) {
      _toast('未设置芯片编号');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => CloudBackupManagerDialog(
        storage: _app.storage,
        chipId: chipId,
        onRestored: () {
          _reload();
        },
      ),
    );
  }
}
