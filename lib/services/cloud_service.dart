import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/enums.dart';
import '../models/models.dart';
import 'storage_service.dart';

/// 云功能服务（可配置端点，默认作者后端）
/// 对应逆向：Analy / add_job / query_job / del_job / savesharedata
class CloudService {
  final StorageService _storage;
  static const String defaultEndpoint =
      'https://fc-mp-25581e18-9b6b-41d7-a1c9-69bb4c0020f7.next.bspapp.com';

  static const String shareEndpoint = 'https://pay.nfctool.cn/wx.mini.php';
  static const String sharePage = 'https://nfctool.cn/dumpshare/';

  CloudService(this._storage);

  /// 当前云端端点
  Future<String> getCloudEndpoint() async => _storage.getCloudEndpoint();

  Future<String> _endpoint() async => _storage.getCloudEndpoint();

  Future<String> _api(Uri base, Map<String, dynamic> data,
      {String method = 'GET'}) async {
    final uri = base.replace(path: '${base.path}/api');
    final http.Response res;
    if (method == 'POST') {
      res = await http
          .post(uri, body: data)
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

  /// 查询云破解任务列表（对应逆向 btnQueryHardnested）
  Future<List<CrackTask>> queryJobs(String userId) async {
    final ep = Uri.parse(await _endpoint());
    final body = await _api(ep, {'user_id': userId, 'content': 'query_job'},
        method: 'POST');
    final res = jsonDecode(body);
    final affectedDocs = res is Map ? (res['affectedDocs'] ?? 0) : 0;
    if (affectedDocs <= 0) return [];
    final raw = (res as Map)['data'] as List;
    return raw.map((e) {
      final m = e as Map;
      return CrackTask(
        id: m['_id']?.toString() ?? '',
        cardId: m['card_id']?.toString() ?? '',
        sector: int.tryParse('${m['sector']}') ?? 0,
        keyType: m['keytype'] == 'B' ? KeyType.keyB : KeyType.keyA,
        key: m['key']?.toString() ?? '',
      );
    }).toList();
  }

  /// 添加云破解任务（对应逆向 add_job，nonce 携带采集数据）
  Future<String> addJob({
    required String userId,
    required String openid,
    required String cardId,
    required int sector,
    required KeyType keyType,
    String? nonceData,
  }) async {
    final nonce = nonceData ?? DateTime.now().millisecondsSinceEpoch.toString();
    final ep = Uri.parse(await _endpoint());
    final body = await _api(ep, {
      'user_id': userId,
      'card_id': cardId,
      'sector': sector,
      'keytype': keyType.label,
      'content': 'add_job',
      'nonce': nonce,
      'openid': openid,
    }, method: 'POST');
    final res = jsonDecode(body);
    if (res is Map && res['affectedDocs'] == 1) {
      return 'ok';
    }
    if (res is Map && res['errMsg'] != null) {
      throw Exception('${res['errMsg']}');
    }
    throw Exception('云端添加任务失败');
  }

  /// 删除云破解任务（对应逆向 btnDelHardnested）
  Future<void> deleteJob(String objId) async {
    final ep = Uri.parse(await _endpoint());
    await _api(ep, {'obj_id': objId, 'content': 'del_job'}, method: 'POST');
  }

  /// 生成分享链接（对应逆向 sharedata，savesharedata 接口）
  Future<String> saveSharedData(String dumpText) async {
    final clean = dumpText
        .replaceAll('\n', '')
        .replaceAll('\r', '')
        .replaceAll(' ', '');
    final uri = Uri.parse(
        '$shareEndpoint?type=savesharedata&data=${Uri.encodeComponent(clean)}');
    final res = await http.get(uri).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('分享失败: HTTP ${res.statusCode}');
    }
    final json = jsonDecode(res.body);
    if (json is Map && json['resultCode'] == 0) {
      return '$sharePage?dataid=${json['id']}';
    }
    throw Exception('生成链接失败');
  }
}
