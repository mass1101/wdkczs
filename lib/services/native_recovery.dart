import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
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

final class _StaticEncryptedNested extends Struct {
  @Uint32()
  external int uid;
  @Uint32()
  external int nt;
  @Uint32()
  external int ntEnc;
  @Uint32()
  external int ntParEnc;
}

typedef _StaticEncryptedNestedFn = Pointer<Uint64> Function(Pointer<_StaticEncryptedNested>, Pointer<Uint32>);

typedef _NestedFn = Pointer<Uint64> Function(Pointer<_Nested>, Pointer<Uint32>);
typedef _StaticNestedFn = Pointer<Uint64> Function(Pointer<_StaticNested>, Pointer<Uint32>);
typedef _HardnestedFn = Uint64 Function(Pointer<_HardNested>);
typedef _HardnestedDartFn = int Function(Pointer<_HardNested>);

final class _HardNested extends Struct {
  external Pointer<Char> nonces;
  @Uint32()
  external int length;
}

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

  /// Darkside 攻击（PM3 nonce2key，C 库同源 CU librecovery）：
  /// 多条样本累积恢复，par==0（lucky 轮）候选与上轮交集收窄。
  /// 计算耗时可能上百毫秒，内部 Isolate.run 防阻塞 UI。
  /// items 每条 = 一次固件采集 (nt1, ks1, par, nr, ar)，ks1/par 为大端 u64。
  static Future<List<int>> darkside({
    required int uid,
    required List<({int nt1, int ks1, int par, int nr, int ar})> items,
  }) {
    return Isolate.run(() => _darksideSync(uid: uid, items: items));
  }

  static List<int> _darksideSync({
    required int uid,
    required List<({int nt1, int ks1, int par, int nr, int ar})> items,
  }) {
    init();
    final lib = _lib;
    if (lib == null) return const [];
    final f = lib.lookupFunction<_DarksideFn, _DarksideFn>('darkside');
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
      return _readKeys(keys, countP.value);
    } finally {
      malloc.free(data);
      malloc.free(itemsP);
      malloc.free(countP);
    }
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

  /// PM3 nonce 缓冲（6 字节头 uid+占位 + 每条 9 字节 nt/ntEnc/par，大端）
  /// → native hardnested（mfnestedhard，多线程，分钟级阻塞），返回 0 表示失败。
  /// 必须在 isolate 中执行（[hardNested]）。
  static int _hardNestedSync(Uint8List buf) {
    final lib = DynamicLibrary.open('librecovery.so');
    final f = lib.lookupFunction<_HardnestedFn, _HardnestedDartFn>('hardnested');
    final p = malloc<_HardNested>();
    final data = malloc<Uint8>(buf.length);
    data.asTypedList(buf.length).setAll(0, buf);
    p.ref.nonces = data.cast<Char>();
    p.ref.length = buf.length;
    final result = f(p);
    malloc.free(p);
    malloc.free(data);
    return result;
  }

  /// Hardnested 攻击（借鉴 Chameleon Ultra：PM3 mfnestedhard native 多线程）。
  /// 阻塞计算分钟级，放入独立 isolate 执行；结果为单 key（0 = 失败）。
  static Future<int> hardNested(Uint8List buf) {
    return Isolate.run(() => _hardNestedSync(buf));
  }

  /// 可取消版 Hardnested：返回 [HardNestedJob]，停止时 kill() 立即终止
  /// C 计算（Isolate.run 无法取消，长时间计算会卡住停止响应）
  static HardNestedJob hardNestedStart(Uint8List buf) {
    return HardNestedJob.start(buf);
  }

  /// 后门卡静态加密嵌套恢复（lfsr_recovery32，毫秒级）
  /// [ntParEnc] 为密文域 parity 的千位编码（parityToInt 语义，bit3=最高字节）
  /// 返回候选 key 列表（uint64 低 48 位），上限 8192
  static List<int> staticEncryptedNested({
    required int uid,
    required int nt,
    required int ntEnc,
    required int ntParEnc,
  }) {
    final lib = _lib;
    if (lib == null) return const [];
    final f = lib
        .lookupFunction<_StaticEncryptedNestedFn, _StaticEncryptedNestedFn>(
            'static_encrypted_nested');
    final data = malloc<_StaticEncryptedNested>();
    final countP = malloc<Uint32>();
    data.ref.uid = uid & 0xFFFFFFFF;
    data.ref.nt = nt & 0xFFFFFFFF;
    data.ref.ntEnc = ntEnc & 0xFFFFFFFF;
    data.ref.ntParEnc = ntParEnc & 0xFFFFFFFF;
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

/// 可取消的 hardnested 计算任务
class HardNestedJob {
  final Completer<int> _completer = Completer<int>();
  Isolate? _isolate;

  HardNestedJob._();

  bool get isCompleted => _completer.isCompleted;

  Future<int> get future => _completer.future;

  /// 立即终止计算（幂等；已完成时无副作用）
  void kill() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    if (!_completer.isCompleted) _completer.complete(0);
  }

  static HardNestedJob start(Uint8List buf) {
    final job = HardNestedJob._();
    final port = ReceivePort();
    port.listen((msg) {
      port.close();
      if (!job._completer.isCompleted) job._completer.complete(msg as int);
    }, onDone: () {
      if (!job._completer.isCompleted) job._completer.complete(0);
    });
    Isolate.spawn(_hardNestedEntry, (port.sendPort, buf)).then((iso) {
      if (job._completer.isCompleted) {
        iso.kill(priority: Isolate.immediate);
        return;
      }
      job._isolate = iso;
    }, onError: (Object e) {
      if (!job._completer.isCompleted) job._completer.complete(0);
    });
    return job;
  }

  static void _hardNestedEntry((SendPort, Uint8List) args) {
    final (port, buf) = args;
    port.send(NativeRecovery._hardNestedSync(buf));
  }
}

