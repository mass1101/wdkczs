import 'dart:typed_data';

/// UltraFrame 帧协议编解码（对应逆向 xw.pack 契约）
///
/// 帧格式（大端）：
///   [0..1]   magic     0x11EF
///   [2..3]   cmd       UInt16BE
///   [4..5]   status    UInt16BE（请求恒 0，响应为状态码）
///   [6..7]   len       UInt16BE
///   [8]      头 LRC
///   [9..9+len) data
///   [末尾]   尾 LRC
///
/// LRC = (256 - Σbytes) & 255
class UltraFrame {
  static const int magic = 0x11EF;
  static const int maxDataLen = 512;
  static const int chunkSize = 20; // BLE MTU 分块
  static const int defaultTimeoutMs = 5000;

  /// 计算 LRC
  static int lrc(Uint8List bytes) {
    var sum = 0;
    for (final b in bytes) {
      sum = (sum + b) & 0xFF;
    }
    return (256 - sum) & 0xFF;
  }

  /// 编码请求帧
  static Uint8List encode({
    required int cmd,
    required Uint8List data,
    int status = 0,
  }) {
    if (data.length > maxDataLen) {
      throw ArgumentError('data too long: ${data.length} > $maxDataLen');
    }
    final header = Uint8List(8);
    final hb = ByteData.sublistView(header);
    hb.setUint16(0, magic);
    hb.setUint16(2, cmd);
    hb.setUint16(4, status);
    hb.setUint16(6, data.length);

    final headLrc = lrc(header);

    final frame = Uint8List(9 + data.length + 1);
    frame.setRange(0, 8, header);
    frame[8] = headLrc;
    frame.setRange(9, 9 + data.length, data);
    final tail = Uint8List(9 + data.length);
    tail.setRange(0, 9 + data.length, frame, 0);
    frame[frame.length - 1] = lrc(tail);
    return frame;
  }

  /// 解码响应帧，返回 (cmd, status, data)
  static (int, int, Uint8List) decode(Uint8List frame) {
    if (frame.length < 10) {
      throw const FormatException('frame too short');
    }
    final bd = ByteData.sublistView(frame);
    final magic = bd.getUint16(0);
    if (magic != UltraFrame.magic) {
      throw FormatException('bad magic: 0x${magic.toRadixString(16)}');
    }
    final cmd = bd.getUint16(2);
    final status = bd.getUint16(4);
    final len = bd.getUint16(6);
    if (frame.length < 10 + len) {
      throw const FormatException('frame truncated');
    }
    final data = frame.sublist(9, 9 + len);
    return (cmd, status, data);
  }

  /// 校验响应帧 LRC（头+尾）
  static bool checkLrc(Uint8List frame) {
    if (frame.length < 10) return false;
    final head = Uint8List(8);
    head.setRange(0, 8, frame, 0);
    if (frame[8] != lrc(head)) return false;
    final tail = Uint8List(frame.length - 1);
    tail.setRange(0, frame.length - 1, frame, 0);
    return frame[frame.length - 1] == lrc(tail);
  }
}
