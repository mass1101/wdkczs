import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../models/enums.dart';
import '../../services/card_library.dart';
import '../../services/storage_service.dart';

/// 卡片编辑对话框（对齐 CU CardEditMenu）
class CardEditDialog extends StatefulWidget {
  final SaveCard card;

  const CardEditDialog({super.key, required this.card});

  @override
  State<CardEditDialog> createState() => _CardEditDialogState();
}

class _CardEditDialogState extends State<CardEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _uidCtrl;
  late final TextEditingController _sakCtrl;
  late final TextEditingController _atqaCtrl;
  late final TextEditingController _atsCtrl;
  late final TextEditingController _ulVersionCtrl;
  late final TextEditingController _ulSignatureCtrl;
  final List<TextEditingController> _counterCtrls = [];

  late final TextEditingController _hidTypeCtrl;
  late final TextEditingController _facilityCodeCtrl;
  late final TextEditingController _issueLevelCtrl;
  late final TextEditingController _oemCtrl;

  late TagType _selectedType;
  late Color _currentColor;
  Color _pickerColor = Colors.deepOrange;
  late String _originalUid;
  late String _originalSak;
  late String _originalAtqa;

  @override
  void initState() {
    super.initState();
    _selectedType = widget.card.tag;
    _nameCtrl = TextEditingController(text: widget.card.name);
    _uidCtrl = TextEditingController(text: widget.card.uid);
    _sakCtrl = TextEditingController(
      text: widget.card.sak.toRadixString(16).padLeft(2, '0'),
    );
    _atqaCtrl = TextEditingController(
      text: _formatHexWithSpace(widget.card.atqa),
    );
    _atsCtrl = TextEditingController(
      text: _formatHexWithSpace(widget.card.ats),
    );
    _ulVersionCtrl = TextEditingController(
      text: _formatHexWithSpace(widget.card.ultralightVersion),
    );
    _ulSignatureCtrl = TextEditingController(
      text: _formatHexWithSpace(widget.card.ultralightSignature),
    );
    _hidTypeCtrl = TextEditingController(text: '1');
    _facilityCodeCtrl = TextEditingController();
    _issueLevelCtrl = TextEditingController();
    _oemCtrl = TextEditingController();
    if (_selectedType == TagType.hidProx) _initHidFields();
    _currentColor = widget.card.color;
    _pickerColor = widget.card.color;
    _originalUid = widget.card.uid;
    _originalSak = widget.card.sak.toRadixString(16).padLeft(2, '0');
    _originalAtqa = _formatHexWithSpace(widget.card.atqa);
    _initCounterControllers();
  }

  void _initCounterControllers() {
    for (final c in _counterCtrls) {
      c.dispose();
    }
    _counterCtrls.clear();
    final count = mfUltralightGetCounterCount(_selectedType);
    for (int i = 0; i < count; i++) {
      final val = i < widget.card.ultralightCounters.length
          ? widget.card.ultralightCounters[i].toString()
          : '0';
      _counterCtrls.add(TextEditingController(text: val));
    }
  }

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
    for (final c in _counterCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isLf => isLfTag(_selectedType);
  bool get _isUltralight => isMifareUltralight(_selectedType);
  bool get _isClassic => isMifareClassic(_selectedType);
  bool get _isHidProx => _selectedType == TagType.hidProx;

  /// 从 13 字节 UID 还原 HID Prox 字段（对齐 CU initHIDFields）；
  /// UID 非 13 字节时按缺省值填充，避免旧数据解析异常
  void _initHidFields() {
    final bytes = hexToUint8List(widget.card.uid);
    final full = bytes.length >= 13;
    _uidCtrl.text = full
        ? bytesToHexSpace(bytes.sublist(5, 10))
        : _formatHexWithSpace(widget.card.uid);
    final type = full && bytes[0] >= 1 && bytes[0] <= 30 ? bytes[0] : 1;
    _hidTypeCtrl.text = type.toString();
    _facilityCodeCtrl.text =
        (full
                ? (bytes[1] << 24) |
                      (bytes[2] << 16) |
                      (bytes[3] << 8) |
                      bytes[4]
                : 0)
            .toString();
    _issueLevelCtrl.text = (full ? bytes[10] : 0).toString();
    _oemCtrl.text = (full ? (bytes[11] << 8) | bytes[12] : 0).toString();
  }

  /// 由 HID Prox 字段重建 13 字节 UID（对齐 CU save 里的 try/catch 回退）
  String _buildUid(Uint8List uidBytes) {
    if (!_isHidProx) return bytesToHexSpace(uidBytes);
    try {
      return hidProxUidFromParts(
        int.parse(_hidTypeCtrl.text),
        int.parse(_facilityCodeCtrl.text),
        uidBytes,
        int.parse(_issueLevelCtrl.text),
        int.parse(_oemCtrl.text),
      );
    } catch (_) {
      return bytesToHexSpace(uidBytes);
    }
  }

  bool _hasDataChanged() =>
      _uidCtrl.text != _originalUid ||
      _sakCtrl.text != _originalSak ||
      _atqaCtrl.text != _originalAtqa;

  bool _canUpdateData() =>
      (_isClassic || _isUltralight) && widget.card.data.isNotEmpty;

  List<TagType> get _tagTypes => TagType.values;

  /// 校验 UID（对齐 CU validateUid 非创建模式：
  /// LF 须等于卡型字节数；HF（含 Ultralight）须 4 / 7 / 10 字节）
  String? _validateUid(String? value) {
    if (value == null || value.isEmpty) return 'UID 不能为空';
    final clean = value.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) {
      return 'UID 只能包含十六进制字符';
    }
    final bytes = clean.length ~/ 2;
    if (_isLf) {
      final expected = lfUidSize(_selectedType);
      if (bytes != expected) {
        return 'UID 需要 $expected 字节（${expected * 2} 位 hex）';
      }
      return null;
    }
    if (bytes != 4 && bytes != 7 && bytes != 10) {
      return 'UID 需要 4 / 7 / 10 字节';
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

  String _formatHexWithSpace(String hex) {
    if (hex.isEmpty) return '';
    final clean = hex.replaceAll(RegExp(r'\s'), '');
    final buf = StringBuffer();
    for (int i = 0; i < clean.length; i += 2) {
      if (i > 0) buf.write(' ');
      buf.write(clean.substring(i, i + 2));
    }
    return buf.toString();
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

  Future<bool> _showUpdateDataDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('更新卡数据'),
            content: const Text('UID/SAK/ATQA 已更改，是否更新卡数据中的对应字段？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('否'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('是'),
              ),
            ],
          ),
        ) ??
        false;
  }

  List<String> _updateCardData({
    required String uid,
    required String sak,
    required String atqa,
  }) {
    if (widget.card.data.isEmpty) return widget.card.data;
    final updated = List<String>.from(widget.card.data);
    if (_isClassic) {
      final uidBytes = hexToUint8List(uid);
      final sakVal = hexToUint8List(sak)[0];
      final atqaBytes = hexToUint8List(atqa);
      final block0 = mfClassicGenerateFirstBlock(uidBytes, sakVal, atqaBytes);
      updated[0] = block0
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    } else if (_isUltralight) {
      final uidBytes = hexToUint8List(uid);
      final newBlocks = mfUltralightGenerateFirstBlocks(uidBytes);
      for (int i = 0; i < newBlocks.length && i < updated.length; i++) {
        updated[i] = newBlocks[i]
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
      }
    }
    return updated;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    List<String> cardData = widget.card.data;
    if (_hasDataChanged() && _canUpdateData()) {
      final shouldUpdate = await _showUpdateDataDialog();
      if (shouldUpdate) {
        cardData = _updateCardData(
          uid: _uidCtrl.text,
          sak: _sakCtrl.text,
          atqa: _atqaCtrl.text,
        );
      }
    }

    final uid = _buildUid(hexToUint8List(_uidCtrl.text));
    final sak = _isLf ? widget.card.sak : hexToUint8List(_sakCtrl.text)[0];
    final atqa = _isLf
        ? widget.card.atqa
        : (_atqaCtrl.text.trim().isNotEmpty
              ? StorageService.bytesToHex(hexToUint8List(_atqaCtrl.text))
              : '');
    final ats = _isLf
        ? widget.card.ats
        : (_atsCtrl.text.trim().isNotEmpty
              ? StorageService.bytesToHex(hexToUint8List(_atsCtrl.text))
              : '');

    final updated = SaveCard(
      id: widget.card.id,
      uid: uid,
      name: _nameCtrl.text,
      tag: _selectedType,
      sak: sak,
      atqa: atqa,
      ats: ats,
      data: cardData,
      ultralightVersion: _ulVersionCtrl.text.trim().isNotEmpty
          ? StorageService.bytesToHex(hexToUint8List(_ulVersionCtrl.text))
          : '',
      ultralightSignature: _ulSignatureCtrl.text.trim().isNotEmpty
          ? StorageService.bytesToHex(hexToUint8List(_ulSignatureCtrl.text))
          : '',
      ultralightCounters: _counterCtrls
          .map((c) => int.tryParse(c.text) ?? 0)
          .toList(),
      folderId: widget.card.folderId,
      colorValue: _currentColor.toARGB32(),
      updatedAt: DateTime.now(),
    );

    await CardLibraryStorage().upsertCard(updated);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑卡片'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            children: [
              TextFormField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: '卡片名称',
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
              DropdownButtonFormField<TagType>(
                initialValue: _selectedType,
                decoration: const InputDecoration(labelText: '卡类型'),
                items: _tagTypes
                    .map(
                      (t) => DropdownMenuItem(value: t, child: Text(t.label)),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null && v != TagType.unknown) {
                    setState(() {
                      _selectedType = v;
                      _initCounterControllers();
                    });
                  }
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _uidCtrl,
                decoration: const InputDecoration(
                  labelText: 'UID',
                  prefixIcon: Icon(Icons.nfc),
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F\s]')),
                ],
                validator: _validateUid,
              ),
              const SizedBox(height: 16),
              if (!_isLf) ...[
                TextFormField(
                  controller: _sakCtrl,
                  decoration: const InputDecoration(
                    labelText: 'SAK',
                    hintText: '1 字节',
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
                    hintText: '2 字节',
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
                if (_isUltralight) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _ulVersionCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Ultralight Version',
                      hintText: '8 字节',
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
                      labelText: 'Ultralight Signature',
                      hintText: '可选',
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'[0-9a-fA-F\s]'),
                      ),
                    ],
                    validator: (v) => _validateHex(v),
                  ),
                  if (mfUltralightHasCounters(_selectedType)) ...[
                    for (int i = 0; i < _counterCtrls.length; i++) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _counterCtrls[i],
                        decoration: InputDecoration(labelText: '计数器 $i'),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        validator: (v) =>
                            _validateRange(v, min: 0, max: 16777215),
                      ),
                    ],
                  ],
                ],
              ],
              if (_isHidProx) ...[
                const SizedBox(height: 16),
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
        TextButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
