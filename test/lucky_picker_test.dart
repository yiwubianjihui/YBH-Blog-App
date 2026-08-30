import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:yibianhui_blog/src/lucky/lucky_models.dart';
import 'package:yibianhui_blog/src/lucky/lucky_picker.dart';

void main() {
  final roster = LuckyRoster(
    classes: const {'1': '一班', '2': '二班'},
    students: const [
      LuckyStudent(name: '张三', classId: '1', gender: '男'),
      LuckyStudent(name: '李四', classId: '1', gender: '女'),
      LuckyStudent(name: '王五', classId: '1', gender: '男'),
      LuckyStudent(name: '赵六', classId: '2', gender: '女'),
      LuckyStudent(name: '孙七', classId: '2', gender: '男'),
    ],
  );

  group('LuckyPicker.candidates', () {
    test('按班级筛选', () {
      final c = LuckyPicker.candidates(roster: roster, classId: '1');
      expect(c.map((s) => s.name).toList(), ['张三', '李四', '王五']);
    });

    test('按性别筛选', () {
      final c = LuckyPicker.candidates(
          roster: roster, gender: LuckyGenderFilter.female);
      expect(c.map((s) => s.name).toList(), ['李四', '赵六']);
    });

    test('屏蔽名单生效', () {
      final c = LuckyPicker.candidates(
          roster: roster, blocked: {'张三', '赵六'});
      expect(c.map((s) => s.name).toList(), ['李四', '王五', '孙七']);
    });

    test('不传班级表示全部', () {
      expect(LuckyPicker.candidates(roster: roster).length, 5);
    });
  });

  group('LuckyPicker.pick', () {
    test('抽指定数量', () {
      final picked = LuckyPicker.pick(
        candidates: LuckyPicker.candidates(roster: roster),
        used: <String>{},
        noRepeat: false,
        count: 3,
        random: Random(1),
      );
      expect(picked.length, 3);
    });

    test('不重复模式下不会重复抽到同一个人', () {
      final candidates = LuckyPicker.candidates(roster: roster);
      final picked = LuckyPicker.pick(
        candidates: candidates,
        used: <String>{},
        noRepeat: true,
        count: 5,
        random: Random(7),
      );
      expect(picked.length, 5);
      expect(picked.map((s) => s.name).toSet().length, 5);
    });

    test('不重复模式跳过已抽过的人', () {
      final candidates = LuckyPicker.candidates(roster: roster);
      final used = <String>{'张三', '李四', '王五'};
      final picked = LuckyPicker.pick(
        candidates: candidates,
        used: used,
        noRepeat: true,
        count: 2,
        random: Random(3),
      );
      expect(picked.length, 2);
      for (final s in picked) {
        expect(used.contains(s.name), isFalse);
      }
    });

    test('不重复模式人数不足时自动重置池补齐', () {
      final candidates = LuckyPicker.candidates(roster: roster);
      // 5 人里已抽掉 4 人，但要连抽 3 人 —— 应补满 3 个而非只给 1 个。
      final used = <String>{'张三', '李四', '王五', '赵六'};
      final picked = LuckyPicker.pick(
        candidates: candidates,
        used: used,
        noRepeat: true,
        count: 3,
        random: Random(5),
      );
      expect(picked.length, 3);
    });

    test('候选池为空时返回空列表', () {
      final picked = LuckyPicker.pick(
        candidates: const <LuckyStudent>[],
        used: <String>{},
        noRepeat: true,
        count: 1,
      );
      expect(picked, isEmpty);
    });

    test('markUsed 在不重复模式关闭时不记录', () {
      final used = LuckyPicker.markUsed(
        used: <String>{'张三'},
        picked: const [LuckyStudent(name: '李四', classId: '1', gender: '男')],
        noRepeat: false,
      );
      expect(used, isEmpty);
    });
  });

  group('LuckyPicker.stats', () {
    test('关闭不重复时剩余等于总数', () {
      final stats = LuckyPicker.stats(
        candidates: LuckyPicker.candidates(roster: roster),
        used: <String>{'张三'},
        noRepeat: false,
      );
      expect(stats.total, 5);
      expect(stats.remaining, 5);
    });

    test('开启不重复时剩余递减', () {
      final stats = LuckyPicker.stats(
        candidates: LuckyPicker.candidates(roster: roster, classId: '1'),
        used: <String>{'张三'},
        noRepeat: true,
      );
      expect(stats.total, 3);
      expect(stats.remaining, 2);
    });
  });

  group('LuckyPicker.parseRosterText', () {
    test('解析带表头的 CSV', () {
      final result = LuckyPicker.parseRosterText(
        '姓名,班级,性别\n张三,1,男\n李四,2,女\n',
      );
      expect(result.students.length, 2);
      expect(result.students.first.name, '张三');
      expect(result.students.first.classId, '1');
      expect(result.students.last.gender, '女');
    });

    test('解析无表头的三列文本', () {
      final result = LuckyPicker.parseRosterText('张三,3,男\n李四,3,女');
      expect(result.students.length, 2);
      expect(result.students.first.classId, '3');
    });

    test('解析制表符分隔', () {
      final result = LuckyPicker.parseRosterText('张三\t5\t男');
      expect(result.students.length, 1);
      expect(result.students.first.classId, '5');
    });

    test('跳过空行并统计无效行', () {
      final result = LuckyPicker.parseRosterText('姓名,班级\n张三,1\n\n,2\n');
      expect(result.students.length, 1);
      expect(result.skipped, 1);
    });

    test('空文本返回空名单', () {
      final result = LuckyPicker.parseRosterText('');
      expect(result.students, isEmpty);
    });
  });

  group('模型归一化', () {
    test('班级号去前导零', () {
      final s = LuckyStudent.fromJson(
          {'name': '张三', 'classId': '007', 'gender': '男'});
      expect(s.classId, '7');
    });

    test('性别归一化', () {
      expect(normalizeGender('女'), '女');
      expect(normalizeGender('F'), '女');
      expect(normalizeGender('男'), '男');
      expect(normalizeGender(''), '男');
    });

    test('班级号按数值排序', () {
      final r = LuckyRoster(students: const [
        LuckyStudent(name: 'a', classId: '10', gender: '男'),
        LuckyStudent(name: 'b', classId: '2', gender: '男'),
        LuckyStudent(name: 'c', classId: '1', gender: '男'),
      ]);
      expect(r.classIds, ['1', '2', '10']);
    });
  });
}
