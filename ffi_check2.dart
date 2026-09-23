import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:wgkczs/services/crypto1.dart';

// static_nested 的 Dart FFI 真值验证（gen2 合成样本）
// 合成用 app 实测过的 Crypto1（与 C crypto1_word/setLfsr 位序同构）

final class StaticNestedS extends Struct {
  @Uint32()
  external int uid;
  @Uint32()
  external int keyType;
  @Uint32()
  external int nt0;
  @Uint32()
  external int nt0Enc;
  @Uint32()
  external int nt1;
  @Uint32()
  external int nt1Enc;
}

typedef StaticNestedFn =
    Pointer<Uint64> Function(Pointer<StaticNestedS>, Pointer<Uint32>);

void main() {
  final lib = DynamicLibrary.open('/tmp/opencode/librecovery.so');
  final staticNested =
      lib.lookupFunction<StaticNestedFn, StaticNestedFn>('static_nested');

  const key = 0xA0B1C2D3E4F5;
  const uid = 0x32432271;
  const nt = 0x009080A2; // gen2 特征值
  const keyType = 0x60; // keyA

  List<int> makeAuth(int dist) {
    final ntp = Crypto1.prngSuccessor(nt, dist);
    final n = (ntp ^ uid) & 0xFFFFFFFF;
    final c = Crypto1()..setLfsr(key);
    final ks1 = c.lfsrWord(n, 0);
    final enc = (ntp ^ ks1) & 0xFFFFFFFF;
    return [ntp, enc];
  }

  final a0 = makeAuth(160);
  final a1 = makeAuth(320);

  // 自洽性：合成样本应能被 app 自身恢复路径恢复出真 key
  final appCandidates = Crypto1.staticnested(
      uid: uid, keyType: keyType, atks: [
    {'nt1': nt, 'nt2': a0[1]},
    {'nt1': nt, 'nt2': a1[1]},
  ]);
  print('app staticnested -> ${appCandidates.length} keys, '
      'contains key: ${appCandidates.contains(key)}');

  final data = malloc<StaticNestedS>();
  final countP = malloc<Uint32>();
  data.ref.uid = uid;
  data.ref.keyType = keyType;
  data.ref.nt0 = nt;
  data.ref.nt0Enc = a0[1];
  data.ref.nt1 = nt;
  data.ref.nt1Enc = a1[1];
  countP.value = 0;

  final keys = staticNested(data, countP);
  print('C static_nested -> ${countP.value} keys');
  var pass = false;
  for (var i = 0; i < countP.value; i++) {
    if (keys[i] == key) {
      pass = true;
      break;
    }
  }
  if (keys != nullptr) malloc.free(keys);
  malloc.free(data);
  malloc.free(countP);
  print(pass ? 'STATIC_NESTED CHECK PASS' : 'STATIC_NESTED CHECK FAIL');
}
