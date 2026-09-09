import 'package:flutter/material.dart';

/// 扇区密钥破解状态（对应小程序 ss.sectors_Key）
class SectorKeyState {
  final int sector;
  bool hasKeyA;
  bool hasKeyB;
  String keyA;
  String keyB;
  SectorKeyState(this.sector)
      : hasKeyA = false,
        hasKeyB = false,
        keyA = '',
        keyB = '';
}

/// 破解/读卡进度对话框（对齐小程序：步骤指示器 + 阶段前缀进度文字 + 扇区状态网格）
class CrackProgressDialog extends StatelessWidget {
  final String title;
  final ValueNotifier<String>? progress;
  final ValueNotifier<int>? step;
  final List<String>? steps;
  final List<SectorKeyState>? sectors;
  final ValueNotifier<int>? refresh;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;
  final String confirmText;
  final String cancelText;
  final bool showConfirm;

  const CrackProgressDialog({
    super.key,
    required this.title,
    this.progress,
    this.step,
    this.steps,
    this.sectors,
    this.refresh,
    this.onCancel,
    this.onConfirm,
    this.confirmText = '确认',
    this.cancelText = '取消',
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
          if (sectors != null && refresh != null)
            ...[
              const SizedBox(height: 12),
              _SectorGrid(sectors: sectors!, refresh: refresh!),
            ],
        ],
      ),
      actions: [
        if (onCancel != null)
          TextButton(onPressed: onCancel, child: Text(cancelText)),
        if (showConfirm)
          TextButton(
            onPressed: onConfirm,
            child: Text(confirmText),
          ),
      ],
    );
  }
}

/// 16 扇区 A/B 密钥破解状态网格（对齐小程序 sectors_Key 实时点亮）
class _SectorGrid extends StatelessWidget {
  final List<SectorKeyState> sectors;
  final ValueNotifier<int> refresh;

  const _SectorGrid({required this.sectors, required this.refresh});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ValueListenableBuilder<int>(
      valueListenable: refresh,
      builder: (ctx, _, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var row = 0; row < 4; row++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  for (var col = 0; col < 4; col++)
                    Expanded(
                      child: _sectorCell(sectors[row * 4 + col], primary),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectorCell(SectorKeyState sk, Color primary) {
    Widget dot(bool done, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 9,
                    color: done ? primary : const Color(0xFFBBBBBB))),
            const SizedBox(width: 2),
            Icon(
              done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 11,
              color: done ? primary : const Color(0xFFDDDDDD),
            ),
          ],
        );
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: sk.hasKeyA && sk.hasKeyB
            ? primary.withValues(alpha: 0.08)
            : const Color(0xFFFAFAFA),
        border: Border.all(
            color: sk.hasKeyA && sk.hasKeyB
                ? primary.withValues(alpha: 0.4)
                : const Color(0xFFEDEDED)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        children: [
          Text('${sk.sector}',
              style: const TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              dot(sk.hasKeyA, 'A'),
              const SizedBox(width: 4),
              dot(sk.hasKeyB, 'B'),
            ],
          ),
        ],
      ),
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
