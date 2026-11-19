/// Session-scoped file queue. Closing this sheet does not cancel active transfers.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../protocol/file_transfer.dart';

class TransferSheet extends StatelessWidget {
  final FileTransferManager manager;

  /// 被控端通过 control 通道下发的 capabilities。用于排查「通道被拒绝」时
  /// 区分是对端不支持、还是本端声明/通道 ID 没被接受。
  final String hostCapabilities;

  const TransferSheet({
    super.key,
    required this.manager,
    this.hostCapabilities = '',
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.65,
        child: AnimatedBuilder(
          animation: manager,
          builder: (context, _) => Column(
            children: [
              ListTile(
                title: Text(L10n.t('file.transfers')),
                trailing: IconButton(
                  tooltip: L10n.t('common.back'),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                child: Text(
                  'Host caps: ${hostCapabilities.isEmpty ? '(none)' : hostCapabilities}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: manager.tasks.length,
                  itemBuilder: (context, index) {
                    final task = manager.tasks[index];
                    final status = switch (task.status) {
                      FileTransferStatus.queued => L10n.t('file.queued'),
                      FileTransferStatus.transferring => task.download
                          ? L10n.t('file.downloading') : L10n.t('file.uploading'),
                      FileTransferStatus.completed => L10n.t('file.done'),
                      FileTransferStatus.cancelled => L10n.t('file.stopped'),
                      FileTransferStatus.failed => L10n.t('file.failed'),
                    };
                    return ListTile(
                      key: ValueKey(task.id),
                      leading: Icon(task.download ? Icons.download : Icons.upload),
                      title: Text(task.filename),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(status),
                          if (task.status == FileTransferStatus.transferring)
                            LinearProgressIndicator(
                              value: task.totalBytes > 0 ? task.fraction : null,
                            ),
                          Text('${task.bytes} / ${task.totalBytes} B'),
                          if (task.error != null) Text(task.error!),
                          if (task.trace.isNotEmpty)
                            Text(
                              'Trace: ${task.trace.join(' | ')}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (task.savedPath != null)
                            SelectableText(L10n.t('file.savedTo', {'path': task.savedPath})),
                        ],
                      ),
                      trailing: task.finished ? null : IconButton(
                        tooltip: L10n.t('common.cancel'),
                        icon: const Icon(Icons.cancel_outlined),
                        onPressed: () => manager.cancel(task.id),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
