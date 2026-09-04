import 'package:flutter/material.dart';

/// 破解进度对话框（显示进度条与说明文字）
class CrackProgressDialog extends StatelessWidget {
  final String title;
  final VoidCallback? onCancel;

  const CrackProgressDialog({super.key, required this.title, this.onCancel});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: const Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Text(
              '正在分析卡片数据，请将卡片放置在读卡器上…\n此过程可能需要数十秒。',
              style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),
          ),
        ],
      ),
      actions: [
        if (onCancel != null)
          TextButton(onPressed: onCancel, child: const Text('取消')),
      ],
    );
  }
}
