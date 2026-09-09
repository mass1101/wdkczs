import 'lib/services/crypto1.dart';

void main() {
  final tests = <(int, int, String)>[
    (0x12345678, 0xA0B1C2D3E4F5, '94bc'),
    (0xFFFFFFFF, 0xFFFFFFFFFFFF, '97ff'),
    (0x00000001, 0x000000000001, 'fefb'),
    (0xC6C6D576, 0x200912280801, '38a1'),
    (0x11223344, 0x5566778899AA, 'ef0d'),
  ];
  var pass = true;
  for (final t in tests) {
    final got = Crypto1.gen3NonceTag(t.$1, t.$2).toRadixString(16);
    final ok = got == t.$3;
    if (!ok) pass = false;
    print('${t.$1.toRadixString(16)} ${t.$2.toRadixString(16)} got=$got want=${t.$3} ${ok ? 'PASS' : 'FAIL'}');
  }
  final keys = Crypto1.gen3GenerateKeys(0xC6C6D576, 0x1234ABCD, 0x5678EF01, 0x5);
  print('gen3GenerateKeys smoke: ${keys.length} candidates');
  print(pass ? 'ALL PASS' : 'FAILED');
}
