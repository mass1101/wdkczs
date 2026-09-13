import 'dart:io' as io;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/dictionary_store.dart';
import '../widgets/common.dart';

/// 字典编辑弹窗（新建 / 修改 / 从文件导入），对齐 CU 字典编辑菜单
class DictionaryEditDialog extends StatefulWidget {
  final Dictionary? dictionary;
  final int defaultColor;

  const DictionaryEditDialog({
    super.key,
    this.dictionary,
    this.defaultColor = 0xFFFF5722,
  });

  /// 弹出并返回被确认的字典；取消返回 null
  static Future<Dictionary?> show(
    BuildContext context, {
    Dictionary? dictionary,
    int defaultColor = 0xFFFF5722,
  }) {
    return showDialog<Dictionary>(
      context: context,
      builder: (_) =>
          DictionaryEditDialog(dictionary: dictionary, defaultColor: defaultColor),
    );
  }

  @override
  State<DictionaryEditDialog> createState() => _DictionaryEditDialogState();
}

class _DictionaryEditDialogState extends State<DictionaryEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _keysCtrl;
  int _keyLength = 12;
  int _color = 0xFFFF5722;
  bool _dirty = false;
  String? _error;

  static const _sizeLabels = {
    12: '12 位 (Mifare Classic, 6 字节)',
    8: '8 位 (T55XX, 4 字节)',
    32: '32 位 (AES / ULC, 16 字节)',
  };

  static const List<int> _colors = [
    0xFFFF5722,
    0xFF8BC34A,
    0xFFE53935,
    0xFF1E88E5,
    0xFF8E24AA,
    0xFFFFC107,
    0xFF00ACC1,
    0xFF5D4037,
    0xFFEC407A,
  ];

  @override
  void initState() {
    super.initState();
    final d = widget.dictionary;
    _nameCtrl = TextEditingController(text: d?.name ?? '');
    _keysCtrl = TextEditingController(text: d?.keys.join('\n') ?? '');
    _keyLength = (d?.keyLength ?? 12) == 0 ? 12 : (d?.keyLength ?? 12);
    _color = d?.colorValue ?? widget.defaultColor;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _keysCtrl.dispose();
    super.dispose();
  }

  List<String>? _parseKeys() {
    final lines = _keysCtrl.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (lines.isEmpty) return [];
    final expected = _keyLength;
    final result = <String>[];
    for (final line in lines) {
      final token = line.split(RegExp(r'\s+')).first;
      if (token.length != expected || !isValidHexString(token)) return null;
      result.add(token.toUpperCase());
    }
    return result;
  }

  List<String>? _splitImport(String text) {
    final parts = text
        .split(RegExp(r'[\n,;]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return [];
    final result = <String>[];
    for (final p in parts) {
      final token = p.split(RegExp(r'\s+')).first;
      if (token.length != _keyLength || !isValidHexString(token)) return null;
      result.add(token.toUpperCase());
    }
    return result;
  }

  void _onOk() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入字典名称');
      return;
    }
    final keys = _parseKeys();
    if (keys == null) {
      setState(() => _error = '密钥格式错误，每行应为 $_keyLength 位 16 进制字符');
      return;
    }
    if (widget.dictionary == null) {
      Navigator.of(context).pop(Dictionary(
        name: name,
        keys: keys,
        keyLength: _keyLength,
        colorValue: _color,
      ));
      return;
    }
    final orig = widget.dictionary!;
    orig.name = name;
    orig.keys = keys;
    orig.keyLength = _keyLength;
    orig.colorValue = _color;
    Navigator.of(context).pop(orig);
  }

  void _onImportText() {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴密钥列表'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextField(
            controller: ctrl,
            maxLines: 8,
            autofocus: true,
            autocorrect: false,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z\s,\-]')),
            ],
            decoration: const InputDecoration(
              hintText: '每行一个密钥，也支持逗号分隔',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _commitImport(ctx, ctrl),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => _commitImport(ctx, ctrl), child: const Text('导入')),
        ],
      ),
    ).then((_) => ctrl.dispose());
  }

  void _commitImport(BuildContext ctx, TextEditingController ctrl) {
    final keys = _splitImport(ctrl.text);
    if (keys == null) {
      ScaffoldMessenger.of(ctx)
          .showSnackBar(const SnackBar(content: Text('密钥长度与所选长度不符')));
      return;
    }
    _keysCtrl.text = keys.join('\n');
    if (_nameCtrl.text.trim().isEmpty) _nameCtrl.text = '导入字典';
    setState(() {
      _error = null;
      _dirty = true;
    });
    Navigator.pop(ctx);
  }

  Future<void> _onImportFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['dic', 'txt'],
    );
    if (result == null || result.files.isEmpty) return;
    final pf = result.files.single;
    final List<int> raw = pf.path != null
        ? await io.File(pf.path!).readAsBytes()
        : (pf.bytes ?? Uint8List(0));
    if (raw.isEmpty) return;
    final parsed = Dictionary.fromString(String.fromCharCodes(raw),
        name: pf.name.isEmpty ? '' : pf.name);
    if (parsed.keys.isEmpty) {
      _toast('文件中没有有效密钥（需为 12/8/32 位 16 进制）');
      return;
    }
    setState(() {
      _keyLength = parsed.keyLength;
      _keysCtrl.text = parsed.keys.join('\n');
      if (_nameCtrl.text.trim().isEmpty) {
        _nameCtrl.text = parsed.name.isEmpty ? '导入字典' : parsed.name;
      }
      _error = null;
      _dirty = true;
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final parsed = _parseKeys();
    final ok = _nameCtrl.text.trim().isNotEmpty && parsed != null && parsed.isNotEmpty;
    return AlertDialog(
      title: Text(_dirty && widget.dictionary != null ? '编辑字典' : '新建字典'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              maxLength: 32,
              decoration: const InputDecoration(
                labelText: '字典名称',
                border: OutlineInputBorder(),
                counterText: '',
              ),
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() => _dirty = true),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              initialValue: _keyLength,
              decoration: const InputDecoration(
                labelText: '密钥长度',
                border: OutlineInputBorder(),
              ),
              items: _sizeLabels.keys
                  .map((v) => DropdownMenuItem(value: v, child: Text(_sizeLabels[v]!)))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _keyLength = v;
                  _dirty = true;
                  _error = null;
                });
              },
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(_color),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFDDDDDD)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ColorPickerRow(
                    colors: _colors,
                    selected: _color,
                    onChange: (c) => setState(() {
                      _color = c;
                      _dirty = true;
                    }),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _keysCtrl,
              maxLines: 8,
              autocorrect: false,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 13, letterSpacing: 1),
              decoration: InputDecoration(
                labelText: '密钥列表（每行一个）',
                hintText: '如 ${_keyLength == 12 ? 'aabbccddeeff' : '0' * _keyLength}',
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              onChanged: (_) => setState(() => _dirty = true),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _error ?? '已解析 ${parsed?.length ?? 0} 个密钥',
                    style: TextStyle(
                        fontSize: 11,
                        color: _error != null
                            ? Colors.red
                            : const Color(0xFF999999)),
                  ),
                ),
                TextButton(
                  onPressed: _onImportFile,
                  child: const Text('导入文件',
                      style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(onPressed: _onImportText, child: const Text('粘贴导入')),
        TextButton(
          onPressed: ok ? _onOk : null,
          child: Text(_dirty && widget.dictionary != null ? '保存' : '新建'),
        ),
      ],
    );
  }
}
