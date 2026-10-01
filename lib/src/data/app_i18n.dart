library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App 界面多语言（0.0.29）。
///
/// 与站点 T66 的机制**分开但语义对齐**：
///   · 站点：`?lang=xx` + cookie，六种语言，缺译回退中文（`ybh_t()`）；
///   · App：本地设置存 SharedPreferences，缺译回退中文原文。
///
/// 设计要点：
///   1. **以中文原文为 key**（与站点 `ybh_t()` 同一习惯），缺译回退原文 ——
///      新增界面文案不需要先补翻译，最坏情况是显示中文；
///   2. 只覆盖 **App 原生界面**（底部导航 / 我的页 / 编辑器提示等）；
///      「整站」「文章阅读器」的排版与语言由站点 CSS / 正文决定，不归这层管；
///   3. 默认 `system`：跟随系统语言，系统语言不在支持表里时用中文。
///   4. 「整站」页的语言切换在站点页脚里（`?lang=xx`），与本设置互不影响 ——
///      站点语言影响网页内容，App 语言影响 App 自己的界面。

/// 支持的语言。code 与站点 T66 的语言注册表一致（`zh-Hans` 缺省）。
enum AppLanguage {
  /// 跟随系统（默认）。
  system('system', '跟随系统', null),

  /// 简体中文（App 文案的原语言）。
  zhHans('zh-Hans', '简体中文', Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans')),

  /// 繁体中文。
  zhHant('zh-Hant', '繁體中文', Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')),

  /// 英文。
  en('en', 'English', Locale('en')),

  /// 日文。
  ja('ja', '日本語', Locale('ja'));

  const AppLanguage(this.code, this.label, this.locale);

  /// 存储用代码（与站点 `?lang=` 取值一致，`system` 为 App 专属）。
  final String code;

  /// 设置页里显示的名字。
  final String label;

  /// 传给 MaterialApp 的 locale；`system` 为 null。
  final Locale? locale;

  static AppLanguage fromCode(String code) => AppLanguage.values
      .firstWhere((l) => l.code == code, orElse: () => AppLanguage.system);
}

/// 译表：key = 中文原文，value = 各语言译文。
/// 缺某个语言的条目 ⇒ 回退中文原文。
const Map<String, Map<String, String>> _translations = <String, Map<String, String>>{
  // ---- 底部导航 ----
  '首页': {
    'zh-Hant': '首頁',
    'en': 'Home',
    'ja': 'ホーム',
  },
  '文章': {
    'zh-Hant': '文章',
    'en': 'Articles',
    'ja': '記事',
  },
  '写文章': {
    'zh-Hant': '寫文章',
    'en': 'Write',
    'ja': '投稿',
  },
  '整站': {
    'zh-Hant': '整站',
    'en': 'Site',
    'ja': 'サイト',
  },
  '我的': {
    'zh-Hant': '我的',
    'en': 'Me',
    'ja': 'マイページ',
  },
  // ---- 常用动作 / 状态 ----
  '刷新': {
    'zh-Hant': '重新整理',
    'en': 'Refresh',
    'ja': '更新',
  },
  '登录': {
    'zh-Hant': '登入',
    'en': 'Sign in',
    'ja': 'ログイン',
  },
  '退出登录': {
    'zh-Hant': '登出',
    'en': 'Sign out',
    'ja': 'ログアウト',
  },
  '用户名 / 邮箱': {
    'zh-Hant': '使用者名稱 / 電子郵件',
    'en': 'Username / Email',
    'ja': 'ユーザー名 / メール',
  },
  '密码': {
    'zh-Hant': '密碼',
    'en': 'Password',
    'ja': 'パスワード',
  },
  '登录失败，请检查用户名与应用密码': {
    'zh-Hant': '登入失敗，請檢查使用者名稱與密碼',
    'en': 'Sign-in failed. Check your username and password.',
    'ja': 'ログインに失敗しました。ユーザー名とパスワードを確認してください。',
  },
  '我的文章': {
    'zh-Hant': '我的文章',
    'en': 'My articles',
    'ja': '自分の記事',
  },
  '分类管理': {
    'zh-Hant': '分類管理',
    'en': 'Categories',
    'ja': 'カテゴリー管理',
  },
  '检查更新': {
    'zh-Hant': '檢查更新',
    'en': 'Check updates',
    'ja': 'アップデート確認',
  },
  '查看是否有新版本可用': {
    'zh-Hant': '查看是否有新版本可用',
    'en': 'See if a new version is available',
    'ja': '新しいバージョンの確認',
  },
  '站点地址': {
    'zh-Hant': '網站位址',
    'en': 'Website',
    'ja': 'サイトアドレス',
  },
  '分享应用': {
    'zh-Hant': '分享應用',
    'en': 'Share app',
    'ja': 'アプリを共有',
  },
  '把 YBH 推荐给朋友': {
    'zh-Hant': '把 YBH 推薦給朋友',
    'en': 'Recommend YBH to friends',
    'ja': 'YBH を友達に紹介',
  },
  '消息中心': {
    'zh-Hant': '訊息中心',
    'en': 'Notifications',
    'ja': 'お知らせ',
  },
  '新文章与投稿进度，随时回看': {
    'zh-Hant': '新文章與投稿進度，隨時回看',
    'en': 'New posts and submission progress',
    'ja': '新着記事と投稿の進捗',
  },
  '通知设置': {
    'zh-Hant': '通知設定',
    'en': 'Notification settings',
    'ja': '通知設定',
  },
  '新文章发布、投稿审核通过提醒': {
    'zh-Hant': '新文章發布、投稿審核通過提醒',
    'en': 'Alerts for new posts and approvals',
    'ja': '新着記事と承認の通知',
  },
  '个人资料': {
    'zh-Hant': '個人資料',
    'en': 'Profile',
    'ja': 'プロフィール',
  },
  '编辑昵称、简介与站点资料页': {
    'zh-Hant': '編輯暱稱、簡介與網站資料頁',
    'en': 'Edit your name, bio and site profile',
    'ja': 'ニックネーム・自己紹介の編集',
  },
  '语言': {
    'zh-Hant': '語言',
    'en': 'Language',
    'ja': '言語',
  },
  'App 界面显示语言': {
    'zh-Hant': 'App 介面顯示語言',
    'en': 'App interface language',
    'ja': 'アプリの表示言語',
  },
  '夜间模式': {
    'zh-Hant': '夜間模式',
    'en': 'Dark mode',
    'ja': 'ダークモード',
  },
  // ---- 编辑器 ----
  '写文章页标题': {
    'zh-Hant': '寫文章',
    'en': 'New post',
    'ja': '記事を書く',
  },
  '编辑文章': {
    'zh-Hant': '編輯文章',
    'en': 'Edit post',
    'ja': '記事を編集',
  },
  '标题': {
    'zh-Hant': '標題',
    'en': 'Title',
    'ja': 'タイトル',
  },
  '发布': {
    'zh-Hant': '發布',
    'en': 'Publish',
    'ja': '公開',
  },
  '保存修改': {
    'zh-Hant': '儲存修改',
    'en': 'Save changes',
    'ja': '変更を保存',
  },
  '保存草稿': {
    'zh-Hant': '儲存草稿',
    'en': 'Save draft',
    'ja': '下書き保存',
  },
  '提交审核': {
    'zh-Hant': '提交審核',
    'en': 'Submit for review',
    'ja': '審査に提出',
  },
  '直接发布': {
    'zh-Hant': '直接發布',
    'en': 'Publish now',
    'ja': '直接公開',
  },
  '存为草稿': {
    'zh-Hant': '存為草稿',
    'en': 'Save as draft',
    'ja': '下書きに保存',
  },
  '请填写标题': {
    'zh-Hant': '請填寫標題',
    'en': 'Please enter a title',
    'ja': 'タイトルを入力してください',
  },
  '请填写正文': {
    'zh-Hant': '請填寫正文',
    'en': 'Please enter the body text',
    'ja': '本文を入力してください',
  },
  '在这里写正文…支持标题、加粗、列表、引用、代码块、链接、图片与脚注。': {
    'zh-Hant': '在這裡寫正文…支援標題、加粗、清單、引用、程式碼區塊、連結、圖片與腳註。',
    'en': 'Write here… headings, bold, lists, quotes, code blocks, links, images and footnotes are supported.',
    'ja': 'ここに本文を入力…見出し・太字・リスト・引用・コードブロック・リンク・画像・脚注に対応。',
  },
  '分类（可选）': {
    'zh-Hant': '分類（可選）',
    'en': 'Category (optional)',
    'ja': 'カテゴリー（任意）',
  },
  '未分类': {
    'zh-Hant': '未分類',
    'en': 'Uncategorized',
    'ja': '未分類',
  },
  // ---- 个人资料页 ----
  '编辑资料': {
    'zh-Hant': '編輯資料',
    'en': 'Edit profile',
    'ja': 'プロフィールを編集',
  },
  '显示名': {
    'zh-Hant': '顯示名稱',
    'en': 'Display name',
    'ja': '表示名',
  },
  '昵称': {
    'zh-Hant': '暱稱',
    'en': 'Nickname',
    'ja': 'ニックネーム',
  },
  '个人简介': {
    'zh-Hant': '個人簡介',
    'en': 'Bio',
    'ja': '自己紹介',
  },
  '个人网站': {
    'zh-Hant': '個人網站',
    'en': 'Website',
    'ja': 'ウェブサイト',
  },
  '保存': {
    'zh-Hant': '儲存',
    'en': 'Save',
    'ja': '保存',
  },
  '已保存': {
    'zh-Hant': '已儲存',
    'en': 'Saved',
    'ja': '保存しました',
  },
  '显示名不能为空': {
    'zh-Hant': '顯示名稱不能為空',
    'en': 'Display name cannot be empty',
    'ja': '表示名は空にできません',
  },
  '修改密码': {
    'zh-Hant': '修改密碼',
    'en': 'Change password',
    'ja': 'パスワード変更',
  },
  '当前密码': {
    'zh-Hant': '目前密碼',
    'en': 'Current password',
    'ja': '現在のパスワード',
  },
  '新密码': {
    'zh-Hant': '新密碼',
    'en': 'New password',
    'ja': '新しいパスワード',
  },
  '确认新密码': {
    'zh-Hant': '確認新密碼',
    'en': 'Confirm new password',
    'ja': '新しいパスワード（確認）',
  },
  '密码已修改': {
    'zh-Hant': '密碼已修改',
    'en': 'Password changed',
    'ja': 'パスワードを変更しました',
  },
  '当前密码不正确': {
    'zh-Hant': '目前密碼不正確',
    'en': 'Current password is incorrect',
    'ja': '現在のパスワードが正しくありません',
  },
  '两次输入的新密码不一致': {
    'zh-Hant': '兩次輸入的新密碼不一致',
    'en': 'New passwords do not match',
    'ja': '新しいパスワードが一致しません',
  },
  '更多设置（头像 / 社交账号 / 偏好）': {
    'zh-Hant': '更多設定（頭像 / 社群帳號 / 偏好）',
    'en': 'More settings (avatar / social / preferences)',
    'ja': 'その他の設定（アイコン / SNS / 環境設定）',
  },
  '在网站资料页中完成，登录状态自动同步': {
    'zh-Hant': '在網站資料頁中完成，登入狀態自動同步',
    'en': 'Done on the site profile page — your sign-in carries over',
    'ja': 'サイトのプロフィールページで行います（ログイン状態は同期済み）',
  },
  // ---- 资料 / 角色 ----
  '管理员': {
    'zh-Hant': '管理員',
    'en': 'Administrator',
    'ja': '管理者',
  },
  '编辑': {
    'zh-Hant': '編輯',
    'en': 'Editor',
    'ja': '編集者',
  },
  '作者': {
    'zh-Hant': '作者',
    'en': 'Author',
    'ja': '投稿者',
  },
  '投稿者': {
    'zh-Hant': '投稿者',
    'en': 'Contributor',
    'ja': '寄稿者',
  },
  '订阅者': {
    'zh-Hant': '訂閱者',
    'en': 'Subscriber',
    'ja': '購読者',
  },
};

/// 本地化入口。用法：`L.t(context, '首页')`。
///
/// [fallback] 为缺译时显示的中文原文本身 —— 所以调用处直接写中文即可。
abstract final class L {
  /// 当前语言（空 = 跟随系统）。
  static String _code = 'system';

  static String get code => _code;

  static bool get isSystem => _code == 'system';

  /// 启动时从存储恢复；`setLanguage` 时更新。
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _code = prefs.getString('ybh_app_lang') ?? 'system';
    } catch (_) {
      _code = 'system';
    }
  }

  static Future<void> setLanguage(String code) async {
    _code = code;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ybh_app_lang', code);
    } catch (_) {}
  }

  /// 解析当前生效的语言代码（`system` 时按系统 locale 匹配支持表，否则中文）。
  static String resolve(BuildContext context) {
    if (_code != 'system') return _code;
    final loc = Localizations.localeOf(context);
    if (loc.languageCode == 'zh') {
      // 繁体地区用繁体；其余（含 zh-Hans/sg/my）用简体。
      final script = loc.scriptCode ?? '';
      if (script == 'Hant' || script == 'HK' || script == 'TW') {
        return 'zh-Hant';
      }
      // 无 script 时的地区启发：TW/HK/MO 常为繁体。
      final country = loc.countryCode?.toUpperCase() ?? '';
      if (country == 'TW' || country == 'HK' || country == 'MO') {
        return 'zh-Hant';
      }
      return 'zh-Hans';
    }
    if (loc.languageCode == 'en') return 'en';
    if (loc.languageCode == 'ja') return 'ja';
    return 'zh-Hans';
  }

  /// 取译文；缺译回退中文原文。
  static String t(BuildContext context, String key) {
    final lang = resolve(context);
    if (lang == 'zh-Hans') return key;
    return _translations[key]?[lang] ?? key;
  }

  /// MaterialApp 用的 supportedLocales + locale。
  static const List<Locale> supportedLocales = <Locale>[
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    Locale('en'),
    Locale('ja'),
  ];

  /// 当前设置的 Locale（`system` 返回 null → 跟随系统）。
  static Locale? get localeOverride =>
      AppLanguage.fromCode(_code).locale;
}
