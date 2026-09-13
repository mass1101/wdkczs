import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../main.dart';
import '../../services/card_backup.dart';
import '../../services/card_library.dart';
import '../../services/card_save_converters.dart';
import '../../services/slot_writer.dart';
import '../../state/app_controller.dart';
import '../screens/geofence_screen.dart';
import '../widgets/common.dart' show ActionButton;

/// 卡库 Tab：已保存卡片网格/列表 + 文件夹分组 + 写卡槽 + 导入/导出
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  late final AppController _app;
  final CardLibraryStorage _lib = CardLibraryStorage();

  List<SaveCard> _cards = [];
  List<SaveFolder> _folders = [];
  String? _folderId; // null 表示全部
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
    final folders = await _lib.getFolders();
    if (!mounted) return;
    setState(() {
      _cards = cards;
      _folders = folders;
      _loading = false;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  List<SaveCard> get _filtered {
    if (_folderId == null) return _cards;
    return _cards.where((c) => c.folderId == _folderId).toList();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      children: [
        // 文件夹过滤条
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            children: [
              _folderChip(null, '全部', primary),
              ..._folders.map((f) => _folderChip(f.id, f.name, primary)),
            ],
          ),
        ),
        // 操作区
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Wrap(
            spacing: 8,
            children: [
              ActionButton(label: '新建文件夹', icon: Icons.create_new_folder,
                  onTap: _connected ? _newFolder : null),
              ActionButton(label: '导入卡片', icon: Icons.file_download,
                  onTap: _openImport),
              ActionButton(label: '写入卡槽', icon: Icons.memory,
                  onTap: _connected ? _pickAndWrite : null),
              ActionButton(label: '电子围栏', icon: Icons.location_on,
                  onTap: _openGeofence),
              ActionButton(label: '云端备份', icon: Icons.cloud_upload,
                  onTap: _cloudBackup),
              ActionButton(label: '云端还原', icon: Icons.cloud_download,
                  onTap: _cloudRestore),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 卡片列表
        Expanded(child: _buildList(primary)),
      ],
    );
  }

  Widget _folderChip(String? id, String label, Color primary) {
    final selected = _folderId == id;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        selectedColor: primary,
        labelStyle: TextStyle(
            fontSize: 13, color: selected ? Colors.white : Colors.black87),
        onSelected: (_) => setState(() => _folderId = id),
      ),
    );
  }

  Widget _buildList(Color primary) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _filtered;
    if (items.isEmpty) {
      return const Center(
          child: Text('卡库为空，可在 IC卡 页保存或点击「导入卡片」',
              style: TextStyle(color: Colors.grey, fontSize: 13)));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 80),
      itemCount: items.length,
      itemBuilder: (_, i) => _cardItem(items[i], primary),
    );
  }

  Widget _cardItem(SaveCard c, Color primary) {
    final freq = isLfTag(c.tag) ? 'ID' : 'HF';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1))
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 34,
            decoration: BoxDecoration(
                color: primary, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name.isEmpty ? '未命名' : c.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
                const SizedBox(height: 2),
                Text(
                  '${c.tag.label}  $freq   UID:${c.uid.toUpperCase()}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (_connected)
            IconButton(
              tooltip: '写入卡槽',
              icon: Icon(Icons.memory, color: primary, size: 20),
              onPressed: () => _writeToSlot(c),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20, color: Color(0xFF888888)),
            onSelected: (v) {
              if (v == 'rename') _renameCard(c);
              if (v == 'folder') _moveCard(c);
              if (v == 'delete') _deleteCard(c);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'folder', child: Text('移动到文件夹')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  // ========== 文件夹 ==========
  Future<void> _newFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _lib.upsertFolder(SaveFolder(name: name));
    await _reload();
  }

  // ========== 卡片操作 ==========
  Future<void> _renameCard(SaveCard c) async {
    final ctrl = TextEditingController(text: c.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    c.name = name;
    await _lib.upsertCard(c);
    await _reload();
  }

  Future<void> _moveCard(SaveCard c) async {
    final folderId = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('移动到文件夹'),
        children: [
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('未分类')),
          for (final f in _folders)
            SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, f.id),
                child: Text(f.name)),
        ],
      ),
    );
    if (folderId == null) return;
    c.folderId = folderId.isEmpty ? null : folderId;
    await _lib.upsertCard(c);
    await _reload();
  }

  Future<void> _deleteCard(SaveCard c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除卡片'),
        content: Text('确定删除「${c.name.isEmpty ? c.uid : c.name}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await _lib.deleteCard(c.id);
    await _reload();
  }

  // ========== 写入卡槽 ==========
  Future<void> _pickAndWrite() async {
    final card = await showDialog<SaveCard>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择要写入的卡片'),
        children: _cards.isEmpty
            ? [const Padding(padding: EdgeInsets.all(20), child: Text('卡库为空'))]
            : _cards
                .map((c) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, c),
                      child: Text(
                          '${c.name.isEmpty ? c.uid : c.name}  [${c.tag.label}]'),
                    ))
                .toList(),
      ),
    );
    if (card == null) return;
    await _writeToSlot(card);
  }

  Future<void> _writeToSlot(SaveCard card) async {
    final slot = await _pickSlotDialog();
    if (slot == null) return;
    try {
      await uploadCardToSlot(_app.device, card, slot, onProgress: (p) {
        _toast('写入卡槽 ${slot + 1}：$p%');
      });
      _toast('已写入卡槽 ${slot + 1}');
      await _app.loadEnabledSlots();
    } catch (e) {
      _toast('写入失败: $e');
    }
  }

  /// 独立卡槽选择器（不复用设置页 8 槽弹窗，走设备实时使能状态）
  Future<int?> _pickSlotDialog() async {
    List<(bool, bool)> enables;
    try {
      enables = await _app.device.cmdSlotGetIsEnable();
    } catch (_) {
      enables = List.generate(8, (_) => (false, false));
    }
    if (!mounted) return null;
    return showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择目标卡槽'),
        children: [
          Wrap(
            children: List.generate(8, (i) {
              final (hf, lf) = enables[i];
              final hasCard = hf || lf;
              return Padding(
                padding: const EdgeInsets.all(4),
                child: ChoiceChip(
                  label: Text('卡槽 ${i + 1}',
                      style: TextStyle(fontSize: 13, color: hasCard ? Colors.black87 : Colors.grey)),
                  selected: false,
                  onSelected: (_) => Navigator.pop(ctx, i),
                ),
              );
            }),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ),
        ],
      ),
    );
  }

  // ========== 导入 ==========
  Future<void> _openImport() async {
    // nfcapp 无 file_picker 依赖，导入采用文本粘贴方式
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => const _ImportSheet(),
    ).then((_) => _reload());
  }

  // ========== 电子围栏 ==========
  void _openGeofence() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GeofenceScreen()),
    ).then((_) => _reload());
  }

  // ========== 云端备份/还原 ==========
  Future<String> _ensureChipId() async {
    final storage = _app.storage;
    var chipId = await storage.getBackupChipId();
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (entered == null || entered.isEmpty) return '';
    chipId = entered;
    await storage.setBackupChipId(chipId);
    return chipId;
  }

  Future<void> _cloudBackup() async {
    if (_cards.isEmpty) {
      _toast('卡库为空，无需备份');
      return;
    }
    final chipId = await _ensureChipId();
    if (chipId.isEmpty) {
      _toast('未设置芯片编号');
      return;
    }
    _toast('正在备份到云端...');
    final result = await backupAllCardsToCloud(
      _app.storage,
      all: _cards,
      chipId: chipId,
    );
    _toast(result.success
        ? '备份成功：${result.uploaded} 张卡片'
        : '备份失败，请检查网络或服务器');
  }

  Future<void> _cloudRestore() async {
    final storage = _app.storage;
    final chipId = await _ensureChipId();
    if (chipId.isEmpty) {
      _toast('未设置芯片编号');
      return;
    }
    final token = await storage.getBackupToken();
    if (token.isEmpty) {
      _toast('尚无备份记录，请先备份');
      return;
    }
    _toast('正在从云端拉取...');
    final cloud = await fetchCloudCards(storage, chipId: chipId);
    if (!mounted) return;
    if (cloud == null) {
      _toast('还原失败或无备份数据');
      return;
    }
    if (cloud.$1.isEmpty) {
      _toast('云端没有可还原的卡片');
      return;
    }
    final result = mergeCloudCards(_cards, cloud.$1, cloud.$2);
    await CardLibraryStorage().saveCards(result.cards);
    await _reload();
    _toast(
        '还原完成：新增 ${result.added}，更新 ${result.updated}，保留 ${result.kept}');
  }
}

/// 导入面板：粘贴 PM3/Flipper/MCT 文本并选择格式
class _ImportSheet extends StatefulWidget {
  const _ImportSheet();

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  final _ctrl = TextEditingController();
  int _fmt = 0; // 0=PM3 1=Flipper NFC 2=Flipper RFID 3=MCT

  Future<void> _doImport() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      _toast('请先粘贴内容或选择文件');
      return;
    }
    try {
      final card = switch (_fmt) {
        1 => flipperNfcToSaveCard(text),
        2 => flipperRfidToSaveCard(text),
        3 => mctToSaveCard(text),
        _ => pm3JsonToSaveCard(text),
      };
      await CardLibraryStorage().upsertCard(card);
      if (mounted) {
        _toast('已导入：${card.tag.label}  UID:${card.uid.toUpperCase()}');
        Navigator.pop(context);
      }
    } catch (e) {
      _toast('导入失败: $e');
    }
  }

  Future<void> _pickFile() async {
    try {
      final pick = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'nfc', 'rfid', 'txt', 'mct'],
        withData: true,
      );
      if (pick == null || pick.files.isEmpty) return;
      final file = pick.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        _toast('无法读取文件');
        return;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      setState(() => _ctrl.text = text.trim());
    } catch (e) {
      _toast('选择文件失败: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 12, right: 12, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('导入卡片',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('PM3')),
              ButtonSegment(value: 1, label: Text('Flipper NFC')),
              ButtonSegment(value: 2, label: Text('Flipper RFID')),
              ButtonSegment(value: 3, label: Text('MCT')),
            ],
            selected: {_fmt},
            onSelectionChanged: (s) => setState(() => _fmt = s.first),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _ctrl,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: '粘贴卡片导出文本（JSON 或文本文件内容）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
              ActionButton(label: '选择文件', icon: Icons.folder_open, onTap: _pickFile),
              const SizedBox(width: 8),
              ActionButton(label: '导入', icon: Icons.check, onTap: _doImport),
            ],
          ),
        ],
      ),
    );
  }
}