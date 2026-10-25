# YBH · 义编会 WordPress 博客客户端

[![CI](https://github.com/Yibianhui/YBH-Blog-App/actions/workflows/ci.yml/badge.svg)](https://github.com/Yibianhui/YBH-Blog-App/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-Dart%203.13-blue.svg)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Web-lightgrey.svg)](https://github.com/Yibianhui/YBH-Blog-App)

多平台 Flutter 应用，内嵌 WordPress 博客站点：<https://www.yibianhui.cn>

- **当前重点：Android APK**（已构建、可安装）
- 其他平台：iOS（已生成工程，需 macOS/Xcode 构建）、Web（已构建 PWA）、Windows/macOS/Linux（桌面壳，跳转系统浏览器）

> **版本命名规则**：`MAJOR.MINOR.PATCH+N`（语义化）。
>
> | 位 | 何时 +1 | 说明 |
> |---|---|---|
> | `PATCH` | **每次发版** | 修 bug、小改进都走这里：`0.1.0 → 0.1.1 → 0.1.2 …` |
> | `MINOR` | 攒够一批功能 / 有不兼容改动 | `0.1.x → 0.2.0`；`0.0.x → 0.1.0` 属于这次跃迁 |
> | `MAJOR` | 不兼容大改或转正式版 | 目前仍是 `0.x`，表示接口与交互仍可能调整 |
> | `+N` | **每次发版必须 +1，永不回退** | build number。CI 取 `BN = 2000 + N` 传给 Flutter，arm64 的 versionCode 因此是 **4000 + N**（`0.1.0+31` → `4031`）；回退会让用户**无法覆盖安装**，只能卸载重装 |
>
> 当前 **`0.1.0+31`**（上一版 `0.0.30+30`）。发版时 `pubspec.yaml`、`git tag`（`v0.1.0`）、
> 线上 `update/version.json` 三处的版本号必须一致，否则更新提示对不上。

## 功能

- **三栏外壳**：「文章」（REST 原生列表）+「整站」（WebView 完整体验）+「我的」
- **原生文章列表**：分类筛选、卡片式布局（随机封面/标题/摘要/日期/标签）、下拉刷新、骨架屏、错误重试
  - **分类联网获取**：分类由 WordPress REST API（`/wp-json/wp/v2/categories`）实时拉取，按文章数降序
  - **分类管理**：可拖拽排序、**置顶**（钉住的分类始终最前）、
    **隐藏**（不出现在筛选条，可在管理页恢复）；偏好仅保存在本机，不影响服务器；
    新分类自动追加到末尾、服务器删除的分类自动忽略；
    三个入口：「文章」页右上角按钮、分类筛选条末尾的「管理」、「我的 → 分类管理」；
    实现见 `lib/src/data/category_order.dart`、`lib/src/ui/category_order_page.dart`
- **原生文章详情**：移动端用 WebView 阅读器完整渲染正文（站点 CSS 样式 /
  自定义字体 base64 内嵌 / 图片自适应与懒加载 / Ruby 振假名 / 代码块语言标签与复制），
  支持选中复制，分享 / 浏览器打开；无法使用 WebView 的平台（Web/桌面）退回 flutter_html 排版
- **抽屉菜单**：文章列表 / 整站 / 关于 / 分享 / 浏览器打开 / 复制地址 / 夜间模式开关
- 整站 WebView：加载进度条、页内返回、回首页/刷新/分享/系统浏览器打开
- 站外链接自动转交系统浏览器，站内链接始终留在应用内
- **旧设备性能模式**：整站页面加载后自动关闭站点动画/毛玻璃/固定背景/粒子 canvas 等重特效
- **检查更新**：启动自动检查 + 「我的」页手动检查，发现新版本弹窗提醒并跳转下载
  （更新清单 URL 见 `lib/src/app_config.dart` 的 `updateManifestUrl`，模板与部署说明见 `YBH-blog-release/update/`）
- **「我的」个人中心**：用站点账号「用户名 + 密码」登录（默认 JWT，站点已安装 JWT Authentication 插件，最方便；
  若 JWT 不可用则自动回退到 WordPress 核心「应用密码」Basic Auth，无需插件、需 HTTPS），
  登录后可查看「我的文章」并在应用内写文章发布；实现见 `lib/src/data/wp_auth.dart`、`lib/src/ui/profile_tab.dart`、`lib/src/ui/editor_page.dart`
- **投稿权限自适应**：登录后读取 `GET /users/me?context=edit` 的 `roles` / `capabilities`。
  「作者 / 编辑 / 管理员」可直接发布；**投稿者（contributor）没有 `publish_posts`**，
  写文章页会把「直接发布」换成「提交审核」，文章以 `pending` 状态进入审核队列；
  若能力读取失败导致服务端 403，会自动降级为「待审核」重试一次。
  「我的文章」拉取 `publish,draft,pending,future` 四种状态并显示状态角标
- **登录态跨端同步**：App 登录成功后，「整站」WebView 用内存中的最新凭据自动完成
  wp-login 表单登录（本站服务端只信任真实浏览器指纹的会话，应用内 HTTP 客户端
  拿到的 Cookie 无效，故必须由 WebView 自身登录；凭据仅存内存、不落盘），
  退出登录同步清空整站 Cookie；实现见 `lib/src/data/wp_auth.dart`、`lib/src/webview_impl.dart`
- 文章正文 WebView 阅读器：图片自适应整行宽度、保持比例、原生懒加载；Ruby 振假名原生排版；
  代码块自动标注语言并提供复制按钮；视频/音频/iframe 内嵌播放
- 应用图标与启动屏来自工作区 `ybh-lo.png` 圆角裁剪版，主题色沿用站点 `#505050`

## 平台承载方式

| 平台 | 实现 |
| --- | --- |
| Android | 原生外壳 + REST 文章列表 + `webview_flutter`（整站） |
| iOS | 原生外壳 + REST 文章列表 + `webview_flutter`（WKWebView） |
| Web | 品牌启动页 + 自动跳转博客整站 |
| macOS | 原生外壳 + REST + WKWebView |
| Windows / Linux | 桌面壳，点击跳转系统浏览器打开站点 |

核心结构：

- `lib/src/shell/home_shell.dart` —— 三栏外壳 + 抽屉菜单
- `lib/src/ui/posts_tab.dart` / `post_detail_page.dart` —— 原生文章列表与详情
- `lib/src/data/blog_api.dart` —— WordPress REST 数据层
- `lib/src/webview_impl.dart` —— 整站 WebView 页
- `lib/src/blog_host.dart` —— 平台分发

## 构建产物

- Android APK：`build/app/outputs/flutter-apk/app-release.apk`
- Web：`build/web/`

## 构建 Android APK

```powershell
# 环境（本机工具链）
$env:PUB_CACHE='E:\dsh\.tools\pub-cache'
$env:ANDROID_HOME='E:\dsh\.tools\android-sdk'
$env:ANDROID_SDK_ROOT='E:\dsh\.tools\android-sdk'
flutter build apk --release
```

分 ABI 包（更小）：

```powershell
flutter build apk --split-per-abi
```

构建 Web：

```powershell
flutter build web --release
```

构建 iOS（需要 macOS + Xcode）：

```bash
flutter build ios --release
```

## 发布签名（Android）

- 已生成发布密钥库：`android/app/ybh-release.jks`
- 签名参数：`android/key.properties`（已加入 `.gitignore`，**两者的密码不要写进任何文档或提交**）
- CI 通过仓库 Secrets 还原密钥：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、
  `ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`（见 `.github/workflows/release.yml`）
- 应用 ID：`cn.yibianhui.blog`，应用名：`YBH`，版本 `0.1.0 (31)`

> **安全提示**：分发源码包时务必排除 `android/key.properties` 与 `android/app/*.jks`。
> 这两个文件合起来就是完整签名私钥，一旦泄露，任何人都能以你的证书签名伪造安装包。
> 本仓库曾有几个历史版本的源码压缩包误打包了它们，现已从服务器删除并在归档前清洗。
> 打包脚本可参考 `make_src_zip.py` 中的 `is_secret()` 硬拦截逻辑。

## 常见开发命令

```powershell
flutter analyze
flutter test
dart run flutter_launcher_icons      # 重新生成应用图标
dart run flutter_native_splash:create # 重新生成启动屏
```

## 备注

- 站点地址与域名白名单集中在 `lib/src/app_config.dart`。
- 项目首次构建时 Gradle 已通过腾讯云镜像下载并缓存；若换机器构建网络较慢，可自行修改 `android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` 指向镜像。

## 开源与许可证

本项目以 **MIT 许可证** 开源，详见 [LICENSE](./LICENSE)。

- 仓库地址（GitHub）：<https://github.com/Yibianhui/YBH-Blog-App>
- 欢迎通过 Issue / Pull Request 参与贡献，完整流程见 [CONTRIBUTING.md](./CONTRIBUTING.md)。提交前请运行：

```powershell
flutter analyze
flutter test
```

- 每次 PR 会自动运行 CI（`flutter analyze --fatal-infos` / `flutter test`），两项均需通过。
- 推送 `v*` 标签（如 `git tag v0.1.0 && git push origin v0.1.0`）会自动构建正式签名的 split APK
  并创建 Release。工作流会先校验「标签版本号 == `pubspec.yaml` 的 version」，
  不匹配则跳过构建——这样历史版本归档标签（v0.0.5、v1.0.0 等）不会被当前代码重新打包覆盖。
- 分类顺序等用户偏好仅保存在本机 `SharedPreferences`，不会上传。
- 发布构建产物（APK / Web / 源码包）归档在同级目录 `YBH-blog-release/`，不纳入本源码仓库。
- 官方下载站 <https://app.yibianhui.cn> 的结构：

  ```
  index.html              下载页（主推 arm64-v8a，其余架构在折叠的「其他下载选项」里）
  app-icon.png
  download/               只保留最新版的三个 ABI 包 + SHA256SUMS.txt + README.txt
  update/version.json     App 自动更新清单
  ```

  历史版本不留在服务器上，统一归档到
  [GitHub Releases](https://github.com/Yibianhui/YBH-Blog-App/releases)。

## 同步到 GitHub

首次推送前先添加远端（把 `<用户名>/<仓库名>` 换成你的仓库）：

```powershell
git remote add origin git@github.com:<用户名>/<仓库名>.git
# 或 HTTPS：
# git remote add origin https://github.com/<用户名>/<仓库名>.git
git push -u origin main
```

之后每次本地有改动要同步，运行仓库根目录的脚本即可（会自动拉取、提交、推送）：

```powershell
pwsh ./sync_to_github.ps1 -Message "本次更新说明"
```

> 注意：`sync_to_github.ps1` 会先提交本地改动、`git pull --rebase` 再推送，避免非快进冲突；如有冲突需手动解决后重跑。
> 首次使用前需把 GitHub 个人访问令牌（PAT，含 `repo` 权限）存入 Windows 凭据管理器（`git credential approve`），方可免交互推送。

