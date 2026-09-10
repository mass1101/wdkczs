import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// static_encrypted_nested（后门卡 lfsr_recovery32）真值验证
// 样本与断言取自 Chameleon Ultra 官方测试（test/recovery_test.dart，真机采集）

final class StaticEncryptedNestedS extends Struct {
  @Uint32()
  external int uid;
  @Uint32()
  external int nt;
  @Uint32()
  external int ntEnc;
  @Uint32()
  external int ntParEnc;
}

typedef StaticEncryptedNestedFn = Pointer<Uint64>
    Function(Pointer<StaticEncryptedNestedS>, Pointer<Uint32>);
typedef StaticEncryptedNestedDartFn = Pointer<Uint64>
    Function(Pointer<StaticEncryptedNestedS>, Pointer<Uint32>);

List<int> callC(DynamicLibrary lib, int uid, int nt, int ntEnc, int ntParEnc) {
  final f = lib.lookupFunction<StaticEncryptedNestedFn,
      StaticEncryptedNestedDartFn>('static_encrypted_nested');
  final p = malloc<StaticEncryptedNestedS>();
  final countP = malloc<Uint32>();
  p.ref.uid = uid & 0xFFFFFFFF;
  p.ref.nt = nt & 0xFFFFFFFF;
  p.ref.ntEnc = ntEnc & 0xFFFFFFFF;
  p.ref.ntParEnc = ntParEnc & 0xFFFFFFFF;
  countP.value = 0;
  final keysP = f(p, countP);
  final out = <int>[];
  for (var i = 0; i < countP.value; i++) {
    out.add(keysP[i] & 0xFFFFFFFFFFFF);
  }
  malloc.free(keysP);
  malloc.free(p);
  malloc.free(countP);
  return out;
}

void main() {
  final lib = DynamicLibrary.open('/tmp/opencode/librecovery.so');

  // 官方样本 1：单条恢复
  final k1 = callC(lib, 0x72000003, 0x82d91e42, 0x98b90e04, 1011);
  final ok1 = k1.contains(0x55654483DA14);
  print('sample1: count=${k1.length} contains=true-key -> $ok1');

  // 官方样本 2：双条恢复 + 数量断言（34675 / 35256）
  final ka = callC(lib, 0x72000003, 647928510, 591664851, 100);
  final kb = callC(lib, 0x72000003, 2195267138, 2562264580, 1011);
  print('sample2: a=${ka.length}(expect 34675) b=${kb.length}(expect 35256)');

  print(ok1 && ka.length == 34675 && kb.length == 35256
      ? 'STATIC_ENCRYPTED_NESTED CHECK PASS'
      : 'CHECK FAIL');
}
