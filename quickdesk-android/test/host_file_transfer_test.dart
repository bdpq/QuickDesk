import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickdesk_android/protocol/file_transfer.dart';
import 'package:quickdesk_android/protocol/host_file_transfer.dart';
import 'package:quickdesk_android/protocol/proto/wire.dart';

class FakeHostChannel implements FileTransferChannel {
  @override
  bool isOpen = true;
  @override
  void Function()? onOpen;
  @override
  void Function(Uint8List)? onData;
  @override
  void Function()? onClosed;
  final sent = <Uint8List>[];
  bool closed = false;

  @override
  Future<int> bufferedBytes() async => 0;

  @override
  Future<void> send(Uint8List data) async {
    if (closed) throw StateError('closed');
    sent.add(data);
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  void reply(Uint8List data) => onData?.call(data);
}

Uint8List emptyField(int number) =>
    lengthDelimitedField(number, Uint8List(0));
Uint8List metadataFrame(String name, int size) => encodeFtMetadata(name, size);
Uint8List dataFrame(List<int> bytes) =>
    encodeFtData(Uint8List.fromList(bytes));
int fieldOf(Uint8List message) => ProtobufReader(message).readTag().fieldNumber;
FtMessage decode(Uint8List message) => decodeFtMessage(message);

Future<void> waitUntil(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }
}

void main() {
  late Directory dir;
  final managers = <HostFileTransferManager>[];
  final events = <HostFileEvent>[];
  final published = <String, List<int>>{};

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qd-host-ft-test-');
    events.clear();
    published.clear();
  });

  tearDown(() async {
    for (final manager in managers) {
      await manager.dispose();
    }
    managers.clear();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<String> publish(String name, File staged) async {
    final bytes = await staged.readAsBytes();
    published[name] = bytes;
    final target = File('${dir.path}${Platform.pathSeparator}$name');
    await target.writeAsBytes(bytes);
    return target.path;
  }

  HostFileTransferManager manager(
    Future<String?> Function() picker, {
    Future<String> Function(String, File)? publisher,
  }) {
    final value = HostFileTransferManager(
      publish: publisher ?? publish,
      pickOutgoing: picker,
      onEvent: events.add,
      stagingRoot: dir,
      idleTimeout: const Duration(seconds: 10),
    );
    managers.add(value);
    return value;
  }

  Future<File> local(String name, List<int> bytes) async {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  test('incoming upload is persisted and acknowledged with success', () async {
    final m = manager(() async => null);
    final ch = FakeHostChannel();
    m.accept(ch, label: 'filetransfer-1');

    ch.reply(metadataFrame('hello.txt', 5));
    ch.reply(dataFrame([1, 2, 3]));
    ch.reply(dataFrame([4, 5]));
    ch.reply(encodeFtEnd());

    await waitUntil(() => events.isNotEmpty);
    expect(events.single.kind, HostFileEventKind.received);
    expect(events.single.filename, 'hello.txt');
    expect(events.single.path, endsWith('hello.txt'));
    expect(published['hello.txt'], [1, 2, 3, 4, 5]);
    expect(ch.sent.any((frame) => fieldOf(frame) == 4), isTrue,
        reason: 'Host must acknowledge upload with success');
    await waitUntil(() => ch.closed);
  });

  test('request_transfer streams a local file and waits for success', () async {
    final source = await local('out.bin', [9, 8, 7, 6]);
    final m = manager(() async => source.path);
    final ch = FakeHostChannel();
    m.accept(ch, label: 'filetransfer-2');

    ch.reply(emptyField(5));
    await waitUntil(() => ch.sent.any((frame) => fieldOf(frame) == 3));

    final meta = decode(ch.sent.firstWhere((f) => fieldOf(f) == 1));
    expect(meta.metaFilename, 'out.bin');
    expect(meta.metaSize, 4);
    final data = ch.sent
        .where((f) => fieldOf(f) == 2)
        .map((f) => decode(f).data!)
        .expand((bytes) => bytes)
        .toList();
    expect(data, [9, 8, 7, 6]);
    expect(events, isEmpty, reason: 'must not claim success before ack');

    ch.reply(emptyField(4));
    await waitUntil(() => events.isNotEmpty);
    expect(events.single.kind, HostFileEventKind.sent);
    expect(events.single.filename, 'out.bin');
  });

  test('cancelled picker is rejected without creating a file', () async {
    final m = manager(() async => null);
    final ch = FakeHostChannel();
    m.accept(ch, label: 'filetransfer-3');

    ch.reply(emptyField(5));
    await waitUntil(() => ch.sent.any((f) => fieldOf(f) == 6));
    expect(decode(ch.sent.firstWhere((f) => fieldOf(f) == 6)).errorType, 1);
    expect(published, isEmpty);
    await waitUntil(() => events.isNotEmpty);
    expect(events.single.kind, HostFileEventKind.failed);
  });

  test('duplicate metadata and data-before-metadata are rejected', () async {
    final m = manager(() async => null);
    final ch = FakeHostChannel();
    m.accept(ch, label: 'filetransfer-4');
    ch.reply(metadataFrame('a.txt', 1));
    ch.reply(metadataFrame('b.txt', 1));
    await waitUntil(() => ch.sent.any((f) => fieldOf(f) == 6));
    expect(published, isEmpty);

    final ch2 = FakeHostChannel();
    m.accept(ch2, label: 'filetransfer-5');
    ch2.reply(dataFrame([1]));
    await waitUntil(() => ch2.sent.any((f) => fieldOf(f) == 6));
    expect(published, isEmpty);
  });

  test('peer error frame aborts upload and reports failure', () async {
    final m = manager(() async => null);
    final ch = FakeHostChannel();
    m.accept(ch, label: 'filetransfer-6');
    ch.reply(metadataFrame('partial.bin', 3));
    ch.reply(dataFrame([1]));
    ch.reply(encodeFtError(1));
    await waitUntil(() => events.isNotEmpty);
    expect(events.single.kind, HostFileEventKind.failed);
    expect(published, isEmpty);
  });

  test('channel close aborts an unfinished transfer', () async {
    final m = manager(() async => null);
    final ch = FakeHostChannel();
    m.accept(ch, label: 'filetransfer-7');
    ch.reply(metadataFrame('partial.bin', 3));
    ch.reply(dataFrame([1]));
    ch.onClosed?.call();
    await waitUntil(() => events.isNotEmpty);
    expect(events.single.kind, HostFileEventKind.failed);
    expect(published, isEmpty);
  });

  test('filenames are sanitized before they become paths', () async {
    final m = manager(() async => null);
    final ch = FakeHostChannel();
    m.accept(ch, label: 'filetransfer-8');
    ch.reply(metadataFrame('../../evil/name.txt', 1));
    ch.reply(dataFrame([42]));
    ch.reply(encodeFtEnd());
    await waitUntil(() => published.isNotEmpty);
    expect(published.keys.single, '.._.._evil_name.txt');
  });

  test('download counts as sent when peer closes after end without ack', () async {
    final source = await local('out2.bin', [1, 2]);
    final m = manager(() async => source.path);
    final ch = FakeHostChannel();
    m.accept(ch, label: 'filetransfer-10');
    ch.reply(emptyField(5));
    await waitUntil(() => ch.sent.any((f) => fieldOf(f) == 3));
    ch.onClosed?.call();
    await waitUntil(() => events.isNotEmpty);
    expect(events.single.kind, HostFileEventKind.sent);
  });

  test('dispose closes active channels and removes staging data', () async {
    final m = manager(() async => null);
    final ch = FakeHostChannel();
    m.accept(ch, label: 'filetransfer-9');
    ch.reply(metadataFrame('pending.bin', 1));
    ch.reply(dataFrame([1]));
    await m.dispose();
    expect(ch.closed, isTrue);
    expect(m.activeCount, 0);
    expect(published, isEmpty);
  });
}
