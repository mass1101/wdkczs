import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/card_library.dart';

/// Dump 编辑器（对齐 CU DumpEditor）
/// 支持 Mifare Classic（扇区/块）和 Ultralight（页）的 hex 数据浏览与编辑
class DumpEditor extends StatefulWidget {
  final SaveCard card;
  final SaveCard? compareTarget;

  const DumpEditor({
    super.key,
    required this.card,
    this.compareTarget,
  });

  @override
  State<DumpEditor> createState() => _DumpEditorState();
}

class _DumpEditorState extends State<DumpEditor> {
  late List<String> _data;
  bool _edited = false;
  SaveCard? _compareTarget;
  bool _pickingCompare = false;

  @override
  void initState() {
    super.initState();
    _data = List<String>.from(widget.card.data);
    _compareTarget = widget.compareTarget;
  }

  bool get _isClassic => isMifareClassic(widget.card.tag);
  bool get _isUltralight => isMifareUltralight(widget.card.tag);
  int get _blockSize => _isClassic ? 16 : 4;
  bool get _canCompare => _isClassic || _isUltralight;

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final showCompare = _compareTarget != null && _canCompare;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Dump 编辑器 - ${widget.card.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_canCompare)
            TextButton(
              onPressed: _pickingCompare ? null : _pickCompare,
              child: Text(
                _compareTarget == null ? '对比' : '换对比卡',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          if (_edited)
            TextButton(
              onPressed: _save,
              child: const Text('保存', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
      body: _data.isEmpty
          ? const Center(child: Text('无数据', style: TextStyle(color: Colors.grey)))
          : Column(
              children: [
                if (showCompare) _buildCompareBanner(),
                Expanded(
                  child: _isClassic
                      ? _buildClassicView()
                      : _isUltralight
                          ? _buildUltralightView()
                          : _buildGenericView(),
                ),
              ],
            ),
    );
  }

  /// 对比卡横幅：显示对比对象名与差异块数
  Widget _buildCompareBanner() {
    final target = _compareTarget!;
    final count = _diffCount(target.data);
    final same = count == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      color: same ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
      child: Row(
        children: [
          Icon(
            same ? Icons.check_circle_outline : Icons.compare_arrows,
            size: 16,
            color: same ? const Color(0xFF2E7D32) : const Color(0xFFEF6C00),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              same
                  ? '与「${target.name.isEmpty ? target.uid : target.name}」完全一致'
                  : '与「${target.name.isEmpty ? target.uid : target.name}」有 $count 块不同',
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: '取消对比',
            onPressed: () => setState(() => _compareTarget = null),
          ),
        ],
      ),
    );
  }

  String _norm(String hex) => hex.replaceAll(RegExp(r'\s'), '').toLowerCase();

  /// 统计两个 dump 的差异块/页数
  int _diffCount(List<String> other) {
    var n = 0;
    final len = _data.length < other.length ? _data.length : other.length;
    for (int i = 0; i < len; i++) {
      if (_norm(_data[i]) != _norm(other[i])) n++;
    }
    return n + (_data.length > other.length
        ? _data.length - other.length
        : other.length - _data.length);
  }

  /// 选择对比卡（同卡型、非自身、有数据）
  Future<void> _pickCompare() async {
    if (_pickingCompare) return;
    setState(() => _pickingCompare = true);
    final cards = await CardLibraryStorage().getCards();
    if (!mounted) return;
    setState(() => _pickingCompare = false);
    final candidates = cards
        .where((c) => c.id != widget.card.id)
        .where((c) => c.tag == widget.card.tag)
        .where((c) => c.data.isNotEmpty)
        .toList();
    if (candidates.isEmpty) {
      _toast('卡包中没有其他同卡型且有数据的卡片');
      return;
    }
    final picked = await showModalBottomSheet<SaveCard>(
      context: context,
      builder: (ctx) => _ComparePicker(candidates: candidates),
    );
    if (picked != null) setState(() => _compareTarget = picked);
  }


  /// Mifare Classic 视图：按扇区分组
  Widget _buildClassicView() {
    final mfcType = tagTypeToMfClassicType(widget.card.tag);
    final sectorCount = mfClassicGetSectorCount(mfcType);
    final compareData = widget.compareTarget?.data ?? const <String>[];

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 80),
      itemCount: sectorCount,
      itemBuilder: (ctx, sector) {
        final firstBlock = mfClassicGetFirstBlockBySector(sector);
        final blockCount = mfClassicGetBlockCountBySector(sector);
        final trailerBlock = mfClassicGetSectorTrailerBlockBySector(sector);

        final sectorBlocks = <int>[];
        for (int i = 0; i < blockCount; i++) {
          final blockIdx = firstBlock + i;
          if (blockIdx < _data.length) {
            sectorBlocks.add(blockIdx);
          }
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(8),
                    topRight: Radius.circular(8),
                  ),
                ),
                child: Row(
                  children: [
                    Text('扇区 $sector',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.primary,
                        )),
                    const SizedBox(width: 8),
                    Text('块 $firstBlock - ${firstBlock + blockCount - 1}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF999999))),
                  ],
                ),
              ),
              for (final blockIdx in sectorBlocks)
                _buildBlockRow(
                  blockIdx: blockIdx,
                  isTrailer: blockIdx == trailerBlock,
                  compareBlock: blockIdx < compareData.length ? compareData[blockIdx] : null,
                ),
            ],
          ),
        );
      },
    );
  }

  /// Ultralight 视图：按页显示
  Widget _buildUltralightView() {
    final compareData = widget.compareTarget?.data ?? const <String>[];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 80),
      itemCount: _data.length,
      itemBuilder: (ctx, pageIdx) => _buildBlockRow(
        blockIdx: pageIdx,
        isTrailer: false,
        compareBlock: pageIdx < compareData.length ? compareData[pageIdx] : null,
        isPage: true,
      ),
    );
  }

  /// 通用视图
  Widget _buildGenericView() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 80),
      itemCount: _data.length,
      itemBuilder: (ctx, idx) => _buildBlockRow(blockIdx: idx, isTrailer: false),
    );
  }

  Widget _buildBlockRow({
    required int blockIdx,
    required bool isTrailer,
    String? compareBlock,
    bool isPage = false,
  }) {
    final hex = _data[blockIdx];
    final bytes = _parseHexBytes(hex);
    final compareBytes = compareBlock != null ? _parseHexBytes(compareBlock) : null;

    final label = isPage ? '页 $blockIdx' : '块 $blockIdx';

    return InkWell(
      onTap: () => _editBlock(blockIdx),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: isTrailer ? Colors.red : const Color(0xFF888888),
                  fontWeight: isTrailer ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Wrap(
                spacing: 2,
                runSpacing: 2,
                children: List.generate(bytes.length, (i) {
                  final b = bytes[i];
                  final cb = compareBytes != null && i < compareBytes.length
                      ? compareBytes[i]
                      : null;
                  final diff = cb != null && cb != b;
                  return Container(
                    width: 24,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: diff ? const Color(0xFFFFEBEE) : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      b.toRadixString(16).padLeft(2, '0').toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: diff ? Colors.red : const Color(0xFF333333),
                        fontWeight: diff ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  );
                }),
              ),
            ),
            Icon(Icons.edit, size: 14, color: const Color(0xFFBBBBBB)),
          ],
        ),
      ),
    );
  }

  List<int> _parseHexBytes(String hex) {
    final clean = hex.replaceAll(RegExp(r'\s'), '');
    final bytes = <int>[];
    for (int i = 0; i + 1 < clean.length; i += 2) {
      bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  void _editBlock(int index) {
    final ctrl = TextEditingController(text: _data[index]);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑 ${_isUltralight ? '页' : '块'} $index'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F\s]')),
          ],
          decoration: InputDecoration(
            labelText: 'Hex 数据',
            helperText: '$_blockSize 字节 / ${_blockSize * 2} 位 hex',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final clean = ctrl.text.replaceAll(RegExp(r'\s'), '');
              if (clean.length != _blockSize * 2) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('需要 $_blockSize 字节 / ${_blockSize * 2} 位 hex')),
                );
                return;
              }
              setState(() {
                _data[index] = clean.toLowerCase();
                _edited = true;
              });
              Navigator.pop(ctx);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final updated = widget.card.copy();
    updated.data = _data;
    updated.updatedAt = DateTime.now();
    await CardLibraryStorage().upsertCard(updated);
    if (mounted) {
      setState(() => _edited = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );
      Navigator.pop(context, true);
    }
  }
}

/// 选择对比卡：同卡型卡片单选列表
class _ComparePicker extends StatelessWidget {
  final List<SaveCard> candidates;

  const _ComparePicker({required this.candidates});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '选择对比卡',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: candidates.length,
              itemBuilder: (_, i) {
                final c = candidates[i];
                return ListTile(
                  onTap: () => Navigator.pop(context, c),
                  title: Row(
                    children: [
                      Container(
                        width: 4,
                        height: 22,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: c.color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          c.name.isEmpty ? '未命名' : c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text(
                    '${c.tag.label}  UID:${c.uid.toUpperCase()}  块数:${c.data.length}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
