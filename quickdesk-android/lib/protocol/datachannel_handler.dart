/// datachannel_handler.dart - control/event 双通道管理（client / host 共用）
///
/// 对照 WebClient/js/protocol/datachannel-handler.js 与 Chromium remoting
/// 的通道分工：
///   - client 角色：本端创建 'event'（键鼠输入），对端(host)创建 'control'
///   - host 角色：本端创建 'control'（能力/剪贴板/VideoLayout），对端创建 'event'
///
/// 两个角色都通过 [handleDataChannel] 接管通道（出站或入站均可）。绑定回调后
/// 会立即检查通道当前状态——入站通道对象可能已携带 OPEN 状态，出站通道在
/// 极快网络下也可能在回调绑定前完成打开。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../util/diag_log.dart';
import 'proto/protobuf_messages.dart';

class DataChannelHandler {
  /// control 通道每次进入打开状态（host 借此下发初始 capabilities/VideoLayout，
  /// 并检查双通道就绪）。同步回调，先于 [onControlReady] 流事件。
  final void Function()? onControlOpen;

  /// event 通道每次进入打开状态
  final void Function()? onEventOpen;

  /// 通道进入 Closing/Closed（label 为 'control'/'event'）。
  /// host 据此判定会话失效；不关心（client 角色）则不传。
  final void Function(String label)? onChannelClosed;

  /// 收到对端输入事件（host 角色消费）。不传时 event 通道入站消息被忽略。
  final void Function(EventMessage event)? onEventMessage;

  final void Function(String message)? onLog;

  DataChannelHandler({
    this.onControlOpen,
    this.onEventOpen,
    this.onChannelClosed,
    this.onEventMessage,
    this.onLog,
  });

  RTCDataChannel? _controlChannel;
  RTCDataChannel? _eventChannel;
  bool _controlReady = false;
  bool _eventReady = false;
  bool _disposed = false;

  /// client 角色的能力声明。由 handler 自己持有，不依赖 UI 层订阅
  /// [onControlReady] 的时序（broadcast 流会丢弃迟到的监听）。
  ///
  /// Chromium Host 的 `PeerSessionImpl::SetCapabilities` **只处理第一次**
  /// 收到的 Capabilities，之后一律报 "has been received already" 并忽略；
  /// 而 `filetransfer-` 通道 handler 正是在这一次调用里依据双方能力交集
  /// 注册的。所以第一次必须带上完整的 `fileTransfer`，且整个会话只发一次
  /// —— 补发既无效，还会在 Host 日志里留下告警。
  String _clientCapabilities = '';
  bool _capabilitiesSent = false;

  bool get controlReady => _controlReady;
  bool get eventReady => _eventReady;

  final _controlReadyCtrl = StreamController<void>.broadcast();
  final _clipboardCtrl = StreamController<ClipboardEventMsg>.broadcast();
  final _capabilitiesCtrl = StreamController<String>.broadcast();
  final _videoLayoutCtrl = StreamController<VideoLayoutMsg>.broadcast();

  Stream<void> get onControlReady => _controlReadyCtrl.stream;
  Stream<ClipboardEventMsg> get onClipboard => _clipboardCtrl.stream;
  Stream<String> get onCapabilities => _capabilitiesCtrl.stream;
  Stream<VideoLayoutMsg> get onVideoLayout => _videoLayoutCtrl.stream;

  /// 接管一个 DataChannel（本端创建的出站通道，或对端创建的入站通道）
  void handleDataChannel(RTCDataChannel channel) {
    switch (channel.label) {
      case 'control':
        _setupControlChannel(channel);
        break;
      case 'event':
        _setupEventChannel(channel);
        break;
      default:
        break;
    }
  }

  void _setupControlChannel(RTCDataChannel channel) {
    _controlChannel = channel;
    channel.onDataChannelState = _handleControlState;
    channel.onMessage = (msg) {
      if (_disposed || !msg.isBinary) return;
      try {
        _handleControlMessage(decodeControlMessage(msg.binary));
      } catch (_) {
        // 忽略无法解析的消息
      }
    };
    _handleControlState(channel.state);
  }

  void _setupEventChannel(RTCDataChannel channel) {
    _eventChannel = channel;
    channel.onDataChannelState = _handleEventState;
    channel.onMessage = (msg) {
      if (_disposed || onEventMessage == null || !msg.isBinary) return;
      try {
        onEventMessage!.call(decodeEventMessage(msg.binary));
      } catch (e) {
        onLog?.call('bad event message: $e');
      }
    };
    _handleEventState(channel.state);
  }

  void _handleControlState(RTCDataChannelState? channelState) {
    if (_disposed) return;
    DiagLog.log('DC',
        'control datachannel: $channelState (sid=${_controlChannel?.id})');
    onLog?.call(
      'control datachannel: $channelState (sid=${_controlChannel?.id})',
    );
    final wasReady = _controlReady;
    _controlReady = channelState == RTCDataChannelState.RTCDataChannelOpen;
    if (_controlReady && !wasReady) {
      // 必须在通知监听者之前发送：此时 _controlReady 已置位，_sendControl
      // 才会真正写出。若登记得晚（control 已打开），也会在这里补上。
      _maybeSendClientCapabilities();
      onControlOpen?.call();
      _controlReadyCtrl.add(null);
    } else if (channelState == RTCDataChannelState.RTCDataChannelClosing ||
        channelState == RTCDataChannelState.RTCDataChannelClosed) {
      onChannelClosed?.call('control');
    }
  }

  void _handleEventState(RTCDataChannelState? channelState) {
    if (_disposed) return;
    onLog?.call('event datachannel: $channelState (sid=${_eventChannel?.id})');
    final wasReady = _eventReady;
    _eventReady = channelState == RTCDataChannelState.RTCDataChannelOpen;
    if (_eventReady && !wasReady) {
      onEventOpen?.call();
    } else if (channelState == RTCDataChannelState.RTCDataChannelClosing ||
        channelState == RTCDataChannelState.RTCDataChannelClosed) {
      onChannelClosed?.call('event');
    }
  }

  void _handleControlMessage(ControlMessage message) {
    if (message.clipboardEvent != null) {
      _clipboardCtrl.add(message.clipboardEvent!);
    }
    if (message.capabilities != null) {
      _capabilitiesCtrl.add(message.capabilities!);
    }
    if (message.videoLayout != null) {
      _videoLayoutCtrl.add(message.videoLayout!);
    }
  }

  // ==================== 发送 ====================

  void _sendEvent(Uint8List data) {
    if (_disposed || !_eventReady || _eventChannel == null) return;
    _eventChannel!.send(RTCDataChannelMessage.fromBinary(data));
  }

  void _sendControl(Uint8List data) {
    if (_disposed || !_controlReady || _controlChannel == null) return;
    _controlChannel!.send(RTCDataChannelMessage.fromBinary(data));
  }

  void sendMouseEvent(MouseEventMsg mouseEvent) {
    _sendEvent(
      encodeEventMessage(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        mouseEvent: mouseEvent,
      ),
    );
  }

  void sendKeyEvent(KeyEventMsg keyEvent) {
    _sendEvent(
      encodeEventMessage(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        keyEvent: keyEvent,
      ),
    );
  }

  /// 文本注入（IME 输入，如中文）
  void sendTextEvent(String text) {
    _sendEvent(
      encodeEventMessage(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        textEventText: text,
      ),
    );
  }

  void sendClipboard(String mimeType, Uint8List data) {
    _sendControl(
      encodeControlMessage(
        clipboardEvent: ClipboardEventMsg(mimeType: mimeType, data: data),
      ),
    );
  }

  void sendCapabilities(String capabilities) {
    _sendControl(encodeControlMessage(capabilities: capabilities));
  }

  /// 登记 client 角色的能力串。若 control 通道已就绪则立即发送，否则等
  /// control 打开时由 [_handleControlState] 补上，不依赖 UI 订阅时序。
  void setClientCapabilities(String capabilities) {
    _clientCapabilities = capabilities;
    _maybeSendClientCapabilities();
  }

  void _maybeSendClientCapabilities() {
    if (_disposed || _capabilitiesSent || _clientCapabilities.isEmpty) return;
    // 只有真正写出才算已发送：control 未就绪时 _sendControl 会静默丢弃，
    // 此时必须保留重发机会，否则 Host 永远注册不了 filetransfer- handler。
    if (!_controlReady || _controlChannel == null) return;
    _sendControl(encodeControlMessage(capabilities: _clientCapabilities));
    _capabilitiesSent = true;
    DiagLog.log('DC', 'client capabilities sent: $_clientCapabilities');
  }

  /// 兼容发起传输前的兜底调用：同一个会话内 Host 只认第一次，因此
  /// 已成功发出后不再重复发送，避免 "Capabilities has been received already"。
  void resendClientCapabilities() => _maybeSendClientCapabilities();

  void sendAudioControl({required bool enable}) {
    _sendControl(encodeControlMessage(audioControlEnable: enable));
  }

  /// 【已停用，勿调用】请求 Host 发起 SDP 重协商。
  ///
  /// 历史原因：曾误以为 flutter_webrtc 需要显式重协商才能 OPEN 新建的
  /// filetransfer-N 通道。Host 端 quickdesk-remoting 的实测日志推翻了该假设：
  /// 此请求实际触发 ICE restart（ufrag 变化）、导致 candidate 全部失配，
  /// 并销毁既有 SCTP 通道，正是文件传输通道 open=false 的根因。
  /// 浏览器 WebClient 从不发送此消息。保留方法仅为协议测试与向后兼容。
  void requestSdpRestart() {
    if (!_controlReady || _controlChannel == null) {
      onLog?.call('requestSdpRestart dropped: control channel not ready');
      return;
    }
    onLog?.call('requestSdpRestart: sending to host');
    _sendControl(encodeControlMessage(requestSdpRestart: true));
  }

  void sendTargetFramerate(int fps) {
    if (![5, 15, 30, 60].contains(fps)) throw ArgumentError.value(fps);
    _sendControl(encodeControlMessage(targetFramerate: fps));
  }

  /// This is a preferred MINIMUM, not a bandwidth ceiling.
  void sendPreferredMinBitrate(int bitsPerSecond) {
    if (bitsPerSecond < 0 || bitsPerSecond > 104857600) {
      throw ArgumentError.value(bitsPerSecond);
    }
    _sendControl(encodeControlMessage(preferredMinBitrateBps: bitsPerSecond));
  }

  void sendClientResolution(ClientResolutionMsg resolution) {
    if (resolution.width <= 0 ||
        resolution.height <= 0 ||
        resolution.width > 7680 ||
        resolution.height > 4320) {
      throw ArgumentError.value(resolution);
    }
    _sendControl(encodeControlMessage(clientResolution: resolution));
  }

  void sendVideoLayout(VideoLayoutMsg layout) {
    _sendControl(encodeControlMessage(videoLayout: layout));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _controlChannel?.close();
    } catch (_) {}
    try {
      await _eventChannel?.close();
    } catch (_) {}
    _controlChannel = null;
    _eventChannel = null;
    _controlReady = false;
    _eventReady = false;
    await _controlReadyCtrl.close();
    await _clipboardCtrl.close();
    await _capabilitiesCtrl.close();
    await _videoLayoutCtrl.close();
  }
}
