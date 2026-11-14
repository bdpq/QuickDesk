/// app_settings.dart - 全局设置（信令服务器地址 / API Key / 最近设备）
///
/// 主控端连接页与被控端 HostController 共用同一份服务器配置。
library;

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

const kDefaultSignalingUrl = 'wss://qdsignaling.quickcoder.cc';
const _kLegacyDefaultSignalingUrls = {
  'ws://qdsignaling.quickcoder.cc:8060',
  'wss://qd.quickcoder.cn',
};
const kBuildTimeApiKey = String.fromEnvironment('QUICKDESK_API_KEY');

class AppSettings {
  static final changes = ValueNotifier<int>(0);
  static const _kSignalingUrl = 'signaling_url';
  static const _kApiKey = 'api_key';
  static const _kLastDeviceId = 'last_device_id';
  static const _kDirectTouchMode = 'remote_direct_touch_mode';

  final String signalingUrl;
  final String apiKey;
  final String lastDeviceId;

  AppSettings({
    required this.signalingUrl,
    required this.apiKey,
    required this.lastDeviceId,
  });

  /// API Key 为空时返回 null（API 客户端以 null 表示"未启用"）
  String? get apiKeyOrNull => apiKey.isEmpty ? null : apiKey;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    var signalingUrl = prefs.getString(_kSignalingUrl) ?? kDefaultSignalingUrl;
    if (_kLegacyDefaultSignalingUrls.contains(signalingUrl)) {
      signalingUrl = kDefaultSignalingUrl;
      await prefs.setString(_kSignalingUrl, signalingUrl);
    }
    return AppSettings(
      signalingUrl: signalingUrl,
      apiKey: prefs.getString(_kApiKey) ?? kBuildTimeApiKey,
      lastDeviceId: prefs.getString(_kLastDeviceId) ?? '',
    );
  }

  static Future<void> save({
    required String signalingUrl,
    required String apiKey,
    String? lastDeviceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSignalingUrl, signalingUrl.trim());
    await prefs.setString(_kApiKey, apiKey.trim());
    changes.value++;
    if (lastDeviceId != null) {
      await prefs.setString(_kLastDeviceId, lastDeviceId.trim());
    }
  }

  /// 直接触摸模式偏好。只是 UI 偏好，读不到存储时安全降级为触控板模式；
  /// 这样在无插件环境（widget 测试 / 预览）也不会抛 MissingPluginException。
  static Future<bool> loadDirectTouchMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kDirectTouchMode) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveDirectTouchMode(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDirectTouchMode, enabled);
    } catch (_) {
      // 偏好写入失败不应影响远程控制本身。
    }
  }

  static bool isSecureSignalingUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null && uri.scheme == 'wss' && uri.host.isNotEmpty;
  }
}
