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

  /// 主题没有给文章设置特色图，Sakurairo 提供了随机图库接口：
  /// 302 跳转到 wp-content/uploads/iro_gallery 下的图片，用作文章卡片封面。
  static String coverUrl(int seed) =>
      'https://www.yibianhui.cn/wp-json/sakura/v1/gallery?img=w&$seed';
}
