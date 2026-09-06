import 'package:flutter/material.dart';

import '../../services/storage_service.dart';
import 'text_input_dialog.dart';

/// 密钥列表弹窗（对齐小程序 keyfile_modal / file_modal）
/// 点击某项以 (name, content) 返回加载该密钥；「使用默认密钥」返回 ('', '')
class KeyFileSheet extends StatefulWidget {
  final StorageService storage;
  final String cardUid;

  const KeyFileSheet({super.key, required this.storage, required this.cardUid});

  @override
  State<KeyFileSheet> createState() => _KeyFileSheetState();
}

class _KeyFileSheetState extends State<KeyFileSheet> {
  Map<String, String> _files = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final f = await widget.storage.getKeyNames();
    if (!mounted) return;
    setState(() {
      _files = f;
      _loading = false;
    });
  }

  int _keyCount(String content) => content
      .split('\n')
      .map((e) => e.trim())
      .where((e) =>
          e.isNotEmpty && RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(e))
      .length;

  void _pick(String name, String content) {
    Navigator.pop(context, (name, content));
  }

  Future<void> _import() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          const TextInputDialog(title: '新建/导入密钥文件', hint: '输入文件名'),
    );
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;
    final content = await showDialog<String>(
      context: context,
      builder: (ctx) => const TextInputDialog(
        title: '密钥内容',
        hint: '粘贴或输入，每行一个 12 位十六进制密钥',
        multiline: true,
      ),
    );
    if (content != null && mounted) {
      await widget.storage.saveKey(name.trim(), content);
      await _reload();
    }
  }

  Future<void> _rename(String name) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => TextInputDialog(
        title: '重命名密钥文件',
        hint: '输入新文件名',
        initial: name,
      ),
    );
    if (newName == null || newName.trim().isEmpty || newName.trim() == name) {
      return;
    }
    final content = await widget.storage.getKey(name);
    await widget.storage.saveKey(newName.trim(), content);
    await widget.storage.delKey(name);
    await _reload();
  }

  Future<void> _del(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除密钥文件', style: TextStyle(fontSize: 16)),
        content: Text('即将删除「$name」，继续吗？', style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await widget.storage.delKey(name);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('密钥列表',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 4),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.key, size: 18),
                    title: const Text('使用默认密钥', style: TextStyle(fontSize: 13)),
                    onTap: () => _pick('', ''),
                  ),
                  if (_files.isEmpty && !_loading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('暂无密钥文件，点下方新建',
                          style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
                    )
                  else
                    ..._files.entries.map((e) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.folder, size: 18),
                          title: Text(e.key, style: const TextStyle(fontSize: 13)),
                          subtitle: Text('${_keyCount(e.value)} 个密钥',
                              style: const TextStyle(fontSize: 11)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.drive_file_rename_outline,
                                    size: 18),
                                onPressed: () => _rename(e.key),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.delete_outline,
                                    size: 18, color: Colors.red),
                                onPressed: () => _del(e.key),
                              ),
                            ],
                          ),
                          onTap: () => _pick(e.key, e.value),
                        )),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      Future.microtask(_import);
                    },
                    icon: Icon(Icons.add, size: 16, color: primary),
                    label: const Text('新建/导入', style: TextStyle(fontSize: 12)),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭', style: TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
