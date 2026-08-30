import 'dart:math';

import 'lucky_models.dart';

/// 摇人的纯逻辑：候选池计算与抽取。
///
/// 不持有状态、不依赖 Flutter，便于单元测试。抽取池由调用方（页面）
/// 管理并持久化。
abstract final class LuckyPicker {
  /// 计算当前候选池：按班级、性别筛选，并剔除屏蔽名单。
  static List<LuckyStudent> candidates({
    required LuckyRoster roster,
    String? classId,
    LuckyGenderFilter gender = LuckyGenderFilter.all,
    Set<String> blocked = const <String>{},
  }) {
    return roster.students.where((s) {
      if (classId != null && classId.isNotEmpty && s.classId != classId) {
        return false;
      }
      if (gender == LuckyGenderFilter.male && s.gender != '男') return false;
      if (gender == LuckyGenderFilter.female && s.gender != '女') return false;
      if (blocked.contains(s.name)) return false;
      return true;
    }).toList();
  }

  /// 从不重复池里剔除已抽过的，得到真正可抽的名单。
  ///
  /// [used] 记录本轮已抽中的姓名。
  static List<LuckyStudent> available({
    required List<LuckyStudent> candidates,
    required Set<String> used,
    required bool noRepeat,
  }) {
    if (!noRepeat) return candidates;
    return candidates.where((s) => !used.contains(s.name)).toList();
  }

  /// 抽 [count] 个人。
  ///
  /// 不重复模式下，若剩余人数不足 [count]：先抽完剩余的，然后自动重置池
  /// 补齐剩余名额（与桌面版行为一致，避免"抽不满"卡住）。
  /// 候选池为空时返回空列表。
  static List<LuckyStudent> pick({
    required List<LuckyStudent> candidates,
    required Set<String> used,
    required bool noRepeat,
    required int count,
    Random? random,
  }) {
    final rng = random ?? Random();
    if (candidates.isEmpty || count <= 0) return const <LuckyStudent>[];

    final picked = <LuckyStudent>[];
    final taken = <String>{...used};

    while (picked.length < count) {
      final pool = available(candidates: candidates, used: taken, noRepeat: noRepeat);
      if (pool.isEmpty) {
        // 不重复模式下已抽完：重置池后继续，保证能抽满。
        if (noRepeat && taken.isNotEmpty) {
          taken.clear();
          continue;
        }
        break;
      }
      final chosen = pool[rng.nextInt(pool.length)];
      picked.add(chosen);
      if (noRepeat) taken.add(chosen.name);
    }
    return picked;
  }

  /// 抽中后更新「已抽」集合；不重复模式关闭时返回空集合。
  static Set<String> markUsed({
    required Set<String> used,
    required Iterable<LuckyStudent> picked,
    required bool noRepeat,
  }) {
    if (!noRepeat) return const <String>{};
    return {...used, ...picked.map((s) => s.name)};
  }

  /// 统计信息：总候选人数 / 不重复池剩余人数。
  static ({int total, int remaining}) stats({
    required List<LuckyStudent> candidates,
    required Set<String> used,
    required bool noRepeat,
  }) {
    return (
      total: candidates.length,
      remaining: noRepeat
          ? available(candidates: candidates, used: used, noRepeat: true).length
          : candidates.length,
    );
  }

  /// 把一段文本解析成名单（CSV 或「姓名,班级,性别」逐行文本）。
  ///
  /// 自动跳过表头；列顺序不固定时按表头名匹配（姓名/班级/性别）。
  /// 至少识别出姓名列才算成功。
  static ({List<LuckyStudent> students, int skipped}) parseRosterText(String text) {
    final rows = _splitRows(text);
    if (rows.isEmpty) return (students: const <LuckyStudent>[], skipped: 0);

    final mapping = _detectColumns(rows.first);
    final hasHeader = mapping != null;
    final nameIdx = mapping?.name ?? 0;
    final classIdx = mapping?.classId ?? 1;
    final genderIdx = mapping?.gender ?? 2;

    final students = <LuckyStudent>[];
    var skipped = 0;
    final start = hasHeader ? 1 : 0;
    for (var i = start; i < rows.length; i++) {
      final cells = rows[i];
      if (cells.every((c) => c.trim().isEmpty)) continue;
      final name = nameIdx < cells.length ? cells[nameIdx].trim() : '';
      if (name.isEmpty) {
        skipped++;
        continue;
      }
      final classId = classIdx < cells.length ? cells[classIdx].trim() : '';
      final gender = genderIdx < cells.length ? cells[genderIdx].trim() : '男';
      students.add(LuckyStudent(
        name: name,
        classId: classId.isEmpty ? '1' : classId,
        gender: gender,
      ));
    }
    return (students: students, skipped: skipped);
  }

  /// 按行切分，支持逗号 / 制表符 / 分号分隔，并兼容引号包裹。
  static List<List<String>> _splitRows(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rows = <List<String>>[];
    for (final line in normalized.split('\n')) {
      if (line.trim().isEmpty) continue;
      rows.add(_splitLine(line));
    }
    return rows;
  }

  static List<String> _splitLine(String line) {
    // 含制表符或分号时按它分列；否则按 CSV 规则解析（支持引号）。
    if (line.contains('\t')) return line.split('\t');
    if (line.contains(';') && !line.contains(',')) return line.split(';');
    final cells = <String>[];
    final buf = StringBuffer();
    var inQuote = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuote && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuote = !inQuote;
        }
      } else if ((ch == ',') && !inQuote) {
        cells.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    cells.add(buf.toString());
    return cells;
  }

  /// 依据首行内容判断是否为表头，并返回列索引。
  static ({int name, int classId, int gender})? _detectColumns(List<String> header) {
    int? find(List<String> keys) {
      for (var i = 0; i < header.length; i++) {
        final cell = header[i].trim().toLowerCase();
        for (final k in keys) {
          if (cell.contains(k)) return i;
        }
      }
      return null;
    }

    final nameIdx = find(['姓名', '名字', 'name', '学生']);
    // 首行里出现任一表头关键字，才认为它是表头。
    final looksLikeHeader = nameIdx != null ||
        find(['班级', 'class']) != null ||
        find(['性别', 'gender', 'sex']) != null;
    if (!looksLikeHeader) return null;

    return (
      name: nameIdx ?? 0,
      classId: find(['班级', 'class', '班']) ?? 1,
      gender: find(['性别', 'gender', 'sex']) ?? 2,
    );
  }
}
