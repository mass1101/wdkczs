import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/card_library.dart';
import '../../services/dump_analyzer.dart';

/// 卡片分析页（对齐 CU 卡片分析菜单，纯本地 ACL/密钥/Value Block 解析）
class CardAnalyzeScreen extends StatelessWidget {
  final SaveCard card;

  const CardAnalyzeScreen({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final analysis = DumpAnalysisRunner.analyze(card);
    return Scaffold(
      appBar: AppBar(
        title: Text('卡片分析 - ${card.name.isEmpty ? card.uid : card.name}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: analysis == null
            ? const []
            : [
                IconButton(
                  tooltip: '复制分析摘要',
                  icon: const Icon(Icons.copy),
                  onPressed: () => _copySummary(context, analysis),
                ),
              ],
      ),
      body: analysis == null ? _buildUnsupported(context) : _buildContent(context, analysis),
    );
  }

  Widget _buildUnsupported(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.info_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              card.data.isEmpty
                  ? '该卡片没有 Dump 数据，无法分析。'
                  : '卡片分析仅支持 MIFARE Classic 卡（${card.tag.label} 不支持）。',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, DumpAnalysis analysis) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 80),
      children: [
        _buildSummaryCard(analysis),
        const SizedBox(height: 10),
        for (final sector in analysis.sectors)
          _buildSectorCard(context, sector),
      ],
    );
  }

  Widget _buildSummaryCard(DumpAnalysis a) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('分析摘要'),
          const SizedBox(height: 4),
          _StatGrid(
            items: [
              _Stat('扇区数', '${a.totalSectors}'),
              _Stat('KeyA 默认', '${a.defaultKeyASectors}'),
              _Stat('KeyB 默认', '${a.defaultKeyBSectors}'),
              _Stat('出厂 ACL', '${a.factoryAclSectors}'),
              _Stat('ACL 异常', '${a.invalidAclSectors}'),
              _Stat('Value 块', '${a.valueBlockCount}'),
            ],
          ),
          const Divider(height: 14),
          _StatRow('UID', a.uidHex),
          _StatRow('SAK', a.sakHex),
          _StatRow('ATQA', a.atqaHex),
          _StatRow('空白数据块', '${a.emptyBlocks}'),
        ],
      ),
    );
  }

  Widget _buildSectorCard(BuildContext context, SectorAnalysis s) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: _cardDecoration(),
      child: ExpansionTile(
        initiallyExpanded: !s.allZero,
        iconColor: const Color(0xFF888888),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        title: Row(
          children: [
            const Icon(Icons.memory, size: 18, color: Color(0xFF2196F3)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('扇区 ${s.sector}',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
            ),
            if (s.allZero)
              const Text('全空', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        children: [
          _keyRow(context, label: 'Key A', value: s.keyA, isDefault: s.hasDefaultKeyA),
          const SizedBox(height: 2),
          _keyRow(context, label: 'Key B', value: s.keyB, isDefault: s.hasDefaultKeyB),
          const SizedBox(height: 6),
          _copyableHexRow(context, 'ACL', s.aclHex),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(s.sectorTrailerDescription,
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF666666), height: 1.4)),
          ),
          const SizedBox(height: 8),
          for (final block in s.blocks) _buildBlockRow(context, block),
        ],
      ),
    );
  }

  Widget _buildBlockRow(BuildContext context, BlockAnalysis b) {
    final valueInfo = b.isValueBlock
        ? '  值:${b.valueInt}  地址:${b.valueAddress}'
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              '块 ${b.blockIndex}',
              style: TextStyle(
                fontSize: 12,
                color: b.isTrailer ? Colors.red : const Color(0xFF888888),
                fontWeight: b.isTrailer ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                     Flexible(
                       child: SelectableText(
                         _spaceHex(b.hex),
                         style: const TextStyle(
                             fontSize: 12, fontFamily: 'monospace'),
                         maxLines: 2,
                       ),
                     ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 14, color: Color(0xFFAAAAAA)),
                      onPressed: () =>
                          _copy(context, b.hex.replaceAll(' ', '').toUpperCase()),
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.only(left: 2),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                if (!b.isTrailer && b.ascii.isNotEmpty)
                  Text(b.ascii,
                      style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF999999),
                          fontFamily: 'monospace'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                if (b.accessDescription != '-')
                  Text(b.accessDescription,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF777777))),
                if (b.isValueBlock)
                  Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: const BoxDecoration(
                      color: Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.all(Radius.circular(3)),
                    ),
                    child: Text('Value 块: $valueInfo'.trim(),
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF2E7D32))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyRow(
    BuildContext context, {
    required String label,
    required String value,
    required bool isDefault,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF888888))),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: Color(0xFF333333)),
          ),
        ),
        if (isDefault)
          Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: const BoxDecoration(
              color: Color(0xFFFFF3E0),
              borderRadius: BorderRadius.all(Radius.circular(3)),
            ),
            child: const Text('默认',
                style: TextStyle(fontSize: 10, color: Color(0xFFE65100))),
          ),
        IconButton(
          icon: const Icon(Icons.copy, size: 14, color: Color(0xFFAAAAAA)),
          onPressed: () =>
              _copy(context, value.replaceAll(' ', '').toUpperCase()),
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.only(left: 2),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _copyableHexRow(BuildContext context, String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF888888))),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
                fontSize: 12, fontFamily: 'monospace', color: Color(0xFF333333)),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 14, color: Color(0xFFAAAAAA)),
          onPressed: () =>
              _copy(context, value.replaceAll(' ', '').toUpperCase()),
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.only(left: 2),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text('已复制: $text'), duration: const Duration(seconds: 1)));
  }

  void _copySummary(BuildContext context, DumpAnalysis a) {
    final buf = StringBuffer();
    buf.write('卡片: ${a.card.name}\n');
    buf.write('类型: ${a.card.tag.label}\n');
    buf.write('UID: ${_spaceHex(a.uidHex)}\n');
    buf.write('SAK: ${_spaceHex(a.sakHex)}  ATQA: ${_spaceHex(a.atqaHex)}\n');
    buf.write('扇区 ${a.totalSectors} | KeyA 默认 ${a.defaultKeyASectors} | '
        'KeyB 默认 ${a.defaultKeyBSectors} | 出厂 ACL ${a.factoryAclSectors} | '
        'ACL 异常 ${a.invalidAclSectors} | Value 块 ${a.valueBlockCount}\n');
    for (final s in a.sectors) {
      buf.write('\n扇区 ${s.sector}\n');
      buf.write('  Key A: ${s.keyA}\n');
      buf.write('  Key B: ${s.keyB}\n');
      if (s.aclHex.isNotEmpty) buf.write('  ACL: ${s.aclHex}\n');
      buf.write('  ${s.sectorTrailerDescription}\n');
      if (s.allZero) buf.write('  (全部数据块为空)\n');
      for (final b in s.blocks) {
        if (b.isTrailer) continue;
        if (b.hex.replaceAll(RegExp(r'\s'), '').replaceAll('0', '').isEmpty) continue;
        buf.write('  块 ${b.blockIndex}: ${_spaceHex(b.hex)}');
        if (b.isValueBlock) {
          buf.write('  [Value ${b.valueInt} @${b.valueAddress}]');
        }
        buf.write('\n');
      }
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
          const SnackBar(content: Text('已复制分析摘要'), duration: Duration(seconds: 1)));
  }

  String _spaceHex(String hex) {
    final clean = hex.replaceAll(RegExp(r'\s'), '');
    if (clean.isEmpty) return '';
    final buf = StringBuffer();
    for (int i = 0; i < clean.length; i += 2) {
      if (i > 0) buf.write(' ');
      buf.write(clean.substring(i, (i + 2) > clean.length ? clean.length : i + 2));
    }
    return buf.toString();
  }

  BoxDecoration _cardDecoration() => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
        ],
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF2196F3)));
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.items});

  final List<_Stat> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items.map((s) => _StatTile(s)).toList(),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile(this.stat);

  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: (MediaQuery.of(context).size.width - 62) / 3,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          Text(stat.value,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF333333))),
          const SizedBox(height: 2),
          Text(stat.label,
              style: const TextStyle(fontSize: 11, color: Color(0xFF999999))),
        ],
      ),
    );
  }
}

class _Stat {
  const _Stat(this.label, this.value);

  final String label;
  final String value;
}

class _StatRow extends StatelessWidget {
  const _StatRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF888888))),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '不可用' : value,
              style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Color(0xFF333333)),
            ),
          ),
        ],
      ),
    );
  }
}
