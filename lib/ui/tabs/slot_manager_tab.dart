import 'dart:math';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/enums.dart';
import '../../services/card_backup.dart';
import '../../services/card_library.dart';
import '../../ui/widgets/common.dart';
import '../../services/slot_writer.dart';
import '../../state/app_controller.dart';

/// 卡槽管理 Tab（对齐 CU slot_manager.dart）
/// 网格展示所有卡槽 + 点击写入卡库卡片 + 单槽设置 + 批量备份
class SlotManagerTab extends StatefulWidget {
  const SlotManagerTab({super.key});

  @override
  State<SlotManagerTab> createState() => _SlotManagerTabState();
}

class _SlotManagerTabState extends State<SlotManagerTab> {
  late final AppController _app;
  final CardLibraryStorage _lib = CardLibraryStorage();

  List<SaveCard> _cards = [];
  List<(int, int)> _slotTypes = [];
  List<(bool, bool)> _enabledSlots = [];
  List<(String?, String?)> _slotNames = [];

  int _progress = -1;

  static const _slotCount = 80;

  @override
  void initState() {
    super.initState();
    _app = AppScope.instance.controller;
    _reload();
  }

  Future<void> _reload() async {
    try {
      _cards = await _lib.getCards();
      _slotTypes = await _app.device.cmdSlotGetInfo();
      _enabledSlots = await _app.device.cmdSlotGetIsEnable();
      _slotNames = await _app.device.cmdSlotGetFreqNames();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _progress = -1);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  void _setProgress(int p) {
    setState(() => _progress = p);
  }

  String _tagName(int tagValue) {
    if (tagValue == 0 || tagValue == 4) return '未设置';
    try {
      return TagType.from(tagValue).label;
    } catch (_) {
      return '未知';
    }
  }

  String _slotName(int slot, int typeValue) {
    final names = _slotNames;
    final raw = typeValue == 1
        ? (slot < names.length ? names[slot].$2 : null)
        : (slot < names.length ? names[slot].$1 : null);
    if (raw == null || raw.isEmpty || raw == 'empty') {
      return '卡槽 ${slot + 1}';
    }
    return '卡槽 ${slot + 1} - $raw';
  }

  Future<void> _onSlotTap(int slot) async {
    if (_progress != -1) return;

    final cards = List<SaveCard>.from(_cards)
      ..sort((a, b) => a.name.compareTo(b.name));
    if (cards.isEmpty) {
      _toast('卡库为空，请先添加卡片');
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade400,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '选择卡片写入卡槽',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '卡槽 ${slot + 1}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: cards.map((card) {
                      return ListTile(
                        onTap: () {
                          Navigator.pop(ctx);
                          _writeCardToSlot(card, slot);
                        },
                        leading: CircleAvatar(
                          backgroundColor: Color(
                            card.colorValue,
                          ).withValues(alpha: 0.2),
                          child: Text(
                            card.tag.label.length >= 2
                                ? card.tag.label.substring(0, 2)
                                : card.tag.label,
                            style: TextStyle(
                              color: Color(card.colorValue),
                              fontSize: 12,
                            ),
                          ),
                        ),
                        title: Text(
                          card.name.isEmpty ? '未命名' : card.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${card.tag.label} | ${card.uid}',
                          style: const TextStyle(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          color: Colors.grey,
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _writeCardToSlot(SaveCard card, int slot) async {
    _setProgress(0);
    try {
      await uploadCardToSlot(_app.device, card, slot, onProgress: _setProgress);
      _toast('卡片已写入卡槽 ${slot + 1}');
      await _reload();
    } catch (e) {
      _toast('写入失败: $e');
    } finally {
      _setProgress(-1);
    }
  }

  Future<void> _showSlotSettings(int slot) async {
    await showDialog(
      context: context,
      builder: (ctx) => SlotSettingsDialog(
        slot: slot,
        app: _app,
        lib: _lib,
        onRefresh: () => _reload(),
        onToast: _toast,
      ),
    );
  }

  Future<void> _batchBackupToLibrary() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量备份到卡库'),
        content: Text('将读取所有 $_slotCount 个卡槽的数据并添加到卡库，确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    var added = 0, skipped = 0;
    _setProgress(0);

    for (var slot = 0; slot < _slotCount; slot++) {
      _setProgress(((slot + 1) / _slotCount * 100).round());
      for (final isHf in [true, false]) {
        final card = await readSlotDump(_app.device, slot, isHf);
        if (card == null) {
          skipped++;
          continue;
        }
        card.name = _slotName(
          slot,
          isHf
              ? _slotTypes.length > slot
                    ? _slotTypes[slot].$1
                    : 0
              : _slotTypes.length > slot
              ? _slotTypes[slot].$2
              : 0,
        );
        card.updatedAt = DateTime.now();
        await _lib.upsertCard(card);
        added++;
      }
    }

    _setProgress(-1);
    if (!mounted) return;
    _toast(added > 0 ? '备份完成：添加 $added 张，跳过 $skipped' : '所有卡槽为空');
    await _reload();
  }

  Future<void> _batchBackupToCloud() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量备份到云端'),
        content: Text('将读取所有 $_slotCount 个卡槽的数据并上传到云端，确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final cards = <SaveCard>[];
    _setProgress(0);

    for (var slot = 0; slot < _slotCount; slot++) {
      _setProgress(((slot + 1) / _slotCount * 100).round());
      for (final isHf in [true, false]) {
        final card = await readSlotDump(_app.device, slot, isHf);
        if (card == null) continue;
        card.name = _slotName(
          slot,
          isHf
              ? _slotTypes.length > slot
                    ? _slotTypes[slot].$1
                    : 0
              : _slotTypes.length > slot
              ? _slotTypes[slot].$2
              : 0,
        );
        card.updatedAt = DateTime.now();
        cards.add(card);
        await _lib.upsertCard(card);
      }
    }

    _setProgress(-1);
    if (!mounted) return;

    if (cards.isEmpty) {
      _toast('所有卡槽为空，无数据上传');
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('正在上传...')),
          ],
        ),
      ),
    );

    final result = await backupAllCardsToCloud(_app.storage, all: cards);
    if (!mounted) return;
    Navigator.pop(context);
    _toast(result.success ? '备份成功：${result.uploaded} 张' : '备份失败');
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final screenWidth = MediaQuery.of(context).size.width;
    final columns = screenWidth >= 1000 ? 4 : (screenWidth >= 700 ? 3 : 2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('卡槽管理'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.cloud_upload),
            onSelected: (value) {
              if (value == 'batch_library') _batchBackupToLibrary();
              if (value == 'batch_cloud') _batchBackupToCloud();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'batch_library',
                child: Row(
                  children: [
                    const Icon(Icons.save, size: 16),
                    const SizedBox(width: 8),
                    const Text('备份到卡库'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'batch_cloud',
                child: Row(
                  children: [
                    const Icon(Icons.cloud_upload, size: 16),
                    const SizedBox(width: 8),
                    const Text('备份到云端'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: _slotCount,
              itemBuilder: (context, index) {
                final hasContent =
                    index < _enabledSlots.length &&
                    (_enabledSlots[index].$1 || _enabledSlots[index].$2);
                final hfType = index < _slotTypes.length
                    ? _slotTypes[index].$1
                    : 0;
                final lfType = index < _slotTypes.length
                    ? _slotTypes[index].$2
                    : 0;
                final hfName = index < _slotNames.length
                    ? _slotNames[index].$1
                    : null;
                final lfName = index < _slotNames.length
                    ? _slotNames[index].$2
                    : null;

                return Card(
                  elevation: hasContent ? 1 : 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: hasContent
                          ? primary.withValues(alpha: 0.3)
                          : Colors.grey.withValues(alpha: 0.2),
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _onSlotTap(index),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.nfc,
                                size: 16,
                                color: hasContent ? primary : Colors.grey,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '卡槽 ${index + 1}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(
                                Icons.credit_card,
                                size: 12,
                                color: Colors.grey[500],
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '${hfName ?? '空'} (${_tagName(hfType)})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF888888),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                Icons.wifi,
                                size: 12,
                                color: Colors.grey[500],
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '${lfName ?? '空'} (${_tagName(lfType)})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF888888),
                                  ),
                                ),
                              ),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                onPressed: () => _showSlotSettings(index),
                                icon: const Icon(
                                  Icons.settings,
                                  size: 16,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_progress != -1) ...[
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('正在处理...', style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(
                value: (_progress / 100).toDouble(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单槽设置对话框（对齐 CU SlotSettings.dart）
class SlotSettingsDialog extends StatefulWidget {
  final int slot;
  final AppController app;
  final CardLibraryStorage lib;
  final VoidCallback onRefresh;
  final void Function(String msg) onToast;

  const SlotSettingsDialog({
    super.key,
    required this.slot,
    required this.app,
    required this.lib,
    required this.onRefresh,
    required this.onToast,
  });

  @override
  State<SlotSettingsDialog> createState() => _SlotSettingsDialogState();
}

class _SlotSettingsDialogState extends State<SlotSettingsDialog> {
  bool _hfEnabled = false;
  bool _lfEnabled = false;
  String _hfName = '';
  String _lfName = '';
  int _hfType = 0;
  int _lfType = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchInfo();
  }

  Future<void> _fetchInfo() async {
    try {
      final names = await widget.app.device.cmdSlotGetFreqNames();
      final types = await widget.app.device.cmdSlotGetInfo();
      final enabled = await widget.app.device.cmdSlotGetIsEnable();
      if (!mounted) return;
      setState(() {
        _hfName = names.length > widget.slot
            ? (names[widget.slot].$1 ?? '')
            : '';
        _lfName = names.length > widget.slot
            ? (names[widget.slot].$2 ?? '')
            : '';
        _hfType = types.length > widget.slot ? types[widget.slot].$1 : 0;
        _lfType = types.length > widget.slot ? types[widget.slot].$2 : 0;
        _hfEnabled = enabled.length > widget.slot
            ? enabled[widget.slot].$1
            : false;
        _lfEnabled = enabled.length > widget.slot
            ? enabled[widget.slot].$2
            : false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _tagName(int tagValue) {
    if (tagValue == 0 || tagValue == 4) return '未设置';
    try {
      return TagType.from(tagValue).label;
    } catch (_) {
      return '未知';
    }
  }

  Future<void> _editTag(bool isHf) async {
    final isEditing = isHf;
    await showDialog(
      context: context,
      builder: (ctx) => SlotEditDialog(
        slot: widget.slot,
        isHf: isHf,
        initialName: isHf ? _hfName : _lfName,
        initialType: isHf ? _hfType : _lfType,
        app: widget.app,
        onSaved: (name, type) {
          setState(() {
            if (isEditing) {
              _hfName = name;
              _hfType = type;
            } else {
              _lfName = name;
              _lfType = type;
            }
          });
          widget.onRefresh();
        },
      ),
    );
  }

  Future<void> _clearSlot(bool isHf) async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除卡槽'),
        content: Text('确定清除${isHf ? '高频' : '低频'}卡槽数据？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await widget.app.device.cmdSlotDeleteFreqName(
                widget.slot,
                isHf ? 2 : 1,
              );
              await widget.app.device.cmdSlotDeleteFreqType(
                widget.slot,
                isHf ? 2 : 1,
              );
              await widget.app.device.cmdSlotSaveSettings();
              if (!mounted) return;
              await _fetchInfo();
              if (!mounted) return;
              widget.onRefresh();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清除'),
          ),
        ],
      ),
    );
  }

  Future<void> _backupToLibrary(bool isHf) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备份到卡库'),
        content: Text(
          '确定读取卡槽 ${widget.slot + 1} ${isHf ? '高频' : '低频'}数据并添加到卡库？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (accepted != true) return;

    final card = await readSlotDump(widget.app.device, widget.slot, isHf);
    if (card == null) {
      widget.onToast('卡槽为空');
      return;
    }
    card.name = isHf ? _hfName : _lfName;
    card.updatedAt = DateTime.now();
    await widget.lib.upsertCard(card);
    widget.onToast('已添加到卡库');
  }

  Future<void> _backupToCloud(bool isHf) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备份到云端'),
        content: Text(
          '确定读取卡槽 ${widget.slot + 1} ${isHf ? '高频' : '低频'}数据并上传到云端？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (accepted != true) return;

    final card = await readSlotDump(widget.app.device, widget.slot, isHf);
    if (card == null) {
      widget.onToast('卡槽为空');
      return;
    }
    card.name = isHf ? _hfName : _lfName;
    card.updatedAt = DateTime.now();
    await widget.lib.upsertCard(card);

    final result = await backupAllCardsToCloud(widget.app.storage, all: [card]);
    if (!mounted) return;
    Navigator.pop(context);
    widget.onToast(result.success ? '上传成功' : '上传失败');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AlertDialog(
        title: Text('卡槽设置'),
        content: Center(child: CircularProgressIndicator()),
      );
    }

    final hasData = _hfType != 0 || _lfType != 0;

    return AlertDialog(
      title: Row(
        children: [
          const Text('卡槽设置'),
          const Spacer(),
          IconButton(
            onPressed: hasData
                ? () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('导出'),
                        content: Text('备份到卡库: ${widget.slot + 1}'),
                        actions: [
                          TextButton(
                            onPressed: () async {
                              Navigator.pop(ctx);
                              for (final isHf in [true, false]) {
                                await _backupToLibrary(isHf);
                              }
                            },
                            child: const Text('导出到卡库'),
                          ),
                          TextButton(
                            onPressed: () async {
                              Navigator.pop(ctx);
                              for (final isHf in [true, false]) {
                                await _backupToCloud(isHf);
                              }
                            },
                            child: const Text('导出到云端'),
                          ),
                        ],
                      ),
                    );
                  }
                : null,
            icon: const Icon(Icons.download),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          children: [
            _buildFreqRow(
              label: 'HF 高频',
              name: _hfName,
              tagType: _hfType,
              enabled: _hfEnabled,
              isHf: true,
            ),
            const SizedBox(height: 12),
            _buildFreqRow(
              label: 'LF 低频',
              name: _lfName,
              tagType: _lfType,
              enabled: _lfEnabled,
              isHf: false,
            ),
            const Divider(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  for (final isHf in [true, false]) {
                    _backupToLibrary(isHf);
                  }
                },
                icon: const Icon(Icons.save),
                label: const Text('备份到卡库'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  for (final isHf in [true, false]) {
                    _backupToCloud(isHf);
                  }
                },
                icon: const Icon(Icons.cloud_upload),
                label: const Text('备份到云端'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFreqRow({
    required String label,
    required String name,
    required int tagType,
    required bool enabled,
    required bool isHf,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('$label:', style: const TextStyle(fontSize: 14)),
            const Spacer(),
            IconButton(
              onPressed: () => _editTag(isHf),
              icon: const Icon(Icons.edit, size: 18),
            ),
            IconButton(
              onPressed: () => _clearSlot(isHf),
              icon: const Icon(Icons.clear_rounded, size: 18),
            ),
            Switch(
              value: enabled,
              onChanged: (v) async {
                await widget.app.device.cmdSlotSetEnable(
                  widget.slot,
                  isHf ? 2 : 1,
                  v,
                );
                await widget.app.device.cmdSlotSaveSettings();
                setState(() {
                  if (isHf) {
                    _hfEnabled = v;
                  } else {
                    _lfEnabled = v;
                  }
                });
                widget.onRefresh();
              },
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFE0E0E0)),
          ),
          child: Row(
            children: [
              Icon(Icons.help_outline, size: 14, color: Colors.grey[400]),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  name.isEmpty ? '未命名' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _tagName(tagType),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 卡槽编辑对话框（对齐 CU SlotEditMenu）
/// HF：卡名 + 标签类型 + UID/SAK/ATQA/ATS + Ultralight 数据 + 仿真器设置
/// LF：卡名 + 标签类型
class SlotEditDialog extends StatefulWidget {
  final int slot;
  final bool isHf;
  final String initialName;
  final int initialType;
  final AppController app;
  final void Function(String name, int type) onSaved;

  const SlotEditDialog({
    super.key,
    required this.slot,
    required this.isHf,
    required this.initialName,
    required this.initialType,
    required this.app,
    required this.onSaved,
  });

  @override
  State<SlotEditDialog> createState() => _SlotEditDialogState();
}

class _SlotEditDialogState extends State<SlotEditDialog> {
  static const List<(String, int)> _prngTypes = [('静态', 0), ('弱', 1), ('强', 2)];

  static const List<(String, int)> _writeModes = [
    ('正常', 0),
    ('拒绝', 1),
    ('欺骗', 2),
    ('影子', 3),
  ];

  late final TextEditingController _nameCtrl;
  late final TextEditingController _uidCtrl;
  late final TextEditingController _sakCtrl;
  late final TextEditingController _atqaCtrl;
  late final TextEditingController _atsCtrl;
  late final TextEditingController _ulVersionCtrl;
  late final TextEditingController _ulSignatureCtrl;
  late final List<TextEditingController> _ulCounterCtrls;

  int _selectedType = 0;
  int _prngType = 1;
  int _classicWriteMode = 0;
  int _ulWriteMode = 0;
  bool _gen1a = true;
  bool _gen2 = false;
  bool _useFirstBlock = false;
  bool _classicDetection = false;
  bool _ulGen2 = false;
  bool _ulDetection = false;
  int _classicDetectionCount = 0;
  int _ulDetectionCount = 0;
  bool _loading = true;
  bool _saving = false;

  TagType get _type => TagType.from(_selectedType);

  bool get _isClassic => _selectedType > 0 && isMifareClassic(_type);

  bool get _isUltralight => _selectedType > 0 && isMifareUltralight(_type);

  int get _counterCount =>
      _isUltralight ? mfUltralightGetCounterCount(_type) : 0;

  int get _uidBytes => _isUltralight ? 7 : 4;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(
      text: widget.initialName.isEmpty ? '' : widget.initialName,
    );
    _uidCtrl = TextEditingController();
    _sakCtrl = TextEditingController();
    _atqaCtrl = TextEditingController();
    _atsCtrl = TextEditingController();
    _ulVersionCtrl = TextEditingController();
    _ulSignatureCtrl = TextEditingController();
    _ulCounterCtrls = List.generate(3, (_) => TextEditingController());
    _selectedType = widget.initialType;
    if (widget.isHf) {
      _loadHfData();
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _uidCtrl.dispose();
    _sakCtrl.dispose();
    _atqaCtrl.dispose();
    _atsCtrl.dispose();
    _ulVersionCtrl.dispose();
    _ulSignatureCtrl.dispose();
    for (final c in _ulCounterCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  /// 读取卡槽碰撞数据、Ultralight 数据与仿真器配置
  Future<void> _loadHfData() async {
    final device = widget.app.device;
    try {
      try {
        final ac = await device.cmdHf14aGetAntiCollData();
        if (ac != null && mounted) {
          setState(() {
            _uidCtrl.text = bytesToHexSpace(ac.uid);
            _sakCtrl.text = ac.sak.toRadixString(16).padLeft(2, '0');
            _atqaCtrl.text = bytesToHexSpace(ac.atqa);
            _atsCtrl.text = bytesToHexSpace(ac.ats);
          });
        }
      } catch (_) {
        // 忽略碰撞数据读取失败，使用空值
      }

      if (_isUltralight) {
        try {
          final version = await device.cmdMf0EmuGetVersionData();
          if (mounted) {
            setState(() => _ulVersionCtrl.text = bytesToHexSpace(version));
          }
        } catch (_) {}
        try {
          final signature = await device.cmdMf0EmuGetSignatureData();
          if (mounted) {
            setState(() => _ulSignatureCtrl.text = bytesToHexSpace(signature));
          }
        } catch (_) {}
        for (var i = 0; i < _counterCount; i++) {
          try {
            final counter = await device.cmdMf0EmuGetCounterData(i);
            if (mounted) {
              setState(() => _ulCounterCtrls[i].text = counter.$1.toString());
            }
          } catch (_) {}
        }
        try {
          final es = await device.cmdMf0EmuGetEmuSettings();
          final count = await device.cmdMf0EmuGetDetectionCount();
          if (mounted) {
            setState(() {
              _ulGen2 = es.gen2;
              _ulDetection = es.detection;
              _ulDetectionCount = count;
            });
          }
        } catch (_) {}
      } else if (_isClassic) {
        try {
          final es = await device.cmdMf1GetEmuSettings();
          final count = await device.cmdMf1GetDetectionCount();
          if (mounted) {
            setState(() {
              _gen1a = es.gen1a;
              _gen2 = es.gen2;
              _useFirstBlock = es.antiColl;
              _classicDetection = es.detection;
              _classicWriteMode = es.write;
              _classicDetectionCount = count;
            });
          }
        } catch (_) {}
        try {
          final prng = await device.cmdMf1GetPrngType();
          if (mounted) {
            setState(() => _prngType = prng);
          }
        } catch (_) {}
      }
    } catch (_) {
      // 忽略读取失败，使用默认值
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.isHf ? 'HF' : 'LF'} 卡槽设置'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(child: _buildContent()),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _field(
          '卡槽名称',
          TextField(
            controller: _nameCtrl,
            maxLength: 19,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<int>(
          initialValue: _selectedType,
          items: [
            for (final t in _availableTagTypes())
              DropdownMenuItem(value: t.$1, child: Text(t.$2)),
            const DropdownMenuItem(value: 0, child: Text('未设置')),
          ],
          onChanged: (v) => setState(() => _selectedType = v ?? 0),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (widget.isHf) ..._hfFields(),
      ],
    );
  }

  /// HF 特有字段：UID/SAK/ATQA/ATS + 按卡型展开的仿真器设置
  List<Widget> _hfFields() {
    final children = <Widget>[
      const SizedBox(height: 10),
      _field('UID', _hexField(_uidCtrl, _uidBytes)),
      const SizedBox(height: 10),
      _field('SAK', _hexField(_sakCtrl, 1)),
      const SizedBox(height: 10),
      _field('ATQA', _hexField(_atqaCtrl, 2)),
      const SizedBox(height: 10),
      _field('ATS（可选）', _hexField(_atsCtrl, 0)),
    ];
    if (_isClassic) {
      children.addAll(_classicFields());
    } else if (_isUltralight) {
      children.addAll(_ultralightFields());
    }
    return children;
  }

  List<Widget> _classicFields() => [
    const SizedBox(height: 14),
    const Divider(),
    const SizedBox(height: 8),
    _toggleRow(
      'Gen1A 魔术模式',
      ['是', '否'],
      _gen1a ? 0 : 1,
      (i) => setState(() => _gen1a = i == 0),
    ),
    _toggleRow(
      'Gen2 魔术模式',
      ['是', '否'],
      _gen2 ? 1 : 0,
      (i) => setState(() => _gen2 = i == 1),
    ),
    _toggleRow(
      'PRNG 类型',
      [for (final p in _prngTypes) p.$1],
      _indexByValue(_prngTypes, _prngType),
      (i) => setState(() => _prngType = _prngTypes[i].$2),
    ),
    _toggleRow(
      '从 0 块使用 UID/SAK/ATQA',
      ['否', '是'],
      _useFirstBlock ? 1 : 0,
      (i) => setState(() => _useFirstBlock = i == 1),
    ),
    _toggleRow(
      '收集 nonces (Mfkey32)',
      ['否', '是'],
      _classicDetection ? 1 : 0,
      (i) => setState(() => _classicDetection = i == 1),
    ),
    _detectionHint(
      enabled: _classicDetection,
      count: _classicDetectionCount,
      disabledHint: '启用收集以恢复密钥',
      emptyHint: '请将卡片靠近读卡器以恢复密钥',
      countText: (c) => '已收集 nonce: $c',
      buttonLabel: '恢复密钥',
      onView: _showMf1DetectionLogs,
    ),
    _toggleRow(
      '写入模式',
      [for (final m in _writeModes) m.$1],
      _indexByValue(_writeModes, _classicWriteMode),
      (i) => setState(() => _classicWriteMode = _writeModes[i].$2),
    ),
  ];

  List<Widget> _ultralightFields() {
    final children = <Widget>[
      const SizedBox(height: 14),
      const Divider(),
      const SizedBox(height: 8),
      _field('Ultralight 版本', _hexField(_ulVersionCtrl, 0)),
      const SizedBox(height: 10),
      _signatureRow(),
    ];
    for (var i = 0; i < _counterCount; i++) {
      children.add(const SizedBox(height: 10));
      children.add(_counterRow(i));
    }
    children.addAll([
      const SizedBox(height: 14),
      const Divider(),
      const SizedBox(height: 8),
      _toggleRow(
        'Gen2 魔术模式',
        ['否', '是'],
        _ulGen2 ? 1 : 0,
        (i) => setState(() => _ulGen2 = i == 1),
      ),
      _toggleRow(
        '密码检测',
        ['否', '是'],
        _ulDetection ? 1 : 0,
        (i) => setState(() => _ulDetection = i == 1),
      ),
      _detectionHint(
        enabled: _ulDetection,
        count: _ulDetectionCount,
        disabledHint: '启用密码检测以恢复密钥',
        emptyHint: '请将卡片靠近读卡器以检测密码',
        countText: (c) => '已检测密码: $c',
        buttonLabel: '查看密码',
        onView: _showMf0DetectionLogs,
      ),
      _toggleRow(
        '写入模式',
        [for (final m in _writeModes) m.$1],
        _indexByValue(_writeModes, _ulWriteMode),
        (i) => setState(() => _ulWriteMode = _writeModes[i].$2),
      ),
    ]);
    return children;
  }

  Widget _signatureRow() => Row(
    children: [
      Expanded(child: _field('Ultralight 签名', _hexField(_ulSignatureCtrl, 0))),
      const SizedBox(width: 8),
      TextButton.icon(
        onPressed: _randomSignature,
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('随机生成', style: TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    ],
  );

  Widget _counterRow(int index) => _field(
    'Ultralight 计数器 ${index + 1}',
    TextField(
      controller: _ulCounterCtrls[index],
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        isDense: true,
        hintText: '0 - 16777215',
      ),
    ),
  );

  Widget _field(String title, Widget child) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          title,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ),
      child,
    ],
  );

  Widget _hexField(TextEditingController ctrl, int? bytes) => TextField(
    controller: ctrl,
    keyboardType: TextInputType.text,
    decoration: const InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
    ),
  );

  Widget _toggleRow(
    String title,
    List<String> labels,
    int selected,
    ValueChanged<int> onSelected,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Flexible(
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            flex: 2,
            child: ToggleButtonsWrapper(
              isSelected: [
                for (var i = 0; i < labels.length; i++) i == selected,
              ],
              children: labels,
              onPressed: onSelected,
            ),
          ),
        ],
      ),
    );
  }

  /// 碰撞检测计数提示：未启用/未检测到/已检测到三态
  Widget _detectionHint({
    required bool enabled,
    required int count,
    required String disabledHint,
    required String emptyHint,
    required String Function(int count) countText,
    required String buttonLabel,
    required VoidCallback onView,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: !enabled
          ? Text(
              disabledHint,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            )
          : count == 0
          ? Text(
              emptyHint,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            )
          : Row(
              children: [
                Flexible(
                  child: Text(
                    countText(count),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                TextButton(
                  onPressed: onView,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(
                    buttonLabel,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
    );
  }

  int _indexByValue(List<(String, int)> options, int value) {
    final i = options.indexWhere((e) => e.$2 == value);
    return i < 0 ? 0 : i;
  }

  List<(int, String)> _availableTagTypes() {
    final types = widget.isHf ? hfTagTypes() : lfTagTypes();
    return [for (final t in types) (t.value, t.label)];
  }

  Future<void> _randomSignature() async {
    final rnd = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < 8; i++) {
      sb.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
      if (i < 7) {
        sb.write(' ');
      }
    }
    final hex = sb.toString();
    setState(() => _ulSignatureCtrl.text = hex);
    try {
      await widget.app.device.cmdMf0EmuSetSignatureData(hexToUint8List(hex));
    } catch (e) {
      _toast('签名写入失败: $e');
    }
  }

  Future<void> _showMf1DetectionLogs() async {
    try {
      final logs = await widget.app.device.cmdMf1GetDetectionLogs(0);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('已收集 nonce'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in logs)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        '块 ${l.block}（${l.isKeyB ? 'B' : 'A'}）: '
                        '${bytesToHexSpace(l.nt)} ${bytesToHexSpace(l.nr)} '
                        '${bytesToHexSpace(l.ar)}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
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
      );
    } catch (e) {
      _toast('读取失败: $e');
    }
  }

  Future<void> _showMf0DetectionLogs() async {
    try {
      final logs = await widget.app.device.cmdMf0EmuGetDetectionLogs(0);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('已检测密码'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < logs.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        '密码 ${i + 1}: ${logs[i]}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                      ),
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
      );
    } catch (e) {
      _toast('读取失败: $e');
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast('请输入卡槽名称');
      return;
    }
    if (name.length > 19) {
      _toast('卡槽名称过长（最多 19 字符）');
      return;
    }

    if (widget.isHf) {
      final uid = formatHexInput(_uidCtrl.text);
      final sak = formatHexInput(_sakCtrl.text);
      final atqa = formatHexInput(_atqaCtrl.text);
      final ats = formatHexInput(_atsCtrl.text);
      if (uid.isEmpty || sak.isEmpty || atqa.isEmpty) {
        _toast('UID / SAK / ATQA 为必填项');
        return;
      }
      if (_isUltralight && uid.length != 14) {
        _toast('Ultralight 卡 UID 应为 7 字节');
        return;
      }
      if (_isClassic && uid.length != 8) {
        _toast('Classic 卡 UID 应为 4 字节');
        return;
      }
      if (sak.length != 2) {
        _toast('SAK 应为 1 字节');
        return;
      }
      if (atqa.length != 4) {
        _toast('ATQA 应为 2 字节');
        return;
      }
      if (ats.isNotEmpty && ats.length > 16) {
        _toast('ATS 最多 8 字节');
        return;
      }
      for (var i = 0; i < _counterCount; i++) {
        final counter = _ulCounterCtrls[i].text.trim();
        final v = int.tryParse(counter);
        if (v == null || v < 0 || v > 0xFFFFFF) {
          _toast('Ultralight 计数器范围为 0 - 16777215');
          return;
        }
      }
    }

    setState(() => _saving = true);
    try {
      if (widget.isHf) {
        await _saveHf(name);
      } else {
        await _applyNameAndType(name);
      }
      if (!mounted) return;
      Navigator.pop(context);
      widget.onSaved(name, _selectedType);
    } catch (e) {
      if (mounted) _toast('保存失败: $e');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 写入卡名与标签类型（LF 卡槽 / HF 卡槽的通用部分）
  Future<void> _applyNameAndType(String name) async {
    final device = widget.app.device;
    await device.cmdSlotSetFreqName(widget.slot, widget.isHf ? 2 : 1, name);
    if (_selectedType > 0 && _selectedType != widget.initialType) {
      await device.cmdSlotChangeTagType(widget.slot, _selectedType);
      await device.cmdSlotResetTagType(widget.slot, _selectedType);
    }
    await device.cmdSlotSaveSettings();
  }

  /// 保存 HF 卡槽（对齐 CU edit.dart save 顺序）
  Future<void> _saveHf(String name) async {
    final device = widget.app.device;
    final uid = hexToUint8List(_uidCtrl.text);
    final atqa = hexToUint8List(_atqaCtrl.text);
    final sak = hexToUint8List(_sakCtrl.text);
    final atsText = formatHexInput(_atsCtrl.text);
    final ats = atsText.isEmpty ? null : hexToUint8List(atsText);

    await device.cmdSlotSetFreqName(widget.slot, 2, name);
    await device.cmdHf14aSetAntiCollData(
      uid: uid,
      atqa: atqa,
      sak: sak,
      ats: ats,
    );
    if (_isUltralight) {
      await _writeUltralightData();
    }

    if (_selectedType > 0 && _selectedType != widget.initialType) {
      await device.cmdSlotChangeTagType(widget.slot, _selectedType);
      await device.cmdSlotResetTagType(widget.slot, _selectedType);
      await device.cmdHf14aSetAntiCollData(
        uid: uid,
        atqa: atqa,
        sak: sak,
        ats: ats,
      );
      if (_isUltralight) {
        await _writeUltralightData();
      }
    }

    if (_isClassic) {
      await device.cmdMf1SetGen1aMode(_gen1a);
      await device.cmdMf1SetGen2Mode(_gen2);
      try {
        await device.cmdMf1SetPrngType(_prngType);
      } catch (_) {
        // 旧固件不支持 PRNG 命令，忽略
      }
      await device.cmdMf1SetAntiCollMode(_useFirstBlock);
      await device.cmdMf1SetDetectionEnable(_classicDetection);
      await device.cmdMf1SetWriteMode(_classicWriteMode);
    }
    if (_isUltralight) {
      await device.cmdMf0EmuSetMagicMode(_ulGen2);
      await device.cmdMf0EmuSetDetectionEnable(_ulDetection);
      await device.cmdMf0EmuSetWriteMode(_ulWriteMode);
    }

    await device.cmdSlotSaveSettings();
  }

  /// 写入 Ultralight 版本 / 签名 / 计数器
  Future<void> _writeUltralightData() async {
    final device = widget.app.device;
    final versionText = formatHexInput(_ulVersionCtrl.text);
    if (versionText.isNotEmpty) {
      await device.cmdMf0EmuSetVersionData(hexToUint8List(versionText));
    }
    final signatureText = formatHexInput(_ulSignatureCtrl.text);
    if (signatureText.isNotEmpty) {
      await device.cmdMf0EmuSetSignatureData(hexToUint8List(signatureText));
    }
    for (var i = 0; i < _counterCount; i++) {
      final counter = _ulCounterCtrls[i].text.trim();
      if (counter.isNotEmpty) {
        await device.cmdMf0EmuSetCounterData(i, int.parse(counter), true);
      }
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }
}
