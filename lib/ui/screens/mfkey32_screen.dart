import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart';
import '../../services/crypto1.dart';
import '../../services/device_service.dart';

/// Mfkey32 密钥恢复页（对齐 CU gui/menu/pages/mfkey32.dart）
///
/// 读取卡槽收集的 Mifare Classic 检测日志（每条含 uid/block/keyType/nt/nr/ar），
/// 按 (uid, block, keyType) 分组，同组两两组合用 Crypto1.mfkey32v2 反推 48 位密钥。
class Mfkey32Screen extends StatefulWidget {
  const Mfkey32Screen({super.key});

  @override
  State<Mfkey32Screen> createState() => _Mfkey32ScreenState();
}

class _Mfkey32ScreenState extends State<Mfkey32Screen> {
  bool _loading = false;
  int _progress = -1;
  final List<_RecoveredKey> _keys = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _recover());
  }

  Future<void> _recover() async {
    setState(() {
      _loading = true;
      _progress = 0;
      _error = null;
      _keys.clear();
    });
    try {
      final device = AppScope.instance.controller.device;
      final count = await device.cmdMf1GetDetectionCount();
      if (count == 0) {
        setState(() => _loading = false);
        return;
      }
      final all = <Mf1DetectionLog>[];
      var offset = 0;
      while (offset < count) {
        final batch = await device.cmdMf1GetDetectionLogs(offset);
        if (batch.isEmpty) break;
        all.addAll(batch);
        offset += batch.length;
        if (!mounted) return;
        setState(() => _progress = (offset / count * 100).round());
      }

      final groups = <String, List<Mf1DetectionLog>>{};
      for (final l in all) {
        final key = '${_bytesToHex(l.uid)}:${l.block}:${l.isKeyB ? 1 : 0}';
        (groups[key] ??= []).add(l);
      }

      final seen = <String>{};
      for (final entry in groups.entries) {
        final list = entry.value;
        final uid = _bytesToInt(list.first.uid);
        for (var i = 0; i < list.length; i++) {
          for (var j = i + 1; j < list.length; j++) {
            final a = list[i];
            final b = list[j];
            final candidates = Crypto1.mfkey32v2(
              uid: uid,
              nt0: _bytesToInt(a.nt),
              nr0: _bytesToInt(a.nr),
              ar0: _bytesToInt(a.ar),
              nt1: _bytesToInt(b.nt),
              nr1: _bytesToInt(b.nr),
              ar1: _bytesToInt(b.ar),
            );
            for (final key in candidates) {
              final hex = (key & 0xFFFFFFFFFFFF)
                  .toRadixString(16)
                  .padLeft(12, '0')
                  .toUpperCase();
              if (seen.add(hex)) {
                _keys.add(_RecoveredKey(
                  uid: _bytesToHex(list.first.uid).toUpperCase(),
                  block: a.block,
                  keyB: a.isKeyB,
                  keyHex: hex,
                ));
              }
            }
            if (!mounted) return;
            setState(() {});
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '恢复失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mfkey32')),
      body: _loading && _keys.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  if (_progress >= 0) Text('读取检测日志 $progressLabel'),
                ],
              ),
            )
          : _keys.isEmpty && _error == null
              ? const Center(child: Text('没有可恢复的密钥（请先用卡槽收集 nonces）'))
              : _error != null && _keys.isEmpty
                  ? Center(child: Text(_error!))
                  : ListView.builder(
                      itemCount: _keys.length,
                      itemBuilder: (context, i) {
                        final k = _keys[i];
                        return ListTile(
                          leading: const Icon(Icons.vpn_key, size: 20),
                          title: Text(
                            k.keyHex,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            'UID ${k.uid}  块 ${k.block}  ${k.keyB ? 'B' : 'A'}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            tooltip: '复制',
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: k.keyHex),
                              );
                              if (!mounted) return;
                              ScaffoldMessenger.of(context)
                                ..clearSnackBars()
                                ..showSnackBar(
                                  const SnackBar(
                                    content: Text('已复制密钥'),
                                    duration: Duration(seconds: 1),
                                  ),
                                );
                            },
                          ),
                        );
                      },
                    ),
    );
  }

  String get progressLabel => _progress > 0 ? '$_progress%' : '';
}

class _RecoveredKey {
  final String uid;
  final int block;
  final bool keyB;
  final String keyHex;

  _RecoveredKey({
    required this.uid,
    required this.block,
    required this.keyB,
    required this.keyHex,
  });
}

String _bytesToHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

int _bytesToInt(Uint8List b) {
  var v = 0;
  for (final x in b) {
    v = (v << 8) | x;
  }
  return v;
}
