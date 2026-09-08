import 'dart:typed_data';

/// MIFARE Crypto1 引擎移植（对应逆向 hS/et 类，mfkey32v2 算法）
///
/// 此实现忠实复刻 mfkey32v2 的 LFSR 状态机与密钥恢复算法。
class Crypto1 {
  static const int _iS = 2739804; // 0x29CE5C
  static const int _nS = 8849412; // 0x870804

  int even = 0;
  int odd = 0;

  Crypto1({this.even = 0, this.odd = 0});

  Crypto1 reset() {
    odd = 0;
    even = 0;
    return this;
  }

  void setLfsr(int key) {
    reset();
    for (var r = 47; r > 0; r -= 2) {
      odd = (odd << 1) | ((key >> ((r - 1) ^ 7)) & 1);
      even = (even << 1) | ((key >> (r ^ 7)) & 1);
    }
  }

  static int readBitLSB(Uint8List buf, int bit) =>
      (buf[bit ~/ 8] >> (bit % 8)) & 1;

  int getLfsr() {
    var t = 0;
    for (var r = 23, i = 3 ^ r; r >= 0; r--, i = 3 ^ r) {
      t = 4 * t + (bit(odd, i) > 0 ? 2 : 0) + bit(even, i);
    }
    return t;
  }

  int lfsrBit(int e, int t) {
    final o = filter(odd);
    final s = (o & (t != 0 ? 1 : 0)) ^ (e != 0 ? 1 : 0) ^ (_iS & odd) ^ (_nS & even);
    final newOdd = ((even << 1) & 0xFFFFFF) | evenParity32(s);
    even = odd;
    odd = newOdd;
    return o;
  }

  int lfsrByte(int e, int t) {
    var i = 0;
    for (var n = 0; n < 8; n++) {
      i |= lfsrBit(bit(e, n), t) << n;
    }
    return i;
  }

  int lfsrWord(int e, int t) {
    var i = 0;
    for (var n = 0; n < 32; n++) {
      i |= lfsrBit(beBit(e, n), t) << (24 ^ n);
    }
    return i & 0xFFFFFFFF;
  }

  int lfsrRollbackBit(int e, int t) {
    final newEven = odd & 0xFFFFFF;
    odd = even;
    even = newEven;
    final l = filter(odd);
    var c = bit(even, 0);
    even = (even >> 1) & 0xFFFFFFFF;
    c ^= _nS & even;
    c ^= _iS & odd;
    c ^= toBool(e) ^ (l & toBool(t));
    even = (even | (evenParity32(c) << 23)) & 0xFFFFFFFF;
    return l;
  }

  int lfsrRollbackByte(int e, int t) {
    var i = 0;
    for (var n = 7; n >= 0; n--) {
      i |= lfsrRollbackBit(bit(e, n), t) << n;
    }
    return i;
  }

  int lfsrRollbackWord(int e, int t) {
    var i = 0;
    for (var n = 31; n >= 0; n--) {
      i |= lfsrRollbackBit(beBit(e, n), t) << (24 ^ n);
    }
    return i & 0xFFFFFFFF;
  }

  static int beBit(int e, int t) => bit(e, 24 ^ t);

  static int bit(int e, int t) => 1 & (e >> t);

  static int toBit(int e) => 1 & e;

  static int toBool(int e) => e != 0 ? 1 : 0;

  static int toUint24(int e) => 0xFFFFFF & e;

  static int toUint32(int e) => e & 0xFFFFFFFF;

  static int toUint8(int e) => 0xFF & e;

  static int castToUint32(dynamic e) {
    if (e is int) return toUint32(e);
    if (e is String) {
      final b = _hexToBytes(e);
      final bd = ByteData.sublistView(b);
      return bd.getUint32(0) & 0xFFFFFFFF;
    }
    return toUint32(e as int);
  }

  static Uint8List? _lfsrBuf;

  static Uint8List get lfsrBuf => _lfsrBuf ??= Uint8List(8);

  /// filter 函数（mfkey32v2 标准表）
  static int filter(int e) {
    var t = 0;
    t |= 991936 >> (15 & e) & 16;
    t |= 444864 >> ((e >> 4) & 15) & 8;
    t |= 247984 >> ((e >> 8) & 15) & 4;
    t |= 123992 >> ((e >> 12) & 15) & 2;
    t |= 55608 >> ((e >> 16) & 15) & 1;
    return bit(3965184010, t);
  }

  static Uint8List? _evenParityCache;

  static void _ensureParityCache() {
    if (_evenParityCache != null && _evenParityCache!.length == 256) return;
    final t = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      var e = i;
      e ^= e >> 4;
      e ^= e >> 2;
      t[i] = bit(e ^ (e >> 1), 0);
    }
    _evenParityCache = t;
  }

  static int evenParity8(int e) {
    _ensureParityCache();
    return _evenParityCache![0xFF & e];
  }

  static int oddParity8(int e) => 1 - evenParity8(e);

  static int evenParity32(int e) {
    e ^= e >> 16;
    return evenParity8(e ^ (e >> 8));
  }

  static int swapEndian(int e) {
    final buf = lfsrBuf;
    ByteData.sublistView(buf).setUint32(0, e & 0xFFFFFFFF);
    return ByteData.sublistView(buf).getUint32(0, Endian.little) & 0xFFFFFFFF;
  }

  /// PRNG 前向（经典 prng_successor）
  static int prngSuccessor(int e, int t) {
    e = swapEndian(e);
    for (var i = 0; i < t; i++) {
      e = (e >> 1) | (((e >> 16) ^ (e >> 18) ^ (e >> 19) ^ (e >> 21)) << 31);
      e &= 0xFFFFFFFF;
    }
    return swapEndian(e);
  }

  static int updateContribution(int e, int t, int r) {
    e &= 0xFFFFFFFF;
    var o = e >> 25;
    o = o << 2 | (evenParity32(e & t) > 0 ? 2 : 0) | evenParity32(e & r);
    return ((o << 24) | (0xFFFFFF & e)) & 0xFFFFFFFF;
  }

  static int _extendTable(_ListRef e, int r, int i, int n, int o) {
    o = (o << 24) & 0xFFFFFFFF;
    for (var c = 0; c < e.s; c++) {
      final a = filter(e.d[e.off + c] *= 2);
      if ((a ^ filter(1 | e.d[e.off + c])) != 0) {
        e.d[e.off + c] = updateContribution(e.d[e.off + c] + (a ^ r), i, n) ^ o;
      } else if (a == r) {
        c++;
        final tmp = e.d[e.off + c];
        e.d[e.off + e.s] = tmp;
        e.s++;
        e.d[e.off + c] = updateContribution(e.d[e.off + c - 1] + 1, i, n) ^ o;
        e.d[e.off + c - 1] = updateContribution(e.d[e.off + c - 1], i, n) ^ o;
      } else {
        e.s--;
        e.d[e.off + c] = e.d[e.off + e.s];
        c--;
      }
    }
    return e.s;
  }

  static int _extendTableSimple(_ListRef e, int r) {
    for (var n = 0; n < e.s; n++) {
      final o = filter(e.d[e.off + n] *= 2);
      if ((o ^ filter(1 | e.d[e.off + n])) != 0) {
        e.d[e.off + n] += o ^ r;
      } else if (o == r) {
        e.d[e.off + e.s] = e.d[e.off + n + 1];
        e.s++;
        n++;
        e.d[e.off + n] = e.d[e.off + n - 1] + 1;
      } else {
        e.s--;
        e.d[e.off + n] = e.d[e.off + e.s];
        n--;
      }
    }
    return e.s;
  }

  /// mfkeyRecoverState：候选状态表恢复（递归）
  static void _mfkeyRecoverState(
      _RecoverState st, void Function(Crypto1) onState) {
    final a = st.evens;
    final l = st.odds;
    final c = st.states;
    if (st.rem < 0) {
      for (var u = 0; u < a.s; u++) {
        a.d[a.off + u] = ((a.d[a.off + u] << 1) ^
                evenParity32(a.d[a.off + u] & _nS) ^
                ((st.input & 4) != 0 ? 1 : 0)) &
            0xFFFFFFFF;
        for (var e = 0; e < l.s; e++) {
          c.add(Crypto1(
              even: l.d[l.off + e],
              odd: (a.d[a.off + u] ^ evenParity32(l.d[l.off + e] & _iS)) &
                  0xFFFFFFFF));
        }
      }
      for (final s in c) {
        onState(s);
      }
    } else {
      // 对齐 JS `t<4 && 0!=e.rem--`：最后一次失败比较也会执行 rem--，
      // 因此 rem 会从 0 减到 -1，触发递归子级的 rem<0 终止分支
      for (var t = 0; t < 4;) {
        final old = st.rem;
        st.rem = old - 1;
        if (old == 0) break;
        st.oks = (st.oks >> 1) & 0xFFFFFFFF;
        st.eks = (st.eks >> 1) & 0xFFFFFFFF;
        st.input = (st.input >> 2) & 0xFFFFFFFF;
        l.s = _extendTable(l, bit(st.oks, 0), 17698825, 5479608, 0);
        if (l.s == 0) return;
        a.s = _extendTable(a, bit(st.eks, 0), _iS, 17698825, 3 & st.input);
        if (a.s == 0) return;
        t++;
      }
      // 对齐小程序 subarray(0, s).sort()：在父缓冲区内原地排序，
      // 供递归子视图共享（sublist 复制会导致子级 extendTable 增长越界）
      final aTmp = a.d.sublist(a.off, a.off + a.s);
      aTmp.sort();
      a.d.setRange(a.off, a.off + a.s, aTmp);
      final lTmp = l.d.sublist(l.off, l.off + l.s);
      lTmp.sort();
      l.d.setRange(l.off, l.off + l.s, lTmp);
      while (l.s + a.s != 0) {
        // 对齐 JS：空表读 view[-1] 得 undefined，&0xFF000000 后为 0
        final topL = l.s > 0 ? toUint32(0xFF000000 & l.d[l.off + l.s - 1]) : 0;
        final topA = a.s > 0 ? toUint32(0xFF000000 & a.d[a.off + a.s - 1]) : 0;
        if (topL != topA) {
          if (topL > topA) {
            l.s = _sortedIndex(l, topL);
          } else {
            a.s = _sortedIndex(a, topA);
          }
          continue;
        }
        final n = _sortedIndex(a, topA);
        final o = _sortedIndex(l, topL);
        _mfkeyRecoverState(
          _RecoverState(
            eks: st.eks,
            evens: _ListRef(a.d, a.off + n, a.s - n),
            odds: _ListRef(l.d, l.off + o, l.s - o),
            oks: st.oks,
            states: st.states,
            rem: st.rem,
            input: st.input,
          ),
          onState,
        );
        a.s = n;
        l.s = o;
      }
    }
  }

  static int _sortedIndex(_ListRef b, int value) {
    var lo = 0, hi = b.s;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (b.d[b.off + mid] < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// lfsrRecovery32：从 32 位 keystream 恢复状态候选
  static List<Crypto1> lfsrRecovery32(int e, int t) {
    final l = _ListRef(Uint32List(1 << 21), 0, 0);
    final c = _ListRef(Uint32List(1 << 21), 0, 0);
    final states = <Crypto1>[];
    var d = 0, h = 0;
    for (var f = 31; f > 0; f -= 2) {
      d = toUint32((d << 1) | beBit(e, f));
      h = toUint32((h << 1) | beBit(e, f - 1));
    }
    final p = toUint32(h) & 1;
    final m = toUint32(d) & 1;
    for (var f = 1 << 20; f >= 0; f--) {
      if (filter(f) == m) c.d[c.off + c.s++] = f;
      if (filter(f) == p) l.d[l.off + l.s++] = f;
    }
    for (var f = 0; f < 4; f++) {
      h = (h >> 1) & 0xFFFFFFFF;
      d = (d >> 1) & 0xFFFFFFFF;
      l.s = _extendTableSimple(l, h & 1);
      c.s = _extendTableSimple(c, d & 1);
    }
    final input = ((t << 16) | ((t >> 16) & 255) | (65280 & t)) << 1;
    final st = _RecoverState(
      eks: h,
      evens: l,
      odds: c,
      oks: d,
      states: states,
      rem: 11,
      input: toUint32(input),
    );
    _mfkeyRecoverState(st, (_) {});
    return states;
  }

  /// mfkey32v2：通过两组 auth 交互恢复 48 位密钥
  static List<int> mfkey32v2({
    required int uid,
    required int nt0,
    required int nr0,
    required int ar0,
    required int nt1,
    required int nr1,
    required int ar1,
  }) {
    final o = castToUint32(uid);
    final s = castToUint32(nt0);
    final a = castToUint32(nr0);
    final l = castToUint32(ar0);
    final c = castToUint32(nt1);
    final u = castToUint32(nr1);
    final d = castToUint32(ar1);
    final h = prngSuccessor(s, 64);
    final f = prngSuccessor(c, 64);
    final p = lfsrRecovery32(l ^ h, 0);
    final result = <int>[];
    for (final m in p) {
      m.lfsrRollbackWord(0, 0);
      m.lfsrRollbackWord(a, 1);
      m.lfsrRollbackWord(o ^ s, 0);
      final e = m.getLfsr();
      m.lfsrWord(o ^ c, 0);
      m.lfsrWord(u, 1);
      if (toUint32(m.lfsrWord(0, 0) ^ f) == d) {
        result.add(e);
      }
    }
    return result;
  }

  /// 用已知密钥解密数据（对应逆向 hS.decrypt）
  static Uint8List decrypt({
    required Uint8List key,
    required Uint8List data,
    required int uid,
    required int nt,
    required int nr,
  }) {
    final o = data.sublist(0);
    final s = Crypto1();
    s.setLfsr(_bytesToInt(key));
    s.lfsrWord(toUint32(uid) ^ toUint32(nt), 0);
    s.lfsrWord(toUint32(nr), 1);
    s.lfsrWord(0, 0);
    s.lfsrWord(0, 0);
    for (var a = 0; a < o.length; a++) {
      o[a] ^= s.lfsrByte(0, 0);
    }
    return o;
  }

  static int _bytesToInt(Uint8List b) {
    if (b.length < 8) {
      final padded = Uint8List(8);
      padded.setRange(8 - b.length, 8, b);
      return ByteData.sublistView(padded).getUint64(2, Endian.big).toInt();
    }
    return ByteData.sublistView(b).getUint64(b.length - 8, Endian.big).toInt();
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.replaceAll(' ', '');
    final bytes = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  // ---- lfsr64（Darkside 专用表） ----
  static const List<int> _oS = [
    401729, 200864, 100432, 50216, 25108, 12554, 548400, 813485, 406742,
    744670, 911578, 455789, 736387, 368193, 690581, 852607, 426303, 213151,
    648954,
  ];
  static const List<int> _sS = [
    978680576, 1563082112, 781541056, 390770528, 195385264, 97692632, 71949928,
    75785392, 1111634520, 662803112, 358630096, 179315048, 1140366128,
    1643924888, 1985916232, 2106580256, 2127031952, 2137257800, 2031185952,
  ];
  static const List<int> _aS = [
    324477, 162238, 621162, 310581, 155290, 77645, 38822, 527718, 802822,
    401411, 743092, 371546, 693016, 855865, 427932, 722299, 361149, 180574,
    90287, 587490, 802244, 940119, 470059, 235029, 626111, 819306, 919168,
    459584, 229792, 624229, 312114, 665388,
  ];
  static const List<int> _lS = [
    1015592976, 1581538312, 696427904, 348213952, 1247848800, 623924400,
    1385704024, 804036264, 290899152, 145449576, 1123367600, 561683800,
    371049768, 229533968, 1188508808, 634065344, 1390774496, 1769129072,
    884564536, 1560033944, 685676232, 315605216, 1231544432, 1689514040,
    1962505112, 2094805576, 953062048, 476531024, 238265512, 28924368,
    1088204008, 651091440,
  ];
  static const List<int> _cS = [542389, 271194, 135597];
  static const List<int> _uS = [27796192, 564667104, 564667104];
  static const List<int> _dS = [
    0, 310355, 60593, 282850, 155177, 451194, 176792, 397003, 0, 121186,
    310355, 353585, 60593, 79315, 282850, 362880,
  ];

  /// lfsrRecovery64：Darkside 64 位 keystream 状态恢复
  static Crypto1 lfsrRecovery64(int e, int t) {
    final s = List<int>.filled(32, 0);
    final a = List<int>.filled(32, 0);
    final l = List<int>.filled(32, 0);
    var c = 0, u = 0;
    final d = _ListRef(Uint32List(65536), 0, 0);
    for (var f = 30; f >= 0; f -= 2) {
      s[f >> 1] = beBit(e, f);
      s[16 + (f >> 1)] = beBit(t, f);
    }
    for (var f = 31; f >= 0; f -= 2) {
      a[f >> 1] = beBit(e, f);
      a[16 + (f >> 1)] = beBit(t, f);
    }
    for (var f = 1048575; f >= 0; f--) {
      if (filter(f) == s[0]) {
        d.s = 0;
        d.d[d.off + d.s++] = f;
        for (var e2 = 1; d.s != 0 && e2 < 29; e2++) {
          d.s = _extendTableSimple(d, s[e2]);
        }
        if (d.s != 0) {
          for (var e2 = 0; e2 < 19; e2++) {
            c = c << 1 | evenParity32(f & _oS[e2]);
          }
          for (var e2 = 0; e2 < 32; e2++) {
            l[e2] = evenParity32(f & _aS[e2]);
          }
          for (var e2 = d.s - 1; e2 >= 0; e2--) {
            var failed = false;
            for (var t2 = 0; t2 < 3; t2++) {
              d.d[d.off + e2] = (d.d[d.off + e2] << 1) & 0xFFFFFFFF;
              d.d[d.off + e2] = (d.d[d.off + e2] | evenParity32(f & _cS[t2] ^ d.d[d.off + e2] & _uS[t2])) & 0xFFFFFFFF;
              if (filter(d.d[d.off + e2]) != s[29 + t2]) {
                failed = true;
                break;
              }
            }
            if (failed) continue;
            u = 0;
            for (var t2 = 0; t2 < 19; t2++) {
              u = (u << 1) & 0xFFFFFFFF | evenParity32(d.d[d.off + e2] & _sS[t2]);
            }
            u ^= c;
            failed = false;
            for (var t2 = 0; t2 < 32; t2++) {
              u = ((u << 1) ^ l[t2] ^ evenParity32(d.d[d.off + e2] & _lS[t2])) & 0xFFFFFFFF;
              if (filter(u) != a[t2]) {
                failed = true;
                break;
              }
            }
            if (failed) continue;
            d.d[d.off + e2] = ((d.d[d.off + e2] << 1) | evenParity32(_nS & d.d[d.off + e2])) & 0xFFFFFFFF;
            return Crypto1(
                even: u, odd: (d.d[d.off + e2] ^ evenParity32(_iS & u)) & 0xFFFFFFFF);
          }
        }
      }
    }
    throw StateError('failed to recover lfsr');
  }

  /// mfkey64：Darkside 密钥恢复
  static int mfkey64({
    required int uid,
    required int nt,
    required int nr,
    required int ar,
    required int at,
  }) {
    final n = castToUint32(uid);
    final o = castToUint32(nt);
    final s = castToUint32(nr);
    final a = castToUint32(ar);
    final l = castToUint32(at);
    final c = prngSuccessor(o, 64);
    final u = a ^ c;
    final d = l ^ prngSuccessor(c, 32);
    final h = lfsrRecovery64(u, d);
    h.lfsrRollbackWord(0, 0);
    h.lfsrRollbackWord(0, 0);
    h.lfsrRollbackWord(s, 1);
    h.lfsrRollbackWord(n ^ o, 0);
    return h.getLfsr();
  }

  /// nestedRecoverState：从多组嵌套攻击数据恢复候选密钥
  static List<int> nestedRecoverState({
    required int uid,
    required List<Map<String, int>> atks,
  }) {
    final counts = <int, int>{};
    for (final atk in atks) {
      final n = toUint32(atk['ntp']! ^ uid);
      final a = lfsrRecovery32(atk['ks1']!, n);
      for (final e in a) {
        e.lfsrRollbackWord(n, 0);
        final t = e.getLfsr();
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final sorted = counts.entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    return sorted.take(50).map((e) => e.key).toList();
  }

  /// staticnested：静态随机数嵌套攻击
  static List<int> staticnested({
    required int uid,
    required int keyType,
    required List<Map<String, int>> atks,
  }) {
    final o = castToUint32(atks[0]['nt1']!);
    var s = 0;
    if (18874693 == o) {
      s = 160;
    } else if (9470114 == o) {
      s = keyType == 96 ? 160 : 161;
    } else {
      throw StateError('unknown static nonce');
    }
    final converted = <Map<String, int>>[];
    for (final atk in atks) {
      final r = castToUint32(atk['nt1']!);
      final o2 = castToUint32(atk['nt2']!);
      final a = prngSuccessor(r, s);
      final l = toUint32(o2 ^ a);
      s += 160;
      converted.add({'ntp': a, 'ks1': l});
    }
    return nestedRecoverState(uid: uid, atks: converted);
  }

  /// nested：非静态随机数嵌套攻击
  static List<int> nested({
    required int uid,
    required int dist,
    required List<Map<String, int>> atks,
  }) {
    final s = castToUint32(dist);
    final collected = <Map<String, int>>[];
    for (final atk in atks) {
      final c = castToUint32(atk['nt1']!);
      final u = castToUint32(atk['nt2']!);
      final d = castToUint32(atk['par']!);
      var h = prngSuccessor(c, s - 14);
      for (var e2 = 0; e2 < 29; e2++, h = prngSuccessor(h, 1)) {
        final e = toUint32(u ^ h);
        if (nestedIsValidNonce(h, u, e, d)) {
          collected.add({'ntp': h, 'ks1': e});
        }
      }
    }
    return nestedRecoverState(uid: uid, atks: collected);
  }

  static bool nestedIsValidNonce(int e, int t, int r, int i) {
    return evenParity8((e >> 24) & 255) ==
            (bit(i, 0) ^ evenParity8((t >> 24) & 255) ^ bit(r, 16)) &&
        (evenParity8((e >> 16) & 255) ==
                (bit(i, 1) ^ evenParity8((t >> 16) & 255) ^ bit(r, 8)) &&
            evenParity8((e >> 8) & 255) ==
                (bit(i, 2) ^ evenParity8((t >> 8) & 255) ^ bit(r, 0)));
  }

  /// lfsrPrefixKs：Darkside 前缀候选（o=true 奇数位）
  static List<int> lfsrPrefixKs(Uint8List e, bool t) {
    final o = <int>[];
    for (var s = 0; s < 2097152; s++) {
      var valid = true;
      for (var o2 = 0; valid && o2 < 8; o2++) {
        final l = toUint32(s ^ _dS[t ? 8 + o2 : o2]);
        valid = bit(e[o2], t ? 1 : 0) == filter(l >> 1) &&
            bit(e[o2], t ? 3 : 2) == filter(l);
      }
      if (valid) o.add(s);
    }
    return o;
  }

  /// checkPfxParity：Darkside 前缀奇偶校验
  static Crypto1? checkPfxParity(
      int e, int t, List<List<int>> r, int i, int n, bool o) {
    final c = Crypto1();
    for (var u = 0; u < 8; u++) {
      c.odd = toUint32(i ^ _dS[8 + u]);
      c.even = toUint32(n ^ _dS[u]);
      c.lfsrRollbackBit(0, 0);
      c.lfsrRollbackBit(0, 0);
      final d = c.lfsrRollbackBit(0, 0);
      final h = c.lfsrRollbackWord(0, 0);
      final f = c.lfsrRollbackWord(e | u << 5, 1);
      if (o) return c;
      final p = toUint32(f ^ (e | u << 5));
      final m = toUint32(h ^ t);
      if ((evenParity32(255 & p) ^ r[u][3] ^ bit(h, 24)) < 1) return null;
      if ((evenParity32(4278190080 & m) ^ r[u][4] ^ bit(h, 16)) < 1) return null;
      if ((evenParity32(16711680 & m) ^ r[u][5] ^ bit(h, 8)) < 1) return null;
      if ((evenParity32(65280 & m) ^ r[u][6] ^ bit(h, 0)) < 1) return null;
      if ((evenParity32(255 & m) ^ r[u][7] ^ d) < 1) return null;
    }
    return c;
  }

  /// lfsrCommonPrefix：Darkside 公共前缀恢复
  static List<Crypto1> lfsrCommonPrefix(int e, int t, Uint8List r,
      List<List<int>> i, bool n) {
    final a = lfsrPrefixKs(r, true);
    final l = lfsrPrefixKs(r, false);
    final c = <Crypto1>[];
    for (var u in a) {
      for (var r2 in l) {
        for (var o = 0; o < 64; o++) {
          u += 2097152;
          r2 += (7 & o) > 0 ? 2097152 : 4194304;
          final a2 = checkPfxParity(e, t, i, u, r2, n);
          if (a2 != null) c.add(a2);
        }
      }
    }
    return c;
  }

  /// darkside：异步采集并恢复密钥
  static Future<int?> darkside(
    Future<Map<String, Uint8List>?> Function(int) acquire,
    Future<bool> Function(Uint8List) checkKey, {
    int maxAttempts = 256,
  }) async {
    final seen = <int>{};
    var accepted = <int>{};
    for (var l = 0; l < maxAttempts; l++) {
      final r = await acquire(l) ?? {};
      Uint8List? rUid = r['uid'];
      Uint8List? rNt = r['nt'];
      Uint8List? rAr = r['ar'];
      Uint8List? rNr = r['nr'];
      Uint8List? rKs = r['ks'];
      Uint8List? rPar = r['par'];
      if (rUid == null || rUid.length != 4) {
        throw ArgumentError('Failed to acquire darkside result: invalid uid');
      }
      if (rNt == null || rNt.length != 4) {
        throw ArgumentError('Failed to acquire darkside result: invalid nt');
      }
      if (rAr == null || rAr.length != 4) {
        throw ArgumentError('Failed to acquire darkside result: invalid ar');
      }
      if (rNr == null || rNr.length != 4) {
        throw ArgumentError('Failed to acquire darkside result: invalid nr');
      }
      if (rKs == null || rKs.length != 8) {
        throw ArgumentError('Failed to acquire darkside result: invalid ks');
      }
      if (rPar == null || rPar.length != 8) {
        throw ArgumentError('Failed to acquire darkside result: invalid par');
      }
      final c = ByteData.sublistView(rUid).getUint32(0);
      final u = ByteData.sublistView(rNt).getUint32(0);
      final d = ByteData.sublistView(rAr).getUint32(0);
      final h = 4294967071 & ByteData.sublistView(rNr).getUint32(0);
      final f = Uint8List.fromList(rKs.map((x) => 15 & x).toList());
      final p = rPar.map((x) => List<int>.generate(8, (t) => bit(x, t))).toList();
      final m = rPar[0] == 0 && rPar[1] == 0 && rPar[2] == 0 && rPar[3] == 0 &&
          rPar[4] == 0 && rPar[5] == 0 && rPar[6] == 0 && rPar[7] == 0;
      var y = <int>{};
      final g = lfsrCommonPrefix(h, d, f, p, m);
      for (final e in g) {
        e.lfsrRollbackWord(toUint32(c ^ u), 0);
        y.add(e.getLfsr());
      }
      if (y.isNotEmpty) {
        if (m) {
          final tmp = accepted;
          accepted = y;
          y = tmp;
          y.removeWhere((e) => accepted.contains(e));
        }
        for (final e in y.toList()) {
          if (seen.contains(e)) continue;
          seen.add(e);
          final buf = Uint8List(6);
          final bd = ByteData.sublistView(buf);
          bd.setUint16(0, (e >> 32) & 0xFFFF, Endian.big);
          bd.setUint32(2, e & 0xFFFFFFFF, Endian.big);
          if (await checkKey(buf)) return e;
        }
      }
    }
    throw StateError('failed to find key, darkside attempts = $maxAttempts');
  }
}

/// 基于大缓冲区的偏移视图（对齐 JS subarray / C 指针语义）：
/// 元素 i 位于 d[off + i]，extendTable 增长时可写入 off+s 之后的空闲空间
class _ListRef {
  final Uint32List d;
  final int off;
  int s;
  _ListRef(this.d, this.off, this.s);
}

class _RecoverState {
  int eks;
  _ListRef evens;
  _ListRef odds;
  int oks;
  List<Crypto1> states;
  int rem;
  int input;
  _RecoverState({
    required this.eks,
    required this.evens,
    required this.odds,
    required this.oks,
    required this.states,
    required this.rem,
    required this.input,
  });
}
