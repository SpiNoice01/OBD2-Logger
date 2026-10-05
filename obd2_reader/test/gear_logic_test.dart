import 'package:flutter_test/flutter_test.dart';
import 'package:obd2_reader/services/gear_estimator.dart';
import 'package:obd2_reader/services/obd_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('parseMode22', () {
    test('single frame positive', () {
      final r = ObdParser.parseMode22('62223003\r\r', 0x2230);
      expect(r.data, [0x03]);
    });
    test('multi frame positive', () {
      const raw = '00B\r0:6222300102\r1:030405060708\r';
      final r = ObdParser.parseMode22(raw, 0x2230);
      expect(r.data, [1, 2, 3, 4, 5, 6, 7, 8]);
    });
    test('negative response', () {
      final r = ObdParser.parseMode22('7F2231\r', 0x2230);
      expect(r.isPositive, false);
      expect(r.nrc, 0x31);
      expect(r.ecuAnswered, true);
    });
    test('no data', () {
      final r = ObdParser.parseMode22('NO DATA\r', 0x2230);
      expect(r.ecuAnswered, false);
    });
  });

  test('estimator finds 5 gears', () async {
    SharedPreferences.setMockInitialValues({});
    final est = GearEstimator(gearCount: 5);
    // rpm per km/h per gear (rough 5AT values)
    const ratios = [120.0, 70.0, 45.0, 33.0, 25.0];
    for (var i = 0; i < 2000; i++) {
      final g = ratios[i % 5];
      final speed = 20.0 + (i % 37);
      final jitter = 1 + ((i % 7) - 3) * 0.004;
      est.addSample(g * speed * jitter, speed);
    }
    expect(est.isCalibrated, true);
    expect(est.estimate(45 * 50, 50), 3);
    expect(est.estimate(120 * 20, 20), 1);
    expect(est.estimate(25 * 100, 100), 5);
    expect(est.estimate(55 * 50, 50), isNull); // between gears
  });
}
