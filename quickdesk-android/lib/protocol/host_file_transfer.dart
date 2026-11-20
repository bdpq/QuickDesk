/// host_file_transfer.dart - 被控端（Host 角色）的文件传输
///
/// 与主控端的 [FileTransferManager] 互为镜像。Windows 桌面端 / Web 客户端
/// 在建立会话后动态创建 `filetransfer-<n>` in-band DataChannel，被控端只需
/// 接管这些入站通道，不需要自己创建通道，也不需要做 SDP 重协商：
///
///   上传（client → Android host）：metadata → data* → end → 回 success
///   下载（Android host → client）：client 发 request_transfer
///                                → metadata → data* → end → 等 success
///
/// 在此之前 Android 被控端只接 'event' 通道，filetransfer-* 全部被忽略，
/// 且不下发 `fileTransfer` 能力，所以桌面端工具栏的传输项始终不可用。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../util/diag_log.dart';
import 'file_transfer.dart';

enum HostFileEventKind { received, sent, failed }

/// 供上层 UI 展示的传输结果（成功路径 / 失败原因）。
class HostFileEvent {
  final HostFileEventKind kind;
  final String filename;
  final String? path;
  final String? message;

  const HostFileEvent({
    required this.kind,
    required this.filename,
    this.path,
    this.message,
  });
}

/// 把暂存文件发布到用户可访问的位置，返回用于展示的路径。
typedef HostFilePublisher = Future<String> Function(
    String filename, File staged);

/// 控制端请求下载时，在本机挑一个文件；返回 null 表示用户取消。
typedef HostFilePicker = Future<String?> Function();

const int _hostChunkSize = 8192;
const int _hostBufferHighWater = _hostChunkSize * 8;
const int _maxQueuedInboundBytes = 8 * 1024 * 1024;

class HostFileTransferManager {
  HostFileTransferManager({
    required this.publish,
    required this.pickOutgoing,
    this.onEvent,
    this.onLog,
    Directory? stagingRoot,
    this.idleTimeout = const Duration(seconds: 60),
  }) : _stagingRoot = stagingRoot ?? Directory.systemTemp;

  final HostFilePublisher publish;
  final HostFilePicker pickOutgoing;
  final void Function(HostFileEvent event)? onEvent;
  final void Function(String message)? onLog;
  final Directory _stagingRoot;
  final Duration idleTimeout;

  final Set<_HostTransfer> _active = {};
  bool _disposed = false;

  int get activeCount => _active.length;

  void _log(String message) {
    DiagLog.log('HOST.FT', message);
    onLog?.call(message);
  }

  /// 接管控制端创建的入站 filetransfer-N 通道。
  void accept(FileTransferChannel channel, {String label = 'filetransfer'}) {
    if (_disposed) {
      unawaited(channel.close());
      return;
    }
    final state = _HostTransfer(channel: channel, label: label);
    _active.add(state);
    _log('accept label=$label open=${channel.isOpen}');

    channel.onOpen = () => _log('open label=$label');
    channel.onClosed = () {
      if (state.done) return;
      // 下载方向已发完 end：控制端可能在写完本地文件后直接关通道，
      // success 帧偶发丢失时不能把一次实际完成的传输误报为失败。
      if (state.serving && state.sentEnd) {
        onEvent?.call(HostFileEvent(
          kind: HostFileEventKind.sent,
          filename: state.filename ?? 'file',
          path: state.sourcePath,
        ));
        _finish(state, null);
      } else {
        _finish(state, 'File channel closed before completion');
      }
    };
    channel.onData = (bytes) {
      if (state.done || _disposed) return;
      // 有序串行处理，避免 end 抢在前面的 data 落盘之前。
      if (state.pendingBytes + bytes.length > _maxQueuedInboundBytes) {
        _fail(state, 'Receive buffer limit exceeded');
        return;
      }
      state.pendingBytes += bytes.length;
      state.inbound = state.inbound
          .then((_) => _handle(state, bytes))
          .catchError((Object error) {
        _fail(state, '$error');
      }).whenComplete(() {
        state.pendingBytes -= bytes.length;
      });
    };
    _touch(state);
  }

  void _touch(_HostTransfer state) {
    if (state.done) return;
    state.idleTimer?.cancel();
    state.idleTimer = Timer(idleTimeout, () {
      _finish(state, 'File transfer timed out');
    });
  }

  Future<void> _handle(_HostTransfer state, Uint8List bytes) async {
    final msg = decodeFtMessage(bytes);
    _touch(state);

    // 控制端主动取消（CANCELED）或报告错误：立刻丢弃暂存数据。
    if (msg.errorType != null) {
      _log('peer error type=${msg.errorType} label=${state.label}');
      _finish(state, 'Remote side cancelled the transfer');
      return;
    }

    if (msg.requestTransfer) {
      await _serve(state);
      return;
    }

    // ---- 下载方向：控制端确认收到我们发过去的文件 ----
    if (msg.success) {
      if (!state.serving || !state.sentEnd) {
        _fail(state, 'Premature success frame');
        return;
      }
      _log('download confirmed label=${state.label}');
      onEvent?.call(HostFileEvent(
        kind: HostFileEventKind.sent,
        filename: state.filename ?? 'file',
        path: state.sourcePath,
      ));
      _finish(state, null, closeChannel: true);
      return;
    }

    // ---- 上传方向 ----
    if (msg.metadata) {
      if (state.serving) {
        _fail(state, 'Unexpected metadata during download');
        return;
      }
      if (state.metadataReceived) {
        _fail(state, 'Duplicate metadata');
        return;
      }
      final size = msg.metaSize;
      if (size != null && size < 0) {
        _fail(state, 'Invalid metadata size');
        return;
      }
      state.metadataReceived = true;
      state.filename = FileTransferManager.sanitizeDownloadName(
          msg.metaFilename ?? 'download');
      state.staging = await _stagingRoot.createTemp('qd-host-ft-');
      state.partPath =
          '${state.staging!.path}${Platform.pathSeparator}payload.part';
      state.output = await File(state.partPath!).open(mode: FileMode.write);
      _log('metadata label=${state.label} name=${state.filename} size=$size');
      return;
    }

    if (msg.data != null) {
      if (!state.metadataReceived || state.output == null) {
        _fail(state, 'Data arrived before metadata');
        return;
      }
      await state.output!.writeFrom(msg.data!);
      state.bytes += msg.data!.length;
      return;
    }

    if (msg.end) {
      if (!state.metadataReceived || state.output == null) {
        _fail(state, 'Incomplete upload');
        return;
      }
      await state.output!.flush();
      await state.output!.close();
      state.output = null;
      if (state.done) return;
      final staged = File(state.partPath!);
      final path = await publish(state.filename!, staged);
      _log('received label=${state.label} bytes=${state.bytes} -> $path');
      // 先回 success 再关通道：控制端以 success 判定完成，通道 close 只能
      // 排在其后，否则部分客户端会把已完成的传输改判为失败。
      await _send(state, encodeFtSuccess());
      onEvent?.call(HostFileEvent(
        kind: HostFileEventKind.received,
        filename: state.filename!,
        path: path,
      ));
      _finish(state, null, closeChannel: true, delayClose: true);
      return;
    }
  }

  /// 控制端请求从 Android 侧取文件：弹选择器 → metadata → 分块 → end。
  Future<void> _serve(_HostTransfer state) async {
    if (state.serving || state.metadataReceived) {
      _fail(state, 'Conflicting transfer direction');
      return;
    }
    state.serving = true;
    _log('request_transfer label=${state.label}');
    final String? path;
    try {
      path = await pickOutgoing();
    } catch (error) {
      await _send(state, encodeFtError(1));
      _finish(state, 'File picker failed: $error', closeChannel: true);
      return;
    }
    if (state.done) return;
    if (path == null || path.isEmpty) {
      _log('download cancelled by local user label=${state.label}');
      await _send(state, encodeFtError(1));
      _finish(state, 'No file selected', closeChannel: true);
      return;
    }
    final source = File(path);
    if (await FileSystemEntity.type(path, followLinks: true) !=
        FileSystemEntityType.file) {
      await _send(state, encodeFtError(1));
      _finish(state, 'Selected item is not a regular file',
          closeChannel: true);
      return;
    }
    final length = await source.length();
    state.sourcePath = path;
    state.filename = FileTransferManager.sanitizeDownloadName(
        path.split(Platform.pathSeparator).last);
    await _send(state, encodeFtMetadata(state.filename!, length));
    final input = await source.open();
    try {
      var offset = 0;
      while (offset < length && !state.done) {
        while (!state.done &&
            await state.channel.bufferedBytes() > _hostBufferHighWater) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        if (state.done) break;
        final remaining = length - offset;
        final chunk = await input
            .read(remaining < _hostChunkSize ? remaining : _hostChunkSize);
        if (chunk.isEmpty) throw StateError('Local file changed during send');
        await _send(state, encodeFtData(chunk));
        offset += chunk.length;
        _touch(state);
      }
      if (state.done) return;
      state.sentEnd = true;
      await _send(state, encodeFtEnd());
      _log('download sent label=${state.label} bytes=$offset; awaiting success');
      _touch(state);
    } catch (error) {
      _fail(state, 'Sending file failed: $error');
    } finally {
      await input.close();
    }
  }

  Future<void> _send(_HostTransfer state, Uint8List frame) async {
    if (state.done) return;
    try {
      await state.channel.send(frame).timeout(const Duration(seconds: 10));
    } catch (error) {
      _fail(state, 'DataChannel send failed: $error');
    }
  }

  void _fail(_HostTransfer state, String reason) {
    if (state.done) return;
    unawaited(state.channel
        .send(encodeFtError(1))
        .then<void>((_) {}, onError: (Object _) {}));
    _finish(state, reason, closeChannel: true, delayClose: true);
  }

  /// 结束一次传输：结算 UI 事件 / 清理暂存 / 可选关闭通道。
  void _finish(
    _HostTransfer state,
    String? reason, {
    bool closeChannel = false,
    bool delayClose = false,
  }) {
    if (state.done) return;
    state.done = true;
    state.idleTimer?.cancel();
    _active.remove(state);
    state.channel.onOpen = null;
    state.channel.onData = null;
    state.channel.onClosed = null;
    unawaited(_cleanup(state, reason, closeChannel, delayClose));
  }

  Future<void> _cleanup(
    _HostTransfer state,
    String? reason,
    bool closeChannel,
    bool delayClose,
  ) async {
    await state.inbound.then<void>((_) {}, onError: (Object _) {});
    try {
      await state.output?.close();
    } catch (_) {}
    state.output = null;
    if (state.staging != null) {
      try {
        await state.staging!.delete(recursive: true);
      } catch (_) {}
    }
    if (reason != null) {
      _log('stopped label=${state.label}: $reason');
      onEvent?.call(HostFileEvent(
        kind: HostFileEventKind.failed,
        filename: state.filename ?? 'file',
        message: reason,
      ));
    }
    if (closeChannel) {
      // 让 success / error 帧先被控制端收到；SCTP 是有序通道，但部分客户端
      // 在 onclose 里会直接把任务改判为失败，留一点余量更稳。
      if (delayClose) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      try {
        await state.channel.close();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final state in _active.toList()) {
      _finish(state, 'Host session closed', closeChannel: true);
    }
    // 等所有暂存清理完成，避免会话结束后残留 .part 文件。
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

class _HostTransfer {
  _HostTransfer({required this.channel, required this.label});

  final FileTransferChannel channel;
  final String label;
  Future<void> inbound = Future<void>.value();
  Timer? idleTimer;
  int pendingBytes = 0;
  int bytes = 0;

  bool done = false;
  bool metadataReceived = false;
  bool serving = false;
  bool sentEnd = false;

  String? filename;
  String? sourcePath;
  String? partPath;
  Directory? staging;
  RandomAccessFile? output;
}
