import 'package:flutter_test/flutter_test.dart';
import 'package:yibianhui_blog/src/data/home_config.dart';

/// 首页配置与站点入口的对齐守卫（2026-09-22）。
///
/// 背景：站点顶部菜单存在 WordPress 数据库里，**仓库里没有定义** —— 改站内菜单
/// 不会自动流到 App。App 侧的那份投影就放在 [HomeConfig.fallback] 的 `nav` 里，
/// 所以它漂了没人会发现。这里把「线上现状」的关键几条钉住：
///   · 站点 1.3.10 把「更新日志」从页脚挪进顶部菜单；
///   · T37 新增「小游戏」（game.yibianhui.cn）；
///   · 新增「试写作业插件」（tools.yibianhui.cn）；
///   · 分组名改为「YBH」与「项目」。
void main() {
  const config = HomeConfig.fallback;

  test('导航分组名与站点一致（YBH / 项目）', () {
    expect(config.nav.map((g) => g.title).toList(), ['YBH', '项目']);
  });

  test('「更新日志」在导航里，不在页脚（站点 1.3.10 的改动）', () {
    final all = [
      for (final g in config.nav)
        for (final l in g.links) l.url,
    ];
    expect(all, contains('app://page/changelog'));
    expect(config.footer.map((l) => l.title), isNot(contains('更新日志')),
        reason: '站点 1.3.10 起页脚已删掉「更新日志」入口，App 不该再留着');
  });

  test('★ YBH 组一律走原生路由（不经内嵌 WebView）', () {
    // 为什么钉这条：主站**子页面**在旧 Android WebView 上 DOM 完整但不绘制
    // （探针能读到 77k 字符正文，屏幕却纯白），注入脚本救不了 ⇒ 这一组必须原生。
    // 谁要把它改回 https://…，这个测试会立刻红。
    final ybh = {
      for (final l in config.nav.firstWhere((g) => g.title == 'YBH').links)
        l.title: l.url,
    };
    expect(ybh['全部文章'], 'app://posts');
    expect(ybh['标签'], 'app://tags');
    expect(ybh['更新日志'], 'app://page/changelog');
    expect(ybh['关于我们'], 'app://page/about');
    expect(ybh['友情链接'], 'app://page/links');
    for (final entry in ybh.entries) {
      expect(entry.value, startsWith('app://'),
          reason: '${entry.key} 应走原生路由，实际 ${entry.value}');
    }
  });

  test('「我要投稿」已从导航移除（底部栏已有「写文章」）', () {
    final titles = [
      for (final g in config.nav)
        for (final l in g.links) l.title,
    ];
    expect(titles, isNot(contains('我要投稿')));
  });

  test('★「项目」组重排：广播站原生、其余折进二级菜单、删掉客户端下载', () {
    final urls = {
      for (final l in config.nav.firstWhere((g) => g.title == '项目').links)
        l.title: l.url,
    };
    // 只剩三项：摇人器（原生）、广播站（原生）、更多站点（二级菜单）
    expect(urls.keys.toList(), ['幸运摇人器', '广播站', '更多站点']);
    expect(urls['广播站'], 'app://brs');
    expect(urls['更多站点'], 'app://sites');
    // 摇人器仍以域名命中原生页（见 home_tab._openUrl），不走 WebView
    expect(urls['幸运摇人器'], 'https://lr.yibianhui.cn');

    // 这三项不再直接占主菜单：它们在应用内 WebView 里整页白屏，只能交给浏览器，
    // 现在统一折进「更多站点」二级菜单（清单见 home_tab._moreSites）。
    expect(urls.containsKey('小游戏'), isFalse);
    expect(urls.containsKey('试写作业插件'), isFalse);
    expect(urls.containsKey('教师节'), isFalse);
    // 用户明确要求删掉
    expect(urls.containsKey('客户端下载'), isFalse);
  });

  test('图标名都能解析（否则会静默退成通用链接图标）', () {
    // _iconFor 的映射在 home_tab.dart；这里只保证配置里用的是**已支持**的名字。
    const supported = {
      'coffee', 'group', 'gift', 'heart', 'article', 'edit', 'info', 'link',
      'casino', 'school', 'campaign', 'download', 'person_add', 'search',
      'shuffle', 'image', 'public', 'github', 'music', 'mail', 'wechat',
      'explore', 'hub', 'history', 'shield', 'cookie', 'gavel', 'bolt',
      'widgets', 'star', 'tag', 'game', 'assignment',
    };
    for (final g in config.nav) {
      expect(supported, contains(g.icon), reason: '分组 ${g.title} 的图标未映射');
      for (final l in g.links) {
        expect(supported, contains(l.icon), reason: '${l.title} 的图标未映射');
      }
    }
    for (final l in config.footer) {
      expect(supported, contains(l.icon), reason: '${l.title} 的图标未映射');
    }
  });

  test('页脚保留三条法务入口', () {
    expect(config.footer.map((l) => l.title).toList(),
        ['隐私政策', 'Cookie 政策', '用户协议']);
  });

  test('远端配置缺段时逐段退回 fallback', () {
    // 站点上真实的 config.json 现在只有 links/announcement/featured。
    const remote = HomeConfig(
      links: <HomeLink>[],
      announcement: '公告',
      featured: <String>[],
    );
    final merged = remote.mergedWithFallback();
    expect(merged.announcement, '公告');
    expect(merged.nav, isNotEmpty, reason: '远端没写 nav 时要用内置的');
    expect(merged.footer, isNotEmpty);
  });
}
