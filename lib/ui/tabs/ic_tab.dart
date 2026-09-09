import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart';
import '../../models/enums.dart';
import '../../models/models.dart';
import '../../services/crypto1.dart';
import '../../services/device_service.dart';
import '../../services/log_service.dart';
import '../../services/native_recovery.dart';
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
    _atsCtrl.text = _app.card.ats;
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

  void _syncCardInfo() {
    _uidCtrl.text = _app.card.uid;
    _atqaCtrl.text = _app.card.atqa;
    _sakCtrl.text = _app.card.sak;
    _atsCtrl.text = _app.card.ats;
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
      List<Uint8List> keys, List<SectorKeyState> sectorKeys) async {
    final mask = Uint8List(10);
    mask.fillRange(0, 10, 0xFF);
    for (var s = 0; s < 16; s++) {
      if (!sectorKeys[s].hasKeyA) mask[s >> 2] ^= 2 << (6 - s % 4 * 2);
      if (!sectorKeys[s].hasKeyB) mask[s >> 2] ^= 1 << (6 - s % 4 * 2);
    }
    LogService.instance.log('[_checkCrackedKeys] keys=${keys.length}, mask=${_hexStr(mask)}');
    final res = await _dev.cmdMf1CheckKeysOfSectors(keys: keys, mask: mask);
    LogService.instance.log('[_checkCrackedKeys] found=${_hexStr(res.found)}, sectorKeys=${res.sectorKeys.map((k) => k == null ? 'null' : _hexStr(k)).join(',')}');
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
    LogService.instance.log('[_checkCrackedKeys] anyMissing=$anyMissing');
    return anyMissing;
  }

  /// 将扇区密钥状态中的密钥追加到密钥区（对齐小程序 ss.keys 合并去重）
  void _appendKeysFromSectors(List<SectorKeyState> sectorKeys) {
    final all = <String>[];
    for (final sk in sectorKeys) {
      if (sk.keyA.isNotEmpty && !all.contains(sk.keyA)) all.add(sk.keyA);
      if (sk.keyB.isNotEmpty && !all.contains(sk.keyB)) all.add(sk.keyB);
    }
    _appendKeys(all);
  }

  /// 新破出密钥后立即用已知密钥复查全扇区：
  /// M1 卡常多扇区共用密钥，能认证通过的槽位直接标记，跳过后续破解
  Future<void> _propagateKeys(List<SectorKeyState> sectorKeys) async {
    final names = <String>[];
    for (final sk in sectorKeys) {
      if (sk.hasKeyA && sk.keyA.isNotEmpty && !names.contains(sk.keyA)) {
        names.add(sk.keyA);
      }
      if (sk.hasKeyB && sk.keyB.isNotEmpty && !names.contains(sk.keyB)) {
        names.add(sk.keyB);
      }
    }
    for (final k in _keys) {
      if (!names.contains(k)) names.add(k);
    }
    if (names.isEmpty) return;
    LogService.instance.log('[_propagateKeys] checking ${names.length} known keys against all sectors');
    await _checkCrackedKeys(names.map(_hex).toList(), sectorKeys);
  }

  // ========== 读卡（对齐小程序 btnRead + btnGen2Read 完整流程） ==========
  Future<void> _readCard() async {
    final progress = ValueNotifier<String>('验证密钥：寻卡中...');
    final step = ValueNotifier<int>(0);
    final sectorKeys = List.generate(16, (s) => SectorKeyState(s));
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

      // 验证密钥：尝试 Gen1a 免密读卡（对齐小程序 _mf1Gen1aAuth）
      try {
        step.value = 1;
        progress.value = '验证密钥：发现UID卡，可免密读卡...';
        final gen1aSectors = List.generate(16, (_) => SectorData());
        for (var s = 0; s < 16; s++) {
          if (!_app.card.toggle[s]) continue;
          progress.value = '读卡片：正在读扇区$s...';
          final data = await _dev.mf1Gen1aReadBlocks(4 * s, 4);
          if (data.length < 64) continue;
          // 标记 haskeyA/haskeyB 为 true（对齐小程序）
          sectorKeys[s].hasKeyA = true;
          sectorKeys[s].hasKeyB = true;
          final blocks = List<BlockData>.generate(
              4, (i) => BlockData(data: _hexStr(data.sublist(i * 16, i * 16 + 16))));
          gen1aSectors[s] = SectorData(blocks: blocks);
          // 从块3提取密钥（对齐小程序：bytes 48-54, 58-64）
          final kA = _hexStr(data.sublist(48, 54));
          final kB = _hexStr(data.sublist(58, 64));
          sectorKeys[s].keyA = kA;
          sectorKeys[s].keyB = kB;
          if (kA != 'ffffffffffff' && kA != '000000000000') found.add(kA);
          if (kB != 'ffffffffffff' && kB != '000000000000') found.add(kB);
        }
        gen1aDone = true;
        setState(() {
          _app.card.uid = uid;
          _app.card.atqa = _hexStrRev(tag.atqa);
          _app.card.sak = tag.sakHex;
          _app.card.ats = tag.atsHex;
          _app.card.sectors = gen1aSectors;
        });
        _syncCardInfo();
        _appendKeys(found);
      } catch (_) {
        // Gen1a 不可用，走常规认证读
      }
      if (gen1aDone) {
        progress.value = '读卡片：读卡完成';
        if (mounted) Navigator.of(context).pop();
        _toast('读卡完成！');
        return;
      }

      // Gen1a 失败：autoloadKeys + checkCrackedKey + btnGen2Read（对齐小程序）
      progress.value = '验证密钥：验证中...';
      await _loadKeys();

      // 批量检测扇区密钥（对齐小程序 checkCrackedKey）
      final allKeys = _keys.map(_hex).toList();
      final anyMissing = await _checkCrackedKeys(allKeys, sectorKeys);
      if (anyMissing) {
        _appendKeysFromSectors(sectorKeys);
        progress.value = '读卡片：卡片有加密，请先使用解卡片功能获取密钥';
        if (mounted) Navigator.of(context).pop();
        _toast('卡片有加密，请先使用解卡片功能获取密钥');
        return;
      }

      // btnGen2Read：逐扇区逐块用已确定密钥读取
      step.value = 1;
      final failedBlocks = <int>[];
      for (var s = 0; s < 16; s++) {
        if (!_app.card.toggle[s]) continue;
        progress.value = '读卡片：正在读取扇区：$s...';
        final baseBlock = s * 4;
        final sectorData = Uint8List(64);
        for (var b = 0; b < 4; b++) {
          final blockNum = baseBlock + b;
          var read = false;
          // 先试 keyA（对齐小程序）
          if (sectorKeys[s].hasKeyA && sectorKeys[s].keyA.isNotEmpty) {
            try {
              final data = await _dev.cmdMf1ReadBlock(
                  block: blockNum,
                  keyType: KeyType.keyA,
                  key: _hex(sectorKeys[s].keyA));
              sectorData.setRange(b * 16, b * 16 + 16, data);
              read = true;
            } catch (_) {}
          }
          // keyA 失败试 keyB（对齐小程序）
          if (!read && sectorKeys[s].hasKeyB && sectorKeys[s].keyB.isNotEmpty) {
            try {
              final data = await _dev.cmdMf1ReadBlock(
                  block: blockNum,
                  keyType: KeyType.keyB,
                  key: _hex(sectorKeys[s].keyB));
              sectorData.setRange(b * 16, b * 16 + 16, data);
              read = true;
            } catch (_) {}
          }
          if (!read) failedBlocks.add(blockNum);
        }
        // 将 keyA/keyB 写入块3（对齐小程序：bytes 48-54, 58-64）
        if (sectorKeys[s].hasKeyA) {
          sectorData.setRange(48, 54, _hex(sectorKeys[s].keyA));
        }
        if (sectorKeys[s].hasKeyB) {
          sectorData.setRange(58, 64, _hex(sectorKeys[s].keyB));
        }
        // 设置扇区数据
        final blocks = List<BlockData>.generate(
            4, (i) => BlockData(data: _hexStr(sectorData.sublist(i * 16, i * 16 + 16))));
        _app.card.sectors[s] = SectorData(blocks: blocks);
        // 提取块3密钥到密钥区
        final kA = _hexStr(sectorData.sublist(48, 54));
        final kB = _hexStr(sectorData.sublist(58, 64));
        if (kA != 'ffffffffffff' && kA != '000000000000') found.add(kA);
        if (kB != 'ffffffffffff' && kB != '000000000000') found.add(kB);
      }
      _app.card.uid = uid;
      _app.card.atqa = _hexStrRev(tag.atqa);
      _app.card.sak = tag.sakHex;
      _app.card.ats = tag.atsHex;
      _appendKeys(found);
      _syncCardInfo();
      setState(() {});
      if (failedBlocks.isEmpty) {
        progress.value = '读卡片：读卡完成';
        if (mounted) Navigator.of(context).pop();
        _toast('读卡完成！');
      } else {
        progress.value = ' 读卡片：块${failedBlocks.join('，')} 读取失败';
        if (mounted) Navigator.of(context).pop();
        _toast('读卡片：块${failedBlocks.join('，')} 读取失败');
      }
    } catch (e) {
      progress.value = '读卡片：失败，$e';
      if (mounted) Navigator.of(context).pop();
      _toast('读卡失败: $e');
    } finally {
      // 对齐小程序 btnRead finally：恢复标签模式 + 提取密钥
      try {
        await _dev.cmdChangeDeviceMode(DeviceMode.tag);
      } catch (_) {}
      _grabKeys();
    }
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
    final sectorKeys = List.generate(16, (s) => SectorKeyState(s));
    final crackTick = ValueNotifier<int>(0);
    final hardnestedNotifier = ValueNotifier<bool>(false);
    NativeRecovery.init();
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final tag = tags.first;
      if (tag.sakHex != '08') {
        _toast('发现非标准M1卡，该卡无法破解');
        return;
      }
      final uid = tag.uid;
      final uidInt = _bytesInt(uid.sublist(0, 4));

      setState(() {
        _app.card.uid = tag.uidHex;
        _app.card.atqa = _hexStrRev(tag.atqa);
        _app.card.sak = tag.sakHex;
        _app.card.ats = tag.atsHex;
      });
      _syncCardInfo();

      if (_keys.isEmpty) {
        _toast('请先填写密钥');
        return;
      }

      if (!mounted) return;
      // 对齐小程序 stop_flag + checkstop：关闭按钮请求停止，检查点终止流程
      var crackStopRequested = false;
      void checkStop() {
        if (crackStopRequested) throw const CrackStoppedException();
      }
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => CrackProgressDialog(
          title: '正在破解卡片...',
          steps: const ['验证密钥', '解卡片'],
          step: step,
          progress: progress,
          sectors: sectorKeys,
          refresh: crackTick,
          onCancel: () {
            crackStopRequested = true;
            progress.value = '停止中，等待当前步骤完成...';
          },
          cancelText: '关闭',
          hardnested: hardnestedNotifier,
        ),
      );

      // 验证密钥：尝试 Gen1a 免密读卡
      try {
        progress.value = '验证密钥：发现UID卡，可免密读卡...';
        LogService.instance.log(
            '[解卡] Gen1a免密读卡可用(UID魔改卡, 无漏洞限制, 直接读全部密钥)');
        final found = <String>[];
        var allRead = true;
        for (var s = 0; s < 16; s++) {
          checkStop();
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
      final allKeys = _keys.map(_hex).toList();
      final anyMissing = await _checkCrackedKeys(allKeys, sectorKeys);
      crackTick.value++;
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

      // 加密嵌套检测：判断是否为第三代无漏洞卡（对齐小程序）
      progress.value = '破解密钥：检测第三代无漏洞卡...';
      Mf1AcquireStaticEncryptedNestedDecoder? encNested;
      final specialKeys = ['A396EFA4E24F', 'A31667A8CEC1', '518B3354E760'];
      for (final sk in specialKeys) {
        try {
          final n1 = await _dev.cmdMf1AcquireStaticEncryptedNested(
              key: _hex(sk));
          final n2 = await _dev.cmdMf1AcquireStaticEncryptedNested(
              key: _hex(sk));
          if (n1.atks.isNotEmpty && n2.atks.isNotEmpty &&
              n1.atks.first.$4 == n2.atks.first.$4) {
            encNested = n1;
          }
          break;
        } catch (_) {}
      }
      if (encNested != null && encNested.atks.isNotEmpty) {
        // 第三代无漏洞卡破解（对齐小程序 Crack_3gen：候选集 + 两两配对交集 + 种子恢复）
        progress.value = '破解密钥：发现第三代无漏洞卡，正在破解...';
        final uidInt = _bytesInt(encNested.uid.sublist(0, 4));
        LogService.instance.log('[_crackCard] 3gen uid=$uidInt atks=${encNested.atks.length}');

        // 预处理：每扇区 A/B 样本 → nt1/nt2/明文域 par（对齐小程序 resA/resB）
        final resA = List<Map<String, int>?>.filled(16, null);
        final resB = List<Map<String, int>?>.filled(16, null);
        final resAKeys = List<List<int>?>.filled(16, null);
        final resBKeys = List<List<int>?>.filled(16, null);
        int fixPar(int par, int ntEnc) =>
            (((par >> 3) & 1) ^ Crypto1.oddParity8((ntEnc >> 24) & 255)) << 3 |
            (((par >> 2) & 1) ^ Crypto1.oddParity8((ntEnc >> 16) & 255)) << 2 |
            (((par >> 1) & 1) ^ Crypto1.oddParity8((ntEnc >> 8) & 255)) << 1 |
            ((par & 1) ^ Crypto1.oddParity8(ntEnc & 255)) << 0;
        for (final a in encNested.atks) {
          final res = <String, int>{
            'nt1': Crypto1.prngSuccessor(a.$3, 16),
            'nt2': a.$4,
            'par': fixPar(a.$5, a.$4),
          };
          LogService.instance.log(
              '[_crackCard] 3gen atk sector=${a.$1} type=${a.$2} res=${a.$2 == KeyType.keyA ? 'A' : 'B'} nt1=${res['nt1']} nt2=${res['nt2']} par=${res['par']}');
          if (a.$2 == KeyType.keyA) {
            resA[a.$1] = res;
          } else {
            resB[a.$1] = res;
          }
        }

        int hex6Int(String hex) => int.parse(hex, radix: 16);
        Uint8List int6Bytes(int k) {
          final b = Uint8List(6);
          for (var i = 5; i >= 0; i--) {
            b[i] = k & 0xFF;
            k >>= 8;
          }
          return b;
        }

        // 候选批量验证（对齐小程序 checkCrackedKey）
        Future<void> verifyKeys(List<int> cands) async {
          if (cands.isEmpty) return;
          final keys = cands.map(int6Bytes).toList();
          LogService.instance.log('[_crackCard] 3gen verify candidates=${keys.length}');
          await _checkCrackedKeys(keys, sectorKeys);
          crackTick.value++;
          _appendKeysFromSectors(sectorKeys);
        }

        // 种子恢复（对齐小程序 CrackAll_bySeedNt）：A 已知推 B，B 已知推 A
        Future<void> crackAllBySeedNt() async {
          for (var s = 0; s < 16; s++) {
            checkStop();
            final ra = resA[s];
            final rb = resB[s];
            if (ra == null || rb == null) continue;
            if (sectorKeys[s].hasKeyA && !sectorKeys[s].hasKeyB) {
              progress.value = '破解密钥：正在计算扇区 $s 的共同密钥...';
              final tag =
                  Crypto1.gen3NonceTag(ra['nt1']!, hex6Int(sectorKeys[s].keyA));
              final cands = Crypto1.gen3RecoverBySeed(
                  uid: uidInt,
                  nt1: rb['nt1']!, nt2: rb['nt2']!, par: rb['par']!,
                  seedTag: tag);
              LogService.instance.log('[_crackCard] 3gen seed sector=$s B cands=${cands.length}');
              await verifyKeys(cands);
            } else if (!sectorKeys[s].hasKeyA && sectorKeys[s].hasKeyB) {
              progress.value = '破解密钥：正在计算扇区 $s 的共同密钥...';
              final tag =
                  Crypto1.gen3NonceTag(rb['nt1']!, hex6Int(sectorKeys[s].keyB));
              final cands = Crypto1.gen3RecoverBySeed(
                  uid: uidInt,
                  nt1: ra['nt1']!, nt2: ra['nt2']!, par: ra['par']!,
                  seedTag: tag);
              LogService.instance.log('[_crackCard] 3gen seed sector=$s A cands=${cands.length}');
              await verifyKeys(cands);
            }
          }
        }

        // 两两配对交集（对齐小程序 Crack_3gen 主循环，候选集惰性生成）
        // 注：C 库无 2x1nt（gen3）实现，保持 Dart 候选生成
        List<int> gen3Candidates(Map<String, int> res) {
          return Crypto1.gen3GenerateKeys(
              uidInt, res['nt1']!, res['nt2']!, res['par']!);
        }

        Future<void> matchPair(
            int s, int r, bool useAs, bool useAr, String label) async {
          final rs = useAs ? resA[s] : resB[s];
          final rr = useAr ? resA[r] : resB[r];
          if (rs == null || rr == null) return;
          progress.value = '破解密钥：正在计算扇区 $s、$r 的共同$label密钥...';
          final cacheS = useAs ? resAKeys : resBKeys;
          final cacheR = useAr ? resAKeys : resBKeys;
          final ka = cacheS[s] ??= gen3Candidates(rs);
          final kb = cacheR[r] ??= gen3Candidates(rr);
          LogService.instance.log(
              '[_crackCard] 3gen pair $s/$r ${useAs ? 'A' : 'B'}${useAr ? 'A' : 'B'} cands=${ka.length}/${kb.length}');
          final inter = ka.toSet().intersection(kb.toSet()).toList();
          if (inter.isEmpty) {
            LogService.instance.log(
                '[解卡] 3gen 扇区$s/$r $label: 候选交集为空(两扇区候选无共同密钥, 采样不足)');
          }
          if (inter.isNotEmpty) {
            await verifyKeys(inter);
            await crackAllBySeedNt();
          }
        }

        // 全卡已有半边密钥的扇区先做种子恢复
        await crackAllBySeedNt();
        for (var o = 0; o < 15; o++) {
          checkStop();
          if (!sectorKeys[o].hasKeyA) {
            for (var r = o + 1; r < 16; r++) {
              checkStop();
              if (!sectorKeys[r].hasKeyA) {
                await matchPair(o, r, true, true, 'keyA');
              }
              checkStop();
              if (!sectorKeys[r].hasKeyB) {
                final ra = resA[r];
                final rb = resB[r];
                if (ra != null && rb != null && ra['nt1'] == rb['nt1']) continue;
                await matchPair(o, r, true, false, 'keyB');
              }
            }
          }
          checkStop();
          if (!sectorKeys[o].hasKeyB) {
            final ra = resA[o];
            final rb = resB[o];
            if (ra != null && rb != null && ra['nt1'] == rb['nt1']) continue;
            for (var r = o + 1; r < 16; r++) {
              checkStop();
              if (!sectorKeys[r].hasKeyA) {
                await matchPair(o, r, false, true, 'keyA');
              }
              checkStop();
              if (!sectorKeys[r].hasKeyB) {
                final ra = resA[r];
                final rb = resB[r];
                if (ra != null && rb != null && ra['nt1'] == rb['nt1']) continue;
                await matchPair(o, r, false, false, 'keyB');
              }
            }
          }
        }
        _appendKeysFromSectors(sectorKeys);
        final allDone = sectorKeys.every((sk) => sk.hasKeyA && sk.hasKeyB);
        if (!allDone) {
          final missing = <String>[];
          for (var s = 0; s < 16; s++) {
            if (!sectorKeys[s].hasKeyA || !sectorKeys[s].hasKeyB) {
              missing.add(
                  '$s(${!sectorKeys[s].hasKeyA ? 'A' : ''}${!sectorKeys[s].hasKeyB ? 'B' : ''})');
            }
          }
          LogService.instance.log(
              '[解卡] 3gen 解不开的扇区: ${missing.join(',')} (候选交集为空或种子恢复失败, 卡片nonce采样质量不足)');
        }
        progress.value = allDone
            ? '解卡片：第三代无漏洞卡破解成功'
            : '解卡片：第三代无漏洞卡破解完成，部分扇区密钥未恢复';
        if (mounted) Navigator.of(context).pop();
        _toast(allDone ? '第三代无漏洞卡破解成功' : '部分扇区密钥未恢复');
        return;
      }

      // 全加密卡：尝试 Darkside 攻击块0 keyA（对齐小程序 hS.darkside）
      if (eSector == -1) {
        progress.value = '破解密钥：发现全加密卡，尝试Darkside攻击...';
        try {
          final darkKey = await Crypto1.darkside(
            (isFirst) async {
              checkStop();
              progress.value = '破解密钥：发现全加密卡，破解密钥中';
              final res = await _dev.cmdMf1AcquireDarkside(
                  block: 0, keyType: KeyType.keyA, isFirst: isFirst == 0);
              if (res.status == 0) {
                return {
                  'uid': res.uid!,
                  'nt': res.nt!,
                  'par': res.par!,
                  'ks': res.ks!,
                  'nr': res.nr!,
                  'ar': res.ar!,
                };
              }
              return null;
            },
            (key) async => await _dev.cmdMf1CheckBlockKey(
                block: 0, keyType: KeyType.keyA, key: key),
          );
          final darkHex = _int6Hex(darkKey!);
          sectorKeys[0].hasKeyA = true;
          sectorKeys[0].keyA = darkHex;
          eSector = 0;
          eKeyType = KeyType.keyA;
          eKeyHex = darkHex;
          _appendKeysFromSectors(sectorKeys);
          await _propagateKeys(sectorKeys);
          crackTick.value++;
          progress.value = '破解密钥：Darkside成功，进入半加密卡破解流程...';
          LogService.instance.log(
              '[解卡] 全加密卡Darkside攻击成功, 恢复扇区0 keyA=$darkHex, 进入半加密流程');
        } catch (_) {
          _appendKeysFromSectors(sectorKeys);
          progress.value = '解卡片：发现全加密卡，无法破解（密钥区为空，需至少一个已知密钥）';
          if (mounted) Navigator.of(context).pop();
          LogService.instance.log(
              '[解卡] 全加密卡解不开: Darkside攻击失败(卡片防Darkside), 全卡无已知密钥');
          _toast('全加密卡，Darkside攻击失败，请先通过其他方式获取至少一个密钥');
          return;
        }
      }

      // 解卡片：逐扇区破解（对齐小程序 Crack()）
      step.value = 1;
      final prng = await _dev.cmdMf1TestPrngType();

      if (prng >= 2) {
        progress.value = '解卡片：该卡片为国产兼容卡\n正在云端破解...';
        await _crackHardnestedCloud(
            uid: uid,
            uidInt: uidInt,
            eSector: eSector,
            eKeyType: eKeyType,
            eKeyHex: eKeyHex,
            sectorKeys: sectorKeys,
            progress: progress,
            crackTick: crackTick,
            checkStop: checkStop);
        if (mounted) Navigator.of(context).pop();
        return;
      }

      // WEAK 卡手动勾选 Hardnested 云端破解（对齐小程序 c_modal.Crack_hardnested）
      if (hardnestedNotifier.value) {
        LogService.instance.log('[_crackCard] WEAK hardnested cloud mode');
        await _crackHardnestedCloud(
            uid: uid,
            uidInt: uidInt,
            eSector: eSector,
            eKeyType: eKeyType,
            eKeyHex: eKeyHex,
            sectorKeys: sectorKeys,
            progress: progress,
            crackTick: crackTick,
            checkStop: checkStop);
        if (mounted) Navigator.of(context).pop();
        return;
      }

      // STATIC (prng==0) 或 WEAK (prng==1)：逐扇区破解 keyA 和 keyB
      final prngName = prng >= 2
          ? 'HARD硬加密(PRNG不可预测, 无本地漏洞, 走Hardnested采集计算)'
          : prng == 1
              ? 'WEAK弱随机(PRNG可预测, 有嵌套漏洞)'
              : 'STATIC静态(固定nonce, 有静态漏洞)';
      LogService.instance.log(
          '[解卡] PRNG分型=$prng -> $prngName; 已知密钥: 扇区$eSector ${eKeyType.label}=$eKeyHex');
      for (var s = 0; s < 16; s++) {
        checkStop();
        if (!sectorKeys[s].hasKeyA) {
          progress.value = prng == 0
              ? '破解密钥：静态卡，正在破解扇区$s keyA...'
              : '破解密钥：弱随机卡，正在破解扇区$s keyA...';
          try {
            final rec = await _crackSectorKey(
                uidInt, s, KeyType.keyA, prng, eSector, eKeyType, eKeyHex,
                progress: progress, checkStop: checkStop);
            if (rec != null) {
              sectorKeys[s].hasKeyA = true;
              sectorKeys[s].keyA = rec;
              LogService.instance.log('[_crackCard] sector=$s keyA FOUND=$rec');
              crackTick.value++;
              await _propagateKeys(sectorKeys);
              crackTick.value++;
            } else {
              LogService.instance.log('[_crackCard] sector=$s keyA NOT FOUND');
            }
          } catch (e) {
            progress.value = '破解密钥：扇区$s keyA 破解失败：$e';
            LogService.instance.log('[_crackCard] sector=$s keyA ERROR=$e');
          }
        }
        if (!sectorKeys[s].hasKeyB) {
          progress.value = prng == 0
              ? '破解密钥：静态卡，正在破解扇区$s keyB...'
              : '破解密钥：弱随机卡，正在破解扇区$s keyB...';
          try {
            final rec = await _crackSectorKey(
                uidInt, s, KeyType.keyB, prng, eSector, eKeyType, eKeyHex,
                progress: progress, checkStop: checkStop);
            if (rec != null) {
              sectorKeys[s].hasKeyB = true;
              sectorKeys[s].keyB = rec;
              LogService.instance.log('[_crackCard] sector=$s keyB FOUND=$rec');
              crackTick.value++;
              await _propagateKeys(sectorKeys);
              crackTick.value++;
            } else {
              LogService.instance.log('[_crackCard] sector=$s keyB NOT FOUND');
            }
          } catch (e) {
            progress.value = '破解密钥：扇区$s keyB 破解失败：$e';
            LogService.instance.log('[_crackCard] sector=$s keyB ERROR=$e');
          }
        }
      }

      // 追加发现的密钥
      _appendKeysFromSectors(sectorKeys);

      // 检查是否全部破解成功（对齐小程序 Check_Crack_isfaild）
      var allFound = true;
      final missing = <String>[];
      for (var s = 0; s < 16; s++) {
        if (!sectorKeys[s].hasKeyA || !sectorKeys[s].hasKeyB) {
          allFound = false;
          missing.add(
              '$s(${!sectorKeys[s].hasKeyA ? 'A' : ''}${!sectorKeys[s].hasKeyB ? 'B' : ''})');
        }
      }
      if (allFound) {
        LogService.instance.log('[解卡] 全部16扇区A/B密钥破解成功');
        progress.value = '解卡片：破解成功，已重新标记密钥信息.';
        if (mounted) Navigator.of(context).pop();
        _toast('破解成功');
      } else {
        LogService.instance.log(
            '[解卡] 破解失败, 未破扇区: ${missing.join(', ')} (各扇区失败原因见上方[解卡]日志)');
        progress.value = '解卡片：破解失败，部分扇区密钥未找到';
        if (mounted) Navigator.of(context).pop();
        _toast('破解失败，部分扇区密钥未找到（已写入找到的密钥）');
      }
    } on CrackStoppedException {
      LogService.instance.log('[_crackCard] stopped by user');
      if (mounted) Navigator.of(context).pop();
      _toast('停止中...');
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('破解失败: $e');
    } finally {
      // 对齐小程序 Crack() finally：恢复标签模式 + 提取密钥
      try {
        await _dev.cmdChangeDeviceMode(DeviceMode.tag);
      } catch (_) {}
      _grabKeys();
    }
  }

  /// 对单个扇区恢复密钥（支持 keyA/keyB，对齐小程序 Crack() 逐扇区破解）
  Future<String?> _crackSectorKey(
      int uidInt, int sector, KeyType targetKeyType, int prng,
      int eSector, KeyType eKeyType, String eKeyHex,
      {ValueNotifier<String>? progress, void Function()? checkStop}) async {
    void stop() => checkStop?.call();
    final eKey = _hex(eKeyHex);
    final keyTypeBit = targetKeyType == KeyType.keyA ? 2 : 1;
    final keyTypeStr = targetKeyType == KeyType.keyA ? 'keyA' : 'keyB';
    LogService.instance.log(
        '[解卡] 扇区$sector $keyTypeStr: ${prng == 0 ? '静态嵌套' : '弱随机嵌套'}攻击 (依据: 扇区$eSector 已知密钥)');

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
      if (atks.isEmpty) {
        LogService.instance.log(
            '[解卡] 扇区$sector $keyTypeStr 解不开: 静态嵌套未采集到数据(设备通信异常)');
        return null;
      }
      final nt1 = atks[0]['nt1']!;
      final nt2 = atks[0]['nt2']!;
      LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr STATIC nt1=$nt1 nt2=$nt2');
      final is1Gen = atks.length > 1 &&
          Crypto1.toUint32(nt2).toRadixString(16) ==
              Crypto1.toUint32(atks[1]['nt2']!).toRadixString(16);
      LogService.instance.log(
          '[解卡] 扇区$sector $keyTypeStr: 静态卡${is1Gen ? '1代(加密nonce固定) -> HardNested候选生成' : '2代(加密nonce变化) -> staticnested状态恢复'}');
      if (!is1Gen) {
        // 2代卡：nt2 不一致，staticnested + 暴力验证
        progress?.value = '破解密钥：静态卡，正在恢复扇区$sector $keyTypeStr候选状态（约1分钟，请耐心等待）...';
        final recovered = NativeRecovery.available && atks.length >= 2
            ? NativeRecovery.staticNested(
                uid: uidInt,
                keyType: targetKeyType.value,
                nt0: atks[0]['nt1']!, nt0Enc: atks[0]['nt2']!,
                nt1: atks[1]['nt1']!, nt1Enc: atks[1]['nt2']!)
            : await Crypto1.staticNestedInIsolate(
                uid: uidInt, keyType: targetKeyType.value, atks: atks);
        LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr 2gen recovered=${recovered.length}');
        if (recovered.isEmpty) {
          LogService.instance.log(
              '[解卡] 扇区$sector $keyTypeStr 解不开: staticnested恢复候选为0(采集数据质量差)');
        }
        return _verifyCandidates(sector, keyTypeBit, recovered, chunkSize: 40);
      }
      // 1代卡：nt2 一致，HardNested + 暴力验证
      final hardRes = await _dev.cmdMf1AcquireHardNested(
          block: eSector * 4, keyType: eKeyType, key: eKey,
          targetBlock: sector * 4, targetKeyType: targetKeyType);
      if (hardRes.isEmpty) {
        LogService.instance.log(
            '[解卡] 扇区$sector $keyTypeStr 解不开: HardNested未采集到数据(设备通信异常)');
        return null;
      }
      final par = hardRes.first.par;
      final candidates = _generateKeysFromHardNested(uidInt, nt1, nt2, par);
      LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr 1gen candidates=${candidates.length}');
      if (candidates.isEmpty) {
        LogService.instance.log(
            '[解卡] 扇区$sector $keyTypeStr 解不开: HardNested候选为0(parity校验全部失败, 采集数据质量差)');
      }
      return _verifyCandidates(sector, keyTypeBit, candidates, chunkSize: 40);
    }
    if (prng == 1) {
      // WEAK 嵌套：重试5次 + 暴力验证
      for (var retry = 0; retry < 5; retry++) {
        stop();
        LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry START');
        try {
          final distRes = await _dev.cmdMf1TestNtDistance(
              block: eSector * 4, keyType: eKeyType, key: eKey);
          LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry distRes.uid=${distRes.uid.length} dist=${distRes.dist.length}');
          final dist = _bytesInt(distRes.dist.sublist(0, 4));
          final nestedUid = _bytesInt(distRes.uid.sublist(0, 4));
          LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry dist=$dist nestedUid=$nestedUid');
          final nested = await _dev.cmdMf1AcquireNested(
              block: eSector * 4,
              keyType: eKeyType,
              key: eKey,
              targetBlock: sector * 4,
              targetKeyType: targetKeyType);
          LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry nested.length=${nested.length}');
          final atks = nested
              .map((a) => {
                    'nt1': _bytesInt(a.nt1),
                    'nt2': _bytesInt(a.nt2),
                    'par': a.par,
                  })
              .toList();
              LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry atks.length=${atks.length}');
          // 对齐小程序：每轮重试追加进度点
          progress?.value = '破解密钥：弱随机卡，正在破解扇区$sector $keyTypeStr${'.' * (retry + 1)}';
          List<int> recovered;
          if (NativeRecovery.available && atks.length >= 2) {
            // native C 路径（PM3 mfnested，毫秒级）：采集对两两配对合并候选
            final merged = <int>{};
            for (var i = 0; i + 1 < atks.length; i += 2) {
              stop();
              merged.addAll(NativeRecovery.nested(
                  uid: nestedUid,
                  dist: dist,
                  nt0: atks[i]['nt1']!, nt0Enc: atks[i]['nt2']!, par0: atks[i]['par']!,
                  nt1: atks[i + 1]['nt1']!, nt1Enc: atks[i + 1]['nt2']!, par1: atks[i + 1]['par']!));
            }
            if (atks.length.isOdd) {
              stop();
              merged.addAll(NativeRecovery.nested(
                  uid: nestedUid,
                  dist: dist,
                  nt0: atks.last['nt1']!, nt0Enc: atks.last['nt2']!, par0: atks.last['par']!,
                  nt1: atks.first['nt1']!, nt1Enc: atks.first['nt2']!, par1: atks.first['par']!));
            }
            recovered = merged.toList();
            LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry native recovered=${recovered.length}');
          } else {
            // Dart 路径（native 不可用时回退）
            // 第一步：奇偶过滤得到有效采样对（快速）
            final collected = Crypto1.nestedCollect(dist: dist, atks: atks);
            LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry collected=${collected.length}');
            // 第二步：逐对状态恢复（每对数十秒，放入后台 isolate 并回报进度）
            final keysPerPair = <List<int>>[];
            for (var i = 0; i < collected.length; i++) {
              stop();
              progress?.value = '破解密钥：弱随机卡，正在恢复扇区$sector $keyTypeStr候选状态 ${i + 1}/${collected.length} 对（每对约半分钟）...';
              final pair = collected[i];
              final keys = await Crypto1.recoverKeysInIsolate(nestedUid, pair);
              keysPerPair.add(keys);
            }
            // 第三步：合并候选取 top50（快速）
            recovered = Crypto1.nestedMerge(keysPerPair);
            LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry recovered=${recovered.length}');
          }
          if (recovered.isEmpty) {
            LogService.instance.log(
                '[解卡] 扇区$sector $keyTypeStr 第${retry + 1}轮候选交集为空(采集样本质量差), 重试');
          } else {
            final found = await _verifyCandidates(sector, keyTypeBit, recovered);
            // 验证失败说明本轮采集样本质量差（候选交集为空），继续重试采集
            if (found != null) return found;
            LogService.instance.log(
                '[解卡] 扇区$sector $keyTypeStr 第${retry + 1}轮候选${recovered.length}个全部验证失败(采集样本质量差), 重试');
          }
        } catch (e) {
          LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry ERROR=$e');
          rethrow;
        }
      }
      LogService.instance.log(
          '[解卡] 扇区$sector $keyTypeStr 解不开: 弱随机嵌套5轮重试全部失败(PRNG距离抖动过大或卡异常), 该扇区放弃');
    }
    return null;
  }

  /// 暴力验证候选密钥（对齐小程序 bruteforce_Crack + mf1CheckKeysOfSectors）
  Future<String?> _verifyCandidates(
      int sector, int keyTypeBit, List<int> candidates,
      {int chunkSize = 20}) async {
    if (candidates.isEmpty) {
      LogService.instance.log('[_verifyCandidates] sector=$sector candidates empty');
      return null;
    }
    LogService.instance.log('[_verifyCandidates] sector=$sector candidates=${candidates.length}');
    final mask = Uint8List(10);
    mask.fillRange(0, 10, 0xFF);
    mask[sector >> 2] ^= keyTypeBit << (6 - sector % 4 * 2);
    final keys = candidates
        .map((k) {
          final buf = Uint8List(6);
          final bd = ByteData.sublistView(buf);
          bd.setUint16(0, (k >> 32) & 0xFFFF, Endian.big);
          bd.setUint32(2, k & 0xFFFFFFFF, Endian.big);
          return buf;
        })
        .toList();
    final res = await _dev.cmdMf1CheckKeysOfSectors(
        keys: keys, mask: mask, chunkSize: chunkSize);
    final idx = keyTypeBit == 2 ? sector * 2 : sector * 2 + 1;
    final found = res.sectorKeys[idx];
    if (found != null) {
      LogService.instance.log('[_verifyCandidates] sector=$sector FOUND key=${_hexStr(found)}');
      return _hexStr(found);
    }
    LogService.instance.log('[_verifyCandidates] sector=$sector NOT FOUND (found bit=0)');
    return null;
  }

  /// 1代卡 HardNested 密钥生成（对齐小程序 generate_keys：从 nt1^nt2 恢复候选密钥）
  /// 从 HardNested 数据生成候选密钥（对齐小程序 generate_keys）
  List<int> _generateKeysFromHardNested(
      int uidInt, int nt1, int nt2, int par) {
    final ks = nt1 ^ uidInt;
    final diff = nt1 ^ nt2;
    final states = Crypto1.lfsrRecovery32(diff, ks);
    final result = <int>[];
    for (final s in states) {
      s.lfsrRollbackWord(ks, 0);
      final key = s.getLfsr();
      s.setLfsr(key);
      s.lfsrWord(ks, 0);
      final word = s.lfsrWord(0, 0);
      final parBit = Crypto1.oddParity8(255 & nt1);
      final calcBit = ((par >> 4) & 1) ^ ((word >> 24) & 1);
      if (parBit == calcBit) result.add(key);
    }
    return result;
  }

  /// 从加密嵌套数据生成候选密钥（对齐小程序 generate_keys：lfsrRecovery64 + rollback）
  int _generateKeyFromEncryptedNested(
      Uint8List uid, int nt, int ntEnc, int par) {
    final state = Crypto1.lfsrRecovery64(ntEnc, par >> 4);
    final uidInt = _bytesInt(uid.sublist(0, 4));
    state.lfsrRollbackWord(uidInt ^ nt, 0);
    return state.getLfsr();
  }

  /// 变换加密嵌套 atks（对齐小程序：nt 前推16步，par 与 ntEnc 高位异或）
  List<(int, int, int, int)> _transformEncNestedAtks(
      List<(int, KeyType, int, int, int)> atks) {
    return atks.map((a) {
      final nt = Crypto1.prngSuccessor(a.$3, 16);
      final p = a.$5;
      final n = a.$4;
      final par = ((p >> 3 & 1) ^ (n >> 24 & 1)) << 3 |
          ((p >> 2 & 1) ^ (n >> 16 & 1)) << 2 |
          ((p >> 1 & 1) ^ (n >> 8 & 1)) << 1 |
          ((p & 1) ^ (n & 1));
      return (a.$1, nt, n, par);
    }).toList();
  }

  /// 双卡破解（对齐小程序 Crack_with2cards：两张同系统不同UID的卡）
  Future<void> _crackWith2Cards() async {
    final progress = ValueNotifier<String>('双卡破解：正在读取第一张卡...');
    final step = ValueNotifier<int>(0);
    NativeRecovery.init();
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final tags1 = await _dev.cmdHf14aScan();
      if (tags1.isEmpty) throw DeviceException(1, '未发现卡片');
      final tag1 = tags1.first;
      if (tag1.sakHex != '08') {
        _toast('发现非标准M1卡，该卡无法破解');
        return;
      }
      final uid1 = tag1.uid;

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => CrackProgressDialog(
          title: '双卡破解...',
          steps: const ['读取卡1', '读取卡2', '生成密钥'],
          step: step,
          progress: progress,
          onCancel: null,
        ),
      );

      // 第一张卡：加密嵌套采集
      Mf1AcquireStaticEncryptedNestedDecoder? enc1;
      final specialKeys = ['A396EFA4E24F', 'A31667A8CEC1', '518B3354E760'];
      for (final sk in specialKeys) {
        try {
          final res = await _dev.cmdMf1AcquireStaticEncryptedNested(
              key: _hex(sk));
          if (res.atks.isNotEmpty) {
            enc1 = res;
            break;
          }
        } catch (_) {}
      }
      if (enc1 == null) {
        throw DeviceException(1,
            '破解失败，只有第一、三代无漏洞卡支持双卡破解！');
      }

      // 等待用户换卡（对齐小程序：100秒超时）
      progress.value = '双卡破解：请读取第二张卡...';
      Uint8List? uid2;
      for (var i = 0; i < 100; i++) {
        progress.value =
            '双卡破解：请读取第二张卡，用时${i}s...';
        try {
          final tags2 = await _dev.cmdHf14aScan();
          if (tags2.isNotEmpty) {
            final tag2 = tags2.first;
            if (_hexStr(tag2.uid) != _hexStr(uid1)) {
              uid2 = tag2.uid;
              break;
            }
          }
        } catch (_) {}
        await Future.delayed(const Duration(seconds: 1));
      }
      if (uid2 == null) {
        throw DeviceException(1, '超时，未检测到第二张卡');
      }

      // 第二张卡：加密嵌套采集
      progress.value = '双卡破解：正在读取第二张卡...';
      Mf1AcquireStaticEncryptedNestedDecoder? enc2;
      for (final sk in specialKeys) {
        try {
          final res = await _dev.cmdMf1AcquireStaticEncryptedNested(
              key: _hex(sk));
          if (res.atks.isNotEmpty) {
            enc2 = res;
            break;
          }
        } catch (_) {}
      }
      if (enc2 == null) {
        throw DeviceException(1,
            '破解失败，第二张卡不支持双卡破解！');
      }

      // 变换 atks 并生成候选密钥
      step.value = 2;
      final sectorKeys = List.generate(16, (s) => SectorKeyState(s));
      // 从当前卡片状态初始化已有密钥
      for (var s = 0; s < 16; s++) {
        final b3 = _app.card.sectors[s].blocks[3].data;
        if (b3.length >= 32) {
          final keyA = b3.substring(0, 12);
          final keyB = b3.substring(20, 32);
          if (keyA != '000000000000') {
            sectorKeys[s].hasKeyA = true;
            sectorKeys[s].keyA = keyA;
          }
          if (keyB != '000000000000') {
            sectorKeys[s].hasKeyB = true;
            sectorKeys[s].keyB = keyB;
          }
        }
      }

      final atks1 = _transformEncNestedAtks(enc1.atks);
      final atks2 = _transformEncNestedAtks(enc2.atks);

      for (var s = 0; s < 16; s++) {
        if (sectorKeys[s].hasKeyA && sectorKeys[s].hasKeyB) continue;
        if (s * 2 + 1 >= atks1.length || s * 2 + 1 >= atks2.length) break;

        // keyA：索引 2*s
        if (!sectorKeys[s].hasKeyA &&
            s * 2 < atks1.length && s * 2 < atks2.length) {
          final a1 = atks1[s * 2];
          final a2 = atks2[s * 2];
          final key1 = _generateKeyFromEncryptedNested(uid1, a1.$2, a1.$3, a1.$4);
          final key2 = _generateKeyFromEncryptedNested(uid2, a2.$2, a2.$3, a2.$4);
          if (key1 == key2) {
            final keyHex = _int6Hex(key1);
            final valid = await _dev.cmdMf1CheckBlockKey(
                block: s * 4, keyType: KeyType.keyA, key: _hex(keyHex));
            if (valid) {
              sectorKeys[s].hasKeyA = true;
              sectorKeys[s].keyA = keyHex;
              progress.value =
                  '双卡破解：扇区$s keyA=$keyHex';
            }
          }
        }

        // keyB：索引 2*s+1
        if (!sectorKeys[s].hasKeyB &&
            s * 2 + 1 < atks1.length && s * 2 + 1 < atks2.length) {
          final a1 = atks1[s * 2 + 1];
          final a2 = atks2[s * 2 + 1];
          final key1 = _generateKeyFromEncryptedNested(uid1, a1.$2, a1.$3, a1.$4);
          final key2 = _generateKeyFromEncryptedNested(uid2, a2.$2, a2.$3, a2.$4);
          if (key1 == key2) {
            final keyHex = _int6Hex(key1);
            final valid = await _dev.cmdMf1CheckBlockKey(
                block: s * 4, keyType: KeyType.keyB, key: _hex(keyHex));
            if (valid) {
              sectorKeys[s].hasKeyB = true;
              sectorKeys[s].keyB = keyHex;
              progress.value =
                  '双卡破解：扇区$s keyB=$keyHex';
            }
          }
        }
      }

      // 检查是否全部找到
      var allFound = true;
      for (var s = 0; s < 16; s++) {
        if (!sectorKeys[s].hasKeyA || !sectorKeys[s].hasKeyB) {
          allFound = false;
          break;
        }
      }

      _appendKeysFromSectors(sectorKeys);
      if (allFound) {
        progress.value = '双卡破解：破解成功，已重新标记密钥信息.';
        if (mounted) Navigator.of(context).pop();
        _toast('双卡破解成功');
      } else {
        progress.value = '双卡破解：破解失败，这两张卡分别拥有不同密钥！';
        if (mounted) Navigator.of(context).pop();
        _toast('双卡破解失败，请确认两张卡属于同一系统');
      }
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('双卡破解失败: $e');
    }
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

  /// 从扇区块3提取密钥（对齐小程序 btnKeysGrab）
  void _grabKeys() {
    final lines = _keys.toList();
    final sectors = _app.card.sectors;
    if (sectors.isEmpty) return;
    for (var s = 0; s < 16 && s < sectors.length; s++) {
      final blocks = sectors[s].blocks;
      if (blocks.length < 4) continue;
      final trailer = blocks[3].data;
      if (trailer.length != 32) continue;
      final kA = trailer.substring(0, 12);
      final kB = trailer.substring(20, 32);
      if (kA != 'ffffffffffff' && kA != '000000000000' && !lines.contains(kA)) {
        lines.add(kA);
      }
      if (kB != 'ffffffffffff' && kB != '000000000000' && !lines.contains(kB)) {
        lines.add(kB);
      }
    }
    if (!mounted) return;
    setState(() {
      _keyCtrl.text = lines.join('\n');
      _app.card.keys = _keyCtrl.text;
      _validateKeys(_keyCtrl.text);
    });
  }

  /// 云端 Hardnested 破解（对齐小程序 Crack_hardnested）：
  /// 1) query_job 拉取云字典，验证全扇区；2) 逐扇区采集 256 个去重 nt 上传 add_job
  Future<void> _crackHardnestedCloud({
    required Uint8List uid,
    required int uidInt,
    required int eSector,
    required KeyType eKeyType,
    required String eKeyHex,
    required List<SectorKeyState> sectorKeys,
    required ValueNotifier<String> progress,
    required ValueNotifier<int> crackTick,
    required void Function() checkStop,
  }) async {
    final uidHex = _hexStr(uid.sublist(0, 4));
    final userId = '01';

    // 第零步（借鉴 Chameleon Ultra）：native 可用时本地 Hardnested 优先
    // PM3 mfnestedhard 多线程计算，单目标分钟级；找到即验证标记，全破则返回
    if (NativeRecovery.available) {
      try {
        for (var s = 0; s < 16; s++) {
          checkStop();
          if (!sectorKeys[s].hasKeyA) {
            final key = await _hardnestedLocal(
                uidInt: uidInt,
                eSector: eSector,
                eKeyType: eKeyType,
                eKeyHex: eKeyHex,
                sector: s,
                targetType: KeyType.keyA,
                progress: progress,
                checkStop: checkStop);
            if (key != null) {
              await _checkCrackedKeys([_hex(key)], sectorKeys);
              crackTick.value++;
              _appendKeysFromSectors(sectorKeys);
              if (sectorKeys.every((sk) => sk.hasKeyA && sk.hasKeyB)) {
                progress.value = '解卡片：破解成功，已重新标记密钥信息.';
                _toast('破解成功');
                return;
              }
            }
          }
          checkStop();
          if (!sectorKeys[s].hasKeyB) {
            final key = await _hardnestedLocal(
                uidInt: uidInt,
                eSector: eSector,
                eKeyType: eKeyType,
                eKeyHex: eKeyHex,
                sector: s,
                targetType: KeyType.keyB,
                progress: progress,
                checkStop: checkStop);
            if (key != null) {
              await _checkCrackedKeys([_hex(key)], sectorKeys);
              crackTick.value++;
              _appendKeysFromSectors(sectorKeys);
              if (sectorKeys.every((sk) => sk.hasKeyA && sk.hasKeyB)) {
                progress.value = '解卡片：破解成功，已重新标记密钥信息.';
                _toast('破解成功');
                return;
              }
            }
          }
        }
        LogService.instance.log(
            '[解卡] 本地Hardnested流程结束, 未能全破, 转云端继续(云字典+云端Hardnested)');
        progress.value = '解卡片：本地计算未能全部破解，转云端继续...';
      } catch (e) {
        LogService.instance.log(
            '[解卡] 本地Hardnested异常=$e, 转云端继续');
      }
    }

    // 第一步：云字典查询（对齐小程序 query_job + KeyFor_<card_id>.txt）
    var dictKeys = <String>[];
    try {
      progress.value = '解卡片：正在查询云端任务...';
      final tasks = await _app.cloud.queryJobs(userId);
      final all = <String>[];
      for (final t in tasks) {
        if (t.key.isNotEmpty && t.key != 'error') {
          if (!all.contains(t.key.toLowerCase())) all.add(t.key.toLowerCase());
        }
      }
      dictKeys = all;
      LogService.instance.log('[_crackHardnestedCloud] dict tasks=${tasks.length} keys=${dictKeys.length}');
    } catch (e) {
      LogService.instance.log('[_crackHardnestedCloud] query_job ERROR=$e');
    }

    if (dictKeys.isNotEmpty) {
      progress.value = '解卡片：云端获取到 ${dictKeys.length} 个密钥，正在验证...';
      try {
        final keys = dictKeys.map(_hex).toList();
        await _checkCrackedKeys(keys, sectorKeys);
        crackTick.value++;
        _appendKeysFromSectors(sectorKeys);
        if (sectorKeys.every((sk) => sk.hasKeyA && sk.hasKeyB)) {
          LogService.instance.log('[_crackHardnestedCloud] ALL sectors cracked from cloud dict');
          progress.value = '解卡片：破解成功，已重新标记密钥信息.';
          _toast('破解成功');
          return;
        }
        LogService.instance.log('[_crackHardnestedCloud] dict verify done, still missing keys');
      } catch (e) {
        LogService.instance.log('[_crackHardnestedCloud] dict verify ERROR=$e');
      }
    }

    // 第二步：逐扇区采集上传（对齐小程序 256 个去重 nt 高字节 + add_job）
    var uploadedAny = false;
    for (var s = 0; s < 16; s++) {
      checkStop();
      if (!sectorKeys[s].hasKeyA) {
        await _collectUploadHardnestedSector(
            uidHex: uidHex,
            userId: userId,
            eSector: eSector,
            eKeyType: eKeyType,
            eKeyHex: eKeyHex,
            sector: s,
            targetType: KeyType.keyA,
            progress: progress,
            checkStop: checkStop);
        uploadedAny = true;
      }
      checkStop();
      if (!sectorKeys[s].hasKeyB) {
        await _collectUploadHardnestedSector(
            uidHex: uidHex,
            userId: userId,
            eSector: eSector,
            eKeyType: eKeyType,
            eKeyHex: eKeyHex,
            sector: s,
            targetType: KeyType.keyB,
            progress: progress,
            checkStop: checkStop);
        uploadedAny = true;
      }
    }
    if (uploadedAny) {
      final task = CrackTask(
        id: 'local_${DateTime.now().millisecondsSinceEpoch}',
        cardId: uidHex,
        sector: 0,
        keyType: KeyType.keyA,
      );
      await _app.storage.addCrackTask(task);
      progress.value = '解卡片：数据已上传云端计算\n请稍后在"查询任务"中查看结果';
      _toast('已上传云端任务');
    }
  }

  /// 本地 Hardnested 单目标（借鉴 Chameleon Ultra）：
  /// 采集 256 高字节 → native mfnestedhard 计算 → 返回 12 位 hex 密钥（失败 null）
  Future<String?> _hardnestedLocal({
    required int uidInt,
    required int eSector,
    required KeyType eKeyType,
    required String eKeyHex,
    required int sector,
    required KeyType targetType,
    required ValueNotifier<String> progress,
    required void Function() checkStop,
  }) async {
    final pairs = await _collectHardnestedData(
        eSector: eSector,
        eKeyType: eKeyType,
        eKeyHex: eKeyHex,
        sector: sector,
        targetType: targetType,
        progress: progress,
        checkStop: checkStop);
    final buf = _buildHardNestedBuf(uidInt, pairs);
    progress.value = '解卡片：本地 Hardnested 计算扇区$sector ${targetType.label}\n可能需要几分钟，请勿断开设备...';
    // 可杀 isolate：轮询停止标记，点停止立即终止 C 计算
    final job = NativeRecovery.hardNestedStart(buf);
    var key = 0;
    try {
      while (!job.isCompleted) {
        await Future.delayed(const Duration(milliseconds: 200));
        checkStop();
      }
      key = await job.future;
    } finally {
      job.kill();
    }
    if (key == 0) {
      LogService.instance.log(
          '[解卡] 扇区$sector ${targetType.label}: 本地Hardnested计算未找到密钥(候选空间缩减不足或采集质量差), 转云端');
      return null;
    }
    final keyHex = key.toRadixString(16).padLeft(12, '0');
    LogService.instance.log(
        '[解卡] 扇区$sector ${targetType.label}: 本地Hardnested计算找到密钥=$keyHex');
    return keyHex;
  }

  /// PM3 nonce 缓冲：6 字节头（uid 大端 + 2 占位）+ 每条 9 字节（nt/ntEnc/par），
  /// 与 native hardnested.c read_nonces 格式对齐
  Uint8List _buildHardNestedBuf(int uidInt, List<Mf1AcquireHardNestedRes> pairs) {
    final buf = Uint8List(6 + pairs.length * 9);
    final bd = ByteData(buf.length);
    bd.setUint32(0, uidInt & 0xFFFFFFFF);
    for (var i = 0; i < pairs.length; i++) {
      final off = 6 + i * 9;
      bd.setUint32(off, _bytesInt(pairs[i].nt) & 0xFFFFFFFF);
      bd.setUint32(off + 4, _bytesInt(pairs[i].ntEnc) & 0xFFFFFFFF);
      buf[off + 8] = pairs[i].par & 0xFF;
    }
    return buf;
  }

  /// 采集单扇区 hardnested 数据直到 256 个去重高字节集满
  /// （借鉴 Chameleon Ultra/PM3：sum8 白名单校验，上限 3 次重采后放行防死循环）
  Future<List<Mf1AcquireHardNestedRes>> _collectHardnestedData({
    required int eSector,
    required KeyType eKeyType,
    required String eKeyHex,
    required int sector,
    required KeyType targetType,
    required ValueNotifier<String> progress,
    required void Function() checkStop,
  }) async {
    const sumWhitelist = {
      0, 32, 56, 64, 80, 96, 104, 112, 120, 128,
      136, 144, 152, 160, 176, 192, 200, 224, 256
    };
    final eKey = _hex(eKeyHex);
    final seen = List<bool>.filled(256, false);
    var count = 0;
    var sum = 0;
    var attempts = 0;
    final pairs = <Mf1AcquireHardNestedRes>[];
    while (true) {
      checkStop();
      progress.value =
          '破解密钥：该卡片为国产兼容卡\n正在获取扇区：$sector ${targetType.label}的数据.\n已获取$count/256个有效数据...';
      final data = await _dev.cmdMf1AcquireHardNested(
          block: eSector * 4,
          keyType: eKeyType,
          key: eKey,
          targetBlock: sector * 4,
          targetKeyType: targetType);
      LogService.instance.log(
          '[_collectHardnestedData] sector=$sector ${targetType.label} batch=${data.length} uniq=$count');
      pairs.addAll(data);
      for (final a in data) {
        final nt = _bytesInt(a.nt);
        final ntEnc = _bytesInt(a.ntEnc);
        final hb = (nt >> 24) & 255;
        if (!seen[hb]) {
          seen[hb] = true;
          count++;
          sum += Crypto1.evenParity32((nt & 0xff000000) | ((a.par >> 4) & 0x08));
        }
        final hb2 = (ntEnc >> 24) & 255;
        if (!seen[hb2]) {
          seen[hb2] = true;
          count++;
          sum += Crypto1.evenParity32((ntEnc & 0xff000000) | (a.par & 0x08));
        }
      }
      if (count >= 256) {
        if (!sumWhitelist.contains(sum) && attempts < 3) {
          attempts++;
          LogService.instance.log(
              '[解卡] 扇区$sector ${targetType.label}: 采集质量差(sum8=$sum 不在白名单), 重采($attempts/3)');
          seen.fillRange(0, 256, false);
          count = 0;
          sum = 0;
          pairs.clear();
          continue;
        }
        if (!sumWhitelist.contains(sum)) {
          LogService.instance.log(
              '[解卡] 扇区$sector ${targetType.label}: 重采3次sum8仍异常($sum), 放行上传(可能影响恢复成功率)');
        }
        LogService.instance.log(
            '[_collectHardnestedData] sector=$sector sum=$sum attempts=$attempts done, pairs=${pairs.length}');
        return pairs;
      }
    }
  }

  /// 上传单扇区 hardnested 数据（对齐小程序 add_job，nonce=采集数据）
  Future<void> _collectUploadHardnestedSector({
    required String uidHex,
    required String userId,
    required int eSector,
    required KeyType eKeyType,
    required String eKeyHex,
    required int sector,
    required KeyType targetType,
    required ValueNotifier<String> progress,
    required void Function() checkStop,
  }) async {
    var uploaded = false;
    while (!uploaded) {
      checkStop();
      final pairs = await _collectHardnestedData(
          eSector: eSector,
          eKeyType: eKeyType,
          eKeyHex: eKeyHex,
          sector: sector,
          targetType: targetType,
          progress: progress,
          checkStop: checkStop);
      final nonceBuf = StringBuffer();
      for (final a in pairs) {
        nonceBuf.write('${_bytesInt(a.nt)}|${(a.par >> 4) & 15}\n');
        nonceBuf.write('${_bytesInt(a.ntEnc)}|${a.par & 15}\n');
      }
      try {
        await _app.cloud.addJob(
            userId: userId,
            openid: uidHex,
            cardId: uidHex,
            sector: sector,
            keyType: targetType,
            nonceData: nonceBuf.toString());
        LogService.instance.log(
            '[_collectUploadHardnestedSector] sector=$sector ${targetType.label} uploaded nonce=${nonceBuf.length}');
        uploaded = true;
      } catch (e) {
        LogService.instance.log(
            '[_collectUploadHardnestedSector] add_job ERROR=$e, retrying');
        // 上传失败重试采集（对齐小程序无限循环直到成功）
      }
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
        _atsCtrl.text = state.ats;
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
          final recovered = NativeRecovery.available && atks.length >= 2
              ? NativeRecovery.staticNested(
                  uid: uid1,
                  keyType: 96,
                  nt0: atks[0]['nt1']!, nt0Enc: atks[0]['nt2']!,
                  nt1: atks[1]['nt1']!, nt1Enc: atks[1]['nt2']!)
              : await Crypto1.staticNestedInIsolate(
                  uid: uid1, keyType: 96, atks: atks);
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
              _sideBtn('双卡破解', Icons.contactless, _crackWith2Cards, primary),
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
        _atsCtrl.text = antiColl.atsHex;
        _app.card.uid = antiColl.uidHex;
        _app.card.atqa = antiColl.atqaHex;
        _app.card.sak = antiColl.sakHex;
        _app.card.ats = antiColl.atsHex;
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
/// 用户请求停止解卡（对齐小程序 stop_flag + checkstop 抛错终止）
class CrackStoppedException implements Exception {
  const CrackStoppedException();

  @override
  String toString() => 'call to stop';
}

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

String _hexStrRev(Uint8List b) =>
    b.reversed.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

int _bytesInt(Uint8List b) {
  final padded = Uint8List(4);
  padded.setRange(4 - b.length, 4, b.sublist(0, b.length > 4 ? 4 : b.length));
  return ByteData.sublistView(padded).getUint32(0);
}

String _int6Hex(int v) =>
    v.toRadixString(16).padLeft(12, '0').substring(0, 12);
