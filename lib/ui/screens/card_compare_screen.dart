import 'package:flutter/material.dart';

import '../../services/card_library.dart';
import '../widgets/common.dart';
import 'dump_editor.dart';

/// 两张卡 Dump 的单块差异
class DiffBlock {
  const DiffBlock({
    required this.index,
    required this.left,
    required this.right,
  });

  final int index;
  final String left;
  final String right;

  /// 差异字节个数（2 位 hex 视为 1 字节）
  int diffByteCount() {
    final a = _clean(left);
    final b = _clean(right);
    final n = a.length < b.length ? a.length : b.length;
    var cnt = 0;
    for (var i = 0; i + 2 <= n; i += 2) {
      if (a.substring(i, i + 2) != b.substring(i, i + 2)) cnt++;
    }
    return cnt;
  }

  static String _clean(String s) => s.replaceAll(RegExp(r'\s'), '').toLowerCase();
}

/// Dump 对比结果
class DumpDiff {
  const DumpDiff({required this.total, required this.diffs, required this.leftSize, required this.rightSize});

  final int total;
  final List<DiffBlock> diffs;
  final int leftSize;
  final int rightSize;

  int get diffCount => diffs.length;

  double get ratio => total == 0 ? 0 : diffs.length / total;
}

/// 比较两张同类型卡的 Dump
DumpDiff computeDumpDiff(SaveCard a, SaveCard b) {
  final total = a.data.length > b.data.length ? a.data.length : b.data.length;
  final diffs = <DiffBlock>[];
  for (var i = 0; i < total; i++) {
    final l = i < a.data.length ? a.data[i] : '00' * 16;
    final r = i < b.data.length ? b.data[i] : '00' * 16;
    if (l.replaceAll(RegExp(r'\s'), '').toLowerCase() !=
        r.replaceAll(RegExp(r'\s'), '').toLowerCase()) {
      diffs.add(DiffBlock(index: i, left: l, right: r));
    }
  }
  return DumpDiff(
    total: total,
    diffs: diffs,
    leftSize: a.data.length,
    rightSize: b.data.length,
  );
}

/// 卡片比较页：选择同类型卡作为对比目标，展示逐块差异
class CardCompareScreen extends StatefulWidget {
  final SaveCard card;

  const CardCompareScreen({super.key, required this.card});

  @override
  State<CardCompareScreen> createState() => _CardCompareScreenState();
}

class _CardCompareScreenState extends State<CardCompareScreen> {
  final CardLibraryStorage _storage = CardLibraryStorage();
  List<SaveCard> _candidates = [];
  SaveCard? _target;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cards = await _storage.getCards();
    final candidates = cards
        .where((c) => c.tag == widget.card.tag && c.id != widget.card.id)
        .toList();
    setState(() {
      _candidates = candidates;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.card.name.isEmpty ? widget.card.uid : widget.card.name;
    return Scaffold(
      appBar: AppBar(
        title: Text('比较 - $name', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _candidates.isEmpty
              ? _buildEmpty()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 80),
                  children: [
                    const Text('选择对比卡',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF888888))),
                    const SizedBox(height: 8),
                    for (final c in _candidates)
                      _CandidateRow(
                        card: c,
                        selected: _target?.id == c.id,
                        onChanged: (sel) => setState(() => _target = sel ? c : null),
                      ),
                    const SizedBox(height: 10),
                    if (_target != null) ...[
                      _buildDiffSummary(computeDumpDiff(widget.card, _target!)),
                      const SizedBox(height: 8),
                      Center(
                        child: ActionButton(
                          label: '在编辑器中逐字节对比',
                          icon: Icons.compare_arrows,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  DumpEditor(card: widget.card, compareTarget: _target),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.swap_horiz, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              '卡包中没有其他 ${widget.card.tag.label} 卡可用于比较',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiffSummary(DumpDiff diff) {
    final same = diff.diffCount == 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                same ? Icons.check_circle_outline : Icons.difference,
                size: 18,
                color: same ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 6),
              Text(
                same ? 'Dump 完全一致' : '存在差异',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: same ? Colors.green : Colors.red),
              ),
              const Spacer(),
              Text(
                '${diff.diffCount}/${diff.total} 块',
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
            ],
          ),
          if (diff.leftSize != diff.rightSize)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('块数不同: ${diff.leftSize} vs ${diff.rightSize}',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF6D00))),
            ),
          if (!same) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            for (final d in diff.diffs) _buildDiffRow(d),
          ],
        ],
      ),
    );
  }

  Widget _buildDiffRow(DiffBlock d) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('块 ${d.index}',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF333333))),
          const SizedBox(height: 1),
          Text('当前: ${_spaceHex(d.left)}',
              style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: Color(0xFF555555))),
          Text('对比: ${_spaceHex(d.right)}',
              style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: Color(0xFFD32F2F))),
        ],
      ),
    );
  }

  String _spaceHex(String hex) {
    final clean = hex.replaceAll(RegExp(r'\s'), '');
    final buf = StringBuffer();
    for (var i = 0; i < clean.length; i += 2) {
      if (i > 0) buf.write(' ');
      buf.write(clean.substring(i, (i + 2) > clean.length ? clean.length : i + 2));
    }
    return buf.toString();
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow(
      {required this.card, required this.selected, required this.onChanged});

  final SaveCard card;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFE3F2FD) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : const Color(0xFFEEEEEE)),
        boxShadow: selected
            ? null
            : const [
                BoxShadow(
                    color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
              ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onChanged(!selected),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : const Color(0xFFCCCCCC),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.name.isEmpty ? card.uid : card.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'UID ${card.uid}${card.data.isNotEmpty ? '  ·  ${card.data.length} 块' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF999999),
                          fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
