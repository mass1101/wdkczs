import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../models/enums.dart';
import '../../services/card_library.dart';
import '../../services/storage_service.dart';

/// 卡片创建对话框（对齐 CU CardCreateMenu）
class CardCreateDialog extends StatefulWidget {
  final String? folderId;

  const CardCreateDialog({super.key, this.folderId});

  @override
  State<CardCreateDialog> createState() => _CardCreateDialogState();
}

class _CardCreateDialogState extends State<CardCreateDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _uidCtrl = TextEditingController();
  final _sakCtrl = TextEditingController();
  final _atqaCtrl = TextEditingController();
  final _atsCtrl = TextEditingController();
  final _ulVersionCtrl = TextEditingController();
  final _ulSignatureCtrl = TextEditingController();

  final _hidTypeCtrl = TextEditingController(text: '1');
  final _facilityCodeCtrl = TextEditingController();
  final _issueLevelCtrl = TextEditingController();
  final _oemCtrl = TextEditingController();

  TagType _selectedType = TagType.mifare1K;
  Color _currentColor = Colors.deepOrange;
  Color _pickerColor = Colors.deepOrange;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _uidCtrl.dispose();
    _sakCtrl.dispose();
    _atqaCtrl.dispose();
    _atsCtrl.dispose();
    _ulVersionCtrl.dispose();
    _ulSignatureCtrl.dispose();
    _hidTypeCtrl.dispose();
    _facilityCodeCtrl.dispose();
    _issueLevelCtrl.dispose();
    _oemCtrl.dispose();
    super.dispose();
  }

  bool get _isLf => isLfTag(_selectedType);
  bool get _isUltralight => isMifareUltralight(_selectedType);
  bool get _isClassic => isMifareClassic(_selectedType);
  bool get _isHidProx => _selectedType == TagType.hidProx;

  /// 获取 HF 卡类型列表（对齐 CU getTagTypesByFrequency(hf)）
  List<TagType> get _hfTypes => hfTagTypes();

  /// 获取 LF 卡类型列表（对齐 CU getTagTypesByFrequency(lf)）
  List<TagType> get _lfTypes => lfTagTypes();

  String? _validateUid(String? value) {
    if (value == null || value.isEmpty) return 'UID 不能为空';
    final clean = value.replaceAll(RegExp(r'\s'), '');
    if (clean.isEmpty) return 'UID 不能为空';
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) return 'UID 只能包含十六进制字符';
    final bytes = clean.length ~/ 2;
    if (_isLf) {
      final expected = lfUidSize(_selectedType);
      if (bytes != expected) {
        return '${_selectedType.label} UID 需要 $expected 字节（${expected * 2} 位 hex）';
      }
      return null;
    }
    if (_isUltralight) {
      if (bytes != 7) return 'Ultralight UID 需要 7 字节（14 位 hex）';
      return null;
    }
    if (bytes != 4 && bytes != 7) return 'UID 需要 4 或 7 字节';
    return null;
  }

  String? _validateHex(
    String? value, {
    int? exactBytes,
    bool required = false,
  }) {
    if (value == null || value.isEmpty) {
      return required ? '不能为空' : null;
    }
    final clean = value.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) {
      return '只能包含十六进制字符';
    }
    if (clean.length % 2 != 0) return '长度为奇数，不是合法 16 进制';
    if (exactBytes != null && clean.length != exactBytes * 2) {
      return '需要 $exactBytes 字节（${exactBytes * 2} 位 hex）';
    }
    return null;
  }

  String? _validateRange(
    String? value, {
    required int min,
    required int max,
    bool required = true,
  }) {
    if (value == null || value.isEmpty) {
      return required ? '范围为 $min - $max' : null;
    }
    final v = int.tryParse(value);
    if (v == null || v < min || v > max) return '范围为 $min - $max';
    return null;
  }

  void _pickColor() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择颜色'),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: _pickerColor,
            onColorChanged: (c) => setState(() => _pickerColor = c),
            pickerAreaHeightPercent: 0.8,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _currentColor = Colors.deepOrange;
                _pickerColor = Colors.deepOrange;
              });
              Navigator.pop(ctx);
            },
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() => _currentColor = _pickerColor);
              Navigator.pop(ctx);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final uidBytes = hexToUint8List(_uidCtrl.text);
    final uid = _isHidProx
        ? hidProxUidFromParts(
            int.parse(_hidTypeCtrl.text),
            int.parse(_facilityCodeCtrl.text),
            uidBytes,
            int.parse(_issueLevelCtrl.text),
            int.parse(_oemCtrl.text),
          )
        : bytesToHexSpace(uidBytes);
    int sak = 0;
    String atqa = '';
    String ats = '';
    List<String> data = [];

    if (!_isLf) {
      sak = hexToUint8List(_sakCtrl.text)[0];
      atqa = StorageService.bytesToHex(hexToUint8List(_atqaCtrl.text));
      ats = StorageService.bytesToHex(hexToUint8List(_atsCtrl.text));

      if (_isClassic) {
        data = generateMfClassicBlocks(_selectedType);
        if (data.isNotEmpty) {
          final block0 = mfClassicGenerateFirstBlock(
            uidBytes,
            sak,
            hexToUint8List(_atqaCtrl.text),
          );
          data[0] = _bytesToHexString(block0);
        }
      } else if (_isUltralight) {
        data = generateMfUltralightBlocks(_selectedType, uidBytes);
      }
    }

    final card = SaveCard(
      uid: uid,
      name: _nameCtrl.text,
      tag: _selectedType,
      sak: sak,
      atqa: atqa,
      ats: ats,
      data: data,
      ultralightVersion: StorageService.bytesToHex(
        hexToUint8List(_ulVersionCtrl.text),
      ),
      ultralightSignature: StorageService.bytesToHex(
        hexToUint8List(_ulSignatureCtrl.text),
      ),
      folderId: widget.folderId,
      colorValue: _currentColor.toARGB32(),
    );

    await CardLibraryStorage().upsertCard(card);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('创建卡片'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 名称 + 颜色
              TextFormField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: '卡片名称',
                  hintText: '请输入卡片名称',
                  prefixIcon: IconButton(
                    icon: Icon(
                      _isLf ? Icons.wifi : Icons.credit_card,
                      color: _currentColor,
                    ),
                    onPressed: _pickColor,
                  ),
                ),
                validator: validateCardName,
              ),
              const SizedBox(height: 16),

              // 卡类型选择
              DropdownButtonFormField<TagType>(
                initialValue: _selectedType,
                decoration: const InputDecoration(labelText: '卡类型'),
                items: [
                  ..._hfTypes.map(
                    (t) => DropdownMenuItem(value: t, child: Text(t.label)),
                  ),
                  ..._lfTypes.map(
                    (t) => DropdownMenuItem(value: t, child: Text(t.label)),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _selectedType = v);
                },
              ),
              const SizedBox(height: 16),

              // UID
              TextFormField(
                controller: _uidCtrl,
                decoration: InputDecoration(
                  labelText: 'UID',
                  hintText: '请输入 UID（十六进制）',
                  prefixIcon: const Icon(Icons.nfc),
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F\s]')),
                ],
                validator: _validateUid,
              ),
              const SizedBox(height: 16),

              // HF 卡额外字段
              if (!_isLf) ...[
                TextFormField(
                  controller: _sakCtrl,
                  decoration: const InputDecoration(
                    labelText: 'SAK',
                    hintText: '1 字节（如 08）',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F\s]')),
                  ],
                  validator: (v) =>
                      _validateHex(v, exactBytes: 1, required: true),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _atqaCtrl,
                  decoration: const InputDecoration(
                    labelText: 'ATQA',
                    hintText: '2 字节（如 00 04）',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F\s]')),
                  ],
                  validator: (v) =>
                      _validateHex(v, exactBytes: 2, required: true),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _atsCtrl,
                  decoration: const InputDecoration(
                    labelText: 'ATS',
                    hintText: '可选',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F\s]')),
                  ],
                  validator: (v) => _validateHex(v),
                ),
                const SizedBox(height: 12),
                if (_isUltralight) ...[
                  TextFormField(
                    controller: _ulVersionCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Ultralight 版本',
                      hintText: '8 字节（可选）',
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'[0-9a-fA-F\s]'),
                      ),
                    ],
                    validator: (v) => _validateHex(v, exactBytes: 8),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _ulSignatureCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Ultralight 签名',
                      hintText: '可选',
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'[0-9a-fA-F\s]'),
                      ),
                    ],
                    validator: (v) => _validateHex(v),
                  ),
                ],
              ],
              if (_isHidProx) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: int.tryParse(_hidTypeCtrl.text) ?? 1,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'HID 类型'),
                  items: List.generate(30, (i) => i + 1)
                      .map(
                        (t) => DropdownMenuItem(
                          value: t,
                          child: Text(getNameForHIDProxType(t)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _hidTypeCtrl.text = v.toString());
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _facilityCodeCtrl,
                  decoration: const InputDecoration(
                    labelText: '设施代码',
                    hintText: '0 - 4294967295',
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) => _validateRange(v, min: 0, max: 4294967295),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _issueLevelCtrl,
                  decoration: const InputDecoration(
                    labelText: '发行级别',
                    hintText: '0 - 255',
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) => _validateRange(v, min: 0, max: 255),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _oemCtrl,
                  decoration: const InputDecoration(
                    labelText: 'OEM',
                    hintText: '0 - 65535',
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) => _validateRange(v, min: 0, max: 65535),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _save, child: const Text('创建')),
      ],
    );
  }
}

String _bytesToHexString(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
