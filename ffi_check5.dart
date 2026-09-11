import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// darkside（PM3 nonce2key）真值验证
// 样本与断言取自 Chameleon Ultra 官方测试（test/recovery_test.dart）：
// uid=2374329723, 两条 lucky(par=0) 样本, 期望候选含 0xFFFFFFFFFFFF

final class _DarksideItem extends Struct {
  @Uint32()
  external int nt1;
  @Uint64()
  external int ks1;
  @Uint64()
  external int par;
  @Uint32()
  external int nr;
  @Uint32()
  external int ar;
}

final class _Darkside extends Struct {
  @Uint32()
  external int uid;
  external Pointer<_DarksideItem> items;
  @Uint32()
  external int count;
}

typedef _DarksideFn = Pointer<Uint64> Function(Pointer<_Darkside>, Pointer<Uint32>);
typedef _DarksideDartFn = Pointer<Uint64> Function(Pointer<_Darkside>, Pointer<Uint32>);

List<int> callC(DynamicLibrary lib, int uid,
    List<({int nt1, int ks1, int par, int nr, int ar})> items) {
  final f = lib.lookupFunction<_DarksideFn, _DarksideDartFn>('darkside');
  final data = malloc<_Darkside>();
  final itemsP = malloc<_DarksideItem>(items.length);
  final countP = malloc<Uint32>();
  data.ref.uid = uid & 0xFFFFFFFF;
  data.ref.items = itemsP;
  data.ref.count = items.length;
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    itemsP[i].nt1 = it.nt1 & 0xFFFFFFFF;
    itemsP[i].ks1 = it.ks1;
    itemsP[i].par = it.par;
    itemsP[i].nr = it.nr & 0xFFFFFFFF;
    itemsP[i].ar = it.ar & 0xFFFFFFFF;
  }
  countP.value = 0;
  try {
    final keys = f(data, countP);
    if (keys == nullptr) return const [];
    final out = <int>[];
    for (var i = 0; i < countP.value; i++) {
      out.add(keys[i]);
    }
    malloc.free(keys);
    return out;
  } finally {
    malloc.free(data);
    malloc.free(itemsP);
    malloc.free(countP);
  }
}

Future<void> main() async {
  final lib = DynamicLibrary.open('/tmp/opencode/librecovery.so');
  const uid = 2374329723;
  final items = <({int nt1, int ks1, int par, int nr, int ar})>[
    (nt1: 913032415, ks1: 216745674933338888, par: 0, nr: 0, ar: 0),
    (nt1: 913032415, ks1: 1010230244403446283, par: 0, nr: 1, ar: 0),
  ];
  // 与 NativeRecovery.darkside 同构：Isolate.run 内重新 open（DynamicLibrary 不可跨 isolate 传递）
  final keys = await Isolate.run(() {
    final lib2 = DynamicLibrary.open('/tmp/opencode/librecovery.so');
    return callC(lib2, uid, items);
  });
  print('候选数=${keys.length}');
  if (keys.isEmpty) throw StateError('FAIL: 候选为空');
  if (!keys.contains(0xFFFFFFFFFFFF)) {
    throw StateError('FAIL: 候选缺少 0xFFFFFFFFFFFF');
  }
  print('PASS: 候选含 0xFFFFFFFFFFFF (与CU官方测试断言一致)');
  print('前5候选: ${keys.take(5).map((k) => k.toRadixString(16).padLeft(12, '0')).join(', ')}');
}
