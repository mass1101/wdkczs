import 'lib/services/crypto1.dart';

void main() {
  final uid = 0x32432271;
  final key = 0xA0B1C2D3E4F5;
  final dist = 42;

  // 生成两组自洽的嵌套攻击样本（同一 dist，不同 nt1）：
  // 模型约定：ks1 = fresh(K) 状态喂入 n=ntp^uid 的输出，nt2enc = ntp ^ ks1
  // 奇偶位满足 nestedIsValidNonce 关系，且 ntp = prngSuccessor(nt1, dist)
  final atks = <Map<String, int>>[];
  for (var i = 0; i < 2; i++) {
    final nt1 = 0x11223344 + i * 0x0A0B0C0D;
    final ntp = Crypto1.prngSuccessor(nt1, dist);
    final n = Crypto1.toUint32(ntp ^ uid);
    final st = Crypto1();
    st.setLfsr(key);
    final ks1 = st.lfsrWord(n, 0);
    final nt2enc = Crypto1.toUint32(ntp ^ ks1);
    final par = (Crypto1.evenParity8((ntp >> 24) & 255) ^
            Crypto1.evenParity8((nt2enc >> 24) & 255) ^
            Crypto1.bit(ks1, 16)) |
        ((Crypto1.evenParity8((ntp >> 16) & 255) ^
                Crypto1.evenParity8((nt2enc >> 16) & 255) ^
                Crypto1.bit(ks1, 8)) <<
            1) |
        ((Crypto1.evenParity8((ntp >> 8) & 255) ^
                Crypto1.evenParity8((nt2enc >> 8) & 255) ^
                Crypto1.bit(ks1, 0)) <<
            2);
    atks.add({'nt1': nt1, 'nt2': nt2enc, 'par': par & 7});
    print('sample$i: nt1=0x${nt1.toRadixString(16)} '
        'nt2enc=0x${nt2enc.toRadixString(16)} par=${par & 7}');
  }

  // 与 JS 对照实验一致：取第一个通过 parity 校验的采集对，单独跑 lfsrRecovery32
  final collected = <Map<String, int>>[];
  for (final atk in atks) {
    final nt1 = atk['nt1']!, nt2 = atk['nt2']!, par = atk['par']!;
    var h = Crypto1.prngSuccessor(nt1, dist - 14);
    for (var i = 0; i < 29; i++) {
      final e = Crypto1.toUint32(nt2 ^ h);
      if (Crypto1.nestedIsValidNonce(h, nt2, e, par)) {
        collected.add({'ntp': h, 'ks1': e});
      }
      h = Crypto1.prngSuccessor(h, 1);
    }
  }
  print('collected pairs: ${collected.length}');

  if (const bool.fromEnvironment('single_pair')) {
    final p = collected.first;
    final n = Crypto1.toUint32(p['ntp']! ^ uid);
    final sw = Stopwatch()..start();
    final states = Crypto1.lfsrRecovery32(p['ks1']!, n);
    print('pair ntp=0x${p['ntp']!.toRadixString(16)} ks1=0x${p['ks1']!.toRadixString(16)} '
        'n=0x${n.toRadixString(16)} states=${states.length} time=${sw.elapsedMilliseconds}ms');
    return;
  }

  // 完整走 nested() 流水线（PRNG 窗口 + 奇偶过滤 + 状态恢复）
  final recovered = Crypto1.nested(uid: uid, dist: dist, atks: atks);
  print('recovered=${recovered.length} candidates');
  final found = recovered.contains(key);
  print('key found: $found');
  for (final k in recovered.take(5)) {
    print('  candidate: 0x${k.toRadixString(16).padLeft(12, '0')}');
  }
  print(found ? 'PASS' : 'FAIL');
}
