import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 轻量诊断日志。
///
/// 部分 ROM（例如 vivo NX809J）会屏蔽 logcat，`adb logcat -d` 恒为空，
/// 导致 Dart 层的通道状态与协商过程完全不可观测。这里把关键日志同步写入
/// 应用私有目录，便于用下面命令拉取：
///
/// ```sh
/// adb shell run-as com.quickcoder.quickdesk_android.dev \
///   cat files/quickdesk_diag.log
/// ```
///
/// 同步写是为了保证进程被杀/崩溃时日志不丢；诊断日志量很小（一次传输
/// 几十行），不会造成可感知的卡顿。
class DiagLog {
  static File? _file;
  static bool _initTried = false;

  static String get path => _file?.path ?? '';

  /// 幂等初始化，每次冷启动重建日志，避免历史内容干扰判断。
  static Future<void> init() async {
    if (_initTried) return;
    _initTried = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/quickdesk_diag.log');
      file.writeAsStringSync(
        '${DateTime.now().toIso8601String()} [DIAG] log started\n',
        mode: FileMode.write,
        flush: true,
      );
      _file = file;
    } catch (_) {
      _file = null;
    }
  }

  static void log(String tag, String message) {
    final line =
        '${DateTime.now().toIso8601String()} [$tag] $message';
    // ignore: avoid_print
    print(line);
    try {
      _file?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志失败不能影响业务链路。
    }
  }
}
