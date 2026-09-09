import 'lib/services/crypto1.dart';

void main() {
  // 复刻 gen3NonceTag 加逐轮打印（与 JS 权威轨迹对拍）
  Crypto1.ensureGen3TablesForTest();
  var s = 0x1234;
  for (var d = 0; d < 14; d++) {
    s = Crypto1.gen3StepForTest(s);
  }
  print('init s=${s.toRadixString(16)}');
  var l = 1;
  var t = 0xA0B1C2D3E4F5;
  for (var d = 0; d < 48; d += 8) {
    if (d == 32) {
      t = (t >> 32) & 0xFFFF;
      if (l == 1) {
        s ^= Crypto1.tab1ForTest[t & 15];
        s ^= Crypto1.tab2ForTest[(t >> 4) & 15] << 4;
      } else {
        s ^= Crypto1.tab2ForTest[t & 15];
        s ^= Crypto1.tab1ForTest[(t >> 4) & 15] << 4;
      }
    } else if (d > 32) {
      t = (t >> 40) & 0xFF;
      if (l == 1) {
        s ^= Crypto1.tab1ForTest[t & 15];
        s ^= Crypto1.tab2ForTest[(t >> 4) & 15] << 4;
      } else {
        s ^= Crypto1.tab2ForTest[t & 15];
        s ^= Crypto1.tab1ForTest[(t >> 4) & 15] << 4;
      }
    } else {
      final lo = (t >> d) & 15;
      final hi = (t >> (d + 4)) & 15;
      if (l == 1) {
        s ^= Crypto1.tab1ForTest[lo];
        s ^= Crypto1.tab2ForTest[hi] << 4;
      } else {
        s ^= Crypto1.tab2ForTest[lo];
        s ^= Crypto1.tab1ForTest[hi] << 4;
      }
    }
    print('d=$d l=$l t=${t.toRadixString(16)} xorS=${s.toRadixString(16)}');
    l ^= 1;
    for (var k = 0; k < 8; k++) {
      s = Crypto1.gen3StepForTest(s);
    }
    print('d=$d stepS=${s.toRadixString(16)}');
  }
  print('final=${s.toRadixString(16)}');
}
