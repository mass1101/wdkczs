import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/enums.dart';
import '../../services/card_backup.dart';
import '../../services/card_library.dart';
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
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
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
    final raw = typeValue == 1 ? (slot < names.length ? names[slot].$2 : null)
                                : (slot < names.length ? names[slot].$1 : null);
    if (raw == null || raw.isEmpty || raw == 'empty') {
      return '卡槽 ${slot + 1}';
    }
    return '卡槽 ${slot + 1} - $raw';
  }

  Future<void> _onSlotTap(int slot) async {
    if (_progress != -1) return;

    final cards = List<SaveCard>.from(_cards)..sort((a, b) => a.name.compareTo(b.name));
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
                    borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
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
                      const Text('选择卡片写入卡槽', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text('卡槽 ${slot + 1}', style: const TextStyle(fontSize: 13, color: Colors.grey)),
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
                          backgroundColor: Color(card.colorValue).withValues(alpha: 0.2),
                          child: Text(card.tag.label.length >= 2 ? card.tag.label.substring(0, 2) : card.tag.label,
                              style: TextStyle(color: Color(card.colorValue), fontSize: 12)),
                        ),
                        title: Text(card.name.isEmpty ? '未命名' : card.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${card.tag.label} | ${card.uid}',
                            style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
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
        card.name = _slotName(slot, isHf ? _slotTypes.length > slot ? _slotTypes[slot].$1 : 0 : _slotTypes.length > slot ? _slotTypes[slot].$2 : 0);
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
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
        card.name = _slotName(slot, isHf ? _slotTypes.length > slot ? _slotTypes[slot].$1 : 0 : _slotTypes.length > slot ? _slotTypes[slot].$2 : 0);
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
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Expanded(child: Text('正在上传...')),
        ]),
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
              PopupMenuItem(value: 'batch_library', child: Row(children: [
                const Icon(Icons.save, size: 16),
                const SizedBox(width: 8),
                const Text('备份到卡库'),
              ])),
              PopupMenuItem(value: 'batch_cloud', child: Row(children: [
                const Icon(Icons.cloud_upload, size: 16),
                const SizedBox(width: 8),
                const Text('备份到云端'),
              ])),
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
                final hasContent = index < _enabledSlots.length &&
                    (_enabledSlots[index].$1 || _enabledSlots[index].$2);
                final hfType = index < _slotTypes.length ? _slotTypes[index].$1 : 0;
                final lfType = index < _slotTypes.length ? _slotTypes[index].$2 : 0;
                final hfName = index < _slotNames.length ? _slotNames[index].$1 : null;
                final lfName = index < _slotNames.length ? _slotNames[index].$2 : null;

                return Card(
                  elevation: hasContent ? 1 : 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: hasContent ? primary.withValues(alpha: 0.3) : Colors.grey.withValues(alpha: 0.2)),
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
                              Icon(Icons.nfc, size: 16, color: hasContent ? primary : Colors.grey),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text('卡槽 ${index + 1}',
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(Icons.credit_card, size: 12, color: Colors.grey[500]),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text('${hfName ?? '空'} (${_tagName(hfType)})',
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(Icons.wifi, size: 12, color: Colors.grey[500]),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text('${lfName ?? '空'} (${_tagName(lfType)})',
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
                              ),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                onPressed: () => _showSlotSettings(index),
                                icon: const Icon(Icons.settings, size: 16, color: Colors.grey),
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
              child: LinearProgressIndicator(value: (_progress / 100).toDouble()),
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
        _hfName = names.length > widget.slot ? (names[widget.slot].$1 ?? '') : '';
        _lfName = names.length > widget.slot ? (names[widget.slot].$2 ?? '') : '';
        _hfType = types.length > widget.slot ? types[widget.slot].$1 : 0;
        _lfType = types.length > widget.slot ? types[widget.slot].$2 : 0;
        _hfEnabled = enabled.length > widget.slot ? enabled[widget.slot].$1 : false;
        _lfEnabled = enabled.length > widget.slot ? enabled[widget.slot].$2 : false;
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
            if (isEditing) { _hfName = name; _hfType = type; }
            else { _lfName = name; _lfType = type; }
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await widget.app.device.cmdSlotDeleteFreqName(widget.slot, isHf ? 2 : 1);
              await widget.app.device.cmdSlotDeleteFreqType(widget.slot, isHf ? 2 : 1);
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
        content: Text('确定读取卡槽 ${widget.slot + 1} ${isHf ? '高频' : '低频'}数据并添加到卡库？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
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
        content: Text('确定读取卡槽 ${widget.slot + 1} ${isHf ? '高频' : '低频'}数据并上传到云端？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
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
      return const AlertDialog(title: Text('卡槽设置'), content: Center(child: CircularProgressIndicator()));
    }

    final hasData = _hfType != 0 || _lfType != 0;

    return AlertDialog(
      title: Row(
        children: [
          const Text('卡槽设置'),
          const Spacer(),
          IconButton(
            onPressed: hasData ? () {
              showDialog(context: context, builder: (ctx) => AlertDialog(
                title: const Text('导出'),
                content: Text('备份到卡库: ${widget.slot + 1}'),
                actions: [
                  TextButton(onPressed: () async {
                    Navigator.pop(ctx);
                    for (final isHf in [true, false]) {
                      await _backupToLibrary(isHf);
                    }
                  }, child: const Text('导出到卡库')),
                  TextButton(onPressed: () async {
                    Navigator.pop(ctx);
                    for (final isHf in [true, false]) {
                      await _backupToCloud(isHf);
                    }
                  }, child: const Text('导出到云端')),
                ],
              ));
            } : null,
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
            IconButton(onPressed: () => _editTag(isHf), icon: const Icon(Icons.edit, size: 18)),
            IconButton(onPressed: () => _clearSlot(isHf), icon: const Icon(Icons.clear_rounded, size: 18)),
            Switch(
              value: enabled,
              onChanged: (v) async {
                await widget.app.device.cmdSlotSetEnable(widget.slot, isHf ? 2 : 1, v);
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
                child: Text(name.isEmpty ? '未命名' : name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 6),
              Text(_tagName(tagType),
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 卡槽编辑对话框（编辑名称 + 选择标签类型）
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
  late final TextEditingController _nameCtrl;
  late int _selectedType;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName.isEmpty ? '' : widget.initialName);
    _selectedType = widget.initialType;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.isHf ? "HF" : "LF"} 卡槽设置'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(labelText: '卡槽名称'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _selectedType,
            items: _availableTagTypes().map((t) => DropdownMenuItem(
              value: t.$1,
              child: Text(t.$2),
            )).toList(),
            onChanged: (v) => setState(() => _selectedType = v ?? 0),
            decoration: const InputDecoration(labelText: '标签类型'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(
          onPressed: () async {
            final name = _nameCtrl.text.trim();
            Navigator.pop(context);
            await widget.app.device.cmdSlotSetFreqName(widget.slot, widget.isHf ? 2 : 1, name);
            if (_selectedType > 0) {
              await widget.app.device.cmdSlotChangeTagType(widget.slot, _selectedType);
              await widget.app.device.cmdSlotResetTagType(widget.slot, _selectedType);
            }
            await widget.app.device.cmdSlotSaveSettings();
            if (!mounted) return;
            widget.onSaved(name, _selectedType);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  List<(int, String)> _availableTagTypes() {
    if (widget.isHf) {
      return [
        (1001, 'Mifare Classic 1K'),
        (1003, 'Mifare Classic 4K'),
        (1100, 'Mifare Ultralight'),
        (1101, 'NTAG215'),
      ];
    }
    return [
      (100, 'EM4100'),
      (104, 'Electra'),
      (170, 'Viking'),
      (150, 'PAC'),
      (200, 'HID Prox'),
      (201, 'ioProx'),
      (310, 'idteck'),
    ];
  }
}
