import 'package:flutter/material.dart';

const int kSlotCount = 80;

Future<int?> showSlotPickerDialog(
  BuildContext context, {
  int currentSlot = -1,
  List<(bool, bool)> enables = const [],
  String title = '选择卡槽',
}) async {
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      actionsPadding: const EdgeInsets.only(right: 8, bottom: 4),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: GridView.count(
          crossAxisCount: 5,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 2.1,
          children: [
            for (var i = 0; i < kSlotCount; i++)
                  _SlotChip(
                index: i,
                selected: i == currentSlot,
                hasCard:
                    i < enables.length && (enables[i].$1 || enables[i].$2),
                onTap: () => Navigator.pop(ctx, i),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

class _SlotChip extends StatelessWidget {
  const _SlotChip({
    required this.index,
    required this.selected,
    required this.hasCard,
    required this.onTap,
  });

  final int index;
  final bool selected;
  final bool hasCard;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Material(
      color: selected ? primary : Colors.white,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected
                  ? primary
                  : (hasCard ? Colors.black38 : Colors.black12),
              width: selected ? 1 : 0.6,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            '卡槽 ${index + 1}',
            style: TextStyle(
              fontSize: 11,
              color: selected
                  ? Colors.white
                  : (hasCard ? Colors.black87 : Colors.grey),
            ),
          ),
        ),
      ),
    );
  }
}
