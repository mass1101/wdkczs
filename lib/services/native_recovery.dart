import 'dart:ffi';
import 'package:ffi/ffi.dart';

// FFI 绑定：Chameleon Ultra 移植的 PM3 native 解卡库（native/CMakeLists.txt 构建）
// 仅在加载成功时启用（NativeRecovery.available），失败自动回退 Dart 实现

final class _Nested extends Struct {
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

final class _StaticNested extends Struct {
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

typedef _NestedFn = Pointer<Uint64> Function(Pointer<_Nested>, Pointer<Uint32>);
typedef _StaticNestedFn = Pointer<Uint64> Function(Pointer<_StaticNested>, Pointer<Uint32>);

class NativeRecovery {
  static DynamicLibrary? _lib;
  static bool get available => _lib != null;

  static void init() {
    if (_lib != null) return;
    try {
      _lib = DynamicLibrary.open('librecovery.so');
    } catch (_) {
      _lib = null;
    }
  }

  static List<int> _readKeys(Pointer<Uint64> keys, int count) {
    final out = <int>[];
    for (var i = 0; i < count; i++) {
      out.add(keys[i]);
    }
    malloc.free(keys);
    return out;
  }

  /// 弱随机卡嵌套攻击（PM3 mfnested，毫秒级）
  static List<int> nested({
    required int uid,
    required int dist,
    required int nt0,
    required int nt0Enc,
    required int par0,
    required int nt1,
    required int nt1Enc,
    required int par1,
  }) {
    final lib = _lib;
    if (lib == null) return const [];
    final f = lib
        .lookupFunction<_NestedFn, _NestedFn>('nested');
    final data = malloc<_Nested>();
    final countP = malloc<Uint32>();
    data.ref.uid = uid & 0xFFFFFFFF;
    data.ref.dist = dist & 0xFFFFFFFF;
    data.ref.nt0 = nt0 & 0xFFFFFFFF;
    data.ref.nt0Enc = nt0Enc & 0xFFFFFFFF;
    data.ref.par0 = par0 & 0xFFFFFFFF;
    data.ref.nt1 = nt1 & 0xFFFFFFFF;
    data.ref.nt1Enc = nt1Enc & 0xFFFFFFFF;
    data.ref.par1 = par1 & 0xFFFFFFFF;
    countP.value = 0;
    try {
      final keys = f(data, countP);
      if (keys == nullptr) return const [];
      return _readKeys(keys, countP.value);
    } finally {
      malloc.free(data);
      malloc.free(countP);
    }
  }

  /// 静态随机卡嵌套攻击（staticnested_1gen，毫秒级）
  static List<int> staticNested({
    required int uid,
    required int keyType,
    required int nt0,
    required int nt0Enc,
    required int nt1,
    required int nt1Enc,
  }) {
    final lib = _lib;
    if (lib == null) return const [];
    final f = lib
        .lookupFunction<_StaticNestedFn, _StaticNestedFn>('static_nested');
    final data = malloc<_StaticNested>();
    final countP = malloc<Uint32>();
    data.ref.uid = uid & 0xFFFFFFFF;
    data.ref.keyType = keyType & 0xFFFFFFFF;
    data.ref.nt0 = nt0 & 0xFFFFFFFF;
    data.ref.nt0Enc = nt0Enc & 0xFFFFFFFF;
    data.ref.nt1 = nt1 & 0xFFFFFFFF;
    data.ref.nt1Enc = nt1Enc & 0xFFFFFFFF;
    countP.value = 0;
    try {
      final keys = f(data, countP);
      if (keys == nullptr) return const [];
      return _readKeys(keys, countP.value);
    } finally {
      malloc.free(data);
      malloc.free(countP);
    }
  }
}

