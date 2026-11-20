/// host_controller.dart - 被控端总控
///
/// 串起：设备注册(provision) → 访问码同步 → 屏幕采集 → 申请 host signal_token
/// → 连接信令监听(HostSession) → 心跳保活；并把收到的输入事件转交注入层。
///
/// 状态机对上层 UI 暴露 HostStatus 流。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../api/host_api.dart';
import '../api/signaling_api.dart' show SignalingApiException;
import '../l10n/app_strings.dart';
import '../protocol/auth/spake2.dart' as spake2;
import '../protocol/host_file_transfer.dart';
import '../protocol/host_session.dart';
import 'host_credential_store.dart';
import 'input_injector.dart';
import 'screen_capture.dart';

enum HostStage {
  idle,
  provisioning,
  needAccessibility, // 无障碍未开启，等待用户授权
  requestingCapture, // 等待屏幕采集授权
  connecting, // 连接信令
  online, // 已上线待命/被控中
  error,
}

class HostStatus {
  final HostStage stage;
  final String? deviceId;
  final String? accessCode;
  final int peerCount;
  final List<ConnectedHostClient> clients;
  final String? message;

  HostStatus({
    required this.stage,
    this.deviceId,
    this.accessCode,
    this.peerCount = 0,
    this.clients = const [],
    this.message,
  });
}

class HostController {
  static const _identityChannel = MethodChannel('quickdesk/host_identity');
  static const _fileStoreChannel = MethodChannel('quickdesk/file_store');

  /// 被控端支持的能力。桌面端 Chromium client 只有看到 `fileTransfer` 才会
  /// 启用文件传输工具栏，并在会话 Stable 后创建 filetransfer-N 通道。
  static const String hostCapabilities = 'fileTransfer';

  final String signalingUrl;
  final String? apiKey;

  final HostCredentialStore? _providedStore;
  final HostApi? _providedApi;
  late final HostCredentialStore _store =
      _providedStore ??
      HostCredentialStore(signalingUrl: signalingUrl, apiKey: apiKey);
  final ScreenCapture _capture;
  final InputInjector _injector;
  late final HostApi _api =
      _providedApi ?? HostApi(signalingUrl, apiKey: apiKey);

  Future<void>? _starting;
  Future<void>? _stopping;
  int _generation = 0;
  bool _disposed = false;

  HostCredentials? _creds;
  HostSession? _session;
  Timer? _heartbeatTimer;
  final List<StreamSubscription> _subs = [];

  final _statusCtrl = StreamController<HostStatus>.broadcast();
  Stream<HostStatus> get onStatus => _statusCtrl.stream;

  final _fileEventCtrl = StreamController<HostFileEvent>.broadcast();

  /// 文件传输结果（收到文件 / 已发送 / 失败），供被控页提示用户。
  Stream<HostFileEvent> get onFileEvent => _fileEventCtrl.stream;

  HostStage _stage = HostStage.idle;
  int _peerCount = 0;
  bool _updatingAccessCode = false;

  HostController({
    required this.signalingUrl,
    this.apiKey,
    HostCredentialStore? credentialStore,
    HostApi? api,
    ScreenCapture? capture,
    InputInjector? injector,
  }) : _providedStore = credentialStore,
       _providedApi = api,
       _capture = capture ?? ScreenCapture(),
       _injector = injector ?? InputInjector();

  String? get deviceId => _creds?.deviceId;
  String? get accessCode => _creds?.accessCode;

  Future<HostCredentials> loadCredentials() async {
    _creds = await _store.load();
    return _creds!;
  }

  // ==================== 被控端文件传输 ====================

  /// 控制端上传完成：先把暂存文件落到 app 私有外部目录（保证一定能写），
  /// 再尝试通过 MediaStore 发布一份到系统「下载/QuickDesk」，让用户能直接
  /// 在文件管理器里看到。Android 10 以下没有 MediaStore.Downloads，保持
  /// 私有目录路径即可。
  Future<String> _publishReceivedFile(String filename, File staged) async {
    final dir = await _receivedDir();
    final target = await _uniqueTarget(dir, filename);
    await staged.copy(target);
    try {
      final publicPath = await _fileStoreChannel.invokeMethod<String>(
        'publishToDownloads',
        {
          'sourcePath': target,
          'displayName': target.split(Platform.pathSeparator).last,
        },
      );
      if (publicPath != null && publicPath.isNotEmpty) return publicPath;
    } catch (_) {
      // MediaStore 不可用时不影响已经落盘的私有副本。
    }
    return target;
  }

  Future<Directory> _receivedDir() async {
    Directory base;
    try {
      base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}QuickDesk'
      '${Platform.pathSeparator}Received',
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 同名文件不覆盖，追加 (1)/(2) 后缀，避免桌面端重复上传丢数据。
  Future<String> _uniqueTarget(Directory dir, String filename) async {
    var candidate = '${dir.path}${Platform.pathSeparator}$filename';
    var index = 1;
    while (await File(candidate).exists()) {
      final dot = filename.lastIndexOf('.');
      final name = dot > 0 ? filename.substring(0, dot) : filename;
      final ext = dot > 0 ? filename.substring(dot) : '';
      candidate = '${dir.path}${Platform.pathSeparator}$name ($index)$ext';
      index++;
    }
    return candidate;
  }

  /// 控制端请求下载：在本机弹文件选择器（被控画面上可直接操作）。
  Future<String?> _pickOutgoingFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    final files = result?.files;
    if (files == null || files.isEmpty) return null;
    return files.single.path;
  }

  void _emitFileEvent(HostFileEvent event) {
    if (!_disposed && !_fileEventCtrl.isClosed) _fileEventCtrl.add(event);
  }

  /// 传输暂存目录用应用 cache（比 Directory.systemTemp 在 Android 上更可靠）。
  Future<Directory?> _stagingRoot() async {
    try {
      return await getTemporaryDirectory();
    } catch (_) {
      return null;
    }
  }

  /// 启动被控：完整流程。调用前应确保无障碍已开启（否则会停在 needAccessibility）。
  Future<void> start() async {
    if (_disposed ||
        _starting != null ||
        _stopping != null ||
        _session != null ||
        _updatingAccessCode) {
      return;
    }
    final generation = ++_generation;
    final work = _start(generation);
    _starting = work;
    try {
      await work;
    } finally {
      _starting = null;
    }
  }

  void _check(int generation) {
    if (_disposed || generation != _generation) throw const _HostCancelled();
  }

  Future<void> _start(int generation) async {
    try {
      _creds ??= await _store.load();
      _check(generation);

      // 0. 无障碍开关检查（输入注入前提）
      _emit(HostStage.requestingCapture, message: L10n.t('host.msgCheckA11y'));
      final a11y = await _injector.isAccessibilityEnabled();
      _check(generation);
      if (!a11y) {
        _emit(HostStage.needAccessibility, message: L10n.t('host.msgNeedA11y'));
        return;
      }

      // 1. 设备注册（幂等：已注册则复用本地凭据）
      if (!_creds!.isProvisioned) {
        _emit(HostStage.provisioning, message: L10n.t('host.msgProvisioning'));
        final result = await _api.provision(deviceUuid: _creds!.deviceUuid);
        // Persist the one-time secret even if stop was requested in flight.
        await _store.saveProvision(
          deviceId: result.deviceId,
          deviceSecret: result.deviceSecret,
        );
        _check(generation);
        _creds = await _store.load();
        _check(generation);
      }

      // 2. 访问码（无则生成并上报）
      var accessCode = _creds!.accessCode;
      if (accessCode == null || accessCode.isEmpty) {
        accessCode = HostCredentialStore.generateAccessCode();
        await _api.setAccessCode(
          deviceId: _creds!.deviceId!,
          deviceSecret: _creds!.deviceSecret!,
          accessCode: accessCode,
        );
        await _store.saveAccessCode(accessCode);
        _creds = await _store.load();
        _check(generation);
      }

      // 3. 屏幕采集授权
      _emit(
        HostStage.requestingCapture,
        message: L10n.t('host.msgRequestCapture'),
      );
      // 旋转/分辨率变化 → 更新会话屏幕尺寸并向所有客户端重发 VideoLayout
      _capture.onSizeChanged = (w, h) => _session?.updateScreenSize(w, h);
      final capture = await _capture.start();
      _check(generation);

      // 4. ICE 配置 + host signal_token
      _emit(HostStage.connecting, message: L10n.t('host.msgConnecting'));
      final iceServers = await _api.getIceServers(
        deviceSecret: _creds!.deviceSecret!,
      );
      _check(generation);
      final signalToken = await _api.issueSignalToken(
        deviceId: _creds!.deviceId!,
        deviceSecret: _creds!.deviceSecret!,
      );

      _check(generation);

      // 5. Host 身份证书 + SPAKE2 共享密钥哈希。
      final hostCertificate = await _identityChannel.invokeMethod<String>(
        'getCertificate',
      );
      _check(generation);
      if (hostCertificate == null || hostCertificate.isEmpty) {
        throw StateError('Android host certificate is unavailable');
      }
      final deviceId = _creds!.deviceId!;
      final sharedSecretHash = spake2.getSharedSecretHash(
        deviceId,
        deviceId + accessCode,
      );

      // 6. 建立 HostSession（含 fileTransfer 能力与文件落盘/选文件回调）
      final session = HostSession(
        signalingUrl: signalingUrl,
        deviceId: deviceId,
        sharedSecretHash: sharedSecretHash,
        hostCertificate: hostCertificate,
        screenStreamProvider: () => capture.stream,
        screenWidth: capture.width,
        screenHeight: capture.height,
        iceServers: iceServers,
        capabilities: hostCapabilities,
        publishReceivedFile: _publishReceivedFile,
        pickOutgoingFile: _pickOutgoingFile,
        onFileEvent: _emitFileEvent,
        stagingRoot: await _stagingRoot(),
        onInput: (event) => _injector.inject(event),
      );
      _session = session;

      _subs.add(
        session.onPeerCountChange.listen((n) {
          if (_disposed ||
              generation != _generation ||
              !identical(_session, session)) {
            return;
          }
          _peerCount = n;
          _emit(HostStage.online);
        }),
      );
      _subs.add(
        session.onStateChange.listen((s) {
          if (_disposed ||
              generation != _generation ||
              !identical(_session, session)) {
            return;
          }
          if (s == HostSessionState.failed) {
            _emit(HostStage.error, message: L10n.t('host.msgSignalDropped'));
          }
        }),
      );

      await session.listen(signalToken);
      _check(generation);

      // 7. 心跳保活
      _startHeartbeat();
      _emit(HostStage.online, message: L10n.t('host.msgOnline'));
    } on _HostCancelled {
      // stop() waits for startup to settle, then releases capture/session.
      return;
    } on SignalingApiException catch (e) {
      if (generation != _generation || _disposed) {
        return;
      }
      _emit(
        HostStage.error,
        message: L10n.t('host.msgServerError', {'code': e.code}),
      );
      await _cleanup();
    } catch (e) {
      if (generation != _generation || _disposed) {
        return;
      }
      _emit(
        HostStage.error,
        message: L10n.t('host.msgStartFailed', {'e': 'HOST_START_FAILED'}),
      );
      await _cleanup();
    }
  }

  Future<void> disconnectClient(
    String clientId, {
    DateTime? connectedAt,
  }) async {
    await _session?.disconnectClient(clientId, connectedAt: connectedAt);
  }

  /// 用户手动重设访问码（随机 6 位数字）
  Future<void> regenerateAccessCode() =>
      _applyAccessCode(HostCredentialStore.generateAccessCode());

  /// 用户自定义固定访问码。
  /// 保存后不会自动刷新；下次开启被控时 host 与服务器都用这个码。
  Future<void> setCustomAccessCode(String code) async {
    final normalized = code.trim();
    if (!HostCredentialStore.isValidCustomAccessCode(normalized)) {
      throw ArgumentError('Access code must be exactly 6 digits');
    }
    await _applyAccessCode(normalized);
  }

  /// 随机刷新与自定义码共用的更新流程：停服校验 → 上报服务器 → 落盘。
  /// 顺序不能反：只有服务器接受后才写入本地，避免断电/离线导致两端不一致。
  Future<void> _applyAccessCode(String code) async {
    if (_disposed || _starting != null || _stopping != null) return;
    final generation = _generation;
    if (_stage != HostStage.idle && _stage != HostStage.error) {
      throw StateError('Stop hosting before changing the access code');
    }
    if (_session != null) throw StateError('Host session is still active');
    if (_creds == null || !_creds!.isProvisioned) return;
    if (_updatingAccessCode) return;
    _updatingAccessCode = true;
    try {
      await _api.setAccessCode(
        deviceId: _creds!.deviceId!,
        deviceSecret: _creds!.deviceSecret!,
        accessCode: code,
      );
      await _store.saveAccessCode(code);
      _creds = await _store.load();
      if (!_disposed && generation == _generation) _emit(_stage);
    } finally {
      _updatingAccessCode = false;
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_creds == null || !_creds!.isProvisioned) {
        return;
      }
      try {
        await _api.heartbeat(
          deviceId: _creds!.deviceId!,
          deviceSecret: _creds!.deviceSecret!,
        );
      } catch (_) {
        // 单次心跳失败忽略；连接状态由信令 WS 反映
      }
    });
  }

  Future<void> stop() {
    ++_generation;
    return _stopping ??= _stop().whenComplete(() => _stopping = null);
  }

  Future<void> _stop() async {
    await _starting;
    await _cleanup();
  }

  Future<void> _cleanup() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _session?.stop();
    _session?.dispose();
    _session = null;
    await _capture.stop();
    _peerCount = 0;
    if (_stage != HostStage.error) {
      _emit(HostStage.idle);
    }
  }

  Future<void> openAccessibilitySettings() =>
      _injector.openAccessibilitySettings();

  void _emit(HostStage stage, {String? message}) {
    _stage = stage;
    if (_disposed || _statusCtrl.isClosed) {
      return;
    }
    _statusCtrl.add(
      HostStatus(
        stage: stage,
        deviceId: _creds?.deviceId,
        accessCode: _creds?.accessCode,
        peerCount: _peerCount,
        clients: _session?.connectedClients ?? const [],
        message: message,
      ),
    );
  }

  void dispose() {
    _disposed = true;
    unawaited(stop().whenComplete(() {
      _statusCtrl.close();
      _fileEventCtrl.close();
    }));
  }
}

class _HostCancelled implements Exception {
  const _HostCancelled();
}
