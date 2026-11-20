/// file_transfer.dart - 文件传输（主控端）
///
/// 对照 WebClient/js/protocol/datachannel-handler.js 的实现，走 remoting 的
/// file_transfer.proto，通过按传输独立的 `filetransfer-<n>` DataChannel 传送：
///
///   FileTransfer {
///     Metadata metadata = 1;        // { string filename=1; optional uint64 size=2; }
///     Data     data     = 2;        // { bytes data=1; }
///     Empty    end      = 3;
///     Empty    success  = 4;
///     Empty    request_transfer = 5;
///     Error    error    = 6;        // { ErrorType type=1; }
///   }
///
/// 上传（client→host）：建通道 → metadata → data* → end → 等 success
/// 下载（host→client）：建通道 → request_transfer → metadata → data* → end → 回 success
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../util/diag_log.dart';
import 'datachannel_config.dart';
import 'proto/wire.dart';

const int _chunkSize = 8192;
const int _bufferHighWater = _chunkSize * 8;

/// 与 WebClient 的模块级 nextFileTransferId 对齐：ID 从 1 开始，且跨会话
/// 单调递增。Chromium Host 以 label 中的 ID 建立/索引传输会话，0 或重复 ID
/// 会命中已结束（或非法）的传输，通道随即被对端关闭，进度永远停在 0 字节。
/// 因此计数器必须是文件级全局，而不是 FileTransferManager 的实例字段——
/// 断开重连会重建 manager，实例级计数会重新从 0 开始。
int _nextTransferId = 1;

// ==================== 编码 ====================

Uint8List _encMetadata(String filename, int size) => lengthDelimitedField(
    1,
    concatBytes([
      lengthDelimitedField(1, filename),
      varintField(2, size),
    ]));

Uint8List _encData(Uint8List data) =>
    lengthDelimitedField(2, lengthDelimitedField(1, data));

Uint8List _encEnd() => lengthDelimitedField(3, Uint8List(0));
Uint8List _encSuccess() => lengthDelimitedField(4, Uint8List(0));
Uint8List _encRequestTransfer() => lengthDelimitedField(5, Uint8List(0));

/// 被控端（Host）复用的编码入口。Host 只在控制端创建的 filetransfer-N
/// 通道上应答/推送文件，帧格式与主控端完全一致。
Uint8List encodeFtMetadata(String filename, int size) =>
    _encMetadata(filename, size);
Uint8List encodeFtData(Uint8List data) => _encData(data);
Uint8List encodeFtEnd() => _encEnd();
Uint8List encodeFtSuccess() => _encSuccess();
Uint8List encodeFtRequestTransfer() => _encRequestTransfer();

/// ErrorType.CANCELED = 1；Host 侧用它拒绝无法完成的传输（例如用户取消
/// 选择文件、收到非法帧）。
Uint8List encodeFtError(int type) =>
    lengthDelimitedField(6, varintField(1, type));

// ==================== 解码 ====================

/// 一条 FileTransfer 帧解析结果。Host 与 client 共用；client 不会收到
/// request_transfer，Host 不会收到 success（上传方向）以外的确认帧。
class FtMessage {
  bool metadata = false;
  String? metaFilename;
  int? metaSize;
  Uint8List? data;
  bool end = false;
  bool success = false;
  bool requestTransfer = false;
  int? errorType;
}

FtMessage decodeFtMessage(Uint8List data) {
  final msg = FtMessage();
  final reader = ProtobufReader(data);
  while (reader.hasMore) {
    final tag = reader.readTag();
    if (tag.wireType != 2) {
      reader.skipField(tag.wireType);
      continue;
    }
    switch (tag.fieldNumber) {
      case 1:
        msg.metadata = true;
        _decodeMetadata(reader.readBytes(), msg);
        break;
      case 2:
        msg.data = _decodeDataField(reader.readBytes());
        break;
      case 3:
        reader.skipField(tag.wireType);
        msg.end = true;
        break;
      case 4:
        reader.skipField(tag.wireType);
        msg.success = true;
        break;
      case 5:
        reader.skipField(tag.wireType);
        msg.requestTransfer = true;
        break;
      case 6:
        final errReader = ProtobufReader(reader.readBytes());
        msg.errorType = 0;
        while (errReader.hasMore) {
          final et = errReader.readTag();
          if (et.fieldNumber == 1 && et.wireType == 0) {
            msg.errorType = errReader.readVarint();
          } else {
            errReader.skipField(et.wireType);
          }
        }
        break;
      default:
        reader.skipField(tag.wireType);
    }
  }
  return msg;
}

void _decodeMetadata(Uint8List data, FtMessage msg) {
  final reader = ProtobufReader(data);
  while (reader.hasMore) {
    final tag = reader.readTag();
    if (tag.fieldNumber == 1 && tag.wireType == 2) {
      msg.metaFilename = reader.readString();
    } else if (tag.fieldNumber == 2 && tag.wireType == 0) {
      msg.metaSize = reader.readVarint();
    } else {
      reader.skipField(tag.wireType);
    }
  }
}

Uint8List _decodeDataField(Uint8List data) {
  final reader = ProtobufReader(data);
  while (reader.hasMore) {
    final tag = reader.readTag();
    if (tag.fieldNumber == 1 && tag.wireType == 2) {
      return reader.readBytes();
    }
    reader.skipField(tag.wireType);
  }
  return Uint8List(0);
}

// ==================== Transport seam and task model ====================

/// Existing remoting wire messages, on one dedicated channel per task.
/// Injectable so lifecycle and filesystem behavior are tested without WebRTC.
abstract class FileTransferChannel {
  bool get isOpen;
  Future<int> bufferedBytes();
  set onOpen(void Function()? callback);
  set onData(void Function(Uint8List)? callback);
  set onClosed(void Function()? callback);
  Future<void> send(Uint8List data);
  Future<void> close();
}

/// 把一条已存在的 [RTCDataChannel] 包装成文件传输通道。
///
/// 供预建通道池使用：会话协商期创建好的通道在真正发起传输时直接复用，
/// 避免在 Stable 之后动态 createDataChannel。
FileTransferChannel wrapRtcDataChannel(RTCDataChannel channel) =>
    RtcFileTransferChannel(channel);

class RtcFileTransferChannel implements FileTransferChannel {
  final RTCDataChannel channel;
  void Function()? _open;
  void Function(Uint8List)? _data;
  void Function()? _closed;

  RtcFileTransferChannel(this.channel) {
    DiagLog.log('FT.CH',
        'construct label=${channel.label} id=${channel.id} state=${channel.state}');
    channel.onDataChannelState = (state) {
      DiagLog.log('FT.CH',
          'state label=${channel.label} id=${channel.id} -> $state ready=$_hasOpened');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _hasOpened = true;
        _open?.call();
      }
      if (state == RTCDataChannelState.RTCDataChannelClosed) _closed?.call();
    };
    channel.onMessage = (message) {
      DiagLog.log('FT.CH',
          'message label=${channel.label} binary=${message.isBinary} '
          'len=${message.binary.length}');
      if (message.isBinary) _data?.call(message.binary);
    };
  }

  bool _hasOpened = false;

  @override
  bool get isOpen => channel.state == RTCDataChannelState.RTCDataChannelOpen;
  @override
  Future<int> bufferedBytes() async {
    // flutter_webrtc 1.6.3 的 getBufferedAmount() 会经 MethodChannel 调用原生
    // `dataChannelGetBufferedAmount`。在 Android 上该调用可能永不返回：上传
    // 循环会在「发完 metadata、检查第一个背压」处永久挂起，而 task.bytes
    // 只在首个数据块写出后才累加，界面就永远停在「0 B 正在上传」，且
    // openTimer 已被 startOpen() 取消，不会有任何错误提示。
    // 这里只读 Dart 侧由 dataChannelBufferedAmountChange 事件维护的缓存值，
    // 完全同步、不可能挂起；缓存缺失时退化为 0（靠 SCTP 自身背压）。
    return channel.bufferedAmount ?? 0;
  }
  @override
  set onOpen(void Function()? callback) => _open = callback;
  @override
  set onData(void Function(Uint8List)? callback) => _data = callback;
  @override
  set onClosed(void Function()? callback) => _closed = callback;
  @override
  Future<void> send(Uint8List data) =>
      channel.send(RTCDataChannelMessage.fromBinary(data));
  @override
  Future<void> close() => channel.close();
}

enum FileTransferStatus { queued, transferring, completed, cancelled, failed }

class FileTransferTask {
  final String id;
  final bool download;
  final String source;
  String filename;
  FileTransferStatus status = FileTransferStatus.queued;
  int bytes = 0;
  int totalBytes = 0;
  String? error;
  String? savedPath;

  /// 关键链路阶段记录，供传输队列直接显示。用于区分「通道没打开」、
  /// 「背压检查挂起」、「metadata 已发但无响应」等 0 字节故障。
  final List<String> trace = [];

  FileTransferTask(this.id, this.filename, this.source, {this.download = false});

  bool get finished =>
      status == FileTransferStatus.completed ||
      status == FileTransferStatus.cancelled ||
      status == FileTransferStatus.failed;
  double get fraction =>
      totalBytes > 0 ? (bytes / totalBytes).clamp(0.0, 1.0).toDouble() : 0;
}

class FileTransferManager extends ChangeNotifier {
  final Future<FileTransferChannel> Function(String) _createChannel;

  /// 仅由 [FileTransferManager.new] 设置，用于在 Trace 中记录创建通道瞬间的
  /// PeerConnection 状态（signalingState / iceConnectionState），定位
  /// 「通道 open=false」究竟是 SCTP 未就绪还是 DCEP 协商卡住。
  /// 使用 [withChannelFactory] 的单元测试里为 null，不影响既有行为。
  RTCPeerConnection Function()? _pcProvider;

  /// 【已停用】历史上用于请求 Host 做 SDP 重协商。Host 日志证实该请求会
  /// 触发 ICE restart 并破坏 SCTP 数据面，现已无调用者，仅保留以兼容测试。
  final void Function()? onChannelCreated;

  /// 从会话协商期预建的通道池里取一条已 OPEN 的通道。
  ///
  /// flutter_webrtc 在 Android 上，会话进入 Stable 之后新建的 in-band
  /// DataChannel 发不出 DCEP OPEN（Host 端完全收不到），通道会永远停在
  /// open=false。因此优先复用协商期创建的通道，仅当池耗尽时才回退到动态
  /// 创建。返回 null 表示池中没有可用通道。
  final Future<FileTransferChannel?> Function()? takePooledChannel;

  final Duration idleTimeout;

  /// 背压探测与单帧发送的 watchdog 时限。可注入以便单元测试覆盖
  /// flutter_webrtc 原生 MethodChannel 不返回时的挂起路径。
  final Duration probeTimeout;
  final Duration sendTimeout;
  final List<FileTransferTask> _tasks = [];
  final Map<String, void Function()> _cancelHooks = {};
  bool _disposed = false;
  bool _running = false;
  final _progressClock = Stopwatch()..start();

  FileTransferManager(RTCPeerConnection Function() pcProvider,
      {void Function()? onChannelCreated,
      Future<FileTransferChannel?> Function()? takePooledChannel})
      : this.withChannelFactory((label) async {
          final pc = pcProvider();
          DiagLog.log('FT.FACTORY',
              'createDataChannel label=$label '
              'pcSignaling=${await pc.getSignalingState()} '
              'iceState=${await pc.getIceConnectionState()}');
          final ch = await pc.createDataChannel(
              label, createRemotingDataChannelInit());
          DiagLog.log('FT.FACTORY',
              'created label=$label id=${ch.id} state=${ch.state}');
          return RtcFileTransferChannel(ch);
        },
            pcProvider: pcProvider,
            onChannelCreated: onChannelCreated,
            takePooledChannel: takePooledChannel);

  FileTransferManager.withChannelFactory(this._createChannel,
      {this.idleTimeout = const Duration(seconds: 60),
      this.probeTimeout = const Duration(seconds: 5),
      this.sendTimeout = const Duration(seconds: 10),
      RTCPeerConnection Function()? pcProvider,
      this.onChannelCreated,
      this.takePooledChannel})
      : _pcProvider = pcProvider;

  List<FileTransferTask> get tasks => List.unmodifiable(_tasks);

  String enqueueUpload(String filename, String path) {
    if (_disposed) throw StateError('This session is closed');
    final source = File(path).absolute.path;
    for (final task in _tasks) {
      if (!task.finished && !task.download && task.source == source) return task.id;
    }
    return _enqueue(filename, source, false);
  }

  String enqueueDownload(String saveDir) {
    if (_disposed) throw StateError('This session is closed');
    // One outstanding remote chooser at a time.
    for (final task in _tasks) {
      if (!task.finished && task.download) return task.id;
    }
    return _enqueue('Download', saveDir, true);
  }

  String _enqueue(String filename, String source, bool download) {
    if (_tasks.where((task) => !task.finished).length >= 256) {
      throw StateError('The transfer queue is full');
    }
    final task = FileTransferTask('filetransfer-${_nextTransferId++}', filename,
        source, download: download);
    _tasks.add(task);
    _changed();
    _pump();
    return task.id;
  }

  void cancel(String id) {
    for (final task in _tasks) {
      if (task.id != id || task.finished) continue;
      task.status = FileTransferStatus.cancelled;
      task.error = task.download
          ? 'Download stopped locally; temporary data will be removed.'
          : 'Stopped locally. A partial file may remain on the remote host.';
      _cancelHooks[id]?.call();
      _changed();
      return;
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _progressChanged() {
    if (_progressClock.elapsedMilliseconds < 100) return;
    _progressClock.reset();
    _changed();
  }

  void _pump() {
    if (_disposed || _running) return;
    final pending = _tasks.where((task) => task.status == FileTransferStatus.queued);
    if (pending.isEmpty) return;
    _running = true;
    final task = pending.first;
    task.status = FileTransferStatus.transferring;
    _changed();
    unawaited(_run(task).whenComplete(() {
      _running = false;
      _pump();
    }));
  }

  Future<void> _run(FileTransferTask task) async {
    FileTransferChannel? channel;
    RandomAccessFile? input;
    RandomAccessFile? output;
    Directory? staging;
    final finished = Completer<void>();
    var inbound = Future<void>.value();
    Future<void>? outbound;
    var pendingInboundBytes = 0;
    Timer? timer;
    Timer? openTimer;
    Timer? watchdog;
    final clock = Stopwatch()..start();
    String stage = 'queue';
    String? failure;
    bool ended = false;
    bool opened = false;
    bool metadataReceived = false;
    bool sentEnd = false;
    bool succeeded = false;

    void mark(String value) {
      stage = value;
      task.trace.add('${clock.elapsedMilliseconds}ms $value');
      if (task.trace.length > 24) task.trace.removeAt(0);
      DiagLog.log('FT.RUN', '${task.id} ${clock.elapsedMilliseconds}ms $value');
      _changed();
    }

    void stop([Object? error]) {
      if (ended) return;
      ended = true;
      if (error != null) {
        failure = '$error (stage: $stage)';
        mark('stopped');
        if (!task.finished) {
          task.status = FileTransferStatus.failed;
          task.error = failure;
          _changed();
        }
      }
      timer?.cancel();
      openTimer?.cancel();
      watchdog?.cancel();
      finished.complete();
    }

    void touch() {
      if (ended || _disposed || task.finished) return;
      timer?.cancel();
      timer = Timer(idleTimeout, () => stop('File transfer timed out'));
    }

    bool getStopped() => ended || _disposed || task.finished;

    _cancelHooks[task.id] = () => stop();
    touch();
    mark('reading source');
    try {
      if (!task.download) {
        if (await FileSystemEntity.type(task.source, followLinks: true) !=
            FileSystemEntityType.file) {
          throw StateError('Folders are not supported. Select a regular file.');
        }
        final openedInput = await File(task.source).open();
        input = openedInput;
        task.totalBytes = await openedInput.length();
      }
      if (getStopped()) return;
      mark('creating channel');
      // 记录创建通道瞬间的 PeerConnection 状态，用于区分：
      // signaling 非 stable（重协商未收敛）/ ICE 未 connected（链路未就绪）
      // 这两种都会让新 DataChannel 永远停在 connecting(open=false)。
      final pc = _pcProvider?.call();
      if (pc != null) {
        try {
          final sig = await pc.getSignalingState();
          final ice = await pc.getIceConnectionState();
          mark('pc signaling=$sig ice=$ice');
        } catch (e) {
          mark('pc state query failed: $e');
        }
      }
      Future<FileTransferChannel> openChannel() async {
        final pooled = await takePooledChannel?.call();
        if (pooled != null) {
          mark('using pooled channel (open=${pooled.isOpen})');
          return pooled;
        }
        mark('pool empty; creating channel dynamically');
        return _createChannel(task.id);
      }

      final creation = openChannel().then<FileTransferChannel?>((created) async {
        if (getStopped()) {
          try { await created.close(); } catch (_) {}
          return null;
        }
        return created;
      });
      channel = await Future.any<FileTransferChannel?>([
        creation,
        finished.future.then((_) => null),
      ]);
      if (channel == null || getStopped()) return;
      mark('channel created (open=${channel.isOpen})');
      // filetransfer-N 是 in-band DCEP 通道，在既有 SCTP 关联上创建后会
      // 自动 OPEN，不请求 SDP 重协商。Host 端 quickdesk-remoting 的日志证实
      // request_sdp_restart 会触发 ICE restart 并销毁 SCTP 通道，是通道
      // 停在 open=false 的真正原因。浏览器 WebClient 同样从不发此请求。
      final transport = channel;
      // send() 走 flutter_webrtc 的 MethodChannel。原生实现若不回 result，
      // Future 会永久挂起；加超时让故障可见，而不是永远显示「正在上传 0 B」。
      Future<void> send(Uint8List data) => Future.any<void>([
        transport.send(data).timeout(
          sendTimeout,
          onTimeout: () => throw StateError('DataChannel send timed out'),
        ),
        finished.future,
      ]);

      Future<void> onOpen() async {
        if (opened || getStopped()) return;
        opened = true;
        mark('channel open');
        try {
          if (task.download) {
            await send(_encRequestTransfer());
            mark('request_transfer sent');
            touch();
            return;
          }
          mark('sending metadata');
          await send(_encMetadata(task.filename, task.totalBytes));
          mark('metadata sent');
          while (task.bytes < task.totalBytes && !getStopped()) {
            mark('checking backpressure');
            while (!getStopped() &&
                await Future.any<int>([
                  transport.bufferedBytes().timeout(
                    probeTimeout,
                    onTimeout: () => 0,
                  ),
                  finished.future.then((_) => 0),
                ]) > _bufferHighWater) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            if (getStopped()) return;
            final remaining = task.totalBytes - task.bytes;
            final chunk = await input!.read(
                remaining < _chunkSize ? remaining : _chunkSize);
            if (getStopped()) return;
            if (chunk.isEmpty) throw StateError('The local file changed during upload');
            await send(_encData(chunk));
            if (getStopped()) return;
            if (task.bytes == 0) mark('first data chunk sent');
            task.bytes += chunk.length;
            touch();
            _progressChanged();
          }
          if (!getStopped()) {
            sentEnd = true;
            _changed();
            await send(_encEnd());
            mark('end sent; awaiting success');
            touch();
          }
        } catch (error) {
          stop(error);
        }
      }

      Future<void> onData(Uint8List bytes) async {
        if (getStopped()) return;
        final message = decodeFtMessage(bytes);
        touch();
        if (message.errorType != null) {
          mark('host error frame');
          stop('Host error ${message.errorType}');
          return;
        }
        if (!task.download) {
          if (message.success && sentEnd) {
            mark('success received');
            succeeded = true;
            stop();
          }
          return;
        }
        if (message.metadata) {
          if (metadataReceived || (message.metaSize != null && message.metaSize! < 0)) {
            throw StateError('Invalid or repeated download metadata');
          }
          metadataReceived = true;
          task.filename = sanitizeDownloadName(message.metaFilename ?? 'download');
          // Existing remoting Metadata.size is optional/advisory. End, not
          // a byte-count equality, determines successful transfer completion.
          task.totalBytes = message.metaSize ?? 0;
          await Directory(task.source).create(recursive: true);
          staging = await Directory(task.source).createTemp('quickdesk-');
          output = await File('${staging!.path}${Platform.pathSeparator}payload.part').open(
              mode: FileMode.write);
          _changed();
        } else if (message.data != null) {
          if (!metadataReceived || output == null) {
            throw StateError('Download data arrived before metadata');
          }
          await output!.writeFrom(message.data!);
          if (getStopped()) return;
          task.bytes += message.data!.length;
          _progressChanged();
        } else if (message.end) {
          if (!metadataReceived || output == null) {
            throw StateError('Incomplete download');
          }
          await output!.flush();
          await output!.close();
          output = null;
          if (getStopped()) return;
          final destination = '${staging!.path}${Platform.pathSeparator}${task.filename}';
          await File('${staging!.path}${Platform.pathSeparator}payload.part').rename(destination);
          if (getStopped()) return;
          task.savedPath = destination;
          // Download completion means our file is durable and finalized. The
          // peer may close immediately after receiving success; that must not
          // delete the committed file or relabel it as a failure.
          succeeded = true;
          task.status = FileTransferStatus.completed;
          task.error = null;
          _changed();
          try {
            await transport.send(_encSuccess()).timeout(const Duration(seconds: 5));
          } catch (_) {
            // Local download remains valid even if the acknowledgement is lost.
          }
          stop();
        }
      }

      void startOpen() {
        if (opened || getStopped()) return;
        openTimer?.cancel();
        outbound = onOpen();
        unawaited(outbound);
      }
      transport.onOpen = startOpen;
      transport.onClosed = () => stop('File channel closed before completion');
      transport.onData = (data) {
        if (getStopped()) return;
        // Bound queued disk writes as well as outbound network buffers. The
        // protocol has no receive-window API; fail safely if disk cannot keep up.
        if (pendingInboundBytes + data.length > 8 * 1024 * 1024) {
          stop('Download receive buffer limit exceeded');
          return;
        }
        pendingInboundBytes += data.length;
        // A single ordered chain prevents end/flush racing preceding writes.
        inbound = inbound.then((_) => onData(data)).catchError((Object error) {
          stop(error);
        }).whenComplete(() {
          pendingInboundBytes -= data.length;
        });
      };
      if (transport.isOpen) {
        startOpen();
      } else {
        // 覆盖「open 回调在绑定前触发、state getter 滞后」的竞态。
        unawaited(Future<void>.delayed(const Duration(seconds: 1), () {
          if (!opened && !getStopped() && transport.isOpen) startOpen();
        }));
      }
      // 无论通道是否报告 open，watchdog 都启用：open 之后发送链路仍可能
      // 卡在背压检查或 send 上，而 openTimer 已被 startOpen() 取消。
      watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
        if (getStopped()) {
          watchdog?.cancel();
          return;
        }
        if (!opened && clock.elapsed >= const Duration(seconds: 15)) {
          stop('File transfer channel did not open within 15s; '
              'the remote host may have rejected this transfer');
        } else if (opened && !task.download && task.bytes == 0 &&
            clock.elapsed >= const Duration(seconds: 20)) {
          stop('No data sent within 20s after the channel opened');
        }
      });
      await finished.future;
    } catch (error) {
      failure = '$error';
      ended = true;
    } finally {
      ended = true;
      timer?.cancel();
      openTimer?.cancel();
      watchdog?.cancel();
      _cancelHooks.remove(task.id);
      if (channel != null) {
        channel.onOpen = null;
        channel.onData = null;
        channel.onClosed = null;
        try { await channel.close(); } catch (_) {}
      }
      await inbound;
      await outbound;
      try { await input?.close(); } catch (_) {}
      try { await output?.close(); } catch (_) {}
      if (!succeeded && staging != null) {
        // Only this task's newly-created private directory is removed.
        try { await staging!.delete(recursive: true); } catch (_) {}
        task.savedPath = null;
      }
      if (!task.finished) {
        task.status = succeeded ? FileTransferStatus.completed : FileTransferStatus.failed;
        task.error = succeeded ? null : (failure ?? 'File transfer stopped');
      }
      _changed();
    }
  }

  /// Peer-supplied filenames never become paths; each download has its own directory.
  static String sanitizeDownloadName(String name) {
    var safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (safe.isEmpty || safe == '.' || safe == '..') safe = 'download';
    if (safe.length > 180) safe = safe.substring(0, 180);
    // Do not collide with our private staging filename.
    if (safe == 'payload.part') safe = 'download-payload.part';
    return safe;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final task in _tasks) {
      if (!task.finished) {
        task.status = FileTransferStatus.cancelled;
        task.error = 'Session closed';
        _cancelHooks[task.id]?.call();
      }
    }
    notifyListeners();
    super.dispose();
  }
}
