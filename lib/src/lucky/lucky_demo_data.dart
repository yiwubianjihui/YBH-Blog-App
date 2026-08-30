import 'lucky_models.dart';

/// 内置示例名单。
///
/// **刻意只使用虚构姓名**（张三 / 李四 / 王五 ……），不含任何真实学生信息：
/// 本仓库是公开开源的，真实姓名一旦进库就无法撤回。
///
/// 真实名单请通过「名单管理 → 从服务器获取」下载，或在 App 内导入 CSV，
/// 数据只保存在本机，不会进入版本库。
const LuckyRoster luckyDemoRoster = LuckyRoster(
  classes: <String, String>{
    '1': '示例一班',
    '2': '示例二班',
    '3': '示例三班',
  },
  students: <LuckyStudent>[
    // 示例一班
    LuckyStudent(name: '张三', classId: '1', gender: '男'),
    LuckyStudent(name: '李四', classId: '1', gender: '男'),
    LuckyStudent(name: '王五', classId: '1', gender: '男'),
    LuckyStudent(name: '赵六', classId: '1', gender: '女'),
    LuckyStudent(name: '孙七', classId: '1', gender: '女'),
    LuckyStudent(name: '周八', classId: '1', gender: '男'),
    LuckyStudent(name: '吴九', classId: '1', gender: '女'),
    LuckyStudent(name: '郑十', classId: '1', gender: '男'),
    LuckyStudent(name: '冯十一', classId: '1', gender: '女'),
    LuckyStudent(name: '陈十二', classId: '1', gender: '男'),
    // 示例二班
    LuckyStudent(name: '褚一', classId: '2', gender: '女'),
    LuckyStudent(name: '卫二', classId: '2', gender: '男'),
    LuckyStudent(name: '蒋三', classId: '2', gender: '男'),
    LuckyStudent(name: '沈四', classId: '2', gender: '女'),
    LuckyStudent(name: '韩五', classId: '2', gender: '男'),
    LuckyStudent(name: '杨六', classId: '2', gender: '女'),
    LuckyStudent(name: '朱七', classId: '2', gender: '男'),
    LuckyStudent(name: '秦八', classId: '2', gender: '女'),
    LuckyStudent(name: '尤九', classId: '2', gender: '男'),
    LuckyStudent(name: '许十', classId: '2', gender: '女'),
    // 示例三班
    LuckyStudent(name: '何一', classId: '3', gender: '男'),
    LuckyStudent(name: '吕二', classId: '3', gender: '女'),
    LuckyStudent(name: '施三', classId: '3', gender: '男'),
    LuckyStudent(name: '张四', classId: '3', gender: '女'),
    LuckyStudent(name: '孔五', classId: '3', gender: '男'),
    LuckyStudent(name: '曹六', classId: '3', gender: '女'),
    LuckyStudent(name: '严七', classId: '3', gender: '男'),
    LuckyStudent(name: '华八', classId: '3', gender: '女'),
    LuckyStudent(name: '金九', classId: '3', gender: '男'),
    LuckyStudent(name: '魏十', classId: '3', gender: '女'),
  ],
  source: LuckyRosterSource.builtIn,
);
