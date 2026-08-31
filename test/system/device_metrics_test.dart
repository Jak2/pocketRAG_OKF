// test/system/device_metrics_test.dart
//
// Parsing and CPU differencing are tested against injected /proc text, never
// the real files, so these pass identically on CI and on a device.
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/system/device_metrics.dart';

// Trimmed but otherwise verbatim /proc/self/status.
const _status = '''
Name:\tflutter
State:\tS (sleeping)
VmPeak:\t  912340 kB
VmSize:\t  812340 kB
VmRSS:\t  148256 kB
Threads:\t28
''';

/// A real /proc/self/stat line. Field 2 deliberately contains a space and a
/// ')' — the kernel does not escape the comm field.
String _stat({required int utime, required int stime, String comm = 'my (app)'}) {
  final fields = <String>[
    '1234', // 1 pid
    '($comm)', // 2 comm
    'S', // 3 state
    '1', '1234', '1234', '0', '-1', '4194304', // 4-9
    '10000', '0', '500', '0', // 10-13
    '$utime', // 14 utime
    '$stime', // 15 stime
    '0', '0', '20', '0', '28', // 16-20
  ];
  return '${fields.join(' ')}\n';
}

void main() {
  _cpuShareTests();
  group('parseVmRssKb', () {
    test('reads the VmRSS line in kB', () {
      expect(parseVmRssKb(_status), 148256);
    });

    test('is not fooled by the other Vm lines above it', () {
      expect(parseVmRssKb(_status), isNot(812340));
    });

    test('returns null when VmRSS is absent', () {
      expect(parseVmRssKb('Name:\tflutter\nThreads:\t28\n'), isNull);
    });

    test('returns null on empty or garbage input', () {
      expect(parseVmRssKb(''), isNull);
      expect(parseVmRssKb('not proc text at all'), isNull);
    });
  });

  group('parseCpuTicks', () {
    test('sums utime and stime', () {
      expect(parseCpuTicks(_stat(utime: 300, stime: 120)), 420);
    });

    test('counts fields from the last ")" so a spacey comm cannot shift them', () {
      expect(parseCpuTicks(_stat(utime: 7, stime: 3, comm: 'a b) c')), 10);
    });

    test('returns null when there are too few fields', () {
      expect(parseCpuTicks('1234 (app) S 1 2 3'), isNull);
    });

    test('returns null on garbage with no parenthesised comm', () {
      expect(parseCpuTicks('garbage'), isNull);
    });
  });

  group('DeviceMetrics.update', () {
    test('first sample has RAM but no CPU% — nothing to difference yet', () {
      final m = DeviceMetrics();
      final s = m.update(statusText: _status, statText: _stat(utime: 100, stime: 0), nowMillis: 0);
      expect(s.rssKb, 148256);
      expect(s.cpuPercent, isNull);
    });

    test('second sample differences ticks over the elapsed interval', () {
      final m = DeviceMetrics();
      m.update(statusText: _status, statText: _stat(utime: 100, stime: 0), nowMillis: 0);
      // +50 ticks = 0.5s of CPU over 1s of wall clock = 50%.
      final s = m.update(statusText: _status, statText: _stat(utime: 140, stime: 10), nowMillis: 1000);
      expect(s.cpuPercent, closeTo(50, 0.001));
    });

    test('reports above 100% when several threads are busy', () {
      final m = DeviceMetrics();
      m.update(statusText: _status, statText: _stat(utime: 0, stime: 0), nowMillis: 0);
      final s = m.update(statusText: _status, statText: _stat(utime: 300, stime: 0), nowMillis: 1000);
      expect(s.cpuPercent, closeTo(300, 0.001));
    });

    test('a failed status read blanks RAM without breaking CPU%', () {
      final m = DeviceMetrics();
      m.update(statusText: null, statText: _stat(utime: 0, stime: 0), nowMillis: 0);
      final s = m.update(statusText: null, statText: _stat(utime: 100, stime: 0), nowMillis: 1000);
      expect(s.rssKb, isNull);
      expect(s.cpuPercent, closeTo(100, 0.001));
    });

    test('a failed stat read drops the baseline instead of faking a delta', () {
      final m = DeviceMetrics();
      m.update(statusText: _status, statText: _stat(utime: 0, stime: 0), nowMillis: 0);
      final gap = m.update(statusText: _status, statText: null, nowMillis: 1000);
      expect(gap.cpuPercent, isNull);
      // The sample after the gap must not divide a two-interval tick delta by
      // one interval — it starts a fresh baseline instead.
      final next = m.update(statusText: _status, statText: _stat(utime: 200, stime: 0), nowMillis: 2000);
      expect(next.cpuPercent, isNull);
      final after = m.update(statusText: _status, statText: _stat(utime: 210, stime: 0), nowMillis: 3000);
      expect(after.cpuPercent, closeTo(10, 0.001));
    });

    test('a zero or backwards interval yields null, never a division blow-up', () {
      final m = DeviceMetrics();
      m.update(statusText: _status, statText: _stat(utime: 0, stime: 0), nowMillis: 5000);
      final same = m.update(statusText: _status, statText: _stat(utime: 50, stime: 0), nowMillis: 5000);
      expect(same.cpuPercent, isNull);
    });

    test('stop() clears the baseline so a resumed poll does not span the pause', () {
      final m = DeviceMetrics();
      m.update(statusText: _status, statText: _stat(utime: 0, stime: 0), nowMillis: 0);
      m.stop();
      final resumed = m.update(statusText: _status, statText: _stat(utime: 9000, stime: 0), nowMillis: 60000);
      expect(resumed.cpuPercent, isNull);
    });
  });
}

void _cpuShareTests() {
  group('cpuPercentOfDevice', () {
    test('divides the top-style figure by the core count', () {
      const s = DeviceSnapshot(cpuPercent: 400, cores: 8);
      expect(s.cpuPercentOfDevice, 50);
    });

    test('clamps to 100 rather than reporting more than the whole device', () {
      const s = DeviceSnapshot(cpuPercent: 900, cores: 8);
      expect(s.cpuPercentOfDevice, 100);
    });

    test('is null when cpu or cores are unknown', () {
      expect(const DeviceSnapshot(cores: 8).cpuPercentOfDevice, isNull);
      expect(const DeviceSnapshot(cpuPercent: 50).cpuPercentOfDevice, isNull);
      expect(const DeviceSnapshot(cpuPercent: 50, cores: 0).cpuPercentOfDevice, isNull);
    });
  });
}
