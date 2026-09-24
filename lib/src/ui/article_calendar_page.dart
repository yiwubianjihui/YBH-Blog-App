import 'package:flutter/material.dart';

import '../data/blog_api.dart';
import 'post_detail_page.dart';
import 'posts_tab.dart';

/// 「全部文章」页 —— 列表 + **日历**两种看法。
///
/// 为什么要日历：本页原先是把「文章」Tab 那套列表原样搬过来，两个入口内容完全一样，
/// 用户没有理由从这里进。日历给的是**另一种找文章的方式**（按"哪天发的"回忆），
/// 与列表（按分类/时间倒序刷）互补。
///
/// 实现要点：
/// * 一天一个格子，**有文章的日期标出数量**，点一下就看那天的文章；
/// * 数据按**整月一次**取回（`after`/`before` 日期区间），不是逐天请求 —— 89 篇文章
///   一个月通常一两篇，逐天要 30 次往返，整月只要 1 次；
/// * 列表视图直接复用 [PostsTab]（分类筛选、下拉刷新、触底加载都在里面）。
class ArticleCalendarPage extends StatefulWidget {
  const ArticleCalendarPage({super.key});

  @override
  State<ArticleCalendarPage> createState() => _ArticleCalendarPageState();
}

class _ArticleCalendarPageState extends State<ArticleCalendarPage> {
  /// 当前视图：false = 列表，true = 日历。
  /// 默认给**列表**（熟面孔），日历一键可切 —— 不强迫所有人换习惯。
  bool _calendarMode = false;

  /// 日历当前所在月份（取该月 1 日）。
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  /// 当月文章按「日」归档。
  Map<int, List<PostSummary>> _byDay = const {};
  bool _loading = false;
  Object? _error;

  /// 选中的某一天（null = 未选，右侧不显示列表）。
  DateTime? _selectedDay;

  static String _two(int v) => v.toString().padLeft(2, '0');

  @override
  void initState() {
    super.initState();
    _loadMonth();
  }

  /// 取回当前月份的文章（含下月 1 日 0 点前的边界，避免月底漏掉当天）。
  Future<void> _loadMonth() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final from = DateTime(_month.year, _month.month, 1);
    // 下月 1 日 00:00:00 作为 before（WordPress 的 before 是开区间）
    final to = DateTime(_month.year, _month.month + 1, 1);
    try {
      final page = await BlogApi.fetchPosts(
        perPage: 100,
        after: '${from.year}-${_two(from.month)}-${_two(from.day)}T00:00:00',
        before: '${to.year}-${_two(to.month)}-${_two(to.day)}T00:00:00',
      );
      final map = <int, List<PostSummary>>{};
      for (final p in page.posts) {
        final d = p.date;
        if (d == null) continue;
        // 只收当月（REST 的时区与本地可能有几小时差，越界的丢掉）
        if (d.year != _month.year || d.month != _month.month) continue;
        map.putIfAbsent(d.day, () => <PostSummary>[]).add(p);
      }
      if (!mounted) return;
      setState(() {
        _byDay = map;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selectedDay = null;
    });
    _loadMonth();
  }

  bool get _canGoNext {
    final now = DateTime.now();
    return _month.year < now.year ||
        (_month.year == now.year && _month.month < now.month);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('全部文章'),
        actions: [
          IconButton(
            tooltip: _calendarMode ? '切换为列表' : '切换为日历',
            onPressed: () => setState(() => _calendarMode = !_calendarMode),
            icon: Icon(_calendarMode ? Icons.view_list_outlined : Icons.calendar_month_outlined),
          ),
        ],
      ),
      body: _calendarMode ? _buildCalendar(context) : const PostsTab(),
    );
  }

  // ------------------------------------------------------------------ 日历

  Widget _buildCalendar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _monthBar(context),
        const Divider(height: 1),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Column(
              children: [
                Text('这个月的文章没取到',
                    style: TextStyle(color: colorScheme.error, fontSize: 13.5)),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _loadMonth,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重试'),
                ),
              ],
            ),
          )
        else ...[
          _weekHeader(context),
          _monthGrid(context),
        ],
        const Divider(height: 1),
        Expanded(child: _dayList(context)),
      ],
    );
  }

  Widget _monthBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final total = _byDay.values.fold<int>(0, (a, l) => a + l.length);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '上个月',
            onPressed: () => _shiftMonth(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          Text('${_month.year} 年 ${_month.month} 月',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          if (!_loading && _error == null)
            Text(total == 0 ? '本月无更新' : '本月 $total 篇',
                style: TextStyle(fontSize: 12.5, color: colorScheme.outline)),
          const Spacer(),
          IconButton(
            tooltip: '下个月',
            onPressed: _canGoNext ? () => _shiftMonth(1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _weekHeader(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Row(
        children: [
          for (final n in names)
            Expanded(
              child: Center(
                child: Text(n,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.outline)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _monthGrid(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 周一为一周之首：DateTime.weekday 里周一 = 1
    final first = DateTime(_month.year, _month.month, 1);
    final leading = first.weekday - 1;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final cells = leading + daysInMonth;
    final rows = (cells / 7).ceil();
    final today = DateTime.now();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        children: [
          for (var r = 0; r < rows; r++)
            Row(
              children: [
                for (var c = 0; c < 7; c++)
                  Expanded(
                    child: Builder(builder: (context) {
                      final dayNo = r * 7 + c - leading + 1;
                      if (dayNo < 1 || dayNo > daysInMonth) {
                        return const SizedBox(height: 46);
                      }
                      final posts = _byDay[dayNo] ?? const <PostSummary>[];
                      final isToday = today.year == _month.year &&
                          today.month == _month.month &&
                          today.day == dayNo;
                      final selected = _selectedDay?.day == dayNo &&
                          _selectedDay?.month == _month.month &&
                          _selectedDay?.year == _month.year;
                      return Padding(
                        padding: const EdgeInsets.all(2),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: posts.isEmpty
                              ? null
                              : () => setState(() => _selectedDay =
                                  DateTime(_month.year, _month.month, dayNo)),
                          child: Container(
                            height: 44,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: selected
                                  ? colorScheme.primaryContainer
                                  : (posts.isEmpty ? null : colorScheme.surface),
                              border: Border.all(
                                color: isToday
                                    ? colorScheme.primary
                                    : (posts.isEmpty
                                        ? Colors.transparent
                                        : colorScheme.outlineVariant),
                                width: isToday ? 1.6 : 1,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  '$dayNo',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: posts.isEmpty
                                        ? FontWeight.w400
                                        : FontWeight.w700,
                                    color: posts.isEmpty
                                        ? colorScheme.outline
                                        : colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                // 有文章的日子给一个圆点 + 数量（1 篇只给点）
                                SizedBox(
                                  height: 14,
                                  child: posts.isEmpty
                                      ? null
                                      : Text(
                                          posts.length > 1 ? '${posts.length} 篇' : '·',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            height: 1.1,
                                            color: colorScheme.primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _dayList(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final day = _selectedDay;
    if (day == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.touch_app_outlined, size: 40, color: colorScheme.outline),
              const SizedBox(height: 12),
              Text('点一个有文章的日期，看那天的文章',
                  style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }
    final posts = _byDay[day.day] ?? const <PostSummary>[];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: posts.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('${day.year}-${_two(day.month)}-${_two(day.day)} · ${posts.length} 篇',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          );
        }
        final p = posts[i - 1];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(p.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
          subtitle: p.terms.isEmpty
              ? null
              : Text(p.terms.take(2).join(' · '),
                  style: TextStyle(fontSize: 12, color: colorScheme.primary)),
          trailing: const Icon(Icons.chevron_right_outlined, size: 20),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PostDetailPage(posts: posts, initialIndex: i - 1),
            ),
          ),
        );
      },
    );
  }
}
