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

  /// 国产卡后门密钥（Gen2/CUID 采集与认证试探共用）
  static const List<String> _backdoorKeys = [
    'A396EFA4E24F',
    'A31667A8CEC1',
    '518B3354E760'
  ];

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
    // 启动时只默认加载 3 把默认密钥；密钥文件在读卡/解卡流程中按需加载
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

  /// 收集验证密钥集合：编辑框现有 + 本卡密钥文件(KeyFor_UID.txt，[uidHex]非空时)
  /// 密钥体系隔离：不读 default_keys.txt 与其他卡的密钥文件（对齐小程序
  /// 按卡号文件隔离的语义，避免无关密钥拖慢验证），编辑框内容保持不动
  Future<List<String>> _collectVerifyKeys({String? uidHex}) async {
    final merged = _keys.toList();
    if (uidHex != null && uidHex.length >= 8) {
      for (final k in await _loadKeyFileForUid(uidHex)) {
        if (!merged.contains(k)) merged.add(k);
      }
    }
    return merged;
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

  /// 字典检查用密钥表：用户密钥 + 扩展字典（Chameleon Ultra 内置表，
  /// 仅用于检查/验证，不显示在编辑区）
  List<String> get _dictKeys {
    final merged = _keys.toList();
    for (final k in kExtendedKeys) {
      if (!merged.contains(k)) merged.add(k);
    }
    return merged;
  }

  // ========== 扇区密钥状态（对齐小程序 sectors_Key） ==========
  /// 批量检查密钥，对齐小程序 checkCrackedKey：用 mf1CheckKeysOfSectors 掩码批量检测
  /// 返回 true 表示仍有未找到的密钥
  /// onProgress：每块（32 把）结果解析并合并后触发，参数为已处理的 key 数量游标（断点续破）
  /// 全卡单次批量检测（cmd mf1CheckKeysOfSectors），普通 M1 卡一次命令扫全部
  /// 未标记槽位，比对逐扇区批量快且稳定（1849ff3 实测正常）
  Future<bool> _checkCrackedKeys(
      List<Uint8List> keys, List<SectorKeyState> sectorKeys,
      {void Function(int processedKeys)? onProgress}) async {
    if (keys.isEmpty) {
      return sectorKeys.any((sk) => !sk.hasKeyA || !sk.hasKeyB);
    }
    final mask = Uint8List(10);
    mask.fillRange(0, 10, 0xFF);
    for (var s = 0; s < 16; s++) {
      if (!sectorKeys[s].hasKeyA) mask[s >> 2] ^= 2 << (6 - s % 4 * 2);
      if (!sectorKeys[s].hasKeyB) mask[s >> 2] ^= 1 << (6 - s % 4 * 2);
    }
    LogService.instance.log('[_checkCrackedKeys] keys=${keys.length}, mask=${_hexStr(mask)}');
    final res = await _dev.cmdMf1CheckKeysOfSectors(
      keys: keys,
      mask: mask,
      onChunk: onProgress == null
          ? null
          : (partial, processed) {
              _mergeSectorKeys(partial, sectorKeys);
              onProgress(processed);
            },
    );
    LogService.instance.log('[_checkCrackedKeys] found=${_hexStr(res.found)}, sectorKeys=${res.sectorKeys.map((k) => k == null ? 'null' : _hexStr(k)).join(',')}');
    final anyMissing = _mergeSectorKeys(res, sectorKeys);
    LogService.instance.log('[_checkCrackedKeys] anyMissing=$anyMissing');
    return anyMissing;
  }

  /// 将批量检查结果合并进扇区密钥状态（幂等，可对累积 partial 重复调用）
  /// 返回 true 表示仍有未找到的密钥
  bool _mergeSectorKeys(
      Mf1CheckKeysOfSectorsRes res, List<SectorKeyState> sectorKeys) {
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
  /// 传播验证：全卡批量 cmdMf1CheckKeysOfSectors（单次命令扫全部未标记槽位，
  /// 动态收缩掩码自动跳过已命中项，比逐把 recheckKey 快 1-2 个数量级）；
  /// 批量返回 keyA 命中后，对「A 新命中且 B 未标记」的扇区读 trailer 的 b3，
  /// keyB 位置非全 0 即免费推导并验证（保留 CU checkKeysOnSector 尾部增强）。
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
    // 传播验证只用已知密钥（用户密钥 + 已破出密钥），
    // 不掺扩展字典：本函数在解卡中高频调用，47 把字典会放大出数千次多余认证
    for (final k in _keys) {
      if (!names.contains(k)) names.add(k);
    }
    if (names.isEmpty) return;
    // 构造只开未标记槽位的掩码；全标记则无需传播
    final mask = Uint8List(10);
    for (var s = 0; s < 16; s++) {
      if (!sectorKeys[s].hasKeyA) mask[s >> 2] |= 2 << (6 - s % 4 * 2);
      if (!sectorKeys[s].hasKeyB) mask[s >> 2] |= 1 << (6 - s % 4 * 2);
    }
    if (mask.every((m) => m == 0)) return;
    LogService.instance.log(
        '[_propagateKeys] ${names.length} known keys, mask=${_hexStr(mask)} (全卡批量)');
    final res = await _dev.cmdMf1CheckKeysOfSectors(
        keys: names.map(_hex).toList(), mask: mask);
    final anyMissing = _mergeSectorKeys(res, sectorKeys);
    LogService.instance.log(
        '[_propagateKeys] found=${_hexStr(res.found)} anyMissing=$anyMissing');
    // 对齐 CU checkKeysOnSector 尾部：A 命中读 trailer 免费推导 keyB
    for (var s = 0; s < 16; s++) {
      if (!sectorKeys[s].hasKeyA || sectorKeys[s].hasKeyB) continue;
      final kname = sectorKeys[s].keyA;
      if (kname.isEmpty) continue;
      try {
        final b3 = await _dev.cmdMf1ReadBlock(
            block: 4 * s + 3, keyType: KeyType.keyA, key: _hex(kname));
        if (b3.length == 16) {
          final bkey = _hexStr(b3.sublist(10, 16));
          if (bkey != '000000000000') {
            final okB = await _dev.cmdMf1CheckBlockKey(
                block: 4 * s, keyType: KeyType.keyB, key: _hex(bkey));
            if (okB) {
              sectorKeys[s].hasKeyB = true;
              sectorKeys[s].keyB = bkey;
              LogService.instance.log(
                  '[_propagateKeys] sector=$s keyB=$bkey FOUND (读b3推导)');
            }
          }
        }
      } catch (_) {}
    }
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

      // 第一步：立即更新 uid/sak 等信息到卡片信息
      if (mounted) {
        setState(() {
          _app.card.uid = uid;
          _app.card.atqa = _hexStrRev(tag.atqa);
          _app.card.sak = tag.sakHex;
          _app.card.ats = tag.atsHex;
        });
        _syncCardInfo();
      }

      // 第二步：该 UID 保存过密钥文件则导入编辑区
      final savedKeys = await _loadKeyFileForUid(uid);
      if (savedKeys.isNotEmpty) {
        _appendKeys(savedKeys);
        _toast('已导入该卡片的历史密钥 ${savedKeys.length} 个');
      }

      // 第三步：继续原本流程（Gen1a 免密读卡 -> 密钥验证 -> 逐扇区读取）
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

      // 批量检测扇区密钥（对齐小程序 checkCrackedKey）
      // 读卡仅用用户密钥：扩展字典 44 把全 miss 时会跑满 1500+ 次失败认证（30-60s），
      // 且部分命中后 anyMissing 仍提示去解卡，收益极低；扩展字典留给解卡第一步
      final allKeys = (await _collectVerifyKeys(uidHex: uid)).map(_hex).toList();
      final anyMissing = await _checkCrackedKeys(allKeys, sectorKeys,
          onProgress: (processed) {
        progress.value = '验证密钥：已验证 $processed/${allKeys.length} 把密钥...';
      });
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
      final writeKeys = await _collectVerifyKeys(uidHex: _app.card.uid);

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
          for (final keyStr in writeKeys) {
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
  Future<List<SectorKeyState>> _crackCard() async {
    final progress = ValueNotifier<String>('验证密钥：寻卡中...');
    final step = ValueNotifier<int>(0);
    final sectorKeys = List.generate(16, (s) => SectorKeyState(s));
    final crackTick = ValueNotifier<int>(0);
    final hardnestedNotifier = ValueNotifier<bool>(false);
    var crackUidHex = '';
    NativeRecovery.init();
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final tag = tags.first;
      if (tag.sakHex != '08') {
        _toast('发现非标准M1卡，该卡无法破解');
        return sectorKeys;
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
      crackUidHex = tag.uidHex;

      if (_dictKeys.isEmpty) {
        _toast('请先填写密钥');
        return sectorKeys;
      }

      if (!mounted) return sectorKeys;
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
          cancelText: '停止',
          hardnested: hardnestedNotifier,
        ),
      );

      // 验证密钥：尝试 Gen1a 免密读卡（对齐小程序 btnCrack：单次授权连续读 16 个 b3，读到即标记）
      try {
        progress.value = '验证密钥：发现UID卡，可免密读卡...';
        LogService.instance.log(
            '[解卡] Gen1a免密读卡可用(UID魔改卡, 无漏洞限制, 直接读全部密钥)');
        final found = <String>[];
        final trailers = List<Uint8List?>.filled(16, null);
        var allRead = false;
        try {
          await _dev.mf1Gen1aReadAllTrailerKeys(trailers,
              onSector: (s) => progress.value = '破解密钥：正在解密扇区$s...');
          allRead = true;
        } catch (e) {
          final readCount = trailers.where((t) => t != null).length;
          LogService.instance.log(
              '[解卡] Gen1a后门读卡中断: $e, 已读$readCount/16扇区, 落常规流程');
          if (readCount == 0 && '$e'.contains('failed 1')) {
            progress.value = '验证密钥：Gen1a后门无响应, 若反复失败请将卡离开读卡器5秒后重放';
          }
        }
        for (var s = 0; s < 16; s++) {
          checkStop();
          final t = trailers[s];
          if (t == null) continue;
          // 对齐小程序：b3 读出的即为卡上真实密钥，读到直接标记扇区恢复
          final kA = _hexStr(t.sublist(0, 6));
          final kB = _hexStr(t.sublist(10, 16));
          sectorKeys[s].hasKeyA = true;
          sectorKeys[s].keyA = kA;
          sectorKeys[s].hasKeyB = true;
          sectorKeys[s].keyB = kB;
          found.add(kA);
          found.add(kB);
          LogService.instance.log('[解卡] Gen1a后门读扇区$s: A=$kA B=$kB');
        }
        if (found.isNotEmpty) {
          _appendKeys(found);
        }
        if (allRead) {
          progress.value = '破解密钥：破解成功';
          if (mounted) Navigator.of(context).pop();
          _toast('破解成功');
          return sectorKeys;
        }
      } catch (_) {}

      // 加密嵌套检测：判断是否为第三代无漏洞卡（对齐小程序）
      // 先 0x64 后门认证快速初筛（对齐 CU mfClassicHasBackdoor）：
      // 普通卡无响应直接跳过采集，命中再做采集区分 3gen（ntEnc 静态）/后门卡（动态）
      progress.value = '破解密钥：检测第三代无漏洞卡...';
      Mf1AcquireStaticEncryptedNestedDecoder? encNested;
      Mf1AcquireStaticEncryptedNestedDecoder? backdoorAcq;
      final hasBackdoor = await _dev.mf1HasBackdoor();
      if (hasBackdoor) {
        for (final sk in _backdoorKeys) {
          try {
            final n1 = await _dev.cmdMf1AcquireStaticEncryptedNested(
                key: _hex(sk));
            final n2 = await _dev.cmdMf1AcquireStaticEncryptedNested(
                key: _hex(sk));
            if (n1.atks.isNotEmpty && n2.atks.isNotEmpty) {
              if (n1.atks.first.$4 == n2.atks.first.$4) {
                encNested = n1;
              } else {
                backdoorAcq = n1;
                LogService.instance.log(
                    '[解卡] 后门卡检测: 采集成功但ntEnc动态($sk), 走backdoor恢复路径');
              }
            }
            break;
          } catch (_) {}
        }
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

        // 候选验证（对齐 CU checkKeysOnSector：逐扇区 x A/B 批量验证）
        Future<void> verifyKeys(List<int> cands) async {
          if (cands.isEmpty) return;
          LogService.instance.log('[_crackCard] 3gen verify candidates=${cands.length}');
          for (var s = 0; s < 16; s++) {
            checkStop();
            if (!sectorKeys[s].hasKeyA) {
              final f = await _verifyCandidates(s, 2, cands);
              if (f != null) {
                sectorKeys[s].hasKeyA = true;
                sectorKeys[s].keyA = f;
              }
            }
            if (!sectorKeys[s].hasKeyB) {
              final f = await _verifyCandidates(s, 1, cands);
              if (f != null) {
                sectorKeys[s].hasKeyB = true;
                sectorKeys[s].keyB = f;
              }
            }
          }
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
        return sectorKeys;
      }

      // 后门卡前置路由（对齐 CU recoverKeys 开头 mfClassicHasBackdoor）：
      // 采集 ntEnc 动态即后门卡，当场识别路由，跳过 Darkside 数分钟弯路
      if (backdoorAcq != null && backdoorAcq.atks.isNotEmpty) {
        LogService.instance.log(
            '[解卡] 前置探测: 后门采集成功(ntEnc动态), 识别为后门卡, 尝试后门key认证');
        String? backdoorHit;
        for (final sk in _backdoorKeys) {
          checkStop();
          if (await _dev.cmdMf1CheckBlockKey(
              block: 0, keyType: KeyType.keyA, key: _hex(sk))) {
            backdoorHit = sk;
            break;
          }
        }
        if (backdoorHit != null) {
          LogService.instance.log(
              '[解卡] 后门key=$backdoorHit 普通认证命中扇区0 keyA, 走常规流程(字典+PRNG分型)');
          sectorKeys[0].hasKeyA = true;
          sectorKeys[0].keyA = backdoorHit;
          _appendKeysFromSectors(sectorKeys);
          await _propagateKeys(sectorKeys);
          crackTick.value++;
          // 不 return，落到下方字典检查与 PRNG 分型常规流程
        } else {
          // 真加密后门卡（后门 key 非真 key）：对齐 CU recovery.dart:314，
          // WEAK 时用 0x64 后门认证采集嵌套走 nested，比静态加密恢复精准
          final uidInt = _bytesInt(backdoorAcq.uid.sublist(0, 4));
          final prng = await _dev.cmdMf1TestPrngType();
          if (prng == 1) {
            LogService.instance.log(
                '[解卡] 后门key认证未命中, WEAK卡走0x64后门认证nested(对齐CU backdoor nested)');
            progress.value = '破解密钥：后门卡弱随机嵌套攻击...';
            String? rec;
            try {
              rec = await _crackSectorKey(
                  uidInt, 0, KeyType.keyA, 1,
                  0, KeyType.keyA, _backdoorKeys.first,
                  progress: progress, checkStop: checkStop,
                  authKeyType: KeyType.backdoor);
            } catch (_) {}
            if (rec != null) {
              LogService.instance.log(
                  '[解卡] 0x64后门nested恢复扇区0 keyA=$rec, 走常规流程');
              sectorKeys[0].hasKeyA = true;
              sectorKeys[0].keyA = rec;
              _appendKeysFromSectors(sectorKeys);
              await _propagateKeys(sectorKeys);
              crackTick.value++;
              // 不 return，落到下方字典检查与 PRNG 分型常规流程
            } else {
              LogService.instance.log(
                  '[解卡] 0x64后门nested未恢复, 走backdoor静态加密恢复');
              await _crackBackdoorNested(
                  acq: backdoorAcq,
                  sectorKeys: sectorKeys,
                  progress: progress,
                  crackTick: crackTick,
                  checkStop: checkStop);
              if (mounted) Navigator.of(context).pop();
              return sectorKeys;
            }
          } else {
            LogService.instance.log(
                '[解卡] 后门key认证未命中, 走backdoor静态加密恢复');
            await _crackBackdoorNested(
                acq: backdoorAcq,
                sectorKeys: sectorKeys,
                progress: progress,
                crackTick: crackTick,
                checkStop: checkStop);
            if (mounted) Navigator.of(context).pop();
            return sectorKeys;
          }
        }
      }

      // 验证密钥：验证中...
      step.value = 0;
      progress.value = '验证密钥：验证中...';

      // 断点续破（对齐小程序破解任务）：同 UID 且字典一致时恢复上次进度
      // 验证集合=编辑框+本卡密钥文件+扩展字典（不使用 default_keys.txt
      // 与其他卡密钥文件，密钥体系按 UID 隔离）
      final dictKeysHex = await _collectVerifyKeys(uidHex: tag.uidHex);
      for (final k in kExtendedKeys) {
        if (!dictKeysHex.contains(k)) dictKeysHex.add(k);
      }
      var dictStart = 0;
      final resume = await _app.storage.getCrackResume();
      if (resume != null &&
          resume['uidHex'] == tag.uidHex &&
          (resume['dictKeys'] as List?)?.join(',') == dictKeysHex.join(',')) {
        final idx = (resume['dictIndex'] as int?) ?? 0;
        if (idx > 0 && idx <= dictKeysHex.length) {
          dictStart = idx;
          final skList = (resume['sectorKeys'] as List?) ?? [];
          for (var s = 0; s < 16 && s < skList.length; s++) {
            final a = (skList[s] as List)[0] as String?;
            final b = (skList[s] as List)[1] as String?;
            if (a != null && a.isNotEmpty) {
              sectorKeys[s].hasKeyA = true;
              sectorKeys[s].keyA = a;
            }
            if (b != null && b.isNotEmpty) {
              sectorKeys[s].hasKeyB = true;
              sectorKeys[s].keyB = b;
            }
          }
          LogService.instance.log(
              '[解卡] 发现相同破解任务, 已恢复进度: 字典$dictStart/${dictKeysHex.length}');
          progress.value = '验证密钥：已恢复上次破解进度...';
        }
      }
      // 恢复即删（对齐小程序 removeStorage），之后逐块写回
      await _app.storage.clearCrackResume();

      // 验证密钥：批量检测扇区密钥（对齐小程序 checkCrackedKey，含扩展字典）
      // 逐块（32 把）点亮：每块命中即标记扇区状态并回填编辑区，刷新网格并保存断点
      final allKeys = dictKeysHex.sublist(dictStart).map(_hex).toList();
      bool anyMissing;
      if (allKeys.isEmpty) {
        // 断点已恢复到字典末尾（上轮跑完）：无密钥可验，跳过空转的固件命令
        LogService.instance.log('[解卡] 字典断点已在末尾, 跳过批量验证');
        anyMissing = sectorKeys.any((sk) => !sk.hasKeyA || !sk.hasKeyB);
      } else {
        anyMissing = await _checkCrackedKeys(allKeys, sectorKeys,
            onProgress: (processed) {
          // 批量验证按 32 把/块(约31s)推进，块返回即检查停止，
          // 停止请求后最多再等一个块即可中断，而非跑完全部字典
          checkStop();
          // 大字典逐块验证，实时反馈进度并点亮已恢复扇区
          progress.value = '验证密钥：已验证 $processed/${allKeys.length} 把密钥...';
          _appendKeysFromSectors(sectorKeys);
          crackTick.value++;
          _app.storage.saveCrackResume({
            'uidHex': tag.uidHex,
            'dictIndex': dictStart + processed,
            'dictKeys': dictKeysHex,
            'sectorKeys': [
              for (final sk in sectorKeys)
                [sk.hasKeyA ? sk.keyA : null, sk.hasKeyB ? sk.keyB : null]
            ],
          });
        });
      }
      crackTick.value++;
      progress.value = '验证密钥：已标记扇区密钥信息.';

      // 检查是否全部已破解
      if (!anyMissing) {
        _appendKeysFromSectors(sectorKeys);
        await _app.storage.clearCrackResume();
        step.value = 1;
        progress.value = '解卡片：破解成功，已重新标记密钥信息.';
        if (mounted) Navigator.of(context).pop();
        _toast('破解成功！');
        return sectorKeys;
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

      // 全加密卡：Darkside 攻击块0 keyA
      // C 库可用（对齐 CU 官方）：前置探测(syncMax=2) → 5次样本累积(syncMax=15)
      // → PM3 nonce2key C 恢复 → 候选上卡验证
      // C 库不可用（回退小程序 hS.darkside 移植算法）：256轮逐条采集+JS式恢复
      if (eSector == -1) {
        progress.value = '破解密钥：发现全加密卡，检测Darkside漏洞...';
        try {
          int? darkKey;
          if (NativeRecovery.available) {
            // 前置探测（对齐小程序 Crack：Darkside 采集用 syncMax 默认 30，
            // 非 CU 的 syncMax=2——CUID 国产卡 NT 固定常需更多同步，syncMax=2
            // 采样不足会误判 cantFixNT/notSendingNACK 而退出）
            final probe = await _dev.cmdMf1AcquireDarkside(
                block: 0, keyType: KeyType.keyA, isFirst: true);
            // status 枚举（对齐 CU DarksideResult）：
            // 0=vulnerable 1=cantFixNT 2=luckyAuthOK 3=notSendingNACK 4=tagChanged
            if (probe.status != 0) {
              LogService.instance.log(
                  '[解卡] Darkside探测 status=${probe.status} (0=vulnerable)');
              throw DeviceException(
                  -1,
                  switch (probe.status) {
                    1 => '该卡片无法固定NT(CANT_FIX_NT), Darkside不可用',
                    2 => 'LUCKY_AUTH_OK',
                    3 => '该卡片不发送NAK(NO_NAK_SENT), Darkside不可用',
                    4 => '卡片响应变化(TAG_CHANGED)',
                    _ => '该卡片为无漏洞全加密卡，请使用侦测功能获取密钥',
                  });
            }
            // 样本累积攻击（对齐 CU recovery.dart:281 tries<5，每条 syncMax=15）
            final items = <({int nt1, int ks1, int par, int nr, int ar})>[];
            int be(List<int> b) {
              var v = 0;
              for (final x in b) {
                v = (v << 8) | (x & 0xFF);
              }
              return v;
            }
            for (var t = 0; t < 5 && darkKey == null; t++) {
              checkStop();
              progress.value = '破解密钥：Darkside攻击中 采集样本${t + 1}/5...';
              final res = await _dev.cmdMf1AcquireDarkside(
                  block: 0, keyType: KeyType.keyA, isFirst: t == 0, syncMax: 15);
              if (res.status != 0 || res.uid == null) {
                LogService.instance.log(
                    '[解卡] Darkside采集失败样本${t + 1} status=${res.status}');
                throw DeviceException(
                    -1, 'Darkside采集失败 (status=${res.status})');
              }
              // 大端组装（对齐 CU bytesToU32/bytesToU64 字段序 uid/nt1/par/ks1/nr/ar）
              items.add((
                nt1: be(res.nt!),
                ks1: be(res.ks!),
                par: be(res.par!),
                nr: be(res.nr!),
                ar: be(res.ar!),
              ));
              final keys = await NativeRecovery.darkside(
                  uid: uidInt, items: items);
              LogService.instance.log(
                  '[解卡] Darkside C库恢复 ${items.length}条样本, 候选${keys.length}个');
              for (final k in keys) {
                checkStop();
                final khex = _int6Hex(k);
                final ok = await _dev.cmdMf1CheckBlockKey(
                    block: 0, keyType: KeyType.keyA, key: _hex(khex));
                if (ok) {
                  darkKey = k;
                  LogService.instance.log(
                      '[解卡] Darkside候选验证命中 key=$khex (样本${items.length}条)');
                  break;
                }
              }
            }
            if (darkKey == null) {
              throw DeviceException(-1,
                  'Darkside攻击穷尽5条样本未破出密钥, 卡片可能防Darkside');
            }
          } else {
            darkKey = await Crypto1.darkside(
              (isFirst) async {
                checkStop();
                // isFirst 实为轮次索引(l)，0 时为首轮(isFirst=true)
                progress.value =
                    '破解密钥：Darkside攻击中 第${isFirst + 1}/256轮...';
                if (isFirst % 16 == 0) {
                  LogService.instance.log('[解卡] Darkside采集轮${isFirst + 1}');
                }
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
                // 对齐小程序采集cb：status枚举 OK=0/CANT_FIX_NT=1/LUCKY_AUTH_OK=2/
                // NO_NAK_SENT=3/TAG_CHANGED=4，非OK单轮即终止（单轮失败即无漏洞卡，
                // 重试无意义），LUCKY_AUTH_OK 幸运碰撞数据同样不可用
                LogService.instance.log(
                    '[解卡] Darkside采集失败轮${isFirst + 1} status=${res.status} (0=OK, 2=LUCKY_AUTH_OK)');
                if (res.status == 2) {
                  throw DeviceException(-1, 'LUCKY_AUTH_OK');
                }
                throw DeviceException(
                    -1, '该卡片为无漏洞全加密卡，请使用侦测功能获取密钥 (status=${res.status})');
              },
              (key) async {
                final ok = await _dev.cmdMf1CheckBlockKey(
                    block: 0, keyType: KeyType.keyA, key: key);
                if (ok) {
                  LogService.instance.log(
                      '[解卡] Darkside候选验证命中 key=${_hexStr(key)}');
                }
                return ok;
              },
            );
          }
          final darkHex = _int6Hex(darkKey!);
          sectorKeys[0].hasKeyA = true;
          sectorKeys[0].keyA = darkHex;
          eSector = 0;
          eKeyType = KeyType.keyA;
          eKeyHex = darkHex;
          _appendKeysFromSectors(sectorKeys);
          await _propagateKeys(sectorKeys);
          crackTick.value++;
          progress.value = '破解密钥：破解出一个密钥，进入半加密卡破解流程...';
          LogService.instance.log(
              '[解卡] 全加密卡Darkside攻击成功, 恢复扇区0 keyA=$darkHex, 进入半加密流程');
        } catch (e) {
          // 透传具体失败原因（对齐小程序 catch 显示采集cb的报错）：
          // 无漏洞卡/卡无响应/LUCKY_AUTH_OK/256轮穷尽各自可见
          LogService.instance.log('[解卡] Darkside异常: $e');
          _appendKeysFromSectors(sectorKeys);
          // 诊断卡 PRNG 类型，辅助判断是否因 syncMax/采样问题误判
          try {
            final dp = await _dev.cmdMf1TestPrngType();
            LogService.instance.log('[解卡] Darkside失败后 PRNG分型=$dp (0=static 1=weak 2=hard)');
          } catch (_) {}
          // 后门卡已在开头前置路由（对齐 CU recoverKeys），此处仅剩无后门的全加密卡
          progress.value = '解卡片：$e';
          if (mounted) Navigator.of(context).pop();
          _toast('Darkside攻击失败: $e\n若卡曾被反复认证, 请离开读卡器10秒后重放再试');
          return sectorKeys;
        }
      }

      // 解卡片：逐扇区破解（对齐小程序 Crack()）
      step.value = 1;
      final prng = await _dev.cmdMf1TestPrngType();

      if (prng >= 2) {
        progress.value = '解卡片：该卡片为国产兼容卡\n正在本地Hardnested破解...';
        LogService.instance.log(
            '[解卡] HARD卡进入本地Hardnested流程(纯本地计算, 无云端)');
        await _crackHardnestedLocal(
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
        return sectorKeys;
      }

      // WEAK 卡手动勾选 Hardnested 本地破解（对齐小程序 c_modal.Crack_hardnested）
      if (hardnestedNotifier.value) {
        LogService.instance.log('[_crackCard] WEAK hardnested local mode');
        await _crackHardnestedLocal(
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
        return sectorKeys;
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
      // 本次解卡得到的密钥（扇区状态中已破解的 keyA/keyB）
      final gainedKeys = <String>[];
      for (final sk in sectorKeys) {
        if (sk.hasKeyA && sk.keyA.length == 12 && !gainedKeys.contains(sk.keyA)) {
          gainedKeys.add(sk.keyA);
        }
        if (sk.hasKeyB && sk.keyB.length == 12 && !gainedKeys.contains(sk.keyB)) {
          gainedKeys.add(sk.keyB);
        }
      }
      // 解卡得到的密钥写入密钥编辑框（幂等去重，兜底各分支的实时回填）
      if (gainedKeys.isNotEmpty) _appendKeysFromSectors(sectorKeys);
      // 命中密钥同时累积进 default_keys.txt（跨卡累积库，不参与验证集合）
      await _appendKeysToDefaultFile(gainedKeys);
      // 仅当本次真正获得密钥时才保存该 UID 的密钥文件，且只存命中的密钥
      if (gainedKeys.isNotEmpty && crackUidHex.isNotEmpty) {
        await _autoSaveKeyFileForUid(crackUidHex, gainedKeys);
      }
    }
    return sectorKeys;
  }

  /// 对单个扇区恢复密钥（支持 keyA/keyB，对齐小程序 Crack() 逐扇区破解）
  Future<String?> _crackSectorKey(
      int uidInt, int sector, KeyType targetKeyType, int prng,
      int eSector, KeyType eKeyType, String eKeyHex,
      {ValueNotifier<String>? progress, void Function()? checkStop,
      KeyType? authKeyType}) async {
    void stop() => checkStop?.call();
    final eKey = _hex(eKeyHex);
    // WEAK 采集认证用的 keyType：后门卡传 0x64（对齐 CU backdoor nested），
    // 常规卡与 eKeyType 一致
    final acquireKeyType = authKeyType ?? eKeyType;
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
        return _verifyCandidates(sector, keyTypeBit, recovered);
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
      return _verifyCandidates(sector, keyTypeBit, candidates);
    }
    if (prng == 1) {
      // WEAK 嵌套：重试5次 + 暴力验证
      for (var retry = 0; retry < 5; retry++) {
        stop();
        LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry START');
        try {
          final distRes = await _dev.cmdMf1TestNtDistance(
              block: eSector * 4, keyType: acquireKeyType, key: eKey);
          LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry distRes.uid=${distRes.uid.length} dist=${distRes.dist.length}');
          final dist = _bytesInt(distRes.dist.sublist(0, 4));
          final nestedUid = _bytesInt(distRes.uid.sublist(0, 4));
          LogService.instance.log('[_crackSectorKey] sector=$sector $keyTypeStr WEAK retry=$retry dist=$dist nestedUid=$nestedUid');
          final nested = await _dev.cmdMf1AcquireNested(
              block: eSector * 4,
              keyType: acquireKeyType,
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
  /// 候选集验证单扇区（对齐 CU checkKeysOnSector：mf1CheckKeysOnBlock 单扇区
  /// 批量认证，chunkSize 对齐 CU BLE=32，目标为扇区 trailer 块）
  Future<String?> _verifyCandidates(
      int sector, int keyTypeBit, List<int> candidates,
      {int chunkSize = 32}) async {
    if (candidates.isEmpty) {
      LogService.instance.log('[_verifyCandidates] sector=$sector candidates empty');
      return null;
    }
    LogService.instance.log('[_verifyCandidates] sector=$sector candidates=${candidates.length} chunkSize=$chunkSize');
    final keyType = keyTypeBit == 2 ? KeyType.keyA : KeyType.keyB;
    final block = 4 * sector + 3; // trailer 块（对齐 CU mfClassicGetSectorTrailerBlockBySector）
    final keys = candidates
        .map((k) {
          final buf = Uint8List(6);
          final bd = ByteData.sublistView(buf);
          bd.setUint16(0, (k >> 32) & 0xFFFF, Endian.big);
          bd.setUint32(2, k & 0xFFFFFFFF, Endian.big);
          return buf;
        })
        .toList();
    for (var i = 0; i < keys.length; i += chunkSize) {
      final end = i + chunkSize < keys.length ? i + chunkSize : keys.length;
      final found = await _dev.cmdMf1CheckKeysOfBlock(
          block: block, keyType: keyType, keys: keys.sublist(i, end));
      if (found != null && found.length == 6) {
        LogService.instance.log('[_verifyCandidates] sector=$sector FOUND key=${_hexStr(found)}');
        return _hexStr(found);
      }
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

  /// parity 千位编码（CU parityToInt 语义）：bit3=最高字节 → 千位，
  /// C 端 bin_to_uint8_arr 按十进制逐位拆回
  int _parityToInt(int raw) =>
      ((raw >> 3) & 1) * 1000 +
      ((raw >> 2) & 1) * 100 +
      ((raw >> 1) & 1) * 10 +
      (raw & 1);


  /// 双卡破解（对齐小程序 Crack_with2cards：两张同系统不同UID的卡）
  /// 候选生成用 NativeRecovery.staticEncryptedNested（对齐后门恢复：
  /// nt16 补全 + lfsr_recovery32 多候选），双卡候选求交集后逐个验证
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
      final uid1Int = _bytesInt(uid1.sublist(0, 4));
      // 对齐小程序 Crack() 分流：STATIC 卡走 1 代分支，其余走后门通用分支
      final prngType = await _dev.cmdMf1TestPrngType();
      if (prngType == 0) {
        return _crackWith2Cards1Gen();
      }

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

      // 第一张卡：加密嵌套采集（后门 key，对齐小程序）
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
      final uid2Int = _bytesInt(uid2.sublist(0, 4));

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

      // 逐扇区：双卡候选密钥求交集后验证（对齐小程序 generate_keys + intersection）
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

      Future<void> crackSlot(int sector, KeyType keyType,
          (int, KeyType, int, int, int) atk1,
          (int, KeyType, int, int, int) atk2) async {
        // nt16 补全为完整 32 位明文 nt（对齐 _crackBackdoorNested/CU general.dart:89）
        int fullNt(int nt16) =>
            ((nt16 << 16) | Crypto1.prngSuccessor(nt16, 16)) & 0xFFFFFFFF;
        final (_, _, nt16a, ntEncA, parA) = atk1;
        final (_, _, nt16b, ntEncB, parB) = atk2;
        final nt1 = fullNt(nt16a);
        final nt2 = fullNt(nt16b);
        final cands1 = NativeRecovery.staticEncryptedNested(
            uid: uid1Int,
            nt: nt1,
            ntEnc: ntEncA,
            ntParEnc: _parityToInt(parA));
        final cands2 = NativeRecovery.staticEncryptedNested(
            uid: uid2Int,
            nt: nt2,
            ntEnc: ntEncB,
            ntParEnc: _parityToInt(parB));
        if (cands1.isEmpty || cands2.isEmpty) return;
        final set2 = cands2.toSet();
        final inter = cands1.where(set2.contains).toSet();
        if (inter.isEmpty) return;
        final block = sector * 4;
        for (final k in inter) {
          final keyHex = _int6Hex(k);
          final valid = await _dev.cmdMf1CheckBlockKey(
              block: block, keyType: keyType, key: _hex(keyHex));
          if (valid) {
            if (keyType == KeyType.keyA) {
              sectorKeys[sector].hasKeyA = true;
              sectorKeys[sector].keyA = keyHex;
            } else {
              sectorKeys[sector].hasKeyB = true;
              sectorKeys[sector].keyB = keyHex;
            }
            progress.value = '双卡破解：扇区$sector ${keyType.label}=$keyHex';
            break;
          }
        }
      }

      for (var s = 0; s < 16; s++) {
        if (sectorKeys[s].hasKeyA && sectorKeys[s].hasKeyB) continue;
        if (s * 2 + 1 >= enc1.atks.length || s * 2 + 1 >= enc2.atks.length) {
          break;
        }
        if (!sectorKeys[s].hasKeyA) {
          await crackSlot(s, KeyType.keyA, enc1.atks[s * 2], enc2.atks[s * 2]);
        }
        if (!sectorKeys[s].hasKeyB) {
          await crackSlot(
              s, KeyType.keyB, enc1.atks[s * 2 + 1], enc2.atks[s * 2 + 1]);
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

  /// 双卡破解 1 代静态卡分支（对齐小程序 Crack_with2cards_1gen）
  /// 以已知密钥扇区为采集源（ss.e_sector），staticnested 采集 nt1/nt2 +
  /// hardnested 采集 par，双卡候选求交集后验证
  Future<void> _crackWith2Cards1Gen() async {
    // 已知密钥扇区（对齐 ss.e_sector）：从当前卡片数据中找第一个有效密钥
    int eSector = -1;
    KeyType eKeyType = KeyType.keyA;
    String eKeyHex = '';
    for (var s = 0; s < 16; s++) {
      final b3 = _app.card.sectors[s].blocks[3].data;
      if (b3.length >= 32) {
        final keyA = b3.substring(0, 12);
        final keyB = b3.substring(20, 32);
        if (keyA != '000000000000' && keyA != 'ffffffffffff') {
          eSector = s;
          eKeyType = KeyType.keyA;
          eKeyHex = keyA;
          break;
        }
        if (keyB != '000000000000' && keyB != 'ffffffffffff') {
          eSector = s;
          eKeyType = KeyType.keyB;
          eKeyHex = keyB;
          break;
        }
      }
    }
    if (eSector == -1) {
      _toast('破解失败，发现全加密无漏洞卡，并且该卡无法使用"双卡破解"功能');
      return;
    }

    final progress = ValueNotifier<String>('双卡破解：正在读取第一张卡...');
    final step = ValueNotifier<int>(0);
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
      final uid1Int = _bytesInt(uid1.sublist(0, 4));

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

      // 采集单槽位：staticnested 出 nt1/nt2 + hardnested 出 par
      Future<(int, int, int)> acquireSlot(int sector, KeyType kt) async {
        final sn = await _dev.cmdMf1AcquireStaticNested(
            block: eSector * 4,
            keyType: eKeyType,
            key: _hex(eKeyHex),
            targetBlock: sector * 4,
            targetKeyType: kt);
        final hard = await _dev.cmdMf1AcquireHardNested(
            block: eSector * 4,
            keyType: eKeyType,
            key: _hex(eKeyHex),
            targetBlock: sector * 4,
            targetKeyType: kt);
        return (
          _bytesInt(sn.atks[0].$1),
          _bytesInt(sn.atks[0].$2),
          hard.isEmpty ? 0 : hard.first.par
        );
      }

      // 预检：1 代卡加密 nonce 固定（两次采集 nt2 一致，对齐小程序）
      final check = await _dev.cmdMf1AcquireStaticNested(
          block: eSector * 4,
          keyType: eKeyType,
          key: _hex(eKeyHex),
          targetBlock: 0,
          targetKeyType: KeyType.keyA);
      if (check.atks.length > 1 &&
          _hexStr(check.atks[0].$2) != _hexStr(check.atks[1].$2)) {
        throw DeviceException(1, '破解失败，请注意，只有第一、三代无漏洞卡支持双卡破解！');
      }

      // 卡1 逐扇区采集 keyA/keyB
      step.value = 0;
      final res1 = List.generate(16, (_) => <KeyType, (int, int, int)?>{});
      for (var s = 0; s < 16; s++) {
        for (final kt in [KeyType.keyA, KeyType.keyB]) {
          progress.value = '双卡破解：正在读取卡1，扇区$s ${kt.label}...';
          res1[s][kt] = await acquireSlot(s, kt);
        }
      }

      // 等待用户换卡（对齐小程序：100秒超时）
      progress.value = '双卡破解：请读取第二张卡...';
      Uint8List? uid2;
      for (var i = 0; i < 100; i++) {
        progress.value = '双卡破解：请读取第二张卡，用时${i}s...';
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
      final uid2Int = _bytesInt(uid2.sublist(0, 4));

      // 卡2 逐扇区采集 + 双卡候选交集验证
      step.value = 2;
      final sectorKeys = List.generate(16, (s) => SectorKeyState(s));
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

      for (var s = 0; s < 16; s++) {
        for (final kt in [KeyType.keyA, KeyType.keyB]) {
          final has = kt == KeyType.keyA
              ? sectorKeys[s].hasKeyA
              : sectorKeys[s].hasKeyB;
          if (has) continue;
          final a1 = res1[s][kt];
          if (a1 == null) continue;
          progress.value = '双卡破解：正在读取卡2，扇区$s ${kt.label}...';
          final a2 = await acquireSlot(s, kt);
          final cands1 = _generateKeysFromHardNested(uid1Int, a1.$1, a1.$2, a1.$3);
          final cands2 = _generateKeysFromHardNested(uid2Int, a2.$1, a2.$2, a2.$3);
          final set2 = cands2.toSet();
          final inter = cands1.where(set2.contains).toSet();
          for (final k in inter) {
            final keyHex = _int6Hex(k);
            final valid = await _dev.cmdMf1CheckBlockKey(
                block: s * 4, keyType: kt, key: _hex(keyHex));
            if (valid) {
              if (kt == KeyType.keyA) {
                sectorKeys[s].hasKeyA = true;
                sectorKeys[s].keyA = keyHex;
              } else {
                sectorKeys[s].hasKeyB = true;
                sectorKeys[s].keyB = keyHex;
              }
              progress.value = '双卡破解：扇区$s ${kt.label}=$keyHex';
              break;
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

  /// 读取该 UID 的历史密钥文件（KeyFor_XXXX.txt），无则返回空列表
  Future<List<String>> _loadKeyFileForUid(String uidHex) async {
    try {
      final all = await _app.storage.getKeyNames();
      final name = 'KeyFor_${uidHex.substring(0, 8).toUpperCase()}.txt';
      final content = all[name];
      if (content == null || content.isEmpty) return [];
      return content
          .split('\n')
          .map((e) => e.trim())
          .where((k) => k.length == 12)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 自动保存该 UID 的密钥文件：仅合并 [keys]（本次命中的密钥）与文件原有内容。
  /// 编辑框是用户自管内容（验证集合由 _collectVerifyKeys 临时构造），
  /// 直接取编辑框会把与本卡无关的密钥混入文件（下次读卡导入拖慢验证），故须显式传参
  Future<void> _autoSaveKeyFileForUid(String uidHex, List<String> keys) async {
    try {
      final list = keys.where((k) => k.length == 12).toList();
      if (list.isEmpty || !mounted) return;
      final name = 'KeyFor_${uidHex.substring(0, 8).toUpperCase()}.txt';
      final all = await _app.storage.getKeyNames();
      final savedContent = all[name] ?? '';
      final merged = <String>[];
      final lines = [savedContent, ...list];
      for (final line in lines) {
        final k = line.trim();
        if (k.length == 12 && !merged.contains(k)) {
          merged.add(k);
        }
      }
      if (merged.isEmpty) return;
      await _app.storage.saveKey(name, merged.join('\n'));
      LogService.instance.log('[密钥文件] 已自动保存 $name（${merged.length} 个密钥）');
    } catch (_) {}
  }

  /// 解卡得到的密钥累积保存进 default_keys.txt：
  /// 文件不存在则新建，已存在则合并追加，去重后写入
  /// （default_keys.txt 不参与按 UID 隔离的验证集合，仅作为跨卡累积库供手动导出/查阅）
  Future<void> _appendKeysToDefaultFile(List<String> keys) async {
    try {
      if (keys.isEmpty) return;
      const name = 'default_keys.txt';
      final all = await _app.storage.getKeyNames();
      final merged = <String>[
        ...(all[name] ?? '')
            .split('\n')
            .map((e) => e.trim())
            .where((k) => k.length == 12)
      ];
      var added = 0;
      for (final k in keys) {
        if (!merged.contains(k)) {
          merged.add(k);
          added++;
        }
      }
      if (added == 0) return;
      await _app.storage.saveKey(name, merged.join('\n'));
      LogService.instance.log('[密钥文件] default_keys.txt 新增 $added 个密钥（共 ${merged.length}）');
    } catch (_) {}
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

  /// 本地 Hardnested 破解（对齐小程序 Crack_hardnested）：
  /// 逐扇区采集 256 个去重 nt → native mfnestedhard 本地计算，纯本地无云端
  Future<void> _crackHardnestedLocal({
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
    // 纯本地 Hardnested：PM3 mfnestedhard 多线程计算，单目标分钟级
    // native 库不可用时无法进行 Hardnested 计算，直接结束
    if (!NativeRecovery.available) {
      LogService.instance.log(
          '[解卡] 本地Hardnested不可用: native计算库加载失败(需rebuild安装librecovery.so)');
      progress.value = '解卡片：本地计算库不可用，无法进行Hardnested破解';
      _toast('本地计算库不可用，请重新安装应用');
      return;
    }

    final missing = <String>[];
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
          }
        }
      }
    } on CrackStoppedException {
      rethrow;
    } catch (e) {
      LogService.instance.log('[解卡] 本地Hardnested异常=$e');
    }

    for (var s = 0; s < 16; s++) {
      if (!sectorKeys[s].hasKeyA || !sectorKeys[s].hasKeyB) {
        missing.add(
            '$s(${!sectorKeys[s].hasKeyA ? 'A' : ''}${!sectorKeys[s].hasKeyB ? 'B' : ''})');
      }
    }
    if (missing.isEmpty) {
      progress.value = '解卡片：破解成功，已重新标记密钥信息.';
      _toast('破解成功');
    } else {
      LogService.instance.log(
          '[解卡] 本地Hardnested结束, 未破扇区: ${missing.join(', ')} (计算未找到密钥或采集质量差, 各扇区原因见上方[解卡]日志)');
      progress.value = '解卡片：本地破解完成，部分扇区密钥未找到';
      _toast('部分扇区密钥未找到（已写入找到的密钥）');
    }
  }

  /// 后门卡恢复（对齐 CU NTLevel.backdoor 分支）：
  /// 后门采集的每条 (nt16, parErr, ntEnc) 重建明文 NT（reconstructFullNt），
  /// 用 C 库 lfsr_recovery32 恢复候选 key 后固件批量验证。
  /// 无需已知密钥，对 weak/hard PRNG 后门卡均有效（Darkside 失败时的兜底路径）
  Future<void> _crackBackdoorNested({
    required Mf1AcquireStaticEncryptedNestedDecoder acq,
    required List<SectorKeyState> sectorKeys,
    required ValueNotifier<String> progress,
    required ValueNotifier<int> crackTick,
    required void Function() checkStop,
  }) async {
    if (!NativeRecovery.available) {
      LogService.instance.log('[解卡] 后门恢复不可用: native计算库加载失败');
      _toast('本地计算库不可用，请重新安装应用');
      return;
    }
    final uidInt = _bytesInt(acq.uid.sublist(0, 4));

    // reconstNamedNt：后门采集仅含 NT 高 16 位，低 16 位由 PRNG 线性特性补全
    // （CU general.dart:89 同公式）
    int fullNt(int nt16) =>
        ((nt16 << 16) | Crypto1.prngSuccessor(nt16, 16)) & 0xFFFFFFFF;

    // 按扇区聚合 A/B 的 (nt, ntEnc, rawPar)
    final bySector = <int, Map<int, (int, int, int)>>{};
    for (final a in acq.atks) {
      final (sector, keyType, nt16, ntEnc, rawPar) = a;
      bySector.putIfAbsent(sector, () => <int, (int, int, int)>{})
        [keyType == KeyType.keyA ? 0 : 1] = (fullNt(nt16), ntEnc, rawPar);
    }

    // 候选约 3.5 万 -> 对齐 CU filterKeys 先做 A/B seednt 交集过滤压到可验证规模
    for (final e in bySector.entries) {
      checkStop();
      final sector = e.key;
      final ab = e.value;
      final hasA = sectorKeys[sector].hasKeyA;
      final hasB = sectorKeys[sector].hasKeyB;
      if (hasA && hasB) continue;
      final ntA = ab[0];
      final ntB = ab[1];
      final candsA = ntA != null
          ? NativeRecovery.staticEncryptedNested(
              uid: uidInt,
              nt: ntA.$1,
              ntEnc: ntA.$2,
              ntParEnc: _parityToInt(ntA.$3))
          : const <int>[];
      final candsB = ntB != null
          ? NativeRecovery.staticEncryptedNested(
              uid: uidInt,
              nt: ntB.$1,
              ntEnc: ntB.$2,
              ntParEnc: _parityToInt(ntB.$3))
          : const <int>[];
      LogService.instance.log(
          '[解卡] 后门恢复 扇区$sector: A候选=${candsA.length} B候选=${candsB.length}');
      // A/B 均有且都未解时用 seednt 交集过滤（CU filterKeys）
      List<int> keysA = candsA;
      List<int> keysB = candsB;
      if (ntA != null && ntB != null && !hasA && !hasB) {
        final f = Crypto1.filterBackdoorKeys(candsA, candsB, ntA.$1, ntB.$1);
        keysA = f.$1;
        keysB = f.$2;
        LogService.instance.log(
            '[解卡] 后门恢复 扇区$sector: filterKeys后 A=${keysA.length} B=${keysB.length}');
      }
      // 上卡批量验证（对齐 CU checkKeysOnSector）；缺对侧/已解一侧时单侧验证
      const chunk = 500;
      for (final entry in [(0, hasA, keysA), (1, hasB, keysB)]) {
        checkStop();
        final pair = entry;
        if (pair.$2) continue;
        final cands = pair.$3;
        if (cands.isEmpty) continue;
        progress.value =
            '解卡片：后门恢复扇区$sector ${pair.$1 == 0 ? 'keyA' : 'keyB'}...';
        final keys = <Uint8List>[];
        for (final k in cands) {
          final b = Uint8List(6);
          var v = k;
          for (var i = 5; i >= 0; i--) {
            b[i] = v & 0xFF;
            v >>= 8;
          }
          keys.add(b);
        }
        for (var i = 0; i < keys.length; i += chunk) {
          checkStop();
          await _checkCrackedKeys(
              keys.sublist(i, (i + chunk).clamp(0, keys.length)), sectorKeys);
        }
        crackTick.value++;
        _appendKeysFromSectors(sectorKeys);
      }
    }
    final missing = <String>[];
    for (var s = 0; s < 16; s++) {
      if (!sectorKeys[s].hasKeyA || !sectorKeys[s].hasKeyB) {
        missing.add(
            '$s(${!sectorKeys[s].hasKeyA ? 'A' : ''}${!sectorKeys[s].hasKeyB ? 'B' : ''})');
      }
    }
    if (missing.isEmpty) {
      progress.value = '解卡片：破解成功，已重新标记密钥信息.';
      _toast('破解成功');
    } else {
      LogService.instance.log(
          '[解卡] 后门恢复完成, 未破: ${missing.join(', ')} (候选验证失败, 见上方[解卡]日志)');
      progress.value = '解卡片：后门恢复完成，部分扇区密钥未找到';
      _toast('部分扇区密钥未找到（已写入找到的密钥）');
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
          '[解卡] 扇区$sector ${targetType.label}: 本地Hardnested计算未找到密钥(候选空间缩减不足或采集质量差), 该扇区放弃');
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

  // ========== 算密钥（mfkey32v2，对齐小程序 btnRecover + btnRecoverHard） ==========
  Future<void> _mfkey() async {
    ValueNotifier<String>? progress;
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);

      // 第一步：读取侦测数据（对齐小程序：count 预检 + 分批拉取全部日志）
      final count = await _dev.cmdMf1GetDetectionCount();
      if (count < 2) {
        throw Exception(
            '侦测数据不足，请将设备当做门禁卡至门禁处刷卡，刷卡不少于两次\n（次数越多成功率越高，次数过多会增加计算时间）');
      }
      if (!mounted) return;
      progress = ValueNotifier<String>('读取数据： 0 / $count');
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => CrackProgressDialog(
            title: '算密钥...', progress: progress, onCancel: null),
      );
      final logs = <Mf1DetectionLog>[];
      while (logs.length < count) {
        logs.addAll(await _dev.cmdMf1GetDetectionLogs(logs.length));
        progress.value = '读取数据： ${logs.length} / $count';
      }

      // 第二步：按 uid-block-keyType 分组（对齐小程序 groupBy）
      final groups = <String, List<Mf1DetectionLog>>{};
      for (final l in logs) {
        groups
            .putIfAbsent(
                '${_hexStr(l.uid)}-${l.block}-${l.isKeyB ? 1 : 0}', () => [])
            .add(l);
      }

      // 第三步：普通计算（每组前两条）→ 强力计算（仍未解出的组内两两配对）
      int? mfkeyOnce(Mf1DetectionLog a, Mf1DetectionLog b) {
        final keys = Crypto1.mfkey32v2(
          uid: _bytesInt(a.uid.sublist(0, 4)),
          nt0: _bytesInt(a.nt),
          nr0: _bytesInt(a.nr),
          ar0: _bytesInt(a.ar),
          nt1: _bytesInt(b.nt),
          nr1: _bytesInt(b.nr),
          ar1: _bytesInt(b.ar),
        );
        return keys.isEmpty ? null : keys.first;
      }

      final added = <String>[];
      final unsolved = <List<Mf1DetectionLog>>[];
      var done = 0;
      progress.value = '计算密钥： 0 / ${groups.length}';
      for (final g in groups.values) {
        try {
          if (g.length >= 2) {
            final k = mfkeyOnce(g[0], g[1]);
            if (k != null) {
              added.add(_int6Hex(k));
            } else {
              unsolved.add(g);
            }
          } else {
            unsolved.add(g);
          }
        } catch (_) {
          unsolved.add(g);
        }
        done++;
        progress.value = '计算密钥： $done / ${groups.length}';
      }
      // 强力计算（对齐小程序 btnRecoverHard：组内两两全配对）
      if (unsolved.isNotEmpty) {
        progress.value = '强力计算： 0 / ${unsolved.length}';
        var hardDone = 0;
        for (final g in unsolved) {
          outer:
          for (var i = 0; i < g.length; i++) {
            for (var j = i + 1; j < g.length; j++) {
              if (i == 0 && j == 1) continue; // 普通计算已试过
              try {
                final k = mfkeyOnce(g[i], g[j]);
                if (k != null) {
                  added.add(_int6Hex(k));
                  break outer;
                }
              } catch (_) {}
            }
          }
          hardDone++;
          progress.value = '强力计算： $hardDone / ${unsolved.length}';
        }
      }
      if (mounted) Navigator.of(context).pop();

      // 第四步：去重回填密钥区头部（对齐 ss.keys = key + "\n" + keys）
      if (added.isEmpty) {
        _toast('未计算出密钥');
        return;
      }
      final uniq = <String>[];
      for (final k in added) {
        if (!uniq.contains(k)) uniq.add(k);
      }
      final fresh =
          uniq.where((k) => !_keys.contains(k)).toList();
      if (fresh.isEmpty) {
        _toast('算得密钥均已存在');
        return;
      }
      if (!mounted) return;
      setState(() {
        _keyCtrl.text = '${fresh.reversed.join('\n')}\n${_keyCtrl.text}';
        _app.card.keys = _keyCtrl.text;
        _validateKeys(_keyCtrl.text);
      });
      _toast('算得密钥：${fresh.length} 个');
    } catch (e) {
      if (mounted && progress != null) Navigator.of(context).pop();
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
                  _formatCard();
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
                  _lockUfuidFlow();
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
            const Divider(height: 1),
            ListTile(
                leading: const Icon(Icons.analytics_outlined),
                title: const Text('电梯卡分析'),
                subtitle: const Text('云端分析电梯卡数据结构'),
                onTap: () {
                  Navigator.pop(ctx);
                  _liftAnalyze();
                }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 通用卡操作包装（连接检查 + 进度）
  Future<bool> _runChip(Future<void> Function() task,
      {String successText = '操作完成'}) async {
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
      _toast(successText);
      return true;
    } catch (e) {
      _toast('操作失败: $e');
      return false;
    }
  }

  /// 锁 UFUID 流程（对齐 2.8.3 lockUFUID）：先检测（只读不写）→ 通过后二次确认 → 锁定
  Future<void> _lockUfuidFlow() async {
    final askDetect = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确定要检测UFUID卡吗？', style: TextStyle(fontSize: 16)),
        content: const Text(
            '即将检测该卡是否支持UFUID卡锁卡指令，继续吗?\n'
            'tips.1 UFUID卡锁定前功能和UID卡一致.\n'
            'tips.2 UFUID卡锁定后变成普通卡,且操作不可逆.\n'
            'tips.3 UFUID卡锁定需二次确认,请放心操作.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (askDetect != true || !mounted) return;
    final detected = await _runChip(_dev.detectUfuid,
        successText: '检测通过：该卡为UFUID卡');
    if (!detected || !mounted) return;
    final askLock = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确定要锁定UFUID吗？', style: TextStyle(fontSize: 16)),
        content: const Text(
            '发现UFUID卡,即将锁定该卡,继续吗?\n'
            'tips.1 UFUID卡锁定前功能和UID卡一致.\n'
            'tips.2 UFUID卡锁定后变成普通卡,且操作不可逆.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (askLock != true || !mounted) return;
    await _runChip(_dev.lockUfuid, successText: 'lockUFUID 成功');
  }

  // ========== 格式化 ==========
  Future<void> _formatCard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('格式化卡片', style: TextStyle(fontSize: 16)),
        content: const Text('将擦除全部扇区数据（保留 UID），操作不可恢复。确认执行？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    await _dev.assureDeviceMode(DeviceMode.reader);
    // 优先 Gen1a 后门免密格式化（UID 卡）
    try {
      await _dev.formatCard();
      _toast('格式化完成');
      return;
    } on DeviceException {
      // 非 UID 卡后门失败 → 解卡后常规认证写擦除
    }
    // 解卡（内部自带进度弹窗，密钥最终写入编辑框），直接取破解结果
    final cracked = await _crackCard();
    final keys = <int, (Uint8List?, Uint8List?)>{};
    for (final sk in cracked) {
      final a = (sk.hasKeyA &&
              sk.keyA.length == 12 &&
              sk.keyA != 'ffffffffffff' &&
              sk.keyA != '000000000000')
          ? _hex(sk.keyA)
          : null;
      final b = (sk.hasKeyB &&
              sk.keyB.length == 12 &&
              sk.keyB != 'ffffffffffff' &&
              sk.keyB != '000000000000')
          ? _hex(sk.keyB)
          : null;
      if (a != null || b != null) keys[sk.sector] = (a, b);
    }
    if (keys.isEmpty) {
      // 兜底：从编辑框密钥逐扇区实测认证（Gen1a 免密读路径等未填扇区状态）
      final lines = _keyCtrl.text
          .split('\n')
          .map((l) => l.trim().toLowerCase())
          .where((l) => l.length == 12 && RegExp(r'^[0-9a-f]+$').hasMatch(l))
          .toSet()
          .toList();
      if (lines.isEmpty) {
        _toast('解卡未获得密钥，无法格式化加密卡');
        return;
      }
      final progress = ValueNotifier<String>('验证密钥：验证中...');
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => CrackProgressDialog(
            title: '验证密钥...',
            progress: progress,
            onCancel: null,
          ),
        );
      }
      final keyBytes = lines.map(_hex).toList();
      for (var s = 0; s < 16; s++) {
        progress.value = '验证密钥：扇区$s/16...';
        final hit = await _dev.mf1CheckSectorKeys(s, keyBytes);
        final pair = (hit[KeyType.keyA.value], hit[KeyType.keyB.value]);
        if (pair.$1 != null || pair.$2 != null) keys[s] = pair;
      }
      if (mounted) Navigator.of(context).pop();
    }
    if (keys.isEmpty) {
      _toast('解卡未获得密钥，无法格式化加密卡');
      return;
    }
    // 常规认证写擦除：数据块清零，block3 重置默认 ACL+密钥（block0 只读跳过）
    // 单块失败（ACL 限制 keyType 无写权限等）换另一把密钥重试，仍失败则跳过继续
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const CrackProgressDialog(
        title: '格式化中...',
        onCancel: null,
      ),
    );
    final failedBlocks = <int>[];
    try {
      const empty = '00000000000000000000000000000000';
      const acl = 'ffffffffffffff078069ffffffffffff';
      for (final e in keys.entries) {
        final s = e.key;
        final (ka, kb) = e.value;
        for (var b = 0; b < 4; b++) {
          final block = s * 4 + b;
          if (block == 0) continue;
          final data = b == 3 ? acl : empty;
          // 传输配置（ff0780）下 trailor 仅 keyA 可写，keyA 优先
          final tryKeys = <(KeyType, Uint8List)>[
            if (ka != null) (KeyType.keyA, ka),
            if (kb != null) (KeyType.keyB, kb),
          ];
          var wrote = false;
          for (final (kt, key) in tryKeys) {
            try {
              await _dev.cmdMf1WriteBlock(
                  block: block, keyType: kt, key: key, data: _hex(data));
              wrote = true;
              break;
            } on DeviceException {
              // 换另一把密钥再试
            }
          }
          if (!wrote) failedBlocks.add(block);
        }
      }
      if (mounted) Navigator.of(context).pop();
      if (failedBlocks.isEmpty) {
        _toast('格式化完成');
      } else {
        LogService.instance.log(
            '[格式化] ACL受限未写入块: ${failedBlocks.join(', ')}');
        _toast('格式化完成，${failedBlocks.length} 个块 ACL 受限未重置');
      }
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _toast('格式化失败: $e');
    }
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
          uid: uid.trim(),
          sak: _sakCtrl.text.trim(),
          atqa: _atqaCtrl.text.trim(),
          keysText: _keyCtrl.text);
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
