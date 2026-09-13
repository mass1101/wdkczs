import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/enums.dart';
import '../../services/card_library.dart';
import '../../services/storage_service.dart';

/// 预设颜色列表
const _presetColors = <Color>[
  Color(0xFFFF5722), // deepOrange
  Color(0xFF2196F3), // blue
  Color(0xFF4CAF50), // green
  Color(0xFF9C27B0), // purple
  Color(0xFFFF9800), // orange
  Color(0xFFE91E63), // pink
  Color(0xFF00BCD4), // cyan
  Color(0xFF795548), // brown
  Color(0xFF607D8B), // blueGrey
  Color(0xFFF44336), // red
];

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
  Color _currentColor = _presetColors[0];

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
    if (value == null || value.trim().isEmpty) return 'UID 不能为空';
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
    if (value == null || value.trim().isEmpty) {
      return required ? '不能为空' : null;
    }
    final clean = value.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) return '只能包含十六进制字符';
    if (exactBytes != null && clean.length != exactBytes * 2) {
      return '需要 $exactBytes 字节（${exactBytes * 2} 位 hex）';
    }
    return null;
  }

  String? _validateRange(String? value, {required int min, required int max}) {
    if (value == null || value.trim().isEmpty) return null;
    final v = int.tryParse(value.trim());
    if (v == null) return '只能包含数字';
    if (v < min || v > max) return '范围为 $min - $max';
    return null;
  }

  void _pickColor() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '选择颜色',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _presetColors.map((c) {
                final selected = c.toARGB32() == _currentColor.toARGB32();
                return GestureDetector(
                  onTap: () {
                    setState(() => _currentColor = c);
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: selected
                          ? Border.all(color: Colors.white, width: 3)
                          : null,
                      boxShadow: selected
                          ? [
                              BoxShadow(
                                color: c,
                                blurRadius: 6,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                    child: selected
                        ? const Icon(Icons.check, color: Colors.white, size: 20)
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                setState(() => _currentColor = _presetColors[0]);
                Navigator.pop(ctx);
              },
              child: const Text('恢复默认'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final uidBytes = hexToUint8List(_uidCtrl.text);
    final uid = _isHidProx
        ? hidProxUidFromParts(
            int.parse(_hidTypeCtrl.text.isEmpty ? '1' : _hidTypeCtrl.text),
            int.parse(
              _facilityCodeCtrl.text.trim().isEmpty
                  ? '0'
                  : _facilityCodeCtrl.text.trim(),
            ),
            uidBytes,
            int.parse(
              _issueLevelCtrl.text.trim().isEmpty
                  ? '0'
                  : _issueLevelCtrl.text.trim(),
            ),
            int.parse(
              _oemCtrl.text.trim().isEmpty ? '0' : _oemCtrl.text.trim(),
            ),
          )
        : bytesToHexSpace(uidBytes);
    int sak = 0;
    String atqa = '';
    String ats = '';
    List<String> data = [];

    if (!_isLf) {
      sak = _sakCtrl.text.trim().isNotEmpty
          ? hexToUint8List(_sakCtrl.text)[0]
          : 0;
      atqa = _atqaCtrl.text.trim().isNotEmpty
          ? StorageService.bytesToHex(hexToUint8List(_atqaCtrl.text))
          : '';
      ats = _atsCtrl.text.trim().isNotEmpty
          ? StorageService.bytesToHex(hexToUint8List(_atsCtrl.text))
          : '';

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
      name: _nameCtrl.text.trim(),
      tag: _selectedType,
      sak: sak,
      atqa: atqa,
      ats: ats,
      data: data,
      ultralightVersion: _ulVersionCtrl.text.trim().isNotEmpty
          ? StorageService.bytesToHex(hexToUint8List(_ulVersionCtrl.text))
          : '',
      ultralightSignature: _ulSignatureCtrl.text.trim().isNotEmpty
          ? StorageService.bytesToHex(hexToUint8List(_ulSignatureCtrl.text))
          : '',
      folderId: widget.folderId,
      colorValue: _currentColor.toARGB32(),
    );

    await CardLibraryStorage().upsertCard(card);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('创建卡片'),
          leading: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(color: Colors.white)),
          ),
          actions: [
            TextButton(
              onPressed: _save,
              child: const Text(
                '创建',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
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
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '请输入名称' : null,
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
    );
  }
}

String _bytesToHexString(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
