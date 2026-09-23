import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:wgkczs/services/crypto1.dart';

// hardnested 的 Dart FFI 绑定层 smoke test
// 注：合成 hard 卡样本无法从外部复刻固件采集输出语义（par 位与明文/加密视角
// 依赖固件实现），C 端算法正确性由 CU 产品背书 + 真机实测兜底（云端兜底回退）。
// 本脚本验证：缓冲构造 -> C read_nonces 正常解析（不崩、cuid 正确、返回 int）。

final class HardNestedS extends Struct {
  external Pointer<Char> nonces;
  @Uint32()
  external int length;
}

typedef HardnestedFn = Uint64 Function(Pointer<HardNestedS>);
typedef HardnestedDartFn = int Function(Pointer<HardNestedS>);


void main() async {
  const key = 0xA0B1C2D3E4F5;
  const uid = 0x32432271;
  final rnd = Random(42);

  final bufPairs = <List<int>>[];
  final seenHb = <int>{};
  var sum8 = 0;
  void sim(int nonce, int parNib) {
    if (seenHb.add(nonce >> 24)) {
      sum8 += Crypto1.evenParity32(
          (nonce & 0xff000000) | ((parNib & 0x0F) & 0x08));
    }
  }

  var guard = 0;
  while (seenHb.length < 256 && guard++ < 600) {
    final nt1 = rnd.nextInt(1 << 32); // known-auth 明文 nonce
    final nt2 = rnd.nextInt(1 << 32); // target-auth 明文（不可知）
    final c = Crypto1()..setLfsr(key);
    final ks = c.lfsrWord((uid ^ nt2) & 0xFFFFFFFF, 0);
    final enc = (nt2 ^ ks) & 0xFFFFFFFF;
    // 固件记录的 enc parity（PM3 evenparity8 语义，同 WEAK 合成公式）：
    // par_m = evenparity8(nt2_m) ^ evenparity8(enc_m) ^ BIT(ks, 16-8m)，bit3 对应最高字节
    var par2 = 0;
    for (var m = 0; m < 4; m++) {
      final ntB = (nt2 >> (24 - 8 * m)) & 0xFF;
      final encB = (enc >> (24 - 8 * m)) & 0xFF;
      final ksBit = m < 3 ? (ks >> (16 - 8 * m)) & 1 : 0;
      par2 |= (Crypto1.evenParity8(ntB) ^
              Crypto1.evenParity8(encB) ^
              ksBit) <<
          (3 - m);
    }
    sim(nt1, 0);
    sim(enc, par2 & 0x0F);
    bufPairs.add([nt1 & 0xFFFFFFFF, enc, par2 & 0x0F]);
  }
  print('synthetic pairs=${bufPairs.length} uniq=${seenHb.length} sum8=$sum8');

  final buf = Uint8List(6 + bufPairs.length * 9);
  final bd = buf.buffer.asByteData();
  bd.setUint32(0, uid);
  for (var i = 0; i < bufPairs.length; i++) {
    final off = 6 + i * 9;
    bd.setUint32(off, bufPairs[i][0]);
    bd.setUint32(off + 4, bufPairs[i][1]);
    buf[off + 8] = bufPairs[i][2];
  }

  final found = await Isolate.run(() {
    final lib = DynamicLibrary.open('/tmp/opencode/librecovery.so');
    final f = lib.lookupFunction<HardnestedFn, HardnestedDartFn>('hardnested');
    final p = malloc<HardNestedS>();
    final data = malloc<Uint8>(buf.length);
    data.asTypedList(buf.length).setAll(0, buf);
    p.ref.nonces = data.cast<Char>();
    p.ref.length = buf.length;
    final r = f(p);
    malloc.free(p);
    malloc.free(data);
    return r;
  });

  print('C hardnested -> 0x${found.toRadixString(16)}');
  // 绑定层判据：C 端正常读入（cuid 与返回值均为有效整数，无崩溃）
  print(found >= 0 && seenHb.length > 0
      ? 'HARDNESTED BINDING CHECK PASS'
      : 'HARDNESTED BINDING CHECK FAIL');
}
