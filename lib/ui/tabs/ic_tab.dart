import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/enums.dart';
import '../../models/models.dart';
import '../../services/crypto1.dart';
import '../../services/device_service.dart';
import '../../state/app_controller.dart';
import '../../ui/dialogs/crack_dialog.dart';
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
  final _keyCtrl = TextEditingController(text: kDefaultKeys.join('\n'));

  String _cardType = 'Mifare Classic 1K';
  String _selectedKeyName = '';

  @override
  void initState() {
    super.initState();
    _uidCtrl.text = _app.card.uid;
    _atqaCtrl.text = _app.card.atqa;
    _sakCtrl.text = _app.card.sak;
    _keyCtrl.text = _app.card.keys;
    _loadKeys();
  }

  @override
  void dispose() {
    _uidCtrl.dispose();
    _atqaCtrl.dispose();
    _sakCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadKeys() async {
    final names = await _app.storage.getKeyNames();
    if (names.isNotEmpty && mounted) {
      _selectedKeyName = names.keys.first;
      _keyCtrl.text = names.values.first;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  List<String> get _keys =>
      _keyCtrl.text.split('\n').map((e) => e.trim()).where((e) => e.length == 12).toList();

  // ========== 读卡 ==========
  Future<void> _readCard() async {
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final tag = tags.first;
      final uid = tag.uidHex;
      setState(() {
        _uidCtrl.text = uid;
        _atqaCtrl.text = tag.atqaHex;
        _sakCtrl.text = tag.sakHex;
      });
      // 读取所有可读块
      final sectors = List.generate(16, (_) => SectorData());
      final blocks = List.generate(64, (_) => BlockData());
      var readCount = 0;
      for (var keyType in [KeyType.keyA, KeyType.keyB]) {
        for (final keyStr in _keys) {
          final key = _hex(keyStr);
          for (var sector = 0; sector < 16; sector++) {
            final blockNum = sector * 4;
            if (blocks[blockNum].data != '00000000000000000000000000000000') {
              continue;
            }
            try {
              final data = await _dev.cmdMf1ReadBlock(
                  block: blockNum, keyType: keyType, key: key);
              blocks[blockNum].data = _hexStr(data);
              // 同扇区其余块用扇区尾（块3）密钥，先只标记扇区可读
              readCount++;
            } catch (_) {}
          }
        }
      }
      // 尝试读取扇区内其余块
      for (var sector = 0; sector < 16; sector++) {
        final first = blocks[sector * 4].data;
        if (first == '00000000000000000000000000000000') continue;
        final blocksArr = List<BlockData>.generate(4, (i) => blocks[sector * 4 + i]);
        sectors[sector] = SectorData(blocks: blocksArr);
      }
      setState(() {
        _app.card.uid = uid;
        _app.card.atqa = tag.atqaHex;
        _app.card.sak = tag.sakHex;
        _app.card.sectors = sectors;
      });
      _toast('读取完成：$readCount 个扇区');
    } catch (e) {
      _toast('读卡失败: $e');
    }
  }

  // ========== 写卡 ==========
  Future<void> _writeCard() async {
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final uid = tags.first.uidHex;
      final uidBytes = _hex(uid);
      await _dev.cmdHf14aSetAntiCollData(
          uid: uidBytes, atqa: _hex(_atqaCtrl.text), sak: _hex(_sakCtrl.text));
      // 逐扇区写入
      var written = 0;
      for (var sector = 0; sector < 16; sector++) {
        final blocks = _app.card.sectors[sector].blocks;
        if (blocks[0].data == '00000000000000000000000000000000') continue;
        for (final keyStr in _keys) {
          final key = _hex(keyStr);
          for (var b = 0; b < 4; b++) {
            final blockNum = sector * 4 + b;
            try {
              await _dev.cmdMf1WriteBlock(
                  block: blockNum,
                  keyType: KeyType.keyA,
                  key: key,
                  data: _hex(blocks[b].data));
              written++;
            } catch (_) {
              try {
                await _dev.cmdMf1WriteBlock(
                    block: blockNum,
                    keyType: KeyType.keyB,
                    key: key,
                    data: _hex(blocks[b].data));
                written++;
              } catch (_) {}
            }
          }
        }
      }
      _toast('写入完成：$written 块');
    } catch (e) {
      _toast('写卡失败: $e');
    }
  }

  // ========== 写卡槽（模拟） ==========
  Future<void> _writeSlot() async {
    try {
      await _dev.assureDeviceMode(DeviceMode.tag);
      // 写入反碰撞数据
      await _dev.cmdHf14aSetAntiCollData(
          uid: _hex(_uidCtrl.text), atqa: _hex(_atqaCtrl.text), sak: _hex(_sakCtrl.text));
      // 写入扇区数据
      final all = StringBuffer();
      for (var sector = 0; sector < 16; sector++) {
        for (var b = 0; b < 4; b++) {
          all.write(_app.card.sectors[sector].blocks[b].data);
        }
      }
      final data = _hex(all.toString());
      for (var off = 0; off < data.length; off += 240) {
        final end = (off + 240 < data.length) ? off + 240 : data.length;
        await _dev.cmdMf1EmuWriteBlock(off, data.sublist(off, end));
      }
      await _app.storage.setCurrentUid(_uidCtrl.text);
      _toast('已写入卡槽');
    } catch (e) {
      _toast('写卡槽失败: $e');
    }
  }

  // ========== 解卡（破解） ==========
  Future<void> _crackCard() async {
    if (_keys.isEmpty) {
      _toast('请先填写密钥');
      return;
    }
    try {
      await _dev.assureDeviceMode(DeviceMode.reader);
      final tags = await _dev.cmdHf14aScan();
      if (tags.isEmpty) throw DeviceException(1, '未发现卡片');
      final uid = tags.first.uid;
      final uidInt = _bytesInt(uid.sublist(0, 4));
      final key = _hex(_keys.first);

      // 探测 PRNG 类型
      final prng = await _dev.cmdMf1TestPrngType();
      if (!mounted) return;
      final results = <String>[];
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => CrackProgressDialog(
          title: '正在破解 (PRNG ${prng == 0 ? '静态' : prng == 1 ? '弱随机' : '强随机'})',
          onCancel: () {},
        ),
      );
      try {
        if (prng == 0) {
          // 静态嵌套
          final res = await _dev.cmdMf1AcquireStaticNested(
              block: 0, keyType: KeyType.keyA, key: key, targetBlock: 0, targetKeyType: KeyType.keyA);
          final atks = res.atks.map((a) => {
                'nt1': _bytesInt(a.$1),
                'nt2': _bytesInt(a.$2),
              }).toList();
          final recovered = Crypto1.staticnested(uid: uidInt, keyType: 96, atks: atks);
          for (final k in recovered) {
            results.add(_int6Hex(k));
          }
        } else if (prng == 1) {
          // 弱随机：检测 NT 距离并嵌套
          final distRes = await _dev.cmdMf1TestNtDistance(block: 0, keyType: KeyType.keyA, key: key);
          final dist = _bytesInt(distRes.dist.sublist(0, 4));
          final nested = await _dev.cmdMf1AcquireNested(
              block: 0, keyType: KeyType.keyA, key: key, targetBlock: 0, targetKeyType: KeyType.keyA);
          final atks = nested.map((a) => {
                'nt1': _bytesInt(a.nt1),
                'nt2': _bytesInt(a.nt2),
                'par': a.par,
              }).toList();
          final recovered = Crypto1.nested(uid: uidInt, dist: dist, atks: atks);
          for (final k in recovered) {
            results.add(_int6Hex(k));
          }
        } else {
          // HardNested：云任务
          await _submitHardnested(uid);
        }
      } finally {
        if (mounted) Navigator.of(context).pop();
      }
      if (results.isNotEmpty) {
        final keys = _keyCtrl.text.trim();
        setState(() {
          _keyCtrl.text = keys.isEmpty ? results.first : '$keys\n${results.first}';
          _app.card.keys = _keyCtrl.text;
        });
        _toast('破解成功：${results.first}');
      } else {
        _toast('未找到密钥');
      }
    } catch (e) {
      _toast('破解失败: $e');
    }
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
      final a = detections[0];
      final b = detections[1];
      final keys = Crypto1.mfkey32v2(
        uid: uidInt,
        nt0: _bytesInt(a.nt),
        nr0: _bytesInt(a.nr),
        ar0: _bytesInt(a.ar),
        nt1: _bytesInt(b.nt),
        nr1: _bytesInt(b.nr),
        ar1: _bytesInt(b.ar),
      );
      if (keys.isEmpty) {
        _toast('未计算出密钥');
        return;
      }
      final found = _int6Hex(keys.first);
      setState(() {
        _keyCtrl.text = '${_keyCtrl.text.trim()}\n$found';
        _app.card.keys = _keyCtrl.text;
      });
      _toast('算得密钥：$found');
    } catch (e) {
      _toast('算密钥失败: $e');
    }
  }

  // ========== 导入 / 导出 / 管理数据 ==========
  Future<void> _importCard() async {
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => const TextInputDialog(
        title: '导入 Dump',
        hint: '粘贴 64 行 dump 文本',
        multiline: true,
      ),
    );
    if (text == null) return;
    final lines = text.trim().split('\n').map((e) => e.trim()).toList();
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
    _toast('导入成功');
  }

  Future<void> _exportCard() async {
    final dump = _app.card.toDumpText();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const TextInputDialog(
        title: '保存 Dump',
        hint: '输入文件名',
      ),
    );
    if (name == null || name.isEmpty) return;
    await _app.storage.saveCard(name, dump);
    _toast('已保存：$name');
  }

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
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.grey),
                    onPressed: () async {
                      await _app.storage.delCard(e.key);
                      if (ctx.mounted) Navigator.pop(ctx);
                      _toast('已删除 ${e.key}');
                    },
                  ),
                )),
          ],
        ),
      ),
    );
  }

  // ========== 更多功能（云） ==========
  Future<void> _moreFeatures() async {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
                leading: Icon(Icons.analytics_outlined),
                title: Text('电梯卡分析')),
            const ListTile(
                leading: Icon(Icons.cloud_outlined),
                title: Text('云破解任务')),
            const ListTile(
                leading: Icon(Icons.share),
                title: Text('在线分享')),
            const SizedBox(height: 8),
          ],
        ),
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
            // 左侧内容
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  // 密钥卡片
                  SectionCard(
                    title: '密钥',
                    child: Column(
                      children: [
                        _cardLabel('密钥文件', _selectedKeyName.isEmpty ? '默认' : _selectedKeyName,
                            trailing: [
                              IconButton(
                                  icon: const Icon(Icons.list, size: 18),
                                  onPressed: _pickKeyFile),
                              IconButton(
                                  icon: const Icon(Icons.edit, size: 18),
                                  onPressed: _editKeys),
                            ]),
                        KeyCard(
                          label: '密钥',
                          value: _keyCtrl.text,
                          onList: _pickKeyFile,
                          onDownload: _saveKeys,
                          onDelete: _deleteKeyFile,
                        ),
                        _cardLabel('卡类型', _cardType,
                            trailing: [IconButton(
                                icon: const Icon(Icons.expand_more, size: 18),
                                onPressed: _pickCardType)]),
                      ],
                    ),
                  ),
                  // 卡片信息
                  SectionCard(
                    title: '卡片信息',
                    child: Column(
                      children: [
                        _infoRow('UID', _uidCtrl, 'deadbeef'),
                        _infoRow('ATQA', _atqaCtrl, '0004'),
                        _infoRow('SAK', _sakCtrl, '08'),
                      ],
                    ),
                  ),
                  // 扇区数据表
                  SectionCard(
                    title: '扇区数据',
                    child: _SectorTable(card: _app.card),
                  ),
                ],
              ),
            ),
            // 右侧按钮列
            Container(
              width: 96,
              margin: const EdgeInsets.fromLTRB(0, 8, 6, 0),
              child: Column(
                children: [
                  _sideBtn('读卡', Icons.radio_button_checked, _readCard, primary),
                  _sideBtn('写卡', Icons.save_alt, _writeCard, primary),
                  _sideBtn('解卡', Icons.lock_open, _crackCard, primary),
                  _sideBtn('读卡槽', Icons.memory, _readSlot, primary),
                  _sideBtn('写卡槽', Icons.memory, _writeSlot, primary),
                  _sideBtn('算密钥', Icons.calculate, _mfkey, primary),
                  _sideBtn('导入', Icons.download, _importCard, primary),
                  _sideBtn('导出', Icons.upload, _exportCard, primary),
                  _sideBtn('管理数据', Icons.folder, _manageData, primary),
                  _sideBtn('更多功能', Icons.more_horiz, _moreFeatures, primary),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _readSlot() async {
    try {
      await _dev.assureDeviceMode(DeviceMode.tag);
      final antiColl = await _dev.cmdHf14aGetAntiCollData();
      setState(() {
        if (antiColl != null) {
          _uidCtrl.text = antiColl.uidHex;
          _atqaCtrl.text = antiColl.atqaHex;
          _sakCtrl.text = antiColl.sakHex;
          _app.card.uid = antiColl.uidHex;
          _app.card.atqa = antiColl.atqaHex;
          _app.card.sak = antiColl.sakHex;
        }
      });
      _toast('已读取当前卡槽数据');
    } catch (e) {
      _toast('读卡槽失败: $e');
    }
  }

  Widget _cardLabel(String label, String value, {List<Widget> trailing = const []}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
              width: 56,
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)))),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF333333),
                    fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis),
          ),
          ...trailing,
        ],
      ),
    );
  }

  Widget _infoRow(String label, TextEditingController ctrl, String hint) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
              width: 56,
              child: Text(label,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF666666)))),
          Expanded(
            child: TextField(
              controller: ctrl,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
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
      child: ActionButton(
          label: label,
          icon: icon,
          color: color,
          onTap: onTap,
          enabled: _app.connected || label == '导入' || label == '管理数据'),
    );
  }

  // ========== 密钥文件管理 ==========
  Future<void> _pickKeyFile() async {
    final names = await _app.storage.getKeyNames();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
                title: Text('选择密钥文件', style: TextStyle(fontWeight: FontWeight.w600))),
            ...names.entries.map((e) => ListTile(
                  title: Text(e.key),
                  onTap: () {
                    setState(() {
                      _selectedKeyName = e.key;
                      _keyCtrl.text = e.value;
                    });
                    Navigator.pop(ctx);
                  },
                )),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新建'),
              onTap: () async {
                Navigator.pop(ctx);
                final name = await showDialog<String>(
                  context: context,
                  builder: (c) => const TextInputDialog(title: '新建密钥文件', hint: '输入文件名'),
                );
                if (name != null && name.isNotEmpty) {
                  await _app.storage.saveKey(name, kDefaultKeys.join('\n'));
                  setState(() {
                    _selectedKeyName = name;
                    _keyCtrl.text = kDefaultKeys.join('\n');
                  });
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _editKeys() async {
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => TextInputDialog(
        title: '编辑密钥',
        hint: '每行一个密钥，12 位十六进制',
        initial: _keyCtrl.text,
        multiline: true,
      ),
    );
    if (text != null) {
      setState(() {
        _keyCtrl.text = text.trim();
        _app.card.keys = _keyCtrl.text;
      });
    }
  }

  Future<void> _saveKeys() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const TextInputDialog(title: '保存密钥文件', hint: '输入文件名'),
    );
    if (name != null && name.isNotEmpty) {
      await _app.storage.saveKey(name, _keyCtrl.text);
      setState(() => _selectedKeyName = name);
      _toast('已保存');
    }
  }

  Future<void> _deleteKeyFile() async {
    if (_selectedKeyName.isEmpty) {
      _toast('当前为默认密钥');
      return;
    }
    await _app.storage.delKey(_selectedKeyName);
    setState(() => _selectedKeyName = '');
    _keyCtrl.text = kDefaultKeys.join('\n');
    _toast('已删除');
  }

  Future<void> _pickCardType() async {
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: TagType.values
              .map((t) => ListTile(
                    title: Text(t.label),
                    onTap: () => Navigator.pop(ctx, t.label),
                  ))
              .toList(),
        ),
      ),
    );
    if (choice != null) setState(() => _cardType = choice);
  }
}

// ========== 扇区数据表 ==========
class _SectorTable extends StatelessWidget {
  final CardState card;
  const _SectorTable({required this.card});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
                width: 40,
                child: Text('扇区', style: TextStyle(fontSize: 11, color: Colors.grey))),
            const SizedBox(
                width: 52,
                child: Text('块号', style: TextStyle(fontSize: 11, color: Colors.grey))),
            Expanded(
                child: Text('数据 (16字节)',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]))),
          ],
        ),
        const SizedBox(height: 4),
        for (var s = 0; s < 16; s++)
          for (var b = 0; b < 4; b++)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text('$s',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF666666))),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text('${s * 4 + b}',
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFF999999))),
                  ),
                  Expanded(
                    child: Text(
                      _format(card.sectors[s].blocks[b].data),
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: b == 3 ? const Color(0xFF1577FE) : const Color(0xFF333333),
                        fontWeight: b == 3 ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  String _format(String hex) {
    if (hex.length < 32) return hex;
    final buf = StringBuffer();
    for (var i = 0; i < 32; i += 2) {
      buf.write(hex.substring(i, i + 2));
      if (i < 30) buf.write(' ');
    }
    return buf.toString();
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
