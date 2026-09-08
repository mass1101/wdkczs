import 'package:flutter/material.dart';

/// 破解/读卡进度对话框（对齐小程序：步骤指示器 + 阶段前缀进度文字 + 确认按钮）
class CrackProgressDialog extends StatelessWidget {
  final String title;
  final ValueNotifier<String>? progress;
  final ValueNotifier<int>? step;
  final List<String>? steps;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;
  final String confirmText;
  final bool showConfirm;

  const CrackProgressDialog({
    super.key,
    required this.title,
    this.progress,
    this.step,
    this.steps,
    this.onCancel,
    this.onConfirm,
    this.confirmText = '确认',
    this.showConfirm = false,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (steps != null && step != null)
            ...[
              _StepIndicator(current: step!, steps: steps!),
              const SizedBox(height: 12),
            ],
          Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: progress != null
                    ? ValueListenableBuilder<String>(
                        valueListenable: progress!,
                        builder: (ctx, text, _) => Text(
                          text,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF666666)),
                          softWrap: true,
                        ),
                      )
                    : const Text(
                        '正在分析卡片数据，请将卡片放置在读卡器上…\n此过程可能需要数十秒。',
                        style: TextStyle(
                            fontSize: 13, color: Color(0xFF666666)),
                      ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        if (onCancel != null)
          TextButton(onPressed: onCancel, child: const Text('取消')),
        if (showConfirm)
          TextButton(
            onPressed: onConfirm,
            child: Text(confirmText),
          ),
      ],
    );
  }
}

/// 步骤指示器（对齐小程序 van-steps）
class _StepIndicator extends StatelessWidget {
  final ValueNotifier<int> current;
  final List<String> steps;

  const _StepIndicator({required this.current, required this.steps});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: current,
      builder: (ctx, current, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < steps.length; i++)
              ...[
                if (i > 0) const SizedBox(width: 8),
                Row(
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: i <= current
                            ? const Color(0xFF1976D2)
                            : Colors.grey[300],
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      steps[i],
                      style: TextStyle(
                        fontSize: 11,
                        color: i <= current
                            ? const Color(0xFF1976D2)
                            : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ],
          ],
        );
      },
    );
  }
}
