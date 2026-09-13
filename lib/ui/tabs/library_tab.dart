import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart';
import '../../models/enums.dart';
import '../../services/card_backup.dart';
import '../../services/card_library.dart';
import '../../services/card_save_converters.dart';
import '../../services/slot_writer.dart';
import '../../services/storage_service.dart';
import '../../state/app_controller.dart';
import '../screens/card_analyze_screen.dart';
import '../screens/card_cloud_analyze_screen.dart';
import '../screens/card_compare_screen.dart';
import '../screens/card_create_dialog.dart';
import '../screens/card_edit_dialog.dart';
import '../screens/card_view_dialog.dart';
import '../screens/dump_editor.dart';
import '../widgets/common.dart' show ActionButton;

/// 二进制导入对话框可选卡型（仅 tagTypeByDumpSize 可推断出的卡型）
const _importTagOptions = <TagType>[
  TagType.mifareClassic1k,
  TagType.mifareClassic4k,
  TagType.mifareUltralight,
  TagType.ntag215,
];

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
  const LibraryTab({super.key});

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
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';

  bool get _connected => _app.connected;

  @override
  void initState() {
    super.initState();
    _app = AppScope.instance.controller;
    _reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
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
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  /// 当前文件夹下的子文件夹（按搜索词过滤）
  List<SaveFolder> get _subFolders => _folders
      .where((f) => f.parentId == _folderId)
      .where((f) => _match(f.name))
      .toList();

  /// 当前文件夹下的卡片（按搜索词过滤）
  List<SaveCard> get _currentCards => _cards
      .where((c) => c.folderId == _folderId)
      .where((c) => _match('${c.name} ${c.uid} ${c.tag.label}'))
      .toList();

  bool _match(String text) =>
      _search.isEmpty || text.toLowerCase().contains(_search.toLowerCase());

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
    return _cards
        .where((c) => c.folderId != null && subtreeIds.contains(c.folderId!))
        .length;
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
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        // 搜索
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: '搜索名称 / UID / 卡型',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchCtrl.clear();
                        _search = '';
                        setState(() {});
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
            ),
            onChanged: (v) {
              _search = v.trim();
              setState(() {});
            },
          ),
        ),
        // 操作区
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ActionButton(
                label: '创建卡片',
                icon: Icons.add_card,
                onTap: _createCard,
              ),
              ActionButton(
                label: '新建文件夹',
                icon: Icons.create_new_folder,
                onTap: _editFolder,
              ),
              ActionButton(
                label: '导入',
                icon: Icons.file_download,
                onTap: _openImport,
              ),
              ActionButton(
                label: '写入卡槽',
                icon: Icons.memory,
                onTap: _connected ? _pickAndWrite : null,
              ),
              ActionButton(
                label: '云端备份',
                icon: Icons.cloud_upload,
                onTap: _cloudBackup,
              ),
              ActionButton(
                label: '云端还原',
                icon: Icons.cloud_download,
                onTap: _cloudRestore,
              ),
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
          _folderId == null ? '卡库为空，点击「创建卡片」或「导入」' : '此文件夹为空',
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
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
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
                  Text(
                    f.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$count 张卡片',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.more_vert,
              size: 20,
              color: Color(0xFF888888),
            ),
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
            child: InkWell(
              onTap: () => _viewCard(c),
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
          ),
          if (_connected)
            IconButton(
              tooltip: '写入卡槽',
              icon: Icon(Icons.memory, color: primary, size: 20),
              onPressed: () => _writeToSlot(c),
            ),
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.more_vert,
              size: 20,
              color: Color(0xFF888888),
            ),
            onSelected: (v) {
              if (v == 'view') _viewCard(c);
              if (v == 'edit') _editCard(c);
              if (v == 'move') _moveCard(c);
              if (v == 'dump') _openDumpEditor(c);
              if (v == 'analyze') _openCardAnalyze(c);
              if (v == 'cloud_analyze') _openCloudAnalyze(c);
              if (v == 'compare') _openCardCompare(c);
              if (v == 'delete') _deleteCard(c);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'view', child: Text('查看')),
              const PopupMenuItem(value: 'edit', child: Text('编辑')),
              if (isMifareClassic(c.tag) || isMifareUltralight(c.tag))
                const PopupMenuItem(value: 'dump', child: Text('Dump 编辑器')),
              if (isMifareClassic(c.tag))
                const PopupMenuItem(value: 'analyze', child: Text('卡片分析')),
              if (isMifareClassic(c.tag))
                const PopupMenuItem(
                  value: 'cloud_analyze',
                  child: Text('云端分析'),
                ),
              if (isMifareClassic(c.tag) || isMifareUltralight(c.tag))
                const PopupMenuItem(value: 'compare', child: Text('比较 Dump')),
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

  Future<void> _openCardAnalyze(SaveCard c) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CardAnalyzeScreen(card: c)),
    );
    await _reload();
  }

  Future<void> _openCloudAnalyze(SaveCard c) async {
    await CardCloudAnalyzeScreen.launch(context, c);
    await _reload();
  }

  Future<void> _openCardCompare(SaveCard c) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CardCompareScreen(card: c)),
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
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
                                        ? Border.all(
                                            color: Colors.white,
                                            width: 3,
                                          )
                                        : null,
                                  ),
                                  child: sel
                                      ? const Icon(
                                          Icons.check,
                                          color: Colors.white,
                                          size: 18,
                                        )
                                      : null,
                                ),
                              );
                            }).toList(),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('取消'),
                            ),
                          ],
                        ),
                      );
                      if (accepted == true) {
                        setDialogState(() => color = picked);
                      }
                    },
                  ),
                ),
                onSubmitted: (_) =>
                    Navigator.pop(ctx, ctrl.text.trim().isNotEmpty),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
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
      await _lib.upsertFolder(
        SaveFolder(
          name: ctrl.text.trim(),
          colorValue: color.toARGB32(),
          parentId: _folderId,
        ),
      );
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
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
                  .map(
                    (c) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, c),
                      child: Text(
                        '${c.name.isEmpty ? c.uid : c.name}  [${c.tag.label}]',
                      ),
                    ),
                  )
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
      await uploadCardToSlot(
        _app.device,
        card,
        slot,
        onProgress: (p) {
          _toast('写入卡槽 ${slot + 1}：$p%');
        },
      );
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
                  label: Text(
                    '卡槽 ${i + 1}',
                    style: TextStyle(
                      fontSize: 13,
                      color: hasCard ? Colors.black87 : Colors.grey,
                    ),
                  ),
                  selected: false,
                  onSelected: (_) => Navigator.pop(ctx, i),
                ),
              );
            }),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
          ),
        ],
      ),
    );
  }

  // ========== 导入 ==========
  Future<void> _openImport() async {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _ImportSheet(folderId: _folderId),
    ).then((_) => _reload());
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
    _toast(result.success ? '备份成功：${result.uploaded} 张卡片' : '备份失败，请检查网络或服务器');
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

/// 导入面板（对齐 CU saved_cards 的 importCard）
/// 支持多选文件、PM3/Flipper/MCT/RFID 文本自动识别、CU 单卡 JSON、CU 文件夹包、二进制 dump
class _ImportSheet extends StatefulWidget {
  final String? folderId;

  const _ImportSheet({this.folderId});

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  final _pasteCtrl = TextEditingController();
  final _pasteNameCtrl = TextEditingController();

  Future<Uint8List> _readBytes(PlatformFile f) async =>
      f.bytes ?? await File(f.path!).readAsBytes();

  /// 文本导出自动识别（顺序对齐 CU importCard）
  SaveCard? _parseText(String t, String name) {
    if (t.contains('"Created": "proxmark3",')) return pm3JsonToSaveCard(t);
    if (t.contains('Filetype: Flipper NFC device')) {
      return flipperNfcToSaveCard(t);
    }
    if (t.contains('+Sector: 0')) return mctToSaveCard(t);
    if (t.contains('Filetype: Flipper RFID key')) {
      return flipperRfidToSaveCard(t);
    }
    try {
      final j = jsonDecode(t);
      if (j is Map && j['uid'] != null) {
        return cuJsonToSaveCard(t)..name = name;
      }
    } catch (_) {}
    return null;
  }

  /// 导入单文件（对齐 CU importCard 逐文件分支）
  Future<void> _importOne(
    Uint8List contents,
    String fileName, {
    bool batch = false,
  }) async {
    final name = baseName(fileName);
    String? text;
    try {
      text = utf8.decode(contents);
    } catch (_) {}

    final t = text?.trim() ?? '';
    if (t.isNotEmpty) {
      // CU 卡片文件夹包
      if (isCuCardBundle(t)) {
        final n = await CardLibraryStorage().importCuBundle(
          t,
          targetFolderId: widget.folderId,
        );
        if (mounted) _toast('已导入文件夹：$n 张卡片');
        return;
      }
      SaveCard? card;
      try {
        card = _parseText(t, name);
      } catch (_) {}
      if (card != null) {
        card.name = name;
        card.folderId = widget.folderId;
        await CardLibraryStorage().upsertCard(card);
        if (mounted) {
          _toast('已导入：${card.tag.label}  UID:${card.uid.toUpperCase()}');
        }
        return;
      }
    }

    // 二进制 dump
    final tag = tagTypeByDumpSize(contents.length);
    if (tag == null) {
      if (mounted) _toast('跳过 $fileName：无法识别的内容');
      return;
    }
    if (batch) {
      await _importBinarySilent(contents, tag, fileName);
      return;
    }
    if (mounted) await _showBinaryDialog(contents, tag, fileName);
  }

  /// 从二进制 dump 按卡型切块（对齐 CU blockSize: Classic 16 / 其他 4）
  List<String> _blocksOf(Uint8List d, TagType tag) {
    final size = isMifareClassic(tag) ? 16 : 4;
    return [
      for (var i = 0; i + size <= d.length; i += size)
        StorageService.bytesToHex(d.sublist(i, i + size)),
    ];
  }

  /// 多文件批量：二进制静默导入（对齐 CU files.length > 1 分支）
  Future<void> _importBinarySilent(
    Uint8List contents,
    TagType tag,
    String fileName,
  ) async {
    var cardName = baseName(fileName);
    final dot = cardName.lastIndexOf('.');
    if (dot > 0) cardName = cardName.substring(0, dot);
    final card = SaveCard(
      name: cardName,
      tag: tag,
      uid: bytesToHexSpace(contents.sublist(0, 4)),
      sak: isMifareClassic(tag) && contents.length > 5 ? contents[5] : 0,
      atqa: isMifareClassic(tag) && contents.length > 7
          ? StorageService.bytesToHex(
              Uint8List.fromList([contents[7], contents[6]]),
            )
          : '',
      data: _blocksOf(contents, tag),
      folderId: widget.folderId,
    );
    await CardLibraryStorage().upsertCard(card);
    if (mounted) {
      _toast('已导入：${card.tag.label}  UID:${card.uid.toUpperCase()}');
    }
  }

  /// 单文件二进制：修正标签数据对话框（对齐 CU correct_tag_data）
  Future<void> _showBinaryDialog(
    Uint8List contents,
    TagType tag,
    String fileName,
  ) async {
    final hasUid4 = isMifareClassic(tag);
    Uint8List uid4 = Uint8List(0);
    Uint8List uid7 = Uint8List(0);
    var sak4 = 0;
    var sak7 = 0;
    Uint8List atqa4 = Uint8List(0);
    Uint8List atqa7 = Uint8List(0);

    if (hasUid4) {
      uid4 = contents.sublist(0, 4);
      uid7 = contents.sublist(0, 7);
      sak4 = contents[5];
      atqa4 = Uint8List.fromList([contents[7], contents[6]]);
    } else if (isMifareUltralight(tag)) {
      atqa7 = Uint8List.fromList([0x00, 0x44]);
      uid7 = Uint8List.fromList([
        ...contents.sublist(0, 3),
        ...contents.sublist(4, 8),
      ]);
    }

    final uid4Ctrl = TextEditingController(text: bytesToHexSpace(uid4));
    final sak4Ctrl = TextEditingController(
      text: StorageService.bytesToHex(Uint8List.fromList([sak4])),
    );
    final atqa4Ctrl = TextEditingController(text: bytesToHexSpace(atqa4));
    final uid7Ctrl = TextEditingController(text: bytesToHexSpace(uid7));
    final sak7Ctrl = TextEditingController(
      text: StorageService.bytesToHex(Uint8List.fromList([sak7])),
    );
    final atqa7Ctrl = TextEditingController(text: bytesToHexSpace(atqa7));
    final nameCtrl = TextEditingController(text: baseName(fileName));
    var selectedTag = tag;
    late BuildContext dialogCtx;

    final hexFmt = FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F\s]'));
    String hexOnly(String s) =>
        s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
    Future<bool> showInvalid(String m) async {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('错误'),
          content: Text(m),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return true;
    }

    Future<bool> saveAs(
      int bytes,
      TextEditingController uid,
      TextEditingController sak,
      TextEditingController atqa,
    ) async {
      if (hexOnly(sak.text).length != 2 || hexOnly(atqa.text).length != 4) {
        if (await showInvalid('SAK 需 1 字节、ATQA 需 2 字节十六进制')) {
          return false;
        }
      }
      final s = hexOnly(uid.text);
      if (s.length != bytes * 2) {
        if (await showInvalid('UID 需 $bytes 字节十六进制')) return false;
      }
      final card = SaveCard(
        name: nameCtrl.text.trim(),
        tag: selectedTag,
        uid: uid.text.trim(),
        sak: hexToUint8List(sak.text).isNotEmpty
            ? hexToUint8List(sak.text)[0]
            : 0,
        atqa: StorageService.bytesToHex(hexToUint8List(atqa.text)),
        data: _blocksOf(contents, selectedTag),
        folderId: widget.folderId,
      );
      await CardLibraryStorage().upsertCard(card);
      if (dialogCtx.mounted) Navigator.pop(dialogCtx);
      _toast('已导入：${card.tag.label}  UID:${card.uid.toUpperCase()}');
      return true;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        dialogCtx = dialogContext;
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('修正标签数据'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasUid4) ...[
                    const Text('UID（4 字节）'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: uid4Ctrl,
                      inputFormatters: [hexFmt],
                      decoration: const InputDecoration(
                        labelText: 'UID',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: sak4Ctrl,
                      inputFormatters: [hexFmt],
                      decoration: const InputDecoration(
                        labelText: 'SAK',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: atqa4Ctrl,
                      inputFormatters: [hexFmt],
                      decoration: const InputDecoration(
                        labelText: 'ATQA',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const Text('UID（7 字节）'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: uid7Ctrl,
                    inputFormatters: [hexFmt],
                    decoration: const InputDecoration(
                      labelText: 'UID',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: sak7Ctrl,
                    inputFormatters: [hexFmt],
                    decoration: const InputDecoration(
                      labelText: 'SAK',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: atqa7Ctrl,
                    inputFormatters: [hexFmt],
                    decoration: const InputDecoration(
                      labelText: 'ATQA',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '名称',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButton<TagType>(
                    value: selectedTag,
                    items: _importTagOptions
                        .map(
                          (t) =>
                              DropdownMenuItem(value: t, child: Text(t.label)),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => selectedTag = v);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              if (hasUid4)
                TextButton(
                  onPressed: () => saveAs(4, uid4Ctrl, sak4Ctrl, atqa4Ctrl),
                  child: const Text('保存为 4 字节 UID'),
                ),
              TextButton(
                onPressed: () => saveAs(7, uid7Ctrl, sak7Ctrl, atqa7Ctrl),
                child: const Text('保存为 7 字节 UID'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickFiles() async {
    try {
      final res = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (res == null || res.files.isEmpty) return;
      final total = res.files.length;
      var ok = 0;
      for (final f in res.files) {
        try {
          await _importOne(
            await _readBytes(f),
            f.name,
            batch: res.files.length > 1,
          );
          ok++;
        } catch (e) {
          if (mounted) _toast('导入失败 ${f.name}: $e');
        }
      }
      if (mounted && ok > 0) _toast('导入完成：成功 $ok / $total');
    } catch (e) {
      if (mounted) _toast('选择文件失败: $e');
    }
  }

  Future<void> _pasteImport() async {
    final text = _pasteCtrl.text.trim();
    if (text.isEmpty) {
      _toast('请先粘贴导出内容');
      return;
    }
    final name = _pasteNameCtrl.text.trim();
    try {
      final card = _parseText(text, name.isNotEmpty ? name : '导入卡片');
      if (card != null) {
        card.name = name.isNotEmpty ? name : card.name;
        card.folderId = widget.folderId;
        await CardLibraryStorage().upsertCard(card);
        if (mounted) {
          _toast('已导入：${card.tag.label}  UID:${card.uid.toUpperCase()}');
          Navigator.pop(context);
        }
        return;
      }
    } catch (e) {
      if (mounted) _toast('导入失败: $e');
      return;
    }
    if (mounted) {
      _toast('无法识别格式，支持 PM3 / Flipper NFC / Flipper RFID / MCT / CU JSON');
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '导入卡片',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ActionButton(
            label: '选择文件',
            icon: Icons.file_upload,
            onTap: _pickFiles,
            stretch: true,
          ),
          const SizedBox(height: 8),
          const Text('或直接粘贴导出内容', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          TextField(
            controller: _pasteCtrl,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: '粘贴 PM3 / Flipper / MCT / CU JSON 文本',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pasteNameCtrl,
            decoration: const InputDecoration(
              hintText: '卡片名称（可选）',
              prefixIcon: Icon(Icons.label_outline),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              ActionButton(label: '导入', icon: Icons.check, onTap: _pasteImport),
            ],
          ),
        ],
      ),
    );
  }
}
