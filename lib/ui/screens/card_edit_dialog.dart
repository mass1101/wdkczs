import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/enums.dart';
import '../../services/card_library.dart';
import '../../services/storage_service.dart';

const _editPresetColors = <Color>[
  Color(0xFFFF5722),
  Color(0xFF2196F3),
  Color(0xFF4CAF50),
  Color(0xFF9C27B0),
  Color(0xFFFF9800),
  Color(0xFFE91E63),
  Color(0xFF00BCD4),
  Color(0xFF795548),
  Color(0xFF607D8B),
  Color(0xFFF44336),
];

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
  late List<TextEditingController> _counterCtrls;

  late TagType _selectedType;
  late Color _currentColor;
  late String _originalUid;
  late String _originalSak;
  late String _originalAtqa;

  @override
  void initState() {
    super.initState();
    _selectedType = widget.card.tag;
    _nameCtrl = TextEditingController(text: widget.card.name);
    _uidCtrl = TextEditingController(text: widget.card.uid);
    final sakHex = widget.card.sak.toRadixString(16).padLeft(2, '0');
    _sakCtrl = TextEditingController(text: sakHex);
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
    _currentColor = widget.card.color;
    _originalUid = widget.card.uid;
    _originalSak = sakHex;
    _originalAtqa = _formatHexWithSpace(widget.card.atqa);
    _initCounterControllers();
  }

  void _initCounterControllers() {
    for (final c in _counterCtrls) {
      c.dispose();
    }
    _counterCtrls = [];
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
    for (final c in _counterCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isLf => isLfTag(_selectedType);
  bool get _isUltralight => isMifareUltralight(_selectedType);
  bool get _isClassic => isMifareClassic(_selectedType);

  bool _hasDataChanged() =>
      _uidCtrl.text != _originalUid ||
      _sakCtrl.text != _originalSak ||
      _atqaCtrl.text != _originalAtqa;

  bool _canUpdateData() =>
      (_isClassic || _isUltralight) && widget.card.data.isNotEmpty;

  List<TagType> get _tagTypes => TagType.values;

  String? _validateUid(String? value) {
    if (value == null || value.trim().isEmpty) return 'UID 不能为空';
    final clean = value.replaceAll(RegExp(r'\s'), '');
    if (clean.isEmpty) return 'UID 不能为空';
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) return 'UID 只能包含十六进制字符';
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
              children: _editPresetColors.map((c) {
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
          ],
        ),
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

    final uidBytes = hexToUint8List(_uidCtrl.text);
    final uid = bytesToHexSpace(uidBytes);
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
      name: _nameCtrl.text.trim(),
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
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('编辑卡片'),
          leading: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(color: Colors.white)),
          ),
          actions: [
            TextButton(
              onPressed: _save,
              child: const Text(
                '保存',
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
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '请输入名称' : null,
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
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          if (n == null || n < 0 || n > 16777215) {
                            return '0-16777215';
                          }
                          return null;
                        },
                      ),
                    ],
                  ],
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
