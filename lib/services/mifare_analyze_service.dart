import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// MIFARE Classic dump 云端分析服务（对齐 CU packages/mifare_analyze）。
///
/// multipart POST 到 analyze.flippercn.com，服务端返回锤子/客栈/夏天三份解析结果。
class MifareAnalyzeService {
  const MifareAnalyzeService({this.baseUrl = _defaultBaseUrl});

  static const String _defaultBaseUrl =
      'https://analyze.flippercn.com/proxy.php?action=upload';

  final String baseUrl;

  /// [dumpBytes] 为卡数据（1K 卡 1024 字节），[filename] 用于上传时的文件名。
  Future<MifareAnalyzeResult> analyzeDump(
    Uint8List dumpBytes,
    String filename,
  ) async {
    final request = http.MultipartRequest('POST', Uri.parse(baseUrl));
    request.files.add(
      http.MultipartFile.fromBytes(
        'upload_dump',
        dumpBytes,
        filename: filename,
      ),
    );

    try {
      final streamed = await request.send().timeout(
        const Duration(seconds: 15),
      );
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode != 200) {
        return MifareAnalyzeResult(
          uploadError: 'HTTP错误: ${response.statusCode}',
        );
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        return MifareAnalyzeResult(uploadError: '返回格式异常');
      }
      return MifareAnalyzeResult.fromJson(decoded);
    } on TimeoutException catch (e) {
      return MifareAnalyzeResult(uploadError: '网络错误: $e');
    } catch (e) {
      return MifareAnalyzeResult(uploadError: '网络错误: $e');
    }
  }
}

/// 服务端返回的完整分析结果。
class MifareAnalyzeResult {
  const MifareAnalyzeResult({
    this.rawdata = '',
    this.hammer,
    this.kz = '',
    this.xt = '',
    this.uploadError = '',
    this.czError = '',
    this.kzError = '',
    this.xtError = '',
  });

  final String rawdata;
  final HammerAnalyzeResult? hammer;
  final String kz;
  final String xt;
  final String uploadError;
  final String czError;
  final String kzError;
  final String xtError;

  bool get hasUploadError => uploadError.isNotEmpty;

  factory MifareAnalyzeResult.fromJson(Map<String, dynamic> json) {
    final czRaw = json['cz'];
    final hammer = czRaw is List ? HammerAnalyzeResult.fromJson(czRaw) : null;
    return MifareAnalyzeResult(
      rawdata: _convertToString(json['rawdata']),
      hammer: hammer,
      kz: _convertToString(json['kz']),
      xt: _convertToString(json['xt']),
      uploadError: _convertToString(json['upload_error']),
      czError: _convertToString(json['cz_error']),
      kzError: _convertToString(json['kz_error']),
      xtError: _convertToString(json['xt_error']),
    );
  }

  static String _convertToString(Object? value) {
    if (value == null) return '';
    if (value is List) {
      return value.map((e) => e.toString()).join('\n');
    }
    return value.toString();
  }
}

/// 锤子（cz）结构化分析结果。
class HammerAnalyzeResult {
  const HammerAnalyzeResult({this.items = const [], this.isRecognized = false});

  final List<HammerAnalyzeItem> items;
  final bool isRecognized;

  bool get isEmpty => items.isEmpty;

  factory HammerAnalyzeResult.fromJson(List<dynamic> json) {
    if (json.length < 2) return const HammerAnalyzeResult();
    final items = (json[0] as List?) ?? const [];
    return HammerAnalyzeResult(
      items: items
          .whereType<Map<String, dynamic>>()
          .map(HammerAnalyzeItem.fromJson)
          .toList(),
      isRecognized: json[1] is bool ? json[1] as bool : false,
    );
  }
}

/// 锤子识别出的单个扇区条目。
class HammerAnalyzeItem {
  const HammerAnalyzeItem({
    this.name = '',
    this.rawname = '',
    this.sectorIndex = 0,
    this.allowModify = false,
    this.values = const [],
  });

  final String name;
  final String rawname;
  final int sectorIndex;
  final bool allowModify;
  final List<HammerValue> values;

  factory HammerAnalyzeItem.fromJson(Map<String, dynamic> json) {
    return HammerAnalyzeItem(
      name: HammerValue._toStringOrEmpty(json['name']),
      rawname: HammerValue._toStringOrEmpty(json['rawname']),
      sectorIndex: HammerValue._toIntOrZero(json['sector_index']),
      allowModify: json['allowmodify'] is bool
          ? json['allowmodify'] as bool
          : false,
      values: ((json['value'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(HammerValue.fromJson)
          .toList(),
    );
  }
}

/// 锤子条目下的单个解析值。
class HammerValue {
  const HammerValue({this.a = '', this.b = '', this.c = '', this.d = ''});

  final String a;
  final String b;
  final String c;
  final String d;

  factory HammerValue.fromJson(Map<String, dynamic> json) {
    return HammerValue(
      a: _toStringOrEmpty(json['a']),
      b: _toStringOrEmpty(json['b']),
      c: _toStringOrEmpty(json['c']),
      d: _toStringOrEmpty(json['d']),
    );
  }

  static String _toStringOrEmpty(Object? value) =>
      value == null ? '' : value.toString();

  static int _toIntOrZero(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}
