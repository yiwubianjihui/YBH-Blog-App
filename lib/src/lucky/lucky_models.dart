// 幸运摇人器的数据模型。
//
// 这一层不依赖 Flutter，方便单元测试。

/// 一名学生。
class LuckyStudent {
  const LuckyStudent({
    required this.name,
    required this.classId,
    required this.gender,
  });

  /// 姓名。
  final String name;

  /// 班级号（字符串，兼容 "1" / "01" / "十九" 等写法）。
  final String classId;

  /// 性别："男" / "女"。
  final String gender;

  Map<String, dynamic> toJson() => {
        'name': name,
        'classId': classId,
        'gender': gender,
      };

  factory LuckyStudent.fromJson(Map<String, dynamic> json) => LuckyStudent(
        name: (json['name'] as String? ?? '').trim(),
        classId: _normalizeClass(json['classId']?.toString() ?? ''),
        gender: normalizeGender(json['gender']?.toString() ?? ''),
      );

  LuckyStudent copyWith({String? name, String? classId, String? gender}) =>
      LuckyStudent(
        name: name ?? this.name,
        classId: classId ?? this.classId,
        gender: gender ?? this.gender,
      );

  @override
  bool operator ==(Object other) =>
      other is LuckyStudent &&
      other.name == name &&
      other.classId == classId &&
      other.gender == gender;

  @override
  int get hashCode => Object.hash(name, classId, gender);

  @override
  String toString() => '$name（$classId·$gender）';
}

/// 班级号归一化：去掉前导零、全角转半角，便于 "01" 与 "1" 视为同一个班。
String _normalizeClass(String raw) {
  var s = raw.trim();
  // 全角数字 → 半角
  const full = '０１２３４５６７８９';
  final buf = StringBuffer();
  for (final ch in s.split('')) {
    final i = full.indexOf(ch);
    buf.write(i >= 0 ? String.fromCharCode(48 + i) : ch);
  }
  s = buf.toString().trim();
  // 纯数字去掉前导零
  if (RegExp(r'^\d+$').hasMatch(s)) {
    s = int.parse(s).toString();
  }
  return s;
}

/// 性别归一化：只接受男 / 女，其余归为男（与原实现保持一致）。
String normalizeGender(String raw) {
  final s = raw.trim();
  if (s.contains('女') || s.toLowerCase() == 'f' || s.toLowerCase() == 'female') {
    return '女';
  }
  return '男';
}

/// 一份完整名单：班级名表 + 学生表。
class LuckyRoster {
  const LuckyRoster({
    this.classes = const <String, String>{},
    this.students = const <LuckyStudent>[],
    this.source = LuckyRosterSource.builtIn,
    this.updatedAt,
  });

  /// 班级号 → 班级显示名（如 "19" → "志成十九"）。
  final Map<String, String> classes;

  final List<LuckyStudent> students;

  /// 名单来源。
  final LuckyRosterSource source;

  /// 最后更新时间。
  final DateTime? updatedAt;

  bool get isEmpty => students.isEmpty;

  int get count => students.length;

  /// 名单里出现过的班级号（按班级号数值升序，非数字排最后）。
  List<String> get classIds {
    final ids = students.map((s) => s.classId).toSet().toList()
      ..sort(_compareClassId);
    return ids;
  }

  static int _compareClassId(String a, String b) {
    final na = int.tryParse(a);
    final nb = int.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.compareTo(b);
  }

  /// 班级显示名：优先用班级名表，没有则回退成 "N班"。
  String classNameOf(String classId) =>
      classes[classId] ?? (RegExp(r'^\d+$').hasMatch(classId) ? '$classId班' : classId);

  LuckyRoster copyWith({
    Map<String, String>? classes,
    List<LuckyStudent>? students,
    LuckyRosterSource? source,
    DateTime? updatedAt,
  }) =>
      LuckyRoster(
        classes: classes ?? this.classes,
        students: students ?? this.students,
        source: source ?? this.source,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'classes': classes,
        'students': students.map((s) => s.toJson()).toList(),
      };

  factory LuckyRoster.fromJson(
    Map<String, dynamic> json, {
    LuckyRosterSource source = LuckyRosterSource.imported,
    DateTime? updatedAt,
  }) {
    final rawClasses = json['classes'];
    final classes = <String, String>{};
    if (rawClasses is Map) {
      rawClasses.forEach((k, v) {
        classes[_normalizeClass(k.toString())] = v.toString();
      });
    }
    final rawStudents = json['students'];
    final students = rawStudents is List
        ? rawStudents
            .whereType<Map<String, dynamic>>()
            .map(LuckyStudent.fromJson)
            .where((s) => s.name.isNotEmpty)
            .toList()
        : <LuckyStudent>[];
    return LuckyRoster(
      classes: classes,
      students: students,
      source: source,
      updatedAt: updatedAt,
    );
  }
}

/// 名单来源。
enum LuckyRosterSource {
  /// 内置示例名单（张三 / 李四 ……），仅供演示，不含任何真实姓名。
  builtIn,

  /// 用户导入（CSV / 手动录入）。
  imported,

  /// 从服务器下载。
  remote,
}

/// 性别筛选。
enum LuckyGenderFilter { all, male, female }

/// 一条抽选记录。
class LuckyPickRecord {
  const LuckyPickRecord({
    required this.id,
    required this.at,
    required this.classId,
    required this.mode,
    required this.names,
  });

  final String id;
  final DateTime at;
  final String classId;

  /// 'single' 抽一人 / 'multi' 连抽多人。
  final String mode;

  final List<String> names;

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toIso8601String(),
        'classId': classId,
        'mode': mode,
        'names': names,
      };

  factory LuckyPickRecord.fromJson(Map<String, dynamic> json) => LuckyPickRecord(
        id: json['id'] as String? ?? '',
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
        classId: json['classId'] as String? ?? '',
        mode: json['mode'] as String? ?? 'single',
        names: (json['names'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}
