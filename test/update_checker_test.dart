import 'package:flutter_test/flutter_test.dart';
import 'package:yibianhui_blog/src/data/update_checker.dart';

void main() {
  group('parseVersion', () {
    test('解析标准三段格式', () {
      expect(UpdateChecker.parseVersion('0.0.5'), (0, 0, 5));
      expect(UpdateChecker.parseVersion('0.0.1'), (0, 0, 1));
      expect(UpdateChecker.parseVersion('1.2.3'), (1, 2, 3));
      expect(UpdateChecker.parseVersion('0.0'), (0, 0, 0));
    });

    test('拒绝非法格式', () {
      expect(UpdateChecker.parseVersion(''), isNull);
      expect(UpdateChecker.parseVersion('a.b.c'), isNull);
      expect(UpdateChecker.parseVersion('0.0.5.1'), isNull);
      expect(UpdateChecker.parseVersion('0.-1.2'), isNull);
    });
  });

  group('isNewerVersion', () {
    test('小改动递增判定', () {
      expect(UpdateChecker.isNewerVersion('0.0.5', '0.0.6'), isTrue);
      expect(UpdateChecker.isNewerVersion('0.0.5', '0.0.5'), isFalse);
      expect(UpdateChecker.isNewerVersion('0.0.6', '0.0.5'), isFalse);
      expect(UpdateChecker.isNewerVersion('0.0.5', '0.1.0'), isTrue);
      expect(UpdateChecker.isNewerVersion('0.9.9', '1.0.0'), isTrue);
      expect(UpdateChecker.isNewerVersion('0.0.1', '0.0.1'), isFalse);
    });

    test('0.0.X 递增跨两位数（0.0.9 → 0.0.10）按数值而非字符串判定', () {
      // 版本号来到两位数后，必须按数值比较：'0.0.10' 按字符串会小于 '0.0.9'，
      // 按数值则正确大于。这里锁住该行为，避免老版本 App 收不到更新提示。
      expect(UpdateChecker.parseVersion('0.0.10'), (0, 0, 10));
      expect(UpdateChecker.isNewerVersion('0.0.9', '0.0.10'), isTrue);
      expect(UpdateChecker.isNewerVersion('0.0.10', '0.0.9'), isFalse);
      expect(UpdateChecker.isNewerVersion('0.0.10', '0.0.10'), isFalse);
    });

    test('次版本号跃迁（0.0.9 → 0.1.0）判定为更新', () {
      expect(UpdateChecker.isNewerVersion('0.0.9', '0.1.0'), isTrue);
      expect(UpdateChecker.isNewerVersion('0.1.0', '0.0.9'), isFalse);
    });

    test('0.1.0 发版的真实升级路径：0.0.30 → 0.1.0 必须判定为更新', () {
      // 这条是 0.1.0 发版的防线：线上用户装的是 0.0.30，更新清单写 0.1.0。
      // 若这里判成 false，所有老用户永远收不到更新提示 —— 而且不报错、静默失败。
      expect(UpdateChecker.isNewerVersion('0.0.30', '0.1.0'), isTrue);
      expect(UpdateChecker.isNewerVersion('0.0.30', '0.1.1'), isTrue);
      expect(UpdateChecker.isNewerVersion('0.1.0', '0.1.1'), isTrue);
      expect(UpdateChecker.isNewerVersion('0.1.0', '0.0.30'), isFalse);
      expect(UpdateChecker.isNewerVersion('0.1.1', '0.1.0'), isFalse);
    });
  });
}