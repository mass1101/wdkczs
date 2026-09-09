import 'dart:ffi';
import 'package:ffi/ffi.dart';

// 验证 Dart FFI 绑定与 C 库联动（host 上加载验证用，结构同 lib/services/native_recovery.dart）

final class NestedS extends Struct {
  @Uint32()
  external int uid;
  @Uint32()
  external int dist;
  @Uint32()
  external int nt0;
  @Uint32()
  external int nt0Enc;
  @Uint32()
  external int par0;
  @Uint32()
  external int nt1;
  @Uint32()
  external int nt1Enc;
  @Uint32()
  external int par1;
}

typedef NestedFn = Pointer<Uint64> Function(Pointer<NestedS>, Pointer<Uint32>);

void main() {
  final lib = DynamicLibrary.open('/tmp/opencode/librecovery.so');
  final nested = lib.lookupFunction<NestedFn, NestedFn>('nested');

  final data = malloc<NestedS>();
  final countP = malloc<Uint32>();
  data.ref.uid = 0x32432271;
  data.ref.dist = 42;
  data.ref.nt0 = 0x11223344;
  data.ref.nt0Enc = 0x44513294;
  data.ref.par0 = 6;
  data.ref.nt1 = 0x11223344 + 0x0A0B0C0D;
  data.ref.nt1Enc = 0x1c7a4c61;
  data.ref.par1 = 0;
  countP.value = 0;

  final keys = nested(data, countP);
  print('dart ffi nested -> ${countP.value} keys');
  var pass = false;
  for (var i = 0; i < countP.value; i++) {
    final k = keys[i];
    print('  key$i=0x${k.toRadixString(16)}');
    if (k == 0xA0B1C2D3E4F5) pass = true;
  }
  malloc.free(keys);
  malloc.free(data);
  malloc.free(countP);
  print(pass ? 'FFI CHECK PASS' : 'FFI CHECK FAIL');
}
