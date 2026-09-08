import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart';
import '../../models/enums.dart';
import '../../models/models.dart';
import '../../services/crypto1.dart';
import '../../services/device_service.dart';
import '../../state/app_controller.dart';
import '../../ui/dialogs/crack_dialog.dart';
import '../../ui/dialogs/key_file_sheet.dart';
import '../../ui/dialogs/text_input_dialog.dart';
import '../widgets/common.dart';

/// IC 卡 Tab：密钥卡片、卡类型、扇区数据表、右侧操作按钮
class IcTab extends StatefulWidget {
  const IcTab({super.key});

  @override
  State<IcTab> createState() => _IcTabState();
}

class _IcTabState extends State<IcTab> {
  AppController get _app => AppScope.instance.controller;
  DeviceService get _dev => _app.device;

  final _uidCtrl = TextEditingController();
  final _atqaCtrl = TextEditingController();
  final _sakCtrl = TextEditingController();
  final _atsCtrl = TextEditingController();
  final _keyCtrl = TextEditingController(text: kDefaultKeys.join('\n'));

  int _slotPage = 0;
  bool _keysValid = true;

  @override
  void initState() {
    super.initState();
    _uidCtrl.text = _app.card.uid;
    _atqaCtrl.text = _app.card.atqa;
    _sakCtrl.text = _app.card.sak;
    _keyCtrl.text = _app.card.keys;
    _validateKeys(_app.card.keys);
    _loadKeys();
    _loadSlots();
  }

  Future<void> _loadSlots() async {
    try {
      await _app.loadEnabledSlots();
      await _app.loadActiveSlotEmuSettings();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _uidCtrl.dispose();
    _atqaCtrl.dispose();
    _sakCtrl.dispose();
    _atsCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadKeys() async {
    final names = await _app.storage.getKeyNames();
    if (names.isEmpty || !mounted) return;
    final existing = _keys.toList();
    final merged = <String>[...existing];
    for (final v in names.values) {
      for (final line in v.split('\n').map((e) => e.trim()).where((e) => e.length == 12)) {
        if (!merged.contains(line)) merged.add(line);
      }
    }
    _keyCtrl.text = merged.join('\n');
    _validateKeys(_keyCtrl.text);
  }

  void _validateKeys(String text) {
    final lines = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    _keysValid = lines.every(
        (e) => RegExp(r'^[0-9a-f]{12}$').hasMatch(e.toLowerCase()));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  List<String> get _keys =>
      _keyCtrl.text.split('\n').map((e) => e.trim()).where((e) => e.length == 12).toList();

  // ========== 扇区密钥状态（对齐小程序 sectors_Key） ==========
  /// 批量检查密钥，对齐小程序 checkCrackedKey：用 mf1CheckKeysOfSectors 掩码批量检测
  /// 返回 true 表示仍有未找到的密钥
  Future<bool> _checkCrackedKeys(
      List<Uint8List> keys, List<_SectorKey> sectorKeys) async {
    final mask = Uint8List(10);
    mask.fillRange(0, 10, 0xFF);
    for (var s = 0; s < 16; s++) {
      if (!sectorKeys[s].hasKeyA) mask[s >> 2] ^= 2 << (6 - s % 4 * 2);
      if (!sectorKeys[s].hasKeyB) mask[s >> 2] ^= 1 << (6 - s % 4 * 2);
    }
    final res = await _dev.cmdMf1CheckKeysOfSectors(keys: keys, mask: mask);
    var anyMissing = false;
    for (var s = 0; s < 16; s++) {
      if (!sectorKeys[s].hasKeyA) {
        final a = res.sectorKeys[s * 2];
        if (a == null) {
          anyMissing = true;
        } else {
          sectorKeys[s].hasKeyA = true;
          sectorKeys[s].keyA = _hexStr(a);
        }
      }
      if (!sectorKeys[s].hasKeyB) {
        final b = res.sectorKeys[s * 2 + 1];
        if (b == null) {
          anyMissing = true;
        } else {
          sectorKeys[s].hasKeyB = true;
          sectorKeys[s].keyB = _hexStr(b);
        }
      }
    }
    return anyMissing;
  }

  /// 将扇区密钥状态中的密钥追加到密钥区（对齐小程序 ss.keys 合并去重）
  void _appendKeysFromSectors(List<_SectorKey> sectorKeys) {
    final all = <String>[];
    for (final sk in sectorKeys) {
      if (sk.keyA.isNotEmpty && !all.contains(sk.keyA)) all.add(sk.keyA);
      if (sk.keyB.isNotEmpty && !all.contains(sk.keyB)) all.add(sk.keyB);
    }
    _appendKeys(all);
  }

  // ========== 读卡（对齐小程序：步骤指示器 + 阶段前缀进度） ==========
  Future<void> _readCard() async {
    final progress = ValueNotifier<String>('验证密钥：寻卡中...');
    final step = ValueNotifier<int>(0);
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final tag = tags.first;
      if (tag.sakHex != '08') {
        _toast('发现非标准M1卡，该卡无法读写');
        return;
      }
      final uid = tag.uidHex;
      final found = <String>[];
      var gen1aDone = false;

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => CrackProgressDialog(
          title: '正在读取卡片...',
          steps: const ['验证密钥', '读卡片'],
          step: step,
          progress: progress,
          onCancel: null,
        ),
      );

      // 验证密钥：尝试 Gen1a 免密读卡
      try {
        step.value = 1;
        progress.value = '验证密钥：发现UID卡，可免密读卡...';
        final gen1aSectors = List.generate(16, (_) => SectorData());
        for (var s = 0; s < 16; s++) {
          if (!_app.card.toggle[s]) continue;
          progress.value = '读卡片：正在读扇区$s...';
          final data = await _dev.mf1Gen1aReadBlocks(4 * s, 4);
          if (data.length < 64) continue;
          final block3 = Uint8List.fromList(data.sublist(48, 64));
          await _overlayBlock3Keys(s, block3);
          final blocks = List<BlockData>.generate(
              4, (i) => BlockData(data: i == 3
                  ? _hexStr(block3)
                  : _hexStr(data.sublist(i * 16, i * 16 + 16))));
          gen1aSectors[s] = SectorData(blocks: blocks);
          final kA = _hexStr(block3.sublist(0, 6));
          final kB = _hexStr(block3.sublist(10, 16));
          if (kA != 'ffffffffffff' && kA != '000000000000') found.add(kA);
          if (kB != 'ffffffffffff' && kB != '000000000000') found.add(kB);
        }
        gen1aDone = true;
        setState(() {
          _app.card.uid = uid;
          _app.card.atqa = tag.atqaHex;
          _app.card.sak = tag.sakHex;
          _app.card.sectors = gen1aSectors;
        });
        _appendKeys(found);
      } catch (_) {
        // Gen1a 不可用，走常规认证读
      }
      if (gen1aDone) {
        if (mounted) Navigator.of(context).pop();
        _toast('读卡完成！');
        return;
      }

      // 验证密钥：验证中...
      step.value = 0;
      progress.value = '验证密钥：验证中...';
      await _loadKeys();

      // 验证密钥：批量检测扇区密钥（对齐小程序 checkCrackedKey）
      final sectorKeys = List.generate(16, (s) => _SectorKey(s));
      final allKeys = _keys.map(_hex).toList();
      final anyMissing = await _checkCrackedKeys(allKeys, sectorKeys);
      progress.value = '验证密钥：已标记扇区密钥信息.';

      if (anyMissing) {
        _appendKeysFromSectors(sectorKeys);
        progress.value = '读卡片：卡片有加密，请先使用解卡片功能获取密钥';
        if (mounted) Navigator.of(context).pop();
        _toast('卡片有加密，请先使用解卡片功能获取密钥');
        return;
      }

      // 读卡片：逐扇区逐块用已确定密钥读取（对齐小程序 btnGen2Read）
      step.value = 1;
      final sectors = List.generate(16, (_) => SectorData());
      final allBlocks = List<BlockData>.generate(64, (_) => BlockData());
      final failedBlocks = <int>[];
      for (var s = 0; s < 16; s++) {
        if (!_app.card.toggle[s]) continue;
        progress.value = '读卡片：正在读扇区$s...';
        final baseBlock = s * 4;
        for (var b = 0; b < 4; b++) {
          final blockNum = baseBlock + b;
          // 先试 keyA，失败再试 keyB（对齐小程序 btnGen2Read）
          var read = false;
          if (sectorKeys[s].hasKeyA && sectorKeys[s].keyA.isNotEmpty) {
            try {
              final data = await _dev.cmdMf1ReadBlock(
                  block: blockNum,
                  keyType: KeyType.keyA,
                  key: _hex(sectorKeys[s].keyA));
              allBlocks[blockNum].data = _hexStr(data);
              read = true;
            } catch (_) {}
          }
          if (!read &&
              sectorKeys[s].hasKeyB &&
              sectorKeys[s].keyB.isNotEmpty) {
            try {
              final data = await _dev.cmdMf1ReadBlock(
                  block: blockNum,
                  keyType: KeyType.keyB,
                  key: _hex(sectorKeys[s].keyB));
              allBlocks[blockNum].data = _hexStr(data);
              read = true;
            } catch (_) {}
          }
          if (!read) failedBlocks.add(blockNum);
        }
        // 块3密钥区覆盖（对齐小程序：用已知密钥回填 block3 bytes 0-5, 10-15）
        final b3Idx = baseBlock + 3;
        if (allBlocks[b3Idx].data != 'ffffffffffffffffffffffffffffffff') {
          final block3 = _hex(allBlocks[b3Idx].data);
          if (sectorKeys[s].hasKeyA) block3.setRange(0, 6, _hex(sectorKeys[s].keyA));
          if (sectorKeys[s].hasKeyB) block3.setRange(10, 16, _hex(sectorKeys[s].keyB));
          allBlocks[b3Idx].data = _hexStr(block3);
        }
      }
      for (var s = 0; s < 16; s++) {
        if (!_app.card.toggle[s]) continue;
        final blocksArr = List<BlockData>.generate(4, (i) => allBlocks[s * 4 + i]);
        sectors[s] = SectorData(blocks: blocksArr);
        // 提取块3密钥到密钥区
        final b3 = allBlocks[s * 4 + 3].data;
        if (b3 != 'ffffffffffffffffffffffffffffffff') {
          final kb = _hex(b3);
          if (kb.length >= 16) {
            final kA = _hexStr(kb.sublist(0, 6));
            final kB = _hexStr(kb.sublist(10, 16));
            if (kA != 'ffffffffffff' && kA != '000000000000') found.add(kA);
            if (kB != 'ffffffffffff' && kB != '000000000000') found.add(kB);
          }
        }
      }
      setState(() {
        _app.card.uid = uid;
        _app.card.atqa = tag.atqaHex;
        _app.card.sak = tag.sakHex;
        _app.card.sectors = sectors;
      });
      _appendKeys(found);
      if (mounted) Navigator.of(context).pop();
      if (failedBlocks.isEmpty) {
        _toast('读卡完成！');
      } else {
        _toast('读卡片：块${failedBlocks.join('，')} 读取失败');
      }
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('读卡失败: $e');
    }
  }

  /// 检测扇区密钥并覆盖块3密钥区（对齐小程序 mf1CheckSectorKeys + sectors_Key 回填）
  /// 读块3时访问位可能遮蔽密钥A（返回0），通过 mf1CheckSectorKeys 检测有效密钥并回填。
  Future<void> _overlayBlock3Keys(int sector, Uint8List block3) async {
    try {
      final validKeys = await _dev.mf1CheckSectorKeys(sector, _keys.map(_hex).toList());
      final va = validKeys[KeyType.keyA.value];
      final vb = validKeys[KeyType.keyB.value];
      if (va != null) block3.setRange(0, 6, va);
      if (vb != null) block3.setRange(10, 16, vb);
    } catch (_) {}
  }

  // ========== 写卡（对齐小程序：确认弹窗 + 步骤指示器 + 阶段前缀进度） ==========
  Future<void> _writeCard() async {
    // 确认弹窗
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确定要写卡片吗？'),
        content: const Text('即将写入数据至卡片，继续吗?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续')),
        ],
      ),
    );
    if (confirm != true) return;

    final progress = ValueNotifier<String>('验证密钥：寻卡中...');
    final step = ValueNotifier<int>(0);
    var stopFlag = false;
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final tag = tags.first;
      if (tag.sakHex != '08') {
        _toast('发现非标准M1卡，该卡无法读写');
        return;
      }
      if (!_nuidXorValid()) throw Exception('数据有误，卡号XOR校验码不正确');

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => CrackProgressDialog(
          title: '写卡片',
          steps: const ['验证密钥', '写卡片'],
          step: step,
          progress: progress,
          onCancel: () {
            stopFlag = true;
          },
        ),
      );

      // 验证密钥：尝试 Gen1a 免密写
      var gen1aDone = false;
      try {
        step.value = 1;
        progress.value = '验证密钥：发现UID卡，可免密读写...';
        for (var sector = 0; sector < 16; sector++) {
          if (stopFlag) throw Exception('已停止');
          if (!_app.card.toggle[sector]) continue;
          final blocks = _app.card.sectors[sector].blocks;
          if (blocks[0].data == '00000000000000000000000000000000') continue;
          progress.value = '写卡片：正在写扇区$sector...';
          final payload = Uint8List(64);
          for (var b = 0; b < 4; b++) {
            payload.setRange(b * 16, b * 16 + 16, _hex(blocks[b].data));
          }
          await _dev.mf1Gen1aWriteBlocks(sector * 4, payload);
        }
        gen1aDone = true;
        progress.value = '写卡片：写入完成';
        _toast('写入完成');
      } catch (e) {
        if (stopFlag) {
          _toast('已停止');
        } else {
          // Gen1a 不可用，走常规认证写
        }
      }
      if (gen1aDone) {
        if (mounted) Navigator.of(context).pop();
        return;
      }

      // 验证密钥：验证中...
      step.value = 0;
      progress.value = '验证密钥：验证中...';
      await _loadKeys();

      // 写卡片：逐扇区写入（对齐小程序 btnGen2Write）
      step.value = 1;
      final failedBlocks = <int>[];
      for (var sector = 0; sector < 16; sector++) {
        if (stopFlag) break;
        if (!_app.card.toggle[sector]) continue;
        progress.value = '写卡片：正在写入扇区：$sector...';
        final blocks = _app.card.sectors[sector].blocks;
        if (blocks[0].data == '00000000000000000000000000000000') continue;
        for (var b = 0; b < 4; b++) {
          if (stopFlag) break;
          final blockNum = sector * 4 + b;
          var written = false;
          for (final keyStr in _keys) {
            final key = _hex(keyStr);
            if (!written) {
              try {
                await _dev.cmdMf1WriteBlock(
                    block: blockNum,
                    keyType: KeyType.keyA,
                    key: key,
                    data: _hex(blocks[b].data));
                written = true;
              } catch (_) {}
            }
            if (!written) {
              try {
                await _dev.cmdMf1WriteBlock(
                    block: blockNum,
                    keyType: KeyType.keyB,
                    key: key,
                    data: _hex(blocks[b].data));
                written = true;
              } catch (_) {}
            }
            if (written) break;
          }
          if (!written) failedBlocks.add(blockNum);
        }
      }
      if (failedBlocks.isEmpty) {
        progress.value = '写卡片：写入完成';
        _toast('写入完成');
      } else {
        progress.value =
            '写卡片：块${failedBlocks.join('，')} 写入失败';
        _toast('写入完成：${failedBlocks.length} 块失败');
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('写卡失败: $e');
    }
  }

  // ========== 写卡槽（模拟） ==========
  /// 把卡槽设为 HF/MIFARE_1024 类型并激活（对应小程序 slotChangeTagTypeAndActive 的 HF 分支）
  Future<void> _prepareHfSlot(int slot) async {
    const mifare1024 = 1001;
    await _dev.cmdSlotChangeTagType(slot, mifare1024);
    await _dev.cmdSlotResetTagType(slot, mifare1024);
    await _dev.cmdSlotSetEnable(slot, 2, true); // freq=2 表示 HF
    await _dev.cmdSlotSaveSettings();
    await _dev.cmdSlotSetActive(slot);
  }

  Future<void> _writeSlot() async {
    final slot = await _pickSlot();
    if (slot == null) return;
    try {
      await _dev.assureDeviceMode(DeviceMode.tag);
      // 输入校验（对齐小程序 btnEmuWrite）
      if (!_nuidXorValid()) throw Exception('数据有误，卡号XOR校验码不正确');
      if (!RegExp(r'^[0-9a-fA-F]{8}$')
          .hasMatch(_uidCtrl.text.replaceAll(RegExp(r'\s'), ''))) {
        throw Exception('卡号有误，IC卡号应为8位16进制数');
      }
      if (!RegExp(r'^[0-9a-fA-F]{2}$')
          .hasMatch(_sakCtrl.text.replaceAll(RegExp(r'\s'), ''))) {
        throw Exception('SAK有误，SAK应为2位16进制数');
      }
      if (!RegExp(r'^[0-9a-fA-F]{4}$')
          .hasMatch(_atqaCtrl.text.replaceAll(RegExp(r'\s'), ''))) {
        throw Exception('ATQA有误，ATQA应为4位16进制数');
      }
      await _prepareHfSlot(slot);
      // 对齐小程序 btnEmuWrite 的 mf1 仿真设置
      await _dev.cmdMf1SetAntiCollMode(false);
      await _dev.cmdMf1SetDetectionEnable(true);
      await _dev.cmdMf1SetGen1aMode(false);
      await _dev.cmdMf1SetGen2Mode(false);
      await _dev.cmdMf1SetWriteMode(0);
      // 写入反碰撞数据（小程序对 atqa 做字节反转）
      final atqa = _hex(_atqaCtrl.text).reversed.toList();
      await _dev.cmdHf14aSetAntiCollData(
          uid: _hex(_uidCtrl.text),
          atqa: Uint8List.fromList(atqa),
          sak: _hex(_sakCtrl.text));
      // 逐扇区写入，对齐小程序 cmdMf1EmuWriteBlock(sector*4, body[sector])
      for (var sector = 0; sector < 16; sector++) {
        if (!_app.card.toggle[sector]) continue;
        final body = StringBuffer();
        for (var b = 0; b < 4; b++) {
          body.write(_app.card.sectors[sector].blocks[b].data);
        }
        await _dev.cmdMf1EmuWriteBlock(sector * 4, _hex(body.toString()));
      }
      await _dev.cmdSlotSaveSettings();
      await _app.storage.setCurrentUid(_uidCtrl.text);
      _app.currentSlot = slot;
      _toast('已写入卡槽 ${slot + 1}');
    } catch (e) {
      _toast('写卡槽失败: $e');
    }
  }

  // ========== 解卡（对齐小程序 btnCrack + Crack() 完整流程） ==========
  Future<void> _crackCard() async {
    final progress = ValueNotifier<String>('验证密钥：寻卡中...');
    final step = ValueNotifier<int>(0);
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final tag = tags.first;
      if (tag.sakHex != '08') {
        _toast('发现非标准M1卡，该卡无法破解');
        return;
      }
      if (_keys.isEmpty) {
        _toast('请先填写密钥');
        return;
      }
      final uid = tag.uid;
      final uidInt = _bytesInt(uid.sublist(0, 4));

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => CrackProgressDialog(
          title: '正在破解卡片...',
          steps: const ['验证密钥', '解卡片'],
          step: step,
          progress: progress,
          onCancel: null,
        ),
      );

      // 验证密钥：尝试 Gen1a 免密读卡
      try {
        progress.value = '验证密钥：发现UID卡，可免密读卡...';
        final found = <String>[];
        var allRead = true;
        for (var s = 0; s < 16; s++) {
          progress.value = '破解密钥：正在解密扇区$s...';
          final Uint8List data;
          try {
            data = await _dev.mf1Gen1aReadBlocks(4 * s, 4);
          } catch (_) {
            allRead = false;
            break;
          }
          if (data.length < 64) {
            allRead = false;
            break;
          }
          final kA = _hexStr(data.sublist(48, 54));
          final kB = _hexStr(data.sublist(58, 64));
          if (kA != 'ffffffffffff' && kA != '000000000000') found.add(kA);
          if (kB != 'ffffffffffff' && kB != '000000000000') found.add(kB);
        }
        if (allRead) {
          _appendKeys(found);
          progress.value = '破解密钥：破解成功';
          if (mounted) Navigator.of(context).pop();
          _toast(found.isEmpty ? '未发现可破解密钥' : '破解成功');
          return;
        }
      } catch (_) {}

      // 验证密钥：验证中...
      step.value = 0;
      progress.value = '验证密钥：验证中...';
      await _loadKeys();

      // 验证密钥：批量检测扇区密钥（对齐小程序 checkCrackedKey）
      final sectorKeys = List.generate(16, (s) => _SectorKey(s));
      final allKeys = _keys.map(_hex).toList();
      final anyMissing = await _checkCrackedKeys(allKeys, sectorKeys);
      progress.value = '验证密钥：已标记扇区密钥信息.';

      // 检查是否全部已破解
      if (!anyMissing) {
        _appendKeysFromSectors(sectorKeys);
        step.value = 1;
        progress.value = '解卡片：破解成功，已重新标记密钥信息.';
        if (mounted) Navigator.of(context).pop();
        _toast('破解成功！');
        return;
      }

      // 找到第一个已知密钥扇区作为 e_sector（对齐小程序 ss.e_sector）
      int eSector = -1;
      KeyType eKeyType = KeyType.keyA;
      String eKeyHex = '';
      for (var s = 0; s < 16; s++) {
        if (sectorKeys[s].hasKeyA && sectorKeys[s].keyA.isNotEmpty) {
          eSector = s;
          eKeyType = KeyType.keyA;
          eKeyHex = sectorKeys[s].keyA;
          break;
        }
        if (sectorKeys[s].hasKeyB && sectorKeys[s].keyB.isNotEmpty) {
          eSector = s;
          eKeyType = KeyType.keyB;
          eKeyHex = sectorKeys[s].keyB;
          break;
        }
      }

      // 全加密卡（无已知密钥），无法进行嵌套攻击
      if (eSector == -1) {
        _appendKeysFromSectors(sectorKeys);
        progress.value = '解卡片：发现全加密卡，无法破解（密钥区为空，需至少一个已知密钥）';
        if (mounted) Navigator.of(context).pop();
        _toast('全加密卡，密钥区为空，请先通过其他方式获取至少一个密钥');
        return;
      }

      // 解卡片：逐扇区破解（对齐小程序 Crack()）
      step.value = 1;
      final prng = await _dev.cmdMf1TestPrngType();

      if (prng >= 2) {
        progress.value = '解卡片：该卡片为强随机卡，正在云端破解...';
        await _submitHardnested(uid);
        if (mounted) Navigator.of(context).pop();
        return;
      }

      // STATIC (prng==0) 或 WEAK (prng==1)：逐扇区破解 keyA 和 keyB
      for (var s = 0; s < 16; s++) {
        if (!sectorKeys[s].hasKeyA) {
          progress.value = prng == 0
              ? '破解密钥：该卡片为静态无漏洞卡，正在破解加密扇区：$s keyA...'
              : '破解密钥：该卡片为弱随机卡，正在破解加密扇区：$s keyA...';
          try {
            final rec = await _crackSectorKey(
                uidInt, s, KeyType.keyA, prng, eSector, eKeyType, eKeyHex);
            if (rec != null) {
              sectorKeys[s].hasKeyA = true;
              sectorKeys[s].keyA = rec;
            }
          } catch (e) {
            progress.value = '破解密钥：扇区$s keyA 破解失败：$e';
          }
        }
        if (!sectorKeys[s].hasKeyB) {
          progress.value = prng == 0
              ? '破解密钥：该卡片为静态无漏洞卡，正在破解加密扇区：$s keyB...'
              : '破解密钥：该卡片为弱随机卡，正在破解加密扇区：$s keyB...';
          try {
            final rec = await _crackSectorKey(
                uidInt, s, KeyType.keyB, prng, eSector, eKeyType, eKeyHex);
            if (rec != null) {
              sectorKeys[s].hasKeyB = true;
              sectorKeys[s].keyB = rec;
            }
          } catch (e) {
            progress.value = '破解密钥：扇区$s keyB 破解失败：$e';
          }
        }
      }

      // 追加发现的密钥
      _appendKeysFromSectors(sectorKeys);

      // 检查是否全部破解成功（对齐小程序 Check_Crack_isfaild）
      var allFound = true;
      for (var s = 0; s < 16; s++) {
        if (!sectorKeys[s].hasKeyA || !sectorKeys[s].hasKeyB) {
          allFound = false;
          break;
        }
      }
      if (allFound) {
        progress.value = '解卡片：破解成功，已重新标记密钥信息.';
        if (mounted) Navigator.of(context).pop();
        _toast('破解成功');
      } else {
        progress.value = '解卡片：破解失败，部分扇区密钥未找到';
        if (mounted) Navigator.of(context).pop();
        _toast('破解失败，部分扇区密钥未找到（已写入找到的密钥）');
      }
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('破解失败: $e');
    }
  }

  /// 对单个扇区恢复密钥（支持 keyA/keyB，对齐小程序 Crack() 逐扇区破解）
  Future<String?> _crackSectorKey(
      int uidInt, int sector, KeyType targetKeyType, int prng,
      int eSector, KeyType eKeyType, String eKeyHex) async {
    final eKey = _hex(eKeyHex);

    if (prng == 0) {
      // STATIC 嵌套：检查 nt2 区分1代/2代卡
      final res = await _dev.cmdMf1AcquireStaticNested(
          block: eSector * 4,
          keyType: eKeyType,
          key: eKey,
          targetBlock: sector * 4,
          targetKeyType: targetKeyType);
      final atks = res.atks
          .map((a) => {'nt1': _bytesInt(a.$1), 'nt2': _bytesInt(a.$2)})
          .toList();
      if (atks.isEmpty) return null;
      // 2代卡：nt2 不一致，使用 staticnested
      final nt2s = atks.map((a) => a['nt2']!).toSet();
      if (nt2s.length > 1) {
        final recovered = Crypto1.staticnested(
            uid: uidInt, keyType: targetKeyType.value, atks: atks);
        if (recovered.isNotEmpty) return _int6Hex(recovered.first);
      }
      return null;
    }
    if (prng == 1) {
      // WEAK 嵌套：重试5次（对齐小程序 WEAK 分支重试逻辑）
      for (var retry = 0; retry < 5; retry++) {
        final distRes = await _dev.cmdMf1TestNtDistance(
            block: eSector * 4, keyType: eKeyType, key: eKey);
        final dist = _bytesInt(distRes.dist.sublist(0, 4));
        final nested = await _dev.cmdMf1AcquireNested(
            block: eSector * 4,
            keyType: eKeyType,
            key: eKey,
            targetBlock: sector * 4,
            targetKeyType: targetKeyType);
        final atks = nested
            .map((a) => {
                  'nt1': _bytesInt(a.nt1),
                  'nt2': _bytesInt(a.nt2),
                  'par': a.par,
                })
            .toList();
        final recovered = Crypto1.nested(uid: uidInt, dist: dist, atks: atks);
        if (recovered.isNotEmpty) return _int6Hex(recovered.first);
      }
    }
    return null;
  }

  /// 卡号 XOR 校验（对齐小程序 btnWrite：卡第5字节 BCC = 前4字节异或）
  bool _nuidXorValid() {
    final b0 = _app.card.sectors[0].blocks[0].data;
    if (b0.length < 10) return false;
    final nums = [0, 2, 4, 6, 8]
        .map((i) => int.parse(b0.substring(i, i + 2), radix: 16))
        .toList();
    return (nums[0] ^ nums[1] ^ nums[2] ^ nums[3]) == nums[4];
  }

  /// 将破解/抽取出的密钥去重回填到密钥输入区
  void _appendKeys(List<String> add) {
    if (add.isEmpty) return;
    final lines = _keys.toList();
    final toAdd = <String>[];
    for (final k in add) {
      if (k.length == 12 && !lines.contains(k)) toAdd.add(k);
    }
    if (toAdd.isEmpty || !mounted) return;
    setState(() {
      _keyCtrl.text = lines.isEmpty
          ? toAdd.join('\n')
          : '${lines.join('\n')}\n${toAdd.join('\n')}';
      _app.card.keys = _keyCtrl.text;
      _validateKeys(_keyCtrl.text);
    });
  }

  Future<void> _submitHardnested(Uint8List uid) async {
    final uidHex = _hexStr(uid.sublist(0, 4));
    final userId = '01';
    final task = CrackTask(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
      cardId: uidHex,
      sector: 0,
      keyType: KeyType.keyA,
    );
    await _app.storage.addCrackTask(task);
    try {
      await _app.cloud.addJob(userId: userId, openid: uidHex, cardId: uidHex, sector: 0, keyType: KeyType.keyA);
    } catch (e) {
      _toast('云端任务提交失败（已保存本地）: $e');
    }
  }

  // ========== 算密钥（mfkey32v2） ==========
  Future<void> _mfkey() async {
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final uidInt = _bytesInt(tags.first.uid.sublist(0, 4));
      // 采集两组认证数据（用已知密钥读块触发 auth 交互）
      final firstKey = _hex(_keys.isEmpty ? 'ffffffffffff' : _keys.first);
      Future<Uint8List> collectAuth(int block) async {
        final data = await _dev.cmdMf1ReadBlock(
            block: block, keyType: KeyType.keyA, key: firstKey);
        return data;
      }

      await collectAuth(0);
      final detections = await _dev.cmdMf1GetDetectionLogs(0);
      if (detections.length < 2) {
        _toast('认证数据不足，请重试');
        return;
      }
      // 对齐小程序：对全部检测日志每对(相邻两条)逐一计算，密钥插入密钥区头部
      var foundCount = 0;
      for (var i = 0; i + 1 < detections.length; i += 2) {
        final a = detections[i];
        final b = detections[i + 1];
        final keys = Crypto1.mfkey32v2(
          uid: uidInt,
          nt0: _bytesInt(a.nt),
          nr0: _bytesInt(a.nr),
          ar0: _bytesInt(a.ar),
          nt1: _bytesInt(b.nt),
          nr1: _bytesInt(b.nr),
          ar1: _bytesInt(b.ar),
        );
        if (keys.isEmpty) continue;
        final found = _int6Hex(keys.first);
        if (!mounted) return;
        setState(() {
          _keyCtrl.text = '$found\n${_keyCtrl.text}';
          _app.card.keys = _keyCtrl.text;
          _validateKeys(_keyCtrl.text);
        });
        foundCount++;
      }
      if (foundCount == 0) {
        _toast('未计算出密钥');
        return;
      }
      _toast('算得密钥：$foundCount 个');
    } catch (e) {
      _toast('算密钥失败: $e');
    }
  }

  // ========== 导入 / 导出 / 管理数据 ==========
  Future<void> _importCard() async {
    try {
      // 从文件选择导入（对齐小程序 btnImportFromMsg，支持 dump/mfd/bin 二进制与 txt/mct 文本）
      final pick = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['dump', 'mfd', 'bin', 'txt', 'mct'],
        withData: true,
      );
      if (pick == null || pick.files.isEmpty) return;
      final file = pick.files.first;
      final data = file.bytes;
      if (data == null) {
        _toast('无法读取文件');
        return;
      }
      final ext = file.name.split('.').last.toLowerCase();
      final List<String> lines;
      if (ext == 'txt' || ext == 'mct') {
        final text = utf8.decode(data, allowMalformed: true);
        lines = text.trim().split('\n').map((e) => e.trim()).toList();
      } else {
        // dump/mfd/bin：原始二进制 1024 字节 → 每块 16 字节转 MCT 行
        if (data.length != 1024) {
          _toast('dump 大小无效：${data.length} 字节');
          return;
        }
        lines = List.generate(64, (b) => _hexStr(data.sublist(b * 16, b * 16 + 16)));
      }
      if (lines.length < 64) {
        _toast('数据行数不足 64');
        return;
      }
      final state = CardState.fromDumpText(lines);
      setState(() {
        _app.card = state;
        _uidCtrl.text = state.uid;
        _atqaCtrl.text = state.atqa;
        _sakCtrl.text = state.sak;
      });
      _toast('导入完成');
    } catch (e) {
      _toast('导入失败: $e');
    }
  }

  Future<void> _exportCard() async {
    final dump = _app.card.toDumpText();
    // 对齐小程序：默认文件名预填 UID_日期.dump
    final uid = _app.card.uid.trim().toUpperCase();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => TextInputDialog(
        title: '保存 Dump',
        hint: '输入文件名',
        initial: uid.isEmpty ? '' : '${uid}_${_dateStamp()}.dump',
      ),
    );
    if (name == null || name.isEmpty) return;
    await _app.storage.saveCard(name, dump);
    _toast('已保存：$name');
  }

  /// 默认导出文件名日期戳（对齐小程序 getDate：yyyy-MM-dd）
  String _dateStamp() => DateTime.now().toIso8601String().split('T')[0];

  Future<void> _manageData() async {
    final names = await _app.storage.getCardNames();
    if (names.isEmpty) {
      _toast('暂无已保存的 Dump');
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(title: Text('已保存的 Dump', style: TextStyle(fontWeight: FontWeight.w600))),
            ...names.entries.map((e) => ListTile(
                  title: Text(e.key),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _loadDump(e.key);
                  },
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.upload, size: 18),
                        tooltip: '加载到扇区数据',
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _loadDump(e.key);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 18),
                        tooltip: '删除',
                        onPressed: () async {
                          await _app.storage.delCard(e.key);
                          if (ctx.mounted) Navigator.pop(ctx);
                          _toast('已删除 ${e.key}');
                        },
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  /// 从已保存的 Dump 加载到扇区数据（对齐小程序 load_dump）
  Future<void> _loadDump(String name) async {
    try {
      final text = await _app.storage.getCard(name);
      final lines = text.trim().split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      if (lines.length < 64) {
        _toast('数据行数不足 64');
        return;
      }
      final state = CardState.fromDumpText(lines);
      setState(() {
        _app.card = state;
        _uidCtrl.text = state.uid;
        _atqaCtrl.text = state.atqa;
        _sakCtrl.text = state.sak;
      });
      _toast('加载完成：$name');
    } catch (e) {
      _toast('加载失败: $e');
    }
  }

  // ========== 更多功能（格式化/改卡号/锁卡/双卡破解/云） ==========
  Future<void> _moreFeatures() async {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('更多功能',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            ListTile(
                leading: const Icon(Icons.cleaning_services),
                title: const Text('格式化'),
                subtitle: const Text('擦除全部扇区（UID 卡免密写）'),
                onTap: () {
                  Navigator.pop(ctx);
                  _runChip(_formatCard);
                }),
            ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('修改卡号'),
                subtitle: const Text('写入新的 UID/SAK/ATQA'),
                onTap: () {
                  Navigator.pop(ctx);
                  _changeUid();
                }),
            ListTile(
                leading: const Icon(Icons.lock),
                title: const Text('锁UFUID'),
                subtitle: const Text('锁定 UFUID 卡（不可逆）'),
                onTap: () {
                  Navigator.pop(ctx);
                  _runChip(_dev.lockUfuid);
                }),
            ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('重置UID'),
                subtitle: const Text('重置 UID 卡为出厂数据'),
                onTap: () {
                  Navigator.pop(ctx);
                  _runChip(_dev.wipeUid);
                }),
            ListTile(
                leading: const Icon(Icons.style),
                title: const Text('双卡破解'),
                subtitle: const Text('使用两张卡片破解扇区密钥'),
                onTap: () {
                  Navigator.pop(ctx);
                  _dualCrack();
                }),
            ListTile(
                leading: const Icon(Icons.cloud_upload),
                title: const Text('云端破解'),
                subtitle: const Text('国产兼容卡 hardnested 云端计算'),
                onTap: () {
                  Navigator.pop(ctx);
                  _cloudCrack();
                }),
            const Divider(height: 1),
            ListTile(
                leading: const Icon(Icons.analytics_outlined),
                title: const Text('电梯卡分析'),
                subtitle: const Text('云端分析电梯卡数据结构'),
                onTap: () {
                  Navigator.pop(ctx);
                  _liftAnalyze();
                }),
            ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('云破解任务'),
                subtitle: const Text('查看云端破解进度并导入密钥'),
                onTap: () {
                  Navigator.pop(ctx);
                  _cloudJobs();
                }),
            ListTile(
                leading: const Icon(Icons.share),
                title: const Text('在线分享'),
                subtitle: const Text('生成 Dump 分享链接'),
                onTap: () {
                  Navigator.pop(ctx);
                  _shareCard();
                }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 通用卡操作包装（连接检查 + 进度）
  Future<void> _runChip(Future<void> Function() task) async {
    try {
      if (!_app.connected) throw Exception('设备未连接');
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const CrackProgressDialog(
          title: '执行中...',
          onCancel: null,
        ),
      );
      try {
        await task();
      } finally {
        if (mounted) Navigator.of(context).pop();
      }
      _toast('操作完成');
    } catch (e) {
      _toast('操作失败: $e');
    }
  }

  // ========== 格式化 ==========
  Future<void> _formatCard() async {
    await _dev.assureDeviceMode(DeviceMode.reader);
    await _dev.formatCard();
  }

  // ========== 修改卡号 ==========
  Future<void> _changeUid() async {
    final uid = await showDialog<String>(
      context: context,
      builder: (ctx) => const TextInputDialog(title: '修改卡号', hint: '8 位十六进制 UID'),
    );
    if (uid == null || uid.trim().isEmpty) return;
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      await _dev.writeUid(
          uid: uid.trim(), sak: _sakCtrl.text.trim(), atqa: _atqaCtrl.text.trim());
      _toast('卡号写入完成');
      // 刷新当前卡号
      await _readCard();
    } catch (e) {
      _toast('写卡号失败: $e');
    }
  }

  // ========== 双卡破解 ==========
  Future<void> _dualCrack() async {
    if (_keys.isEmpty) {
      _toast('请先填写密钥');
      return;
    }
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final key = _hex(_keys.first);

      // 第一张卡：读取已知密钥扇区（默认扇区 0 用作 e_sector）
      _toast('请将已破解的卡片贴近读卡器...');
      await Future.delayed(const Duration(seconds: 1));
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final uid1 = _bytesInt(tags.first.uid.sublist(0, 4));

      // 第二张卡提示
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('双卡破解', style: TextStyle(fontSize: 16)),
          content: const Text('已读取卡1。请放上卡2（目标卡）后点击确定'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
          ],
        ),
      );
      if (ok != true) return;

      final results = <String>[];
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => CrackProgressDialog(
          title: '双卡破解中...',
          onCancel: () {},
        ),
      );
      try {
        // 用卡1的已知密钥对卡2扇区 0 做静态嵌套，校验两张卡
        final checkRes = await _dev.cmdMf1AcquireStaticNested(
            block: 0,
            keyType: KeyType.keyA,
            key: key,
            targetBlock: 0,
            targetKeyType: KeyType.keyA);
        if (checkRes.atks.length < 2 ||
            checkRes.atks[0].$2.join() != checkRes.atks[1].$2.join()) {
          throw Exception('破解失败，只有第一、三代无漏洞卡支持双卡破解！');
        }
        // 逐扇区用卡1已知密钥 + 卡2嵌套采集
        for (var sector = 0; sector < 16; sector++) {
          final atks = <Map<String, int>>[];
          for (var i = 0; i < 4; i++) {
            final res = await _dev.cmdMf1AcquireStaticNested(
                block: 0,
                keyType: KeyType.keyA,
                key: key,
                targetBlock: sector * 4,
                targetKeyType: KeyType.keyA);
            if (res.atks.isNotEmpty) {
              atks.add({
                'nt1': _bytesInt(res.atks.first.$1),
                'nt2': _bytesInt(res.atks.first.$2),
              });
            }
          }
          if (atks.isEmpty) continue;
          final recovered = Crypto1.staticnested(uid: uid1, keyType: 96, atks: atks);
          if (recovered.isNotEmpty) {
            results.add(_int6Hex(recovered.first));
          }
        }
      } finally {
        if (mounted) Navigator.of(context).pop();
      }
      if (results.isNotEmpty) {
        setState(() {
          _keyCtrl.text = '${_keyCtrl.text.trim()}\n${results.join('\n')}';
          _app.card.keys = _keyCtrl.text;
          _validateKeys(_keyCtrl.text);
        });
        _toast('双卡破解成功，已添加 ${results.length} 个密钥');
      } else {
        _toast('双卡破解未找到密钥');
      }
    } catch (e) {
      _toast('双卡破解失败: $e');
    }
  }

  // ========== 云端破解（国产兼容卡 hardnested） ==========
  Future<void> _cloudCrack() async {
    if (_keys.isEmpty) {
      _toast('请先填写密钥');
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('云端破解', style: TextStyle(fontSize: 16)),
        content: const Text('绝大部分普通卡使用解卡片功能可以秒解，极少部分识别为普通卡却无法破解的卡才需要云端破解，确定要继续吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final key = _hex(_keys.first);
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final uidHex = tags.first.uidHex.substring(0, 8);

      // 扇区 0 采集 256 个有效 hardnested 数据
      final userId = '01';
      final nonceBuf = StringBuffer();
      final seen = <int>{};
      var collected = 0;
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => CrackProgressDialog(
          title: '云端破解中：采集 256/0 数据...',
          onCancel: () {},
        ),
      );
      try {
        while (collected < 256) {
          final data = await _dev.cmdMf1AcquireHardNested(
              block: 0,
              keyType: KeyType.keyA,
              key: key,
              targetBlock: 0,
              targetKeyType: KeyType.keyA);
          for (final d in data) {
            final nt = _bytesInt(d.nt);
            if (seen.add(nt)) {
              nonceBuf.write('$nt|${d.par >> 4}\n');
              collected++;
            }
            final ntEnc = _bytesInt(d.ntEnc);
            if (seen.add(ntEnc)) {
              nonceBuf.write('$ntEnc|${d.par & 15}\n');
              collected++;
            }
            if (collected >= 256) break;
          }
        }
      } finally {
        if (mounted) Navigator.of(context).pop();
      }
      await _app.cloud.addJob(
          userId: userId,
          openid: uidHex,
          cardId: uidHex,
          sector: 0,
          keyType: KeyType.keyA,
          nonceData: nonceBuf.toString());
      _toast('已提交云端破解任务，可在 云破解任务 中查看进度');
    } catch (e) {
      _toast('云端破解失败: $e');
    }
  }

  // ========== 电梯卡分析 ==========
  Future<void> _liftAnalyze() async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const CrackProgressDialog(title: '云端分析中...', onCancel: null),
    );
    try {
      final dump = _app.card.toDumpText();
      final result = await _app.cloud.analyzeLift(dump);
      if (mounted) Navigator.of(context).pop();
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('电梯卡分析', style: TextStyle(fontSize: 16)),
          content: SingleChildScrollView(
            child: Text(result, style: const TextStyle(fontSize: 12)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('分析失败: $e');
    }
  }

  // ========== 云破解任务 ==========
  Future<void> _cloudJobs() async {
    final userId = '01';
    try {
      final jobs = await _app.cloud.queryJobs(userId);
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.white,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('云破解任务',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              const Divider(height: 1),
              if (jobs.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('暂无云端破解任务'),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: jobs.length,
                    itemBuilder: (_, i) {
                      final job = jobs[i];
                      final statusText = job.key.isEmpty
                          ? '拼命计算中...'
                          : job.key == 'error'
                              ? '计算出错，请重试破解'
                              : '计算完成，密钥已下载';
                      return ListTile(
                        leading: Icon(
                          job.key.isEmpty
                              ? Icons.play_circle_fill
                              : job.key == 'error'
                                  ? Icons.cancel
                                  : Icons.check_circle,
                          color: job.key.isEmpty
                              ? Colors.orange
                              : job.key == 'error'
                                  ? Colors.red
                                  : Colors.green,
                        ),
                        title: Text(
                            '${job.cardId}_${job.sector}_${job.keyType.label}'),
                        subtitle: Text(statusText),
                        trailing: job.key.isNotEmpty && job.key != 'error'
                            ? IconButton(
                                icon: const Icon(Icons.download, size: 18),
                                onPressed: () async {
                                  await _saveKeyFromCloud(job.key, job.cardId);
                                },
                              )
                            : IconButton(
                                icon: const Icon(Icons.delete_outline, size: 18),
                                onPressed: () async {
                                  await _app.cloud.deleteJob(job.id);
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  _cloudJobs();
                                },
                              ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    } catch (e) {
      _toast('查询任务失败: $e');
    }
  }

  Future<void> _saveKeyFromCloud(String key, String cardId) async {
    try {
      final name = 'KeyFor_${cardId.toUpperCase()}.txt';
      final all = await _app.storage.getKeyNames();
      final existing = all[name] ?? '';
      final lines = existing.trim().split('\n').where((e) => e.isNotEmpty).toList();
      if (!lines.contains(key)) {
        lines.add(key);
      }
      await _app.storage.saveKey(name, lines.join('\n'));
      setState(() {
        _keyCtrl.text = lines.join('\n');
        _validateKeys(_keyCtrl.text);
      });
      _toast('密钥已导入：$name');
    } catch (e) {
      _toast('导入失败: $e');
    }
  }

  // ========== 在线分享 ==========
  Future<void> _shareCard() async {
    try {
      final dump = _app.card.toDumpText();
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const CrackProgressDialog(title: '生成分享链接中...', onCancel: null),
      );
      final link = await _app.cloud.saveSharedData(dump);
      if (mounted) Navigator.of(context).pop();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('分享链接', style: TextStyle(fontSize: 16)),
          content: SelectableText(link, style: const TextStyle(fontSize: 13)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('分享失败: $e');
    }
  }

  // ========== UI ==========
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: _app,
      builder: (context, _) {
        return _buildSlotPage(_slotPage, primary);
      },
    );
  }

  /// 单槽页内容（密钥 + 卡片信息 + 槽配置 + 扇区数据 + 右侧按钮）
  Widget _buildSlotPage(int slot, Color primary) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左侧内容
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              // 密钥（对齐小程序：IC密钥前缀 + 无边框textarea + 右侧图标列）
              SectionCard(
                title: '密钥',
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 6, left: 4),
                          child: Text('IC密钥：',
                              style: TextStyle(
                                  fontSize: 13, color: Color(0xFF000000))),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _keyCtrl,
                            maxLines: 6,
                            minLines: 4,
                            textAlign: TextAlign.center,
                             style: TextStyle(
                                 fontFamily: 'monospace',
                                 fontSize: 13,
                                 color: _keysValid
                                     ? const Color(0xFF333333)
                                     : Colors.red),
                            decoration: const InputDecoration(
                              hintText: '一行一个密钥,密钥应为12位16进制数',
                              hintStyle:
                                  TextStyle(color: Color(0xFF999999), fontSize: 12),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                             onChanged: (t) {
                               _app.card.keys = t;
                               setState(() => _validateKeys(t));
                             },
                            ),
                          ),
                        Column(
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.list, size: 18),
                              tooltip: '密钥列表',
                              onPressed: _openKeyList,
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.download, size: 18),
                              tooltip: '导出',
                              onPressed: _exportKeys,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 卡片信息（对齐小程序：动态 M1 前缀 + 无边框输入框 + 实时校验变色 + 条件 ATS）
              SectionCard(
                margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
                padding: const EdgeInsets.fromLTRB(12, 5, 12, 6),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _infoField(
                          Text(_isStandardM1 ? '标准M1卡:' : '非标准M1卡:',
                               style: TextStyle(
                                   fontSize: 8,
                                   color: _isStandardM1
                                       ? Colors.green
                                       : const Color(0xFFE53935))),
                          _uidCtrl, '卡号应为8位16进制数',
                           validRegex: r'^([0-9A-Fa-f]{8}\s*)+$',
                           okColor: '#9933FF',
                           fieldWidth: 70),
                       const SizedBox(width: 4),
                       _infoField(
 const Text('SAK:',
                                style: TextStyle(
                                    fontSize: 8, color: Color(0xFF666666))),
                           _sakCtrl, '08',
                           validRegex: r'^([0-9A-Fa-f]{2}\s*)+$',
                           fieldWidth: 20),
                       const SizedBox(width: 4),
                       _infoField(
 const Text('ATQA:',
                                style: TextStyle(
                                    fontSize: 8, color: Color(0xFF666666))),
                           _atqaCtrl, '0004',
                           validRegex: r'^([0-9A-Fa-f]{4}\s*)+$',
                           fieldWidth: 40),
                      const SizedBox(width: 4),
                      if (_atsCtrl.text.isNotEmpty)
                        _infoField(
const Text('ATS:',
                                 style: TextStyle(
                                     fontSize: 8, color: Color(0xFF666666))),
                            _atsCtrl, '',
                            fieldWidth: 120),
                    ],
                  ),
                ),
              ),
              // 扇区数据表
              SectionCard(
                title: '扇区数据',
                child: _SectorTable(
                  card: _app.card,
                  onDataChanged: _app.refreshUi,
                ),
              ),
            ],
          ),
        ),
        // 右侧按钮列（按钮等宽并向右对齐）
        Container(
          width: 96,
          margin: const EdgeInsets.fromLTRB(0, 8, 6, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _sideBtn('读卡片', Icons.radio_button_checked, _readCard, primary),
              _sideBtn('写卡片', Icons.save_alt, _writeCard, primary),
              _sideBtn('解卡片', Icons.lock_open, _crackCard, primary),
              _sideBtn('读卡槽', Icons.memory, _readSlot, primary),
              _sideBtn('写卡槽', Icons.memory, _writeSlot, primary),
              _sideBtn('算密钥', Icons.calculate, _mfkey, primary),
              _sideBtn('导入', Icons.download, _importCard, primary),
              _sideBtn('导出', Icons.upload, _exportCard, primary),
              _sideBtn('管理数据', Icons.folder, _manageData, primary),
              _sideBtn('更多功能', Icons.more_horiz, _moreFeatures, primary),
              const SizedBox(height: 8),
              ConnectionBanner(
                connected: _app.connected,
                deviceName: _app.ble.device?.platformName,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }

  // ========== 卡槽选择（弹框） ==========
  /// 弹出卡槽选择对话框，返回所选卡槽索引（取消返回 null），选择后切到该卡槽
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
      // 先切到该卡槽并从设备加载该槽的真实模拟设置与卡片标识
      await _app.selectSlot(slot);
      if (mounted) setState(() => _slotPage = slot);
    }
    return slot;
  }

  Future<void> _readSlot() async {
    final slot = await _pickSlot();
    if (slot == null) return;
    try {
      await _dev.assureDeviceMode(DeviceMode.tag);
      if (_app.currentSlot != slot) await _dev.cmdSlotSetActive(slot);
      // 对齐小程序 btnEmuRead：读反碰撞数据，空则说明卡槽无 IC 卡信息
      final antiColl = await _dev.cmdHf14aGetAntiCollData();
      if (antiColl == null) {
        _toast('卡槽 ${slot + 1} 无 IC 卡信息');
        return;
      }
      final sectors = List.generate(16, (_) => SectorData());
      final found = <String>[];
      for (var sector = 0; sector < 16; sector++) {
        if (!_app.card.toggle[sector]) continue;
        try {
          final block = await _dev.cmdMf1EmuReadBlock(sector * 4, 4);
          if (block.length >= 64) {
            final blocks = List<BlockData>.generate(4, (i) => BlockData(
                data: _hexStr(
                    block.sublist(i * 16, (i + 1) * 16))));
            sectors[sector] = SectorData(blocks: blocks);
            // 从 trailer(块3) 提取密钥回填（对齐小程序 btnEmuRead 的 btnKeysGrab）
            final kA = _hexStr(block.sublist(48, 54));
            final kB = _hexStr(block.sublist(58, 64));
            if (kA != 'ffffffffffff' && kA != '000000000000') found.add(kA);
            if (kB != 'ffffffffffff' && kB != '000000000000') found.add(kB);
          }
        } catch (_) {}
      }
      setState(() {
        _uidCtrl.text = antiColl.uidHex;
        _atqaCtrl.text = antiColl.atqaHex;
        _sakCtrl.text = antiColl.sakHex;
        _app.card.uid = antiColl.uidHex;
        _app.card.atqa = antiColl.atqaHex;
        _app.card.sak = antiColl.sakHex;
        _app.card.sectors = sectors;
        _app.slotCardIds[slot] = (
          uid: antiColl.uidHex,
          sak: antiColl.sakHex,
          atqa: antiColl.atqaHex,
        );
        _app.currentSlot = slot;
      });
      _appendKeys(found);
      _toast('已读取卡槽 ${slot + 1} 数据');
    } catch (e) {
      _toast('读卡槽失败: $e');
    }
  }

  bool get _isStandardM1 => _sakCtrl.text.trim() == '08';

  /// 对齐小程序卡片信息：前缀标签 + 无边框输入框 + 实时格式校验变色
  Widget _infoField(Widget prefix, TextEditingController ctrl, String hint,
      {String? validRegex, String? okColor, double fieldWidth = 60}) {
    final ok = validRegex == null || RegExp(validRegex).hasMatch(ctrl.text);
    final fail = const Color(0xFFE53935);
    final Color? textColor = !ok
        ? fail
        : (okColor != null
            ? Color(int.parse(okColor.replaceFirst('#', '0xFF')))
            : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          prefix,
          const SizedBox(width: 4),
          SizedBox(
            width: fieldWidth,
            child: TextField(
              controller: ctrl,
              onChanged: (_) => setState(() {}),
              style: TextStyle(
                   fontSize: 8, color: textColor ?? const Color(0xFF333333)),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(color: Color(0xFF999999), fontSize: 8),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                border: InputBorder.none,
                isCollapsed: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sideBtn(String label, IconData icon, VoidCallback? onTap, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        width: 96,
        child: ActionButton(
            label: label,
            icon: icon,
            color: color,
            onTap: onTap,
            enabled: _app.connected || label == '导入' || label == '管理数据'),
      ),
    );
  }

  // ========== 密钥文件管理（对齐小程序：密钥列表弹窗 + 导出） ==========
  Future<void> _openKeyList() async {
    if (!mounted) return;
    final sel = await showModalBottomSheet<(String, String)>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      builder: (ctx) => KeyFileSheet(
          storage: _app.storage, cardUid: _app.card.uid),
    );
    if (sel == null || !mounted) return;
    setState(() {
      _keyCtrl.text = sel.$2.isEmpty ? kDefaultKeys.join('\n') : sel.$2;
      _app.card.keys = _keyCtrl.text;
      _validateKeys(_keyCtrl.text);
    });
  }

  Future<void> _exportKeys() async {
    try {
      final uri = await FilePicker.platform.saveFile(
        fileName: 'KeyFor_${_app.card.uid.toUpperCase()}.TXT',
        bytes: Uint8List.fromList(utf8.encode(_keyCtrl.text)),
      );
      if (mounted && uri != null) _toast('已导出：$uri');
    } catch (e) {
      if (mounted) _toast('导出失败: $e');
    }
  }
}

// ========== 扇区数据表（可编辑，对齐小程序） ==========
class _SectorTable extends StatefulWidget {
  final CardState card;
  final VoidCallback onDataChanged;
  const _SectorTable({required this.card, required this.onDataChanged});

  @override
  State<_SectorTable> createState() => _SectorTableState();
}

class _SectorTableState extends State<_SectorTable> {
  String _blockHex(int s, int b) {
    final d = widget.card.sectors[s].blocks[b].data;
    return d.length >= 32 ? d : '00000000000000000000000000000000';
  }

  void _toggleSector(int s) {
    setState(() => widget.card.toggle[s] = !widget.card.toggle[s]);
    widget.onDataChanged();
  }

  Future<void> _editSector(int s) async {
    final ctrls =
        List.generate(4, (b) => TextEditingController(text: _blockHex(s, b)));
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('扇区 $s', style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var b = 0; b < 4; b++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Text('块$b', style: const TextStyle(fontSize: 12, color: Color(0xFF666666))),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: ctrls[b],
                        style: TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            color: b == 3 ? const Color(0xFF1E88E5) : const Color(0xFF333333)),
                        maxLines: 1,
                        decoration: InputDecoration(
                          isDense: true,
                          border: const OutlineInputBorder(),
                          hintText: '16字节hex',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    var changed = false;
    if (saved == true) {
      for (var b = 0; b < 4; b++) {
        final clean = ctrls[b].text.replaceAll(RegExp(r'[\s-]'), '').toLowerCase();
        if (RegExp(r'^[0-9a-f]{32}$').hasMatch(clean)) {
          if (widget.card.sectors[s].blocks[b].data != clean) {
            widget.card.sectors[s].blocks[b].data = clean;
            changed = true;
          }
        }
      }
    }
    for (final c in ctrls) {
      c.dispose();
    }
    if (changed) widget.onDataChanged();
  }

  Widget _buildBlockText(int s, int b, String hex) {
    // 块3：密钥A(12字符,绿色) + 访问位(8字符,橙色) + 密钥B(12字符,绿色)
    if (b == 3) {
      return Text.rich(
        TextSpan(
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          children: [
            TextSpan(text: hex.substring(0, 12), style: const TextStyle(color: Color(0xFF4CAF50))),
            TextSpan(text: hex.substring(12, 20), style: const TextStyle(color: Color(0xFFFF9800))),
            TextSpan(text: hex.substring(20), style: const TextStyle(color: Color(0xFF4CAF50))),
          ],
        ),
        maxLines: 1,
      );
    }
    // 扇区0块0：卡号(前4字节,紫色) + 中间4字节(默认) + 厂商码(后8字节,黄色)
    if (s == 0 && b == 0) {
      return Text.rich(
        TextSpan(
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          children: [
            TextSpan(text: hex.substring(0, 8), style: const TextStyle(color: Color(0xFF9C27B0))),
            TextSpan(text: hex.substring(8, 16), style: const TextStyle(color: Color(0xFF333333))),
            TextSpan(text: hex.substring(16), style: const TextStyle(color: Color(0xFFFFEB3B))),
          ],
        ),
        maxLines: 1,
      );
    }
    return Text(hex, maxLines: 1, style: const TextStyle(fontSize: 12, fontFamily: 'monospace'));
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var s = 0; s < 16; s++)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFEDEDED)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 扇区行（toggle + 扇区号）
                InkWell(
                  onTap: () => _toggleSector(s),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      children: [
                        Icon(
                          widget.card.toggle[s]
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 16,
                          color: widget.card.toggle[s]
                              ? primary
                              : const Color(0xFFBBBBBB),
                        ),
                        const SizedBox(width: 6),
                        Text('扇区 $s',
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
                for (var b = 0; b < 4; b++)
                  InkWell(
                    onTap: () => _editSector(s),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 30,
                            child: Text('块$b',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.grey[500])),
                          ),
                          Expanded(
                            child: SizedBox(
                              height: 17,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: _buildBlockText(s, b, _blockHex(s, b)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ========== 辅助 ==========
Uint8List _hex(String hex) {
  final clean = hex.replaceAll(RegExp(r'[\s-]'), '');
  final bytes = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

String _hexStr(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

int _bytesInt(Uint8List b) {
  final padded = Uint8List(4);
  padded.setRange(4 - b.length, 4, b.sublist(0, b.length > 4 ? 4 : b.length));
  return ByteData.sublistView(padded).getUint32(0);
}

String _int6Hex(int v) =>
    v.toRadixString(16).padLeft(12, '0').substring(0, 12);

class _SectorKey {
  final int sector;
  bool hasKeyA;
  bool hasKeyB;
  String keyA;
  String keyB;
  _SectorKey(this.sector)
      : hasKeyA = false,
        hasKeyB = false,
        keyA = '',
        keyB = '';
}
