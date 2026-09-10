import 'dart:convert';

import 'package:http/http.dart' as http;

import 'storage_service.dart';

/// 云功能服务（可配置端点，默认作者后端）
/// 对应逆向：Analy（电梯卡分析）
class CloudService {
  final StorageService _storage;
  static const String defaultEndpoint =
      'https://fc-mp-25581e18-9b6b-41d7-a1c9-69bb4c0020f7.next.bspapp.com';

  CloudService(this._storage);

  /// 当前云端端点
  Future<String> getCloudEndpoint() async => _storage.getCloudEndpoint();

  Future<String> _endpoint() async => _storage.getCloudEndpoint();

  Future<String> _api(Uri base, Map<String, dynamic> data,
      {String method = 'GET'}) async {
    final uri = base.replace(path: '${base.path}/api');
    final http.Response res;
    if (method == 'POST') {
      // 云端（uniCloud 云函数）只接受 JSON body（form-urlencoded 会报
      // FunctionBizError: Unexpected token ... in JSON at position 0）
      res = await http
          .post(uri,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(data))
          .timeout(const Duration(seconds: 20));
    } else {
      res = await http
          .get(uri.replace(queryParameters: data.map(
              (k, v) => MapEntry(k, v.toString()))))
          .timeout(const Duration(seconds: 20));
    }
    if (res.statusCode != 200) {
      throw Exception('云端请求失败: HTTP ${res.statusCode}');
    }
    return res.body;
  }

  /// 电梯卡数据分析（对应逆向 btnLift，GET /api content=Analy）
  Future<String> analyzeLift(String dumpText) async {
    final ep = Uri.parse(await _endpoint());
    return _api(ep, {
      'appid': 'QUZCOEE5QjRBN0FCRkFEQkM0NDlD',
      'userid': '01',
      'content': 'Analy',
      'data': dumpText,
    });
  }
}
