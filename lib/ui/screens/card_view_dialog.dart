import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/card_library.dart';
import 'card_analyze_screen.dart';
import 'card_cloud_analyze_screen.dart';
import 'card_compare_screen.dart';
import 'card_edit_dialog.dart';
import 'dump_editor.dart';

/// 卡片查看对话框（对齐 CU CardViewMenu）
class CardViewDialog extends StatefulWidget {
  final SaveCard card;
  final Future<void> Function(SaveCard card)? onMove;
  final VoidCallback? onChanged;

  const CardViewDialog({
    super.key,
    required this.card,
    this.onMove,
    this.onChanged,
  });

  @override
  State<CardViewDialog> createState() => _CardViewDialogState();
}

class _CardViewDialogState extends State<CardViewDialog> {
  late SaveCard _card;

  @override
  void initState() {
    super.initState();
    _card = widget.card;
  }

  void _refreshCardData() async {
    final updated = await CardLibraryStorage().getCardById(widget.card.id);
    if (updated != null && mounted) {
      setState(() => _card = updated);
    }
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已复制: $text'),
          duration: const Duration(seconds: 1),
        ),
      );
  }

  Widget _infoRow(String label, String value, {bool copyable = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF888888)),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '不可用' : value,
              style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
            ),
          ),
          if (copyable && value.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy, size: 16, color: Color(0xFF888888)),
              onPressed: () => _copy(value),
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.only(left: 4),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLf = isLfTag(_card.tag);
    final isHf = !isLf;
    final isClassic = isMifareClassic(_card.tag);
    final isUltralight = isMifareUltralight(_card.tag);

    final sakHex = _card.sak.toRadixString(16).padLeft(2, '0');
    final atqaDisplay = _card.atqa.isEmpty
        ? ''
        : _formatHexWithSpace(_card.atqa);

    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _card.name.isEmpty ? '未命名' : _card.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          leading: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭', style: TextStyle(color: Colors.white)),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 基本信息
            Container(
              padding: const EdgeInsets.all(12),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isLf ? Icons.wifi : Icons.credit_card,
                        color: _card.color,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _card.tag.label,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isLf
                              ? const Color(0xFFFF9800)
                              : const Color(0xFF2196F3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isLf ? 'LF' : 'HF',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 16),
                  _infoRow('UID', _card.uid),
                  if (isHf) ...[
                    _infoRow('SAK', sakHex),
                    _infoRow('ATQA', atqaDisplay),
                    if (_card.ats.isNotEmpty)
                      _infoRow('ATS', _formatHexWithSpace(_card.ats)),
                  ],
                  if (isUltralight) ...[
                    if (_card.ultralightVersion.isNotEmpty)
                      _infoRow(
                        '版本',
                        _formatHexWithSpace(_card.ultralightVersion),
                      ),
                    if (_card.ultralightSignature.isNotEmpty)
                      _infoRow(
                        '签名',
                        _formatHexWithSpace(_card.ultralightSignature),
                      ),
                    if (_card.ultralightCounters.isNotEmpty)
                      _infoRow(
                        '计数器',
                        _card.ultralightCounters
                            .map((c) => c.toString())
                            .join(', '),
                        copyable: false,
                      ),
                  ],
                  _infoRow('数据块', '${_card.data.length} 块', copyable: false),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 操作按钮
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: const Text('编辑'),
                  avatar: const Icon(Icons.edit, size: 18),
                  onPressed: () async {
                    final changed = await showDialog<bool>(
                      context: context,
                      builder: (_) => CardEditDialog(card: _card),
                    );
                    if (changed == true) {
                      _refreshCardData();
                      widget.onChanged?.call();
                    }
                  },
                ),
                ActionChip(
                  label: const Text('复制'),
                  avatar: const Icon(Icons.copy_all, size: 18),
                  onPressed: () async {
                    final dup = _card.copy();
                    dup.id =
                        'c${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
                    dup.name = '${_card.name} (副本)';
                    dup.updatedAt = DateTime.now();
                    await CardLibraryStorage().upsertCard(dup);
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    widget.onChanged?.call();
                  },
                ),
                if (isClassic || isUltralight)
                  ActionChip(
                    label: const Text('Dump 编辑器'),
                    avatar: const Icon(Icons.edit_document, size: 18),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DumpEditor(card: _card),
                        ),
                      ).then((changed) {
                        if (changed == true) {
                          _refreshCardData();
                          widget.onChanged?.call();
                        }
                      });
                    },
                  ),
                if (isClassic)
                  ActionChip(
                    label: const Text('分析'),
                    avatar: const Icon(Icons.insights, size: 18),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CardAnalyzeScreen(card: _card),
                        ),
                      );
                    },
                  ),
                if (isClassic)
                  ActionChip(
                    label: const Text('云端分析'),
                    avatar: const Icon(Icons.cloud_upload_outlined, size: 18),
                    onPressed: () =>
                        CardCloudAnalyzeScreen.launch(context, _card),
                  ),
                if (isClassic || isUltralight)
                  ActionChip(
                    label: const Text('比较'),
                    avatar: const Icon(Icons.compare_arrows, size: 18),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CardCompareScreen(card: _card),
                        ),
                      );
                    },
                  ),
                if (widget.onMove != null)
                  ActionChip(
                    label: const Text('移动'),
                    avatar: const Icon(Icons.drive_file_move_outline, size: 18),
                    onPressed: () async {
                      await widget.onMove!(_card);
                      _refreshCardData();
                    },
                  ),
                ActionChip(
                  label: const Text('导出 JSON'),
                  avatar: const Icon(Icons.download, size: 18),
                  onPressed: () {
                    _copy(_card.toJson());
                  },
                ),
                ActionChip(
                  label: const Text('删除'),
                  avatar: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: Colors.red,
                  ),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('删除卡片'),
                        content: Text(
                          '确定删除「${_card.name.isEmpty ? _card.uid : _card.name}」？',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text(
                              '删除',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    await CardLibraryStorage().deleteCard(_card.id);
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    widget.onChanged?.call();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatHexWithSpace(String hex) {
    if (hex.isEmpty) return '';
    final clean = hex.replaceAll(RegExp(r'\s'), '');
    final buf = StringBuffer();
    for (int i = 0; i < clean.length; i += 2) {
      if (i > 0) buf.write(' ');
      buf.write(clean.substring(i, i + 2));
    }
    return buf.toString();
  }
}
