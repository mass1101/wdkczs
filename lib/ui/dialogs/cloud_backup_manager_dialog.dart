import 'package:flutter/material.dart';

import '../../services/card_backup.dart';
import '../../services/storage_service.dart';

/// 云端备份管理弹窗：查看云端备份记录，支持多选批量删除单卡或整条备份
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
  List<CloudBackupEntry> _entries = const [];
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
    final entries = await fetchCloudBackups(widget.storage, chipId: widget.chipId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _selected.clear();
      if (entries == null) {
        _error = '获取云端备份失败：未配置备份令牌、令牌未注册或网络异常';
        _entries = const [];
      } else {
        _entries = entries;
        _error = null;
      }
    });
  }

  String _key(int backupId, int index) => '$backupId#$index';

  void _toggle(String key, bool value) {
    setState(() {
      if (value) {
        _selected.add(key);
      } else {
        _selected.remove(key);
      }
    });
  }

  void _toggleEntry(CloudBackupEntry entry, bool value) {
    setState(() {
      for (final c in entry.cards) {
        final key = _key(c.backupId, c.index);
        if (value) {
          _selected.add(key);
        } else {
          _selected.remove(key);
        }
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除云端备份'),
        content: Text(
          '确定从云端删除选中的 ${_selected.length} 张卡片备份吗？本地卡包不受影响。',
        ),
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

    final byBackup = <int, List<int>>{};
    for (final key in _selected) {
      final parts = key.split('#');
      if (parts.length != 2) continue;
      final id = int.tryParse(parts[0]);
      final idx = int.tryParse(parts[1]);
      if (id == null || idx == null) continue;
      byBackup.putIfAbsent(id, () => []).add(idx);
    }

    setState(() => _loading = true);
    var deleted = 0;
    var failed = 0;
    for (final entry in byBackup.entries) {
      final indexes = entry.value..sort((a, b) => b.compareTo(a));
      for (final idx in indexes) {
        final remaining = await deleteCloudBackupCard(
          widget.storage,
          entry.key,
          idx,
          chipId: widget.chipId,
        );
        if (remaining < 0) {
          failed++;
        } else {
          deleted++;
        }
      }
    }
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    final msg = failed > 0
        ? '已删除 $deleted 张，$failed 张失败'
        : '已删除 $deleted 张云端备份';
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _deleteEntry(CloudBackupEntry entry) async {
    if (entry.cards.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除备份记录'),
        content: Text(
          '确定删除备份 #${entry.id} 的全部 ${entry.cards.length} 张卡片吗？本地卡包不受影响。',
        ),
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
    final n = await deleteCloudBackup(widget.storage, entry.id, chipId: widget.chipId);
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(n < 0 ? '删除失败' : '已删除备份 #$entry.id（$n 张）'),
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
        width: 460,
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
    if (_entries.isEmpty) {
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
                '云端暂无备份记录',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      );
    }
    final rows = <Widget>[];
    for (final entry in _entries) {
      rows.add(_buildSectionHeader(entry));
      for (final card in entry.cards) {
        rows.add(_buildCardTile(card));
      }
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
          child: ListView(children: rows),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              '共 ${_entries.length} 条备份 · 已选 ${_selected.length} 张',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF666666),
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => _toggleAll(!_allChecked),
              child: Text(_allChecked ? '取消全选' : '全选'),
            ),
          ],
        ),
      ],
    );
  }

  bool get _allChecked =>
      _entries.isNotEmpty &&
      _selected.length ==
          _entries.fold<int>(0, (sum, e) => sum + e.cards.length);

  void _toggleAll(bool value) {
    setState(() {
      _selected.clear();
      if (value) {
        for (final e in _entries) {
          for (final c in e.cards) {
            _selected.add(_key(c.backupId, c.index));
          }
        }
      }
    });
  }

  Widget _buildSectionHeader(CloudBackupEntry entry) {
    final allChecked = entry.cards
        .every((c) => _selected.contains(_key(c.backupId, c.index)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 2),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(
              allChecked
                  ? Icons.check_box
                  : Icons.check_box_outline_blank,
              size: 18,
              color: Colors.grey,
            ),
            onPressed: () => _toggleEntry(entry, !allChecked),
          ),
          Expanded(
            child: Text(
              '备份 #${entry.id} · ${entry.timestamp.isEmpty ? '未知时间' : entry.timestamp} · ${entry.cards.length} 张',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: _loading ? null : () => _deleteEntry(entry),
            child: const Text(
              '删除全部',
              style: TextStyle(fontSize: 12, color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardTile(CloudBackupCardItem card) {
    final key = _key(card.backupId, card.index);
    return CheckboxListTile(
      value: _selected.contains(key),
      onChanged: (v) => _toggle(key, v == true),
      controlAffinity: ListTileControlAffinity.leading,
      dense: true,
      title: Text(
        card.name.isEmpty ? card.uid : card.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          card.uid,
          if (card.tagType.isNotEmpty) card.tagType,
          if (card.hasBin) '含 dump',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
      ),
    );
  }
}
