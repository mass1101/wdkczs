import 'dart:convert';
import 'dart:io' as io;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/dictionary_store.dart';
import '../widgets/common.dart';
import 'dictionary_edit_dialog.dart';

/// 字典管理页（对齐 CU 字典下载菜单）
/// 文件夹 / 字典 CRUD、移动、删除子树、导出 .dic 与文件夹包、导入
class DictionaryManagerScreen extends StatefulWidget {
  const DictionaryManagerScreen({super.key});

  @override
  State<DictionaryManagerScreen> createState() => _DictionaryManagerScreenState();
}

class _DictionaryManagerScreenState extends State<DictionaryManagerScreen> {
  final DictionaryStorage _storage = DictionaryStorage();
  final List<Dictionary> _entries = [];
  final List<DictionaryFolder> _folders = [];
  String? _folderId;
  bool _busy = false;

  static const List<int> _pickerColors = [
    0xFFFF5722,
    0xFF8BC34A,
    0xFFE53935,
    0xFF1E88E5,
    0xFF8E24AA,
    0xFFFFC107,
    0xFF00ACC1,
    0xFF5D4037,
    0xFFEC407A,
  ];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final dicts = await _storage.getDictionaries();
    final folders = await _storage.getFolders();
    if (!mounted) return;
    setState(() {
      _entries
        ..clear()
        ..addAll(dicts);
      _folders
        ..clear()
        ..addAll(folders);
      if (_folderId != null && !_folders.any((f) => f.id == _folderId)) {
        _folderId = null;
      }
    });
  }

  DictionaryFolder? get _currentFolder {
    final id = _folderId;
    if (id == null) return null;
    for (final f in _folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  List<Dictionary> get _currentEntries => _folderId == null
      ? const []
      : _entries.where((d) => d.folderId == _folderId).toList();

  int _countIn(String folderId) =>
      _entries.where((d) => d.folderId == folderId).length;

  int _subtreeCount(String folderId) =>
      _storage.countDictionariesInSubtree(folderId, _folders, _entries);

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _setBusy(bool v) => setState(() => _busy = v);

  @override
  Widget build(BuildContext context) {
    final inFolder = _folderId != null;
    final folder = _currentFolder;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          inFolder ? (folder?.name ?? '字典') : '字典管理',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: inFolder
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _folderId = null),
              )
            : null,
        actions: inFolder && folder != null
            ? [
                IconButton(
                    tooltip: '新建字典',
                    icon: const Icon(Icons.note_add),
                    onPressed: () => _addEntry()),
                IconButton(
                    tooltip: '导出',
                    icon: const Icon(Icons.file_download),
                    onPressed: () => _showExportSheet(folder)),
                IconButton(
                    tooltip: '编辑文件夹',
                    icon: const Icon(Icons.edit),
                    onPressed: () => _editFolder(folder)),
                IconButton(
                    tooltip: '删除文件夹',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteFolder(folder)),
              ]
            : [
                IconButton(
                    tooltip: '新建文件夹',
                    icon: const Icon(Icons.create_new_folder),
                    onPressed: _addFolder),
                IconButton(
                    tooltip: '新建字典',
                    icon: const Icon(Icons.note_add),
                    onPressed: _addEntry),
                IconButton(
                    tooltip: '导入',
                    icon: const Icon(Icons.file_upload),
                    onPressed: _import),
                IconButton(
                    tooltip: '导出全部',
                    icon: const Icon(Icons.file_download),
                    onPressed: _exportAll),
              ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : (inFolder ? _buildFolderBody() : _buildRootBody()),
    );
  }

  // ---------------- 列表 ----------------

  Widget _buildRootBody() {
    if (_folders.isEmpty) {
      return _buildEmpty(
        const Icon(Icons.folder_outlined, size: 52, color: Colors.grey),
        '还没有字典文件夹\n先新建一个文件夹，再往里放字典',
         action: ActionButton(
           label: '新建文件夹',
           icon: Icons.create_new_folder,
           onTap: _addFolder,
         ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Row(
            children: [
              const Icon(Icons.bookmarks, size: 18, color: Color(0xFF888888)),
              const SizedBox(width: 6),
              Text('共 ${_folders.length} 个文件夹 / ${_entries.length} 个字典',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF888888))),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 80),
            itemCount: _folders.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final f = _folders[i];
              final own = _countIn(f.id);
              final subtree = _subtreeCount(f.id);
              return _Row(
                color: f.colorValue,
                icon: Icons.folder,
                title: f.name,
                subtitle: '$own 个字典${subtree > own ? '（含子文件夹 $subtree）' : ''}',
                trailing: [
                  IconButton(
                      icon: const Icon(Icons.move_to_inbox, size: 18),
                      onPressed: () => _moveFolder(f),
                      tooltip: '移动'),
                  IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => _deleteFolder(f),
                      tooltip: '删除'),
                ],
                onTap: () => setState(() => _folderId = f.id),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFolderBody() {
    final list = _currentEntries;
    if (list.isEmpty) {
      return _buildEmpty(
        const Icon(Icons.book_outlined, size: 52, color: Colors.grey),
        '该文件夹还没有字典',
        action: ActionButton(label: '新建字典', icon: Icons.note_add, onTap: _addEntry),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 80),
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final d = list[i];
        return _Row(
          color: d.colorValue,
          icon: Icons.book,
          title: d.name,
          subtitle: '${d.keys.length} 个密钥 · ${d.keyLength ~/ 2} 字节',
          trailing: [
            IconButton(
                icon: const Icon(Icons.move_to_inbox, size: 18),
                onPressed: () => _moveEntry(d),
                tooltip: '移动'),
            IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => _deleteEntry(d),
                tooltip: '删除'),
          ],
          onTap: () => _viewEntry(d),
        );
      },
    );
  }

  Widget _buildEmpty(Widget icon, String text, {Widget? action}) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        icon,
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF999999))),
        ),
        if (action != null) ...[const SizedBox(height: 18), action],
      ],
    );
  }

  // ---------------- 文件夹 ----------------

  Future<void> _addFolder() async {
    final ctrl = TextEditingController();
    final color = <int>[0xFFFF5722];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _FolderDialog(
        title: '新建文件夹',
        nameCtrl: ctrl,
        color: color[0],
        onColor: (c) => color[0] = c,
        confirmText: '创建',
      ),
    );
    if (ok != true) return;
    final f = DictionaryFolder(
        name: ctrl.text.trim(), parentId: _folderId, colorValue: color[0]);
    await _storage.upsertFolder(f);
    await _reload();
    setState(() => _folderId = f.id);
  }

  Future<void> _editFolder(DictionaryFolder f) async {
    final ctrl = TextEditingController(text: f.name);
    final color = <int>[f.colorValue];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _FolderDialog(
        title: '编辑文件夹',
        nameCtrl: ctrl,
        color: color[0],
        onColor: (c) => color[0] = c,
        confirmText: '保存',
      ),
    );
    if (ok != true) return;
    f.name = ctrl.text.trim();
    f.colorValue = color[0];
    await _storage.upsertFolder(f);
    await _reload();
  }

  Future<void> _deleteFolder(DictionaryFolder f) async {
    final n = _subtreeCount(f.id);
    final ok = await _confirm('删除文件夹「${f.name}」？',
        '将同时删除其下所有子文件夹，$n 个字典会被移除');
    if (ok != true) return;
    await _storage.deleteFolder(f.id);
    await _reload();
    setState(() => _folderId = null);
  }

  Future<void> _moveFolder(DictionaryFolder f) async {
    final target = await _pickFolder('移动文件夹到…', exclude: f.id);
    if (target == null) {
      if (f.parentId != null) {
        f.parentId = null;
        await _storage.upsertFolder(f);
        await _reload();
      }
      return;
    }
    f.parentId = target;
    await _storage.upsertFolder(f);
    await _reload();
  }

  // ---------------- 字典 ----------------

  Future<void> _addEntry() async {
    if (_folderId == null) {
      _toast('请先新建或进入一个文件夹');
      return;
    }
    final d = await DictionaryEditDialog.show(context);
    if (d == null) return;
    d.folderId = _folderId;
    await _storage.upsertDictionary(d);
    await _reload();
    _toast('已新建字典「${d.name}」');
  }

  Future<void> _editEntry(Dictionary d) async {
    final result = await DictionaryEditDialog.show(context, dictionary: d);
    if (result == null) return;
    await _storage.upsertDictionary(result);
    await _reload();
    _toast('已保存字典「${result.name}」');
  }

  Future<void> _deleteEntry(Dictionary d) async {
    final ok = await _confirm('删除字典「${d.name}」？',
        '将删除该字典中的 ${d.keys.length} 个密钥');
    if (ok != true) return;
    await _storage.deleteDictionary(d.id);
    await _reload();
  }

  Future<void> _moveEntry(Dictionary d) async {
    final target = await _pickFolder('移动字典到…', current: d.folderId);
    if (target == null && d.folderId != null) {
      await _storage.moveDictionary(d.id, null);
      await _reload();
    } else if (target != null) {
      await _storage.moveDictionary(d.id, target);
      await _reload();
    }
  }

  Future<String?> _pickFolder(String title, {String? exclude, String? current}) async {
    final options = <MapEntry<String, String>>[
      const MapEntry('', '（根目录）'),
      for (final f in _folders)
        if (f.id != exclude)
          MapEntry(f.id, '${f.name}${f.id == current ? ' (当前)' : ''}'),
    ];
    if (options.length <= 1) {
      _toast('没有可移动到的目标文件夹');
      return null;
    }
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            for (final opt in options)
              ListTile(
                leading: Icon(
                    opt.key.isEmpty ? Icons.drive_folder_upload : Icons.folder),
                title: Text(opt.value),
                onTap: () => Navigator.pop(ctx, opt.key.isEmpty ? null : opt.key),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------- 查看 ----------------

  void _viewEntry(Dictionary d) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _EntryViewDialog(entry: d, onEdit: () => _editEntry(d)),
    );
  }

  // ---------------- 导出 ----------------

  Future<void> _exportAll() async {
    if (_folders.isEmpty) {
      _toast('没有可导出的字典文件夹');
      return;
    }
    _setBusy(true);
    try {
      for (final f in _folders.where((x) => x.parentId == null).toList()) {
        final bundle = DictionaryStorage.buildFolderBundle(_folders, _entries, f.id);
        final json = bundle.bundleJson();
        if (!await _saveFile(
            json, '${f.name}.dic.bundle',
            bytes: Uint8List.fromList(Utf8Encoder().convert(json)))) {
          return;
        }
      }
      _toast('已导出全部字典文件夹');
    } finally {
      _setBusy(false);
    }
  }

  void _showExportSheet(DictionaryFolder folder) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text('导出',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.folder_special),
              title: const Text('导出文件夹包'),
              subtitle: const Text('包含子文件夹及其字典，.dic.bundle'),
              onTap: () async {
                Navigator.pop(ctx);
                await _exportFolderBundle(folder);
              },
            ),
            for (final d in _currentEntries)
              ListTile(
                leading: const Icon(Icons.book),
                title: Text(d.name),
                subtitle: Text('${d.keys.length} 个密钥，.dic'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _exportEntry(d);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportFolderBundle(DictionaryFolder f) async {
    final bundle = DictionaryStorage.buildFolderBundle(_folders, _entries, f.id);
    final json = bundle.bundleJson();
    final name = '${f.name}.dic.bundle';
    await _saveFile(json, name,
        bytes: Uint8List.fromList(Utf8Encoder().convert(json)));
    if (!mounted) return;
    _toast('已导出 $name');
  }

  Future<void> _exportEntry(Dictionary d) async {
    final text = _storage.dictionaryText(d);
    final name = '${d.name}.dic';
    await _saveFile(text, name,
        bytes: Uint8List.fromList(Utf8Encoder().convert(text)));
    if (!mounted) return;
    _toast('已导出 $name');
  }

  Future<bool> _saveFile(String content, String fileName,
      {required Uint8List bytes}) async {
    final savedPath = await FilePicker.platform.saveFile(
      fileName: fileName,
      initialDirectory: '.',
      bytes: bytes,
    );
    return savedPath != null && savedPath.isNotEmpty;
  }

  // ---------------- 导入 ----------------

  Future<void> _import() async {
    _setBusy(true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['dic', 'txt', 'bundle'],
      );
      if (result == null || result.files.isEmpty) return;
      final pf = result.files.single;
      final List<int> raw = pf.path != null
          ? await io.File(pf.path!).readAsBytes()
          : (pf.bytes ?? Uint8List(0));
      if (raw.isEmpty) return;
      final text = utf8.decode(raw, allowMalformed: true).trim();
      if (text.isEmpty) return;

      // 先尝试按 CU 文件夹包解析，失败则按纯文本字典导入
      try {
        final json = jsonDecode(text) as Map<String, dynamic>;
        if (json['format'] ==
            DictionaryFolderBundle.format &&
            (json['version'] ?? 0) == DictionaryFolderBundle.version) {
          await _storage.importBundle(text, targetFolderId: _folderId);
          await _reload();
          _toast('已导入字典文件夹包');
          return;
        }
      } catch (_) {}

      final count = await _storage.importText(text,
          folderId: _folderId, name: _stripExt(pf.name));
      await _reload();
      if (count == 0) {
        _toast('文件中没有有效密钥（需为 12/8/32 位 16 进制）');
      } else {
        _toast('已导入 $count 个字典');
      }
    } finally {
      if (mounted) _setBusy(false);
    }
  }

  static String _stripExt(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  // ---------------- 通用确认 ----------------

  Future<bool?> _confirm(String title, String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

/// 文件夹新建 / 编辑弹窗
class _FolderDialog extends StatelessWidget {
  const _FolderDialog({
    required this.title,
    required this.nameCtrl,
    required this.color,
    required this.onColor,
    required this.confirmText,
  });

  final String title;
  final TextEditingController nameCtrl;
  final int color;
  final ValueChanged<int> onColor;
  final String confirmText;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameCtrl,
            maxLength: 32,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: '文件夹名称',
                border: OutlineInputBorder(),
                counterText: ''),
          ),
          const SizedBox(height: 12),
          ColorPickerRow(
            colors: _DictionaryManagerScreenState._pickerColors,
            selected: color,
            onChange: onColor,
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        TextButton(
          onPressed: () {
            if (nameCtrl.text.trim().isEmpty) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('请输入文件夹名称')));
              return;
            }
            Navigator.pop(context, true);
          },
          child: Text(confirmText),
        ),
      ],
    );
  }
}

/// 字典查看弹窗
class _EntryViewDialog extends StatelessWidget {
  const _EntryViewDialog({required this.entry, required this.onEdit});

  final Dictionary entry;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final text = entry.keys.join('\n');
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Color(entry.colorValue),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () {
                    Navigator.pop(context);
                    onEdit();
                  },
                ),
              ],
            ),
            Text('${entry.keys.length} 个密钥 · ${entry.keyLength ~/ 2} 字节 · '
                '${entry.keyLength} 位 hex',
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999))),
            const Divider(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 13, height: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: ActionButton(
                label: '复制全部',
                icon: Icons.copy,
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('已复制到剪贴板'),
                          duration: Duration(seconds: 1)));
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// 列表行通用样式
class _Row extends StatelessWidget {
  const _Row({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing = const [],
  });

  final int color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      elevation: 0.5,
      shadowColor: const Color(0x0A000000),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Color(color),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 1),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF999999))),
                  ],
                ),
              ),
              ...trailing,
            ],
          ),
        ),
      ),
    );
  }
}
