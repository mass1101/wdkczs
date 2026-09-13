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

  @override
  void initState() {
    super.initState();
    _data = List<String>.from(widget.card.data);
  }

  bool get _isClassic => isMifareClassic(widget.card.tag);
  bool get _isUltralight => isMifareUltralight(widget.card.tag);
  int get _blockSize => _isClassic ? 16 : 4;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Dump 编辑器 - ${widget.card.name}'),
        actions: [
          if (_edited)
            TextButton(
              onPressed: _save,
              child: const Text('保存', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
      body: _data.isEmpty
          ? const Center(child: Text('无数据', style: TextStyle(color: Colors.grey)))
          : _isClassic
              ? _buildClassicView()
              : _isUltralight
                  ? _buildUltralightView()
                  : _buildGenericView(),
    );
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
