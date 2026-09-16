import 'package:flutter/material.dart';

import '../../services/card_backup.dart';
import '../../services/storage_service.dart';

/// 云端备份管理弹窗：查看云端备份卡片，支持多选批量删除
class CloudBackupManagerDialog extends StatefulWidget {
  final StorageService storage;
  final String chipId;

  const CloudBackupManagerDialog({
    super.key,
    required this.storage,
    required this.chipId,
  });

  @override
  State<CloudBackupManagerDialog> createState() =>
      _CloudBackupManagerDialogState();
}

class _CloudBackupManagerDialogState
    extends State<CloudBackupManagerDialog> {
  bool _loading = true;
  String? _error;
  List<CloudCard> _cards = const [];
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await fetchCloudCards(widget.storage, chipId: widget.chipId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _selected.clear();
      if (res == null) {
        _error = '获取云端备份失败：未配置备份、无备份记录或网络异常';
        _cards = const [];
      } else {
        _cards = res.$1;
        _error = res.$2 > 0
            ? '已加载 ${res.$1.length} 张，${res.$2} 张格式异常未显示'
            : null;
      }
    });
  }

  void _toggle(String id, bool value) {
    setState(() {
      if (value) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  void _toggleAll(bool value) {
    setState(() {
      if (value) {
        _selected.addAll(_cards.map((c) => c.card.id));
      } else {
        _selected.clear();
      }
    });
  }

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除云端备份'),
        content: Text('确定从云端删除选中的 ${ids.length} 张卡片备份吗？本地卡库不受影响。'),
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
    if (ok != true || !mounted) return;

    setState(() => _loading = true);
    final n = await deleteCloudCards(
      widget.storage,
      ids,
      chipId: widget.chipId,
    );
    if (!mounted) return;
    if (n < 0) {
      setState(() {
        _loading = false;
        _error = '删除失败：服务器不支持删除云端备份';
      });
      return;
    }
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除 $n 张云端备份'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Text('云端备份管理', style: TextStyle(fontSize: 16)),
          const Spacer(),
          TextButton.icon(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('刷新'),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : _buildBody(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        ElevatedButton(
          onPressed: _selected.isEmpty ? null : _deleteSelected,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          child: Text('删除选中 (${_selected.length})'),
        ),
      ],
    );
  }

  Widget _buildBody() {
    final allChecked = _cards.isNotEmpty && _selected.length == _cards.length;
    if (_cards.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null)
              Text(
                _error!,
                style: const TextStyle(fontSize: 13, color: Colors.red),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                '云端暂无备份卡片',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
        SizedBox(
          height: 320,
          child: ListView.builder(
            itemCount: _cards.length,
            itemBuilder: (ctx, i) {
              final c = _cards[i].card;
              return CheckboxListTile(
                value: _selected.contains(c.id),
                onChanged: (v) => _toggle(c.id, v == true),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text(
                  c.name.isEmpty ? c.uid : c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '${c.uid} · ${c.tag.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF888888),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              '共 ${_cards.length} 张 · 已选 ${_selected.length} 张',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF666666),
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => _toggleAll(!allChecked),
              child: Text(allChecked ? '取消全选' : '全选'),
            ),
          ],
        ),
      ],
    );
  }
}
