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

  // ⚠️ 这里曾经有 `luckyRosterUrl`（app.yibianhui.cn/lucky/roster.json）与
  // 「名单管理 → 从服务器获取」入口。**服务端从来没有部署过这份名单** ——
  // 那是立项时的设想，实现却只做了一半：App 侧有按钮，服务器侧没文件，
  // 用户点了永远只会得到"取不到"。2026-09-22 已连同 `LuckyRosterFetcher`
  // 一并删除；名单的真实来源只有两条：粘贴导入、手动添加（都只存本机）。

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
  ///
  /// [card] 为 true 时请求**卡片小图变体**（`size=card`，站点为每张图备了
  /// `-card` 后缀的 1200px/q82 版本）。卡片只有 112×112，取 1920 大图纯属浪费流量 ——
  /// 站点自己的卡片区也是走小图（主题提交 2e4cf822）。
  static String coverUrl(int seed, {bool card = true}) =>
      '$_coverBase?img=w${card ? '&size=card' : ''}&$seed';

  /// 兜底封面端点（主题内建 REST）。万一 `rand-cover.php` 不可用
  /// （例如主题被换掉、文件被删），卡片会退到这里，而不是直接显示占位图。
  ///
  /// ⚠️ 该端点**不认** `size=card`（它只读 `img`），所以兜底路径拿到的是大图 ——
  /// 这是刻意的：兜底只在轻量端点整个不可用时才发生，此时优先保证「有图」。
  static String coverUrlFallback(int seed) =>
      'https://www.yibianhui.cn/wp-json/sakura/v1/gallery?img=w&$seed';

  static const String _coverBase =
      'https://www.yibianhui.cn/wp-content/themes/SakurairoYBH/rand-cover.php';

  /// 批量取封面的地址：服务端**一次抽 N 张互不重复**的图，返回 JSON
  /// `{"urls":[...]}`（见主题 `rand-cover.php` 的 `n` 分支）。
  ///
  /// 为什么用它：一页 20 张卡片按老写法是 20 次 302 往返，还各自带着
  /// 一次完整请求开销；批量端点一次就够。它与单张模式走的是同一份
  /// `imglist.json` 索引，**都不加载 WordPress**。
  ///
  /// 服务器侧约束（逐条对齐源码）：`n > 1` 才进批量分支；`n` 被夹到 **最多 60**；
  /// 响应是 `Cache-Control: no-store`（每次都是新的一批，不要指望 HTTP 缓存）。
  static String batchCoverUrl(int n, {bool card = true, bool wide = true}) =>
      '$_coverBase?img=${wide ? 'w' : 'l'}${card ? '&size=card' : ''}&n=$n';

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
