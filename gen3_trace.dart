void main() {
  final sI = List<int>.filled(65536, 0);
  final aI = List<int>.filled(65536, 0);
  var e = 1;
  for (var t = 1; t < 65536; ++t) {
    sI[((e & 255) << 8) | (e >> 8)] = t;
    aI[t] = ((e & 255) << 8) | (e >> 8);
    e = (e >> 1) | ((e ^ (e >> 2) ^ (e >> 3) ^ (e >> 5)) << 15);
    e &= 65535;
  }
  print('sI[0x1234]=${sI[0x1234]}');
  var s = 0x1234;
  final trace = <String>[];
  for (var d = 0; d < 14; d++) {
    var t = sI[s & 0xFFFF];
    t = t == 1 ? 65535 : t - 1;
    s = aI[t];
    trace.add(s.toRadixString(16));
  }
  print('DART steps: ${trace.join(',')}');
}
