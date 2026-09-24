import 'package:flutter_test/flutter_test.dart';
import 'package:yibianhui_blog/src/ui/brs_page.dart';

/// 广播站原生页的解析测试。
///
/// 为什么必须单测：这个入口在首页「项目」组的最下面，真机上要先滚动再点，
/// 而这台设备的输入事件会延迟/落到相邻项，UI 路径难以稳定复现；
/// 但 `campuses` / `playlists` / `songs` / `title` / `artist` / `by` 这些**字段名**
/// 一旦写错，只有在真机上才会表现为"歌单是空的" ⇒ 用这里兜住。
///
/// 样本结构与线上一致（实测 https://brs.yibianhui.cn/data/data.json）：
///   { updated_at, campuses: { main:{label,notice,playlists[]}, north:{...} } }
///   playlists[] = { id, date, period, note, songs[] }
///   songs[]     = { title, artist, by }
void main() {
  const sample = '''
{
  "updated_at": "2026-09-14 23:25",
  "campuses": {
    "main": { "label": "主校区", "notice": "", "playlists": [] },
    "north": {
      "label": "北校区",
      "notice": "广播时间：早上 06:40-07:05",
      "playlists": [
        { "id": "n1", "date": "2026-09-07", "period": "n1", "note": "",
          "songs": [
            { "title": "海东青", "artist": "某歌手", "by": "张三" },
            { "title": "第二首", "artist": "", "by": "" }
          ] }
      ]
    }
  }
}
''';

  test('解析出两个校区，顺序与 JSON 一致', () {
    final c = BrsPage.parseCampuses(sample);
    expect(c.length, 2);
    expect(c[0]['key'], 'main');
    expect(c[0]['label'], '主校区');
    expect(c[1]['label'], '北校区');
  });

  test('★ 期次 period 必须解析出来（同一天的多期靠它区分）', () {
    // 线上 2026-09-07 有 n1–n5 五期、日期完全相同；不显示 period 的话
    // 一屏会出现五张看起来一模一样的卡片（真机截图确认过）。
    final c = BrsPage.parseCampuses(
        '{"campuses":{"n":{"label":"北","notice":"","playlists":['
        '{"date":"2026-09-07","period":"n2","note":"","songs":[]},'
        '{"date":"2026-07-24","period":"成品混音","note":"第8期","songs":[]}'
        ']}}}');
    final lists = c.single['playlists'] as List;
    expect((lists[0] as Map)['period'], 'n2');
    expect((lists[1] as Map)['period'], '成品混音');
  });

  test('公告与期次、曲目字段都正确落到目标键上', () {
    final c = BrsPage.parseCampuses(sample);
    final north = c[1];
    expect(north['notice'], contains('06:40'));
    final lists = north['playlists'] as List;
    expect(lists.length, 1);
    final p = lists.first as Map<String, dynamic>;
    expect(p['date'], '2026-09-07');
    final songs = p['songs'] as List;
    expect(songs.length, 2);
    expect((songs[0] as Map)['title'], '海东青');
    expect((songs[0] as Map)['artist'], '某歌手');
    expect((songs[0] as Map)['by'], '张三');
    // 缺字段不该变成 'null' 字符串
    expect((songs[1] as Map)['artist'], '');
    expect((songs[1] as Map)['by'], '');
  });

  test('label 为空时回退到校区键名（不至于显示空白 Tab）', () {
    final c = BrsPage.parseCampuses(
        '{"campuses":{"main":{"label":"","notice":"","playlists":[]}}}');
    expect(c.single['label'], 'main');
  });

  test('脏数据不抛异常：坏 JSON / 缺 campuses / campuses 不是对象', () {
    expect(BrsPage.parseCampuses('not json'), isEmpty);
    expect(BrsPage.parseCampuses('{}'), isEmpty);
    expect(BrsPage.parseCampuses('{"campuses":[]}'), isEmpty);
    expect(BrsPage.parseCampuses('{"campuses":{"x":"不是对象"}}'), isEmpty);
  });

  test('期次里混入非对象元素时跳过，不影响其余', () {
    final c = BrsPage.parseCampuses(
        '{"campuses":{"n":{"label":"N","notice":"","playlists":[1,{"date":"d","note":"","songs":[]}]}}}');
    expect((c.single['playlists'] as List).length, 1);
    expect(((c.single['playlists'] as List).first as Map)['date'], 'd');
  });
}
