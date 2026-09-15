/// 全局配置：义编会（YBH）WordPress 博客客户端。
abstract final class AppConfig {
  /// 站点名称（与 WordPress 站点一致）。
  static const String siteName = 'YBH';

  /// 应用显示名称。
  static const String appName = 'YBH';

  /// 内嵌的 WordPress 博客地址。
  static const String blogUrl = 'https://www.yibianhui.cn';

  /// WordPress REST API 根地址。
  static const String apiBase = 'https://www.yibianhui.cn/wp-json/wp/v2';

  /// JWT 登录令牌地址（JWT Authentication for WP REST API 插件）。
  /// 站点已安装并配置好该插件；登录用「用户名 + 账号密码」换取 Bearer 令牌。
  static const String jwtTokenUrl =
      'https://www.yibianhui.cn/wp-json/jwt-auth/v1/token';

  /// 检查更新所用的版本清单地址（JSON，见 YBH-blog-release/update/version.json 模板）。
  /// 请求失败时静默忽略（自动检查）或提示稍后重试（手动检查）。
  static const String updateManifestUrl =
      'https://app.yibianhui.cn/update/version.json';

  /// 允许在应用内打开的域名（主域与其全部子域名）。
  static const String allowDomain = 'yibianhui.cn';

  /// 应用主题色（取自站点 theme-color: #505050）。
  static const int themeColorValue = 0xFF505050;

  /// 幸运摇人器的真实名单地址。
  ///
  /// 真实名单**不进版本库**（公开仓库会泄露学生姓名），托管在下载站上，
  /// App 里「名单管理 → 从服务器获取」拉取；更新这个文件即可同步。
  /// 未部署时返回 404，App 会提示改用粘贴导入。
  static const String luckyRosterUrl =
      'https://app.yibianhui.cn/lucky/roster.json';

  /// 首页配置：固定链接、展台公告与精选。未部署时 App 用内置兜底。
  static const String homeConfigUrl =
      'https://app.yibianhui.cn/home/config.json';

  /// 是否允许在应用内直接导航到该地址。
  static bool isInAppUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (!uri.hasAuthority && !uri.hasScheme) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    return host == allowDomain || host.endsWith('.$allowDomain');
  }

  /// 封面图地址 —— 走**主题自带的轻量端点** `rand-cover.php`。
  ///
  /// ⚠️ 别改回 `/wp-json/sakura/v1/gallery`：那是主题内建 REST，每次请求都要
  /// **完整启动 WordPress**（内核 + 全部插件 + 主题）再 302；一页 10 张封面就是
  /// 10 次重量级 PHP 启动 —— 在这台内存吃紧的机器上是实打实的负担。
  ///
  /// `rand-cover.php` **不加载 WordPress**，只读 `imglist.json` 后 302，
  /// 耗时从数百毫秒降到几毫秒，还自带 `Cache-Control: max-age=60`。
  /// （网站侧早就这么做了，见主题 `inc/ybh/bootstrap.php` §9。）
  ///
  /// `seed` 参数端点并不使用（两个端点都是纯随机），它的作用是**给客户端当缓存键** ——
  /// `CachedNetworkImage` 按 URL 做磁盘缓存，带稳定 seed 才能让同一篇文章的封面
  /// 在 App 内保持一致。
  static String coverUrl(int seed) => '$_coverBase?img=w&$seed';

  /// 兜底封面端点（主题内建 REST）。万一 `rand-cover.php` 不可用
  /// （例如主题被换掉、文件被删），卡片会退到这里，而不是直接显示占位图。
  static String coverUrlFallback(int seed) =>
      'https://www.yibianhui.cn/wp-json/sakura/v1/gallery?img=w&$seed';

  static const String _coverBase =
      'https://www.yibianhui.cn/wp-content/themes/SakurairoYBH/rand-cover.php';

  /// 每次调用都换一张的随机封面（首页首屏用它当背景，点「换封面」也用它）。
  ///
  /// 用微秒时间戳当 seed：端点虽然忽略它，但**能保证每次 URL 都不同** ——
  /// 否则 `CachedNetworkImage` 会把第一次的结果一直缓存下去，「换封面」就永远不换。
  static String randomCoverUrl({bool wide = true}) =>
      '$_coverBase?img=${wide ? 'w' : 'l'}'
      '&${DateTime.now().microsecondsSinceEpoch % 1000000007}';

  /// `randomCoverUrl` 的兜底版本。
  static String randomCoverUrlFallback({bool wide = true}) =>
      'https://www.yibianhui.cn/wp-json/sakura/v1/gallery'
      '?img=${wide ? 'w' : 'l'}'
      '&${DateTime.now().microsecondsSinceEpoch % 1000000007}';

  /// 站点的「随机文章」入口（主题提供，302 跳到一篇随机文章）。
  /// 首页工具行与「随机文章」入口都用它。
  static const String randomPostUrl = 'https://www.yibianhui.cn/?random_post=1';
}
