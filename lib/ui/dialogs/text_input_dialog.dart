import 'package:flutter/material.dart';

/// 通用文本输入对话框
class TextInputDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String initial;
  final bool multiline;

  const TextInputDialog({
    super.key,
    required this.title,
    this.hint = '',
    this.initial = '',
    this.multiline = false,
  });

  @override
  State<TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<TextInputDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, style: const TextStyle(fontSize: 16)),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLines: widget.multiline ? 12 : 1,
        minLines: widget.multiline ? 6 : 1,
        style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
        decoration: InputDecoration(
          hintText: widget.hint,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
