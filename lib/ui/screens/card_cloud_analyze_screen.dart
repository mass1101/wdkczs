import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/card_backup.dart';
import '../../services/card_library.dart';
import '../../services/mifare_analyze_service.dart';

/// 云端卡片分析页（对齐 CU CardAnalyzeMenu：dump 上传云端返回锤子/客栈/夏天三份结果）
class CardCloudAnalyzeScreen extends StatefulWidget {
  final SaveCard card;
  final Uint8List dumpBytes;
  final String dumpFilename;

  const CardCloudAnalyzeScreen({
    super.key,
    required this.card,
    required this.dumpBytes,
    required this.dumpFilename,
  });

  /// 弹确认框说明上传内容，确认后进入分析页
  static Future<void> launch(BuildContext context, SaveCard card) async {
    final bytes = cardSaveToBin(card);
    if (bytes.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('该卡片没有 Dump 数据，无法分析'),
            duration: Duration(seconds: 2),
          ),
        );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('云端卡片分析'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('将上传当前卡的 dump 原始字节到云端进行分析。', style: TextStyle(fontSize: 14)),
            SizedBox(height: 8),
            Text(
              '上传目标：数据仅用于本次分析，请勿分析含个人隐私的卡。',
              style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认上传', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final filename =
        '${(card.name.isEmpty ? card.uid : card.name).trim()}.dump';
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CardCloudAnalyzeScreen(
          card: card,
          dumpBytes: bytes,
          dumpFilename: filename,
        ),
      ),
    );
  }

  @override
  State<CardCloudAnalyzeScreen> createState() => _CardCloudAnalyzeScreenState();
}

class _CardCloudAnalyzeScreenState extends State<CardCloudAnalyzeScreen> {
  static const _service = MifareAnalyzeService();

  late Future<MifareAnalyzeResult> _future;

  @override
  void initState() {
    super.initState();
    _future = _service.analyzeDump(widget.dumpBytes, widget.dumpFilename);
  }

  void _retry() {
    setState(() {
      _future = _service.analyzeDump(widget.dumpBytes, widget.dumpFilename);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '云端分析 - ${widget.card.name.isEmpty ? widget.card.uid : widget.card.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: FutureBuilder<MifareAnalyzeResult>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _ErrorView(
              message: '云端分析出错: ${snapshot.error}',
              onRetry: _retry,
            );
          }
          if (!snapshot.hasData) {
            return _LoadingView(
              detail: '上传 ${widget.dumpBytes.length} 字节 dump 并等待云端解析',
            );
          }
          final result = snapshot.data!;
          if (result.hasUploadError) {
            return _ErrorView(message: result.uploadError, onRetry: _retry);
          }
          return _ResultTabs(result: result);
        },
      ),
    );
  }
}

/// 三份云端结果 Tab 页
class _ResultTabs extends StatelessWidget {
  const _ResultTabs({required this.result});

  final MifareAnalyzeResult result;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: '锤子'),
              Tab(text: '客栈'),
              Tab(text: '夏天'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildHammerView(result.hammer, result.czError),
                _buildTextView(result.kz, result.kzError),
                _buildTextView(result.xt, result.xtError),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHammerView(HammerAnalyzeResult? hammer, String error) {
    if (hammer == null) {
      return _TextView(text: error.isEmpty ? '锤子分析失败' : error);
    }
    if (hammer.isEmpty) {
      return error.isEmpty ? const _EmptyView() : _TextView(text: error);
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: hammer.items.length,
      itemBuilder: (context, index) {
        final item = hammer.items[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
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
                  Expanded(
                    child: Text(
                      item.name.isEmpty ? '条目 ${item.sectorIndex}' : item.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF333333),
                      ),
                    ),
                  ),
                  if (item.allowModify)
                    const Text(
                      '可修改',
                      style: TextStyle(fontSize: 11, color: Color(0xFF2E7D32)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (final v in item.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: SelectableText(
                    [v.a, v.b, v.c, v.d].where((s) => s.isNotEmpty).join(' '),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF444444),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTextView(String text, String error) {
    if (text.isEmpty && error.isEmpty) return const _EmptyView();
    return _TextView(text: text.isEmpty ? error : text);
  }
}

/// 纯文本结果视图
class _TextView extends StatelessWidget {
  const _TextView({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(text, style: const TextStyle(fontSize: 13)),
    );
  }
}

/// 空结果提示
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('暂未识别到有效信息'));
  }
}

/// 上传中提示
class _LoadingView extends StatelessWidget {
  const _LoadingView({required this.detail});

  final String detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            const Text(
              '正在上传并分析...',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 失败提示 + 重试
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Color(0xFFFF9800)),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
