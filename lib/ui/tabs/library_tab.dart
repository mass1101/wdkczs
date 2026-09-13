import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../main.dart';
import '../../services/card_backup.dart';
import '../../services/card_library.dart';
import '../../services/card_save_converters.dart';
import '../../services/slot_writer.dart';
import '../../state/app_controller.dart';
import '../screens/card_create_dialog.dart';
import '../screens/card_edit_dialog.dart';
import '../screens/card_view_dialog.dart';
import '../screens/dump_editor.dart';
import '../screens/geofence_screen.dart';
import '../widgets/common.dart' show ActionButton;

/// 预设文件夹颜色
const _folderColors = <Color>[
  Color(0xFFFF5722),
  Color(0xFF2196F3),
  Color(0xFF4CAF50),
  Color(0xFF9C27B0),
  Color(0xFFFF9800),
  Color(0xFFE91E63),
  Color(0xFF00BCD4),
  Color(0xFF795548),
  Color(0xFF607D8B),
  Color(0xFFF44336),
];

/// 卡库 Tab：已保存卡片列表 + 文件夹树形导航 + 写卡槽 + 导入/导出
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key, this.onOpenGeofence});

  final VoidCallback? onOpenGeofence;

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  late final AppController _app;
  final CardLibraryStorage _lib = CardLibraryStorage();

  List<SaveCard> _cards = [];
  List<SaveFolder> _folders = [];
  String? _folderId;
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
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  /// 当前文件夹下的子文件夹
  List<SaveFolder> get _subFolders => _folders
      .where((f) => f.parentId == _folderId)
      .toList();

  /// 当前文件夹下的卡片
  List<SaveCard> get _currentCards =>
      _cards.where((c) => c.folderId == _folderId).toList();

  /// 当前文件夹对象
  SaveFolder? get _currentFolder {
    if (_folderId == null) return null;
    for (final f in _folders) {
      if (f.id == _folderId) return f;
    }
    return null;
  }

  /// 文件夹子树内卡片总数
  int _folderCardCount(SaveFolder folder) {
    final subtreeIds = _lib.folderSubtreeIds(folder.id, _folders);
    return _cards.where((c) => c.folderId != null && subtreeIds.contains(c.folderId!)).length;
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      children: [
        // 文件夹导航条
        if (_currentFolder != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            color: const Color(0xFFF0F2F5),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  onPressed: () => setState(() {
                    _folderId = _currentFolder!.parentId;
                  }),
                  constraints: const BoxConstraints(),
                ),
                Expanded(
                  child: Text(
                    _currentFolder!.name,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        // 操作区
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ActionButton(label: '创建卡片', icon: Icons.add_card, onTap: _createCard),
              ActionButton(label: '新建文件夹', icon: Icons.create_new_folder, onTap: _editFolder),
              ActionButton(label: '导入', icon: Icons.file_download, onTap: _openImport),
              ActionButton(label: '写入卡槽', icon: Icons.memory,
                  onTap: _connected ? _pickAndWrite : null),
              ActionButton(label: '电子围栏', icon: Icons.location_on, onTap: _openGeofence),
              ActionButton(label: '云端备份', icon: Icons.cloud_upload, onTap: _cloudBackup),
              ActionButton(label: '云端还原', icon: Icons.cloud_download, onTap: _cloudRestore),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // 列表
        Expanded(child: _buildList(primary)),
      ],
    );
  }

  Widget _buildList(Color primary) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final folders = _subFolders;
    final cards = _currentCards;

    if (folders.isEmpty && cards.isEmpty) {
      return Center(
        child: Text(
          _folderId == null
              ? '卡库为空，点击「创建卡片」或「导入」'
              : '此文件夹为空',
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 80),
      itemCount: folders.length + cards.length,
      itemBuilder: (_, i) {
        if (i < folders.length) {
          return _folderItem(folders[i], primary);
        }
        return _cardItem(cards[i - folders.length], primary);
      },
    );
  }

  /// 文件夹项
  Widget _folderItem(SaveFolder f, Color primary) {
    final count = _folderCardCount(f);
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
          Icon(Icons.folder, color: f.color, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _folderId = f.id),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(f.name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
                  const SizedBox(height: 2),
                  Text('$count 张卡片',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF999999))),
                ],
              ),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20, color: Color(0xFF888888)),
            onSelected: (v) {
              if (v == 'edit') _editFolder(folder: f);
              if (v == 'move') _moveFolder(f);
              if (v == 'delete') _deleteFolder(f);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'move', child: Text('移动')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  /// 卡片项
  Widget _cardItem(SaveCard c, Color primary) {
    final freq = isLfTag(c.tag) ? 'LF' : 'HF';
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
                color: c.color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: () => _viewCard(c),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name.isEmpty ? '未命名' : c.name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
                  const SizedBox(height: 2),
                  Text(
                    '${c.tag.label}  $freq  UID:${c.uid.toUpperCase()}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
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
              if (v == 'view') _viewCard(c);
              if (v == 'edit') _editCard(c);
              if (v == 'move') _moveCard(c);
              if (v == 'dump') _openDumpEditor(c);
              if (v == 'delete') _deleteCard(c);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'view', child: Text('查看')),
              const PopupMenuItem(value: 'edit', child: Text('编辑')),
              if (isMifareClassic(c.tag) || isMifareUltralight(c.tag))
                const PopupMenuItem(value: 'dump', child: Text('Dump 编辑器')),
              const PopupMenuItem(value: 'move', child: Text('移动到文件夹')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  // ========== 卡片操作 ==========
  Future<void> _createCard() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => CardCreateDialog(folderId: _folderId),
    );
    if (changed == true) await _reload();
  }

  Future<void> _viewCard(SaveCard c) async {
    await showDialog<void>(
      context: context,
      builder: (_) => CardViewDialog(
        card: c,
        onMove: (card) => _moveCard(card),
        onChanged: _reload,
      ),
    );
    await _reload();
  }

  Future<void> _editCard(SaveCard c) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => CardEditDialog(card: c),
    );
    if (changed == true) await _reload();
  }

  Future<void> _openDumpEditor(SaveCard c) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DumpEditor(card: c)),
    );
    await _reload();
  }

  Future<void> _moveCard(SaveCard c) async {
    final folderId = await _pickFolderDestination();
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
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    await _lib.deleteCard(c.id);
    await _reload();
  }

  // ========== 文件夹操作 ==========
  Future<void> _editFolder({SaveFolder? folder}) async {
    final ctrl = TextEditingController(text: folder?.name ?? '');
    var color = folder?.color ?? _folderColors[0];
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(folder == null ? '新建文件夹' : '编辑文件夹'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '名称',
                  prefixIcon: IconButton(
                    icon: Icon(Icons.folder, color: color),
                    onPressed: () async {
                      var picked = color;
                      final accepted = await showDialog<bool>(
                        context: ctx,
                        builder: (c) => AlertDialog(
                          title: const Text('选择颜色'),
                          content: Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: _folderColors.map((cc) {
                              final sel = cc.toARGB32() == picked.toARGB32();
                              return GestureDetector(
                                onTap: () {
                                  picked = cc;
                                  Navigator.pop(c, true);
                                },
                                child: Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: cc,
                                    shape: BoxShape.circle,
                                    border: sel
                                        ? Border.all(color: Colors.white, width: 3)
                                        : null,
                                  ),
                                  child: sel
                                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                                      : null,
                                ),
                              );
                            }).toList(),
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false),
                                child: const Text('取消')),
                          ],
                        ),
                      );
                      if (accepted == true) {
                        setDialogState(() => color = picked);
                      }
                    },
                  ),
                ),
                onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim().isNotEmpty),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isNotEmpty),
              child: Text(folder == null ? '创建' : '保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    if (folder == null) {
      await _lib.upsertFolder(SaveFolder(
        name: ctrl.text.trim(),
        colorValue: color.toARGB32(),
        parentId: _folderId,
      ));
    } else {
      folder.name = ctrl.text.trim();
      folder.colorValue = color.toARGB32();
      await _lib.upsertFolder(folder);
    }
    await _reload();
  }

  Future<String?> _pickFolderDestination({SaveFolder? movingFolder}) async {
    final excluded = movingFolder == null
        ? <String>{}
        : _lib.folderSubtreeIds(movingFolder.id, _folders);
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('移动到文件夹'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const ListTile(
              leading: Icon(Icons.home),
              title: Text('根目录'),
            ),
          ),
          for (final f in _folders)
            if (!excluded.contains(f.id))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, f.id),
                child: ListTile(
                  leading: Icon(Icons.folder, color: f.color),
                  title: Text(f.name),
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _moveFolder(SaveFolder folder) async {
    final dest = await _pickFolderDestination(movingFolder: folder);
    if (dest == null) return;
    folder.parentId = dest.isEmpty ? null : dest;
    await _lib.upsertFolder(folder);
    await _reload();
  }

  Future<void> _deleteFolder(SaveFolder folder) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除文件夹「${folder.name}」'),
        content: const Text('将删除此文件夹及其所有子文件夹，文件夹内的卡片将移至根目录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    await _lib.deleteFolder(folder.id);
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
                      child: Text('${c.name.isEmpty ? c.uid : c.name}  [${c.tag.label}]'),
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
                      style: TextStyle(
                          fontSize: 13, color: hasCard ? Colors.black87 : Colors.grey)),
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
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => const _ImportSheet(),
    ).then((_) => _reload());
  }

  // ========== 电子围栏 ==========
  void _openGeofence() {
    final cb = widget.onOpenGeofence;
    if (cb != null) {
      cb();
      return;
    }
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
    _toast('还原完成：新增 ${result.added}，更新 ${result.updated}，保留 ${result.kept}');
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
  int _fmt = 0;

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
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
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
