import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/enums.dart';
import '../../models/models.dart';
import '../../services/device_service.dart';
import '../../state/app_controller.dart';
import '../widgets/common.dart';

/// ID 卡 Tab：4 密钥 / Hex+Dec 显示 / 卡列表 / 读卡与写卡槽
class IdTab extends StatefulWidget {
  const IdTab({super.key});

  @override
  State<IdTab> createState() => _IdTabState();
}

class _IdTabState extends State<IdTab> {
  AppController get _app => AppScope.instance.controller;
  DeviceService get _dev => _app.device;

  final _decCtrl = TextEditingController();
  final _hexCtrl = TextEditingController();
  final _keysCtrl = TextEditingController();

  int _slotPage = 0;

  bool _keysValid = true;
  List<IdCardItem> _cards = [];

  @override
  void initState() {
    super.initState();
    _slotPage = _app.currentSlot;
    _decCtrl.text = _app.idCard.idCardDec;
    _hexCtrl.text = _app.idCard.idCardHex;
    _keysCtrl.text = _app.idCard.idCardKeys;
    _load();
  }

  @override
  void dispose() {
    _decCtrl.dispose();
    _hexCtrl.dispose();
    _keysCtrl.dispose();
    super.dispose();
  }

  // ========== 卡槽选择（弹框） ==========
  /// 弹出卡槽选择对话框，返回所选卡槽索引（取消返回 null）
  Future<int?> _pickSlot() async {
    final slot = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择卡槽', style: TextStyle(fontSize: 16)),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < 8; i++)
              ChoiceChip(
                label: Text('卡槽 ${i + 1}', style: const TextStyle(fontSize: 12)),
                selected: i == _slotPage,
                onSelected: (_) => Navigator.pop(ctx, i),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    );
    if (slot != null) {
      await _app.selectSlot(slot);
      if (mounted) setState(() => _slotPage = slot);
    }
    return slot;
  }

  Future<void> _load() async {
    final cards = await _app.storage.getIdCards();
    final keys = await _app.storage.getIdCardKeys();
    if (mounted) {
      setState(() {
        _cards = cards;
        _keysCtrl.text = keys;
      });
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  void _syncHex(String dec) {
    final v = BigInt.tryParse(dec.trim());
    _hexCtrl.text = v == null
        ? ''
        : v.toRadixString(16).toLowerCase().padLeft(10, '0');
  }

  void _syncDec(String hex) {
    final clean = hex.trim();
    if (clean.isEmpty || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) {
      _decCtrl.text = '';
      return;
    }
    final v = BigInt.parse(clean, radix: 16);
    _decCtrl.text = v.toString().padLeft(13, '0');
  }

  // ========== 读卡 ==========
  Future<void> _readCard() async {
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final res = await _dev.cmdEm410xScan();
      if (res.id.length != 5) throw DeviceException(1, '未发现 ID 卡');
      final hex = res.id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      setState(() {
        _hexCtrl.text = hex.toLowerCase();
        _syncDec(hex);
        _app.idCard.setCard(hex);
      });
      _toast('读到 ID：${_app.idCard.idCardDec}');
    } catch (e) {
      _toast('读卡失败: $e');
    }
  }

  // ========== 读卡槽 ==========
  /// 把卡槽设为 LF/EM4100 类型并激活（对应小程序 slotChangeTagTypeAndActive）
  /// 必须先将卡槽 tagType 设为 EM4100，否则 em410x 命令返回 invalid param
  Future<void> _prepareLfSlot(int slot) async {
    // 固件 TagSpecificType.EM410X = 100（见 chameleon_enum.py），旧值 4 是 OLD_MIFARE_2048
    const em4100 = 100;
    await _dev.cmdSlotChangeTagType(slot, em4100);
    await _dev.cmdSlotResetTagType(slot, em4100);
    await _dev.cmdSlotSetEnable(slot, 1, true);
    await _dev.cmdSlotSaveSettings();
    await _dev.cmdSlotSetActive(slot);
  }

  Future<void> _readSlot() async {
    final slot = await _pickSlot();
    if (slot == null) return;
    try {
      await _dev.assureDeviceMode(DeviceMode.tag);
      // 对齐小程序 btnEmuReadID：读卡槽只激活，不改变/重置卡槽数据，
      // 否则 cmdSlotResetTagType(setSlotDataDefault) 会清空已有 ID 数据
      if (_app.currentSlot != slot) await _dev.cmdSlotSetActive(slot);
      final id = await _dev.cmdEm410xGetEmuId();
      if (id.length != 5) throw DeviceException(1, '该卡槽无 ID 数据');
      final hex = id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      setState(() {
        _hexCtrl.text = hex.toLowerCase();
        _syncDec(hex.toLowerCase());
        _app.idCard.setCard(hex);
        _app.currentSlot = slot;
      });
      _toast('已读取卡槽 ${slot + 1} 的 ID：${_app.idCard.idCardDec}');
    } on DeviceException catch (e) {
      // 对齐小程序：invalid param(96) 视为卡槽无 ID 数据，非失败
      if (e.status == 96) {
        _toast('卡槽 ${slot + 1} 无 ID 数据');
      } else {
        _toast('读卡槽失败: ${e.message}');
      }
    } catch (e) {
      _toast('读卡槽失败: $e');
    }
  }

  // ========== 写卡槽 ==========
  Future<void> _writeSlot() async {
    final hex = _hexCtrl.text.trim().toLowerCase();
    if (hex.isEmpty || !RegExp(r'^[0-9a-f]{10}$').hasMatch(hex)) {
      _toast('请输入有效的 10 位十六进制卡号');
        return;
    }
    final slot = await _pickSlot();
    if (slot == null) return;
    try {
      // EM4100 5 字节卡号直接由 10 位 hex 转换
      final idBytes = Uint8List(5);
      for (var i = 0; i < 5; i++) {
        idBytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      await _dev.assureDeviceMode(DeviceMode.tag);
      await _prepareLfSlot(slot);
      await _dev.cmdEm410xSetEmuId(idBytes);
      // 对齐小程序：写入 ID 数据后保存卡槽设置
      await _dev.cmdSlotSaveSettings();
      _app.currentSlot = slot;
      // 对齐小程序 btnEmuWriteID：写卡槽后刷新启用卡槽列表（cmdSlotGetIsEnable）
      try {
        await _app.loadEnabledSlots();
        if (mounted) setState(() {});
      } catch (_) {}
      _toast('已写入卡槽 ${slot + 1}');
    } catch (e) {
      _toast('写卡槽失败: $e');
    }
  }

  // ========== 写卡（写 T55xx 实体卡） ==========
  Future<void> _writeCard() async {
    final hex = _hexCtrl.text.trim().toLowerCase();
    if (hex.isEmpty || !RegExp(r'^[0-9a-f]{10}$').hasMatch(hex)) {
      _toast('请输入有效的 10 位十六进制卡号');
      return;
    }
    final keys = _keysCtrl.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(e))
        .toList();
    if (keys.isEmpty) {
      _toast('请先在密钥中填入有效的 T55xx 密钥（8 位十六进制）');
      return;
    }
    try {
      final idBytes = Uint8List(5);
      for (var i = 0; i < 5; i++) {
        idBytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      final newKey = Uint8List(4);
      for (var i = 0; i < 4; i++) {
        newKey[i] = int.parse(keys[0].substring(i * 2, i * 2 + 2), radix: 16);
      }
      // 逐个尝试旧密钥写入并回读验证
      for (final k in keys) {
        final oldKey = Uint8List(4);
        for (var i = 0; i < 4; i++) {
          oldKey[i] = int.parse(k.substring(i * 2, i * 2 + 2), radix: 16);
        }
        _toast('正在尝试密钥 $k ...');
        await _dev.cmdEm410xWriteToT55xx(idBytes, newKey, [oldKey]);
        final r = await _dev.cmdEm410xScan();
        if (r.id.length == 5 &&
            r.id.map((b) => b.toRadixString(16).padLeft(2, '0')).join() ==
                hex) {
          _toast('写入完成');
          return;
        }
      }
      _toast('可能卡片不支持修改卡号，或请尝试用机器背面写卡');
    } catch (e) {
      _toast('写卡失败: $e');
    }
  }

  // ========== 卡列表 ==========
  Future<void> _showCardList() async {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
                title: Text('已保存 ID 卡', style: TextStyle(fontWeight: FontWeight.w600))),
            Expanded(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _cards.length,
                itemBuilder: (_, i) {
                  final c = _cards[i];
                  return ListTile(
                    title: Text(c.id),
                    subtitle: Text(c.name),
                    onTap: () {
                      setState(() {
                        _hexCtrl.text = c.id;
                        _syncDec(c.id);
                        _app.idCard.setCard(c.id);
                      });
                      Navigator.pop(ctx);
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.grey),
                      onPressed: () async {
                        setState(() => _cards.removeAt(i));
                        await _app.storage.saveIdCards(_cards);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addCard() async {
    final hex = _hexCtrl.text.trim().toLowerCase();
    if (hex.isEmpty || !RegExp(r'^[0-9a-f]{10}$').hasMatch(hex)) {
      _toast('请输入有效的 10 位十六进制卡号');
      return;
    }
    setState(() {
      _cards = [
        ..._cards,
        IdCardItem(id: hex, name: '卡${_cards.length + 1}'),
      ];
    });
    await _app.storage.saveIdCards(_cards);
    _toast('已保存到列表');
  }

  // ========== 编辑密钥 ==========
  Future<void> _editKeys() async {
    await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑密钥', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: _keysCtrl,
          maxLines: 4,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          decoration: const InputDecoration(
            hintText: '每行一个密钥，8 位十六进制',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () async {
                await _app.storage.saveIdCardKeys(_keysCtrl.text);
                if (ctx.mounted) Navigator.pop(ctx);
                _toast('已保存');
              },
              child: const Text('确定')),
        ],
      ),
    );
  }

  // ========== UI ==========
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: _app,
      builder: (context, _) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  // 卡号
                  SectionCard(
                    title: 'ID 卡号',
                    child: Column(
                      children: [
                        _numRow('十进制', _decCtrl, '000536875977487',
                            onChanged: _syncHex),
                        _numRow('十六进制', _hexCtrl, '0000000000',
                            onChanged: _syncDec),
                      ],
                    ),
                  ),
                  // 密钥：对齐小程序为可编辑文本域（非法输入显示红色小写）
                  SectionCard(
                    title: '密钥',
                    child: TextField(
                      controller: _keysCtrl,
                      decoration: const InputDecoration(
                        hintText: '一行一个密钥,密钥应为8位16进制数',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: _keysValid ? const Color(0xFF333333) : Colors.red,
                      ),
                      maxLines: 4,
                      minLines: 4,
                      onChanged: (text) => setState(() {
                        final lines = text
                            .split('\n')
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .toList();
                        _keysValid = lines.every(
                            (e) => RegExp(r'^[0-9a-f]{8}$').hasMatch(e.toLowerCase()));
                      }),
                    ),
                  ),
                  // 卡列表
                  SectionCard(
                    title: '卡列表',
                    child: _cards.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(4),
                            child: Text('暂无保存的 ID 卡',
                                style: TextStyle(fontSize: 13, color: Colors.grey)),
                          )
                        : Column(
                            children: _cards
                                .take(5)
                                .map((c) => ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(c.id,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontFamily: 'monospace')),
                                      subtitle: Text(c.name,
                                          style: const TextStyle(fontSize: 11)),
                                    ))
                                .toList(),
                          ),
                  ),
                ],
              ),
            ),
            // 右侧按钮
            Container(
              width: 96,
              margin: const EdgeInsets.fromLTRB(0, 8, 6, 0),
              child: Column(
                children: [
                  ActionButton(
                      label: '读卡',
                      icon: Icons.radio_button_checked,
                      color: primary,
                      onTap: _readCard,
                      enabled: _app.connected),
                  const SizedBox(height: 8),
                  ActionButton(
                      label: '写卡',
                      icon: Icons.save_alt,
                      color: primary,
                      onTap: _writeCard,
                      enabled: _app.connected),
                  const SizedBox(height: 8),
                  ActionButton(
                      label: '读卡槽',
                      icon: Icons.memory,
                      color: primary,
                      onTap: _readSlot,
                      enabled: _app.connected),
                  const SizedBox(height: 8),
                  ActionButton(
                      label: '写卡槽',
                      icon: Icons.memory,
                      color: primary,
                      onTap: _writeSlot,
                      enabled: _app.connected),
                  const SizedBox(height: 8),
                  ActionButton(
                      label: '卡列表',
                      icon: Icons.list,
                      color: primary,
                      onTap: _showCardList),
                  const SizedBox(height: 8),
                  ActionButton(
                      label: '添加到列表',
                      icon: Icons.add,
                      color: primary,
                      onTap: _addCard),
                  const SizedBox(height: 8),
                  ActionButton(
                      label: '编辑密钥',
                      icon: Icons.edit,
                      color: primary,
                      onTap: _editKeys),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _numRow(String label, TextEditingController ctrl, String hint,
      {ValueChanged<String>? onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
              width: 64,
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)))),
          Expanded(
            child: TextField(
              controller: ctrl,
              onChanged: onChanged,
              style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
