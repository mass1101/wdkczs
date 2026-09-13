import 'dart:convert';

import 'package:http/http.dart' as http;

import 'storage_service.dart';

/// 卡库卡片订阅 API（对齐 CU helpers/card_subscription.dart，接 card.zzx1101.tk）。
class CardSubscriptionInfo {
  final int id;
  final String code;
  final String name;
  final String description;
  final String mode;
  final String ownerChipId;
  final String createdAt;
  final int cardCount;
  final int memberCount;
  final bool isMember;

  CardSubscriptionInfo({
    required this.id,
    required this.code,
    required this.name,
    required this.description,
    required this.mode,
    required this.ownerChipId,
    required this.createdAt,
    required this.cardCount,
    required this.memberCount,
    required this.isMember,
  });

  bool get isAuthorized => mode == 'authorized';

  factory CardSubscriptionInfo.fromJson(Map<String, dynamic> json) {
    return CardSubscriptionInfo(
      id: json['id'] as int,
      code: json['code'] as String,
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      mode: json['mode'] as String? ?? 'open',
      ownerChipId: json['owner_chip_id'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      cardCount: json['card_count'] as int? ?? 0,
      memberCount: json['member_count'] as int? ?? 0,
      isMember: json['is_member'] as bool? ?? false,
    );
  }
}

class CardSubscriptionApi {
  static Future<String> _endpoint() async {
    final storage = StorageService();
    return storage.getBackupEndpoint();
  }

  static Future<List<CardSubscriptionInfo>> fetchCreated(String chipId) async {
    final ep = await _endpoint();
    final response = await http
        .get(Uri.parse(
            '$ep/api/card-subscriptions/created?chip_id=${Uri.encodeComponent(chipId)}'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception(_errorMessage(response));
    }
    final list = jsonDecode(response.body) as List;
    return list
        .map((e) => CardSubscriptionInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<List<CardSubscriptionInfo>> fetchSubscribed(String chipId) async {
    final ep = await _endpoint();
    final response = await http
        .get(Uri.parse(
            '$ep/api/card-subscriptions/subscribed?chip_id=${Uri.encodeComponent(chipId)}'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception(_errorMessage(response));
    }
    final list = jsonDecode(response.body) as List;
    return list
        .map((e) => CardSubscriptionInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<CardSubscriptionInfo> fetchDetail(String code) async {
    final ep = await _endpoint();
    final response = await http
        .get(Uri.parse(
            '$ep/api/card-subscriptions/${Uri.encodeComponent(code)}'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception(_errorMessage(response));
    }
    return CardSubscriptionInfo.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  static Future<String> create({
    required String name,
    String description = '',
    required String mode,
    required String adminPassword,
    String dataPassword = '',
    required String chipId,
    required List<Map<String, dynamic>> cards,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'description': description,
      'mode': mode,
      'admin_password': adminPassword,
      'owner_chip_id': chipId,
      'cards': cards,
    };
    if (mode == 'authorized') {
      body['data_password'] = dataPassword;
    }
    final ep = await _endpoint();
    final response = await http
        .post(
          Uri.parse('$ep/api/card-subscriptions'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 201) {
      throw Exception(_errorMessage(response));
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['code'] as String;
  }

  static Future<void> join({
    required String code,
    required String chipId,
    String dataPassword = '',
    String? adminPassword,
  }) async {
    final body = <String, dynamic>{
      'chip_id': chipId,
      'data_password': dataPassword,
      'admin_password': adminPassword ?? '',
    };
    final ep = await _endpoint();
    final response = await http
        .post(
          Uri.parse(
              '$ep/api/card-subscriptions/${Uri.encodeComponent(code)}/join'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception(_errorMessage(response));
    }
  }

  static Future<List<Map<String, dynamic>>> fetchCards({
    required String code,
    required String chipId,
    String dataPassword = '',
  }) async {
    final ep = await _endpoint();
    final response = await http
        .post(
          Uri.parse(
              '$ep/api/card-subscriptions/${Uri.encodeComponent(code)}/cards'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'chip_id': chipId,
            'data_password': dataPassword,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception(_errorMessage(response));
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return (json['cards'] as List).cast<Map<String, dynamic>>();
  }

  static Future<void> leave(String code, String chipId) async {
    final ep = await _endpoint();
    final response = await http
        .post(
          Uri.parse(
              '$ep/api/card-subscriptions/${Uri.encodeComponent(code)}/leave'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'chip_id': chipId}),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception(_errorMessage(response));
    }
  }

  static Future<void> delete(String code, String chipId, String adminPassword) async {
    final ep = await _endpoint();
    final response = await http
        .delete(
          Uri.parse(
              '$ep/api/card-subscriptions/${Uri.encodeComponent(code)}'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'chip_id': chipId, 'admin_password': adminPassword}),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception(_errorMessage(response));
    }
  }

  static String _errorMessage(http.Response response) {
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return json['error'] as String? ?? '请求失败 (${response.statusCode})';
    } catch (_) {
      return '请求失败 (${response.statusCode})';
    }
  }
}