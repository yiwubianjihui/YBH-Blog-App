import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 字体清单的自洽性守卫。
///
/// 为什么需要它：清单（`assets/fonts/manifest.json`）引用的是**安装包内的资产**，
/// 而 Flutter 的 `assets:` 目录声明**不含子目录** —— 漏列一个目录，
/// `rootBundle.load` 就会抛异常。215161b 那次正是如此：清单里加了
/// `slices/` 与 `emoji/`，`pubspec.yaml` 却没声明它们，于是
/// `EmbeddedFonts.prepare()` 整体失败、**字体本地化全线静默失效**
/// （表现是整站又退回十几 MB 的网络字体，日志里只有一行「准备失败」）。
///
/// 这个测试把「清单 → 资产文件 → pubspec 声明」这条链子在**提交前**跑通，
/// 而不是等真机上发现字体变慢。
void main() {
  group('字体清单', () {
    late Map<String, dynamic> manifest;
    late String pubspec;
    late List<String> declaredAssetDirs;

    setUpAll(() {
      // flutter test 的工作目录就是包根目录。
      final manifestFile = File('assets/fonts/manifest.json');
      expect(manifestFile.existsSync(), isTrue,
          reason: 'assets/fonts/manifest.json 不存在；请跑 '
              '`python tool/font_manifest.py --write`');
      manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      pubspec = File('pubspec.yaml').readAsStringSync();
      declaredAssetDirs = _parseAssetDirs(pubspec);
    });

    test('每个规则都指向一个已登记的资产', () {
      final files = <String>{
        for (final f in (manifest['files'] as List<dynamic>).cast<Map<String, dynamic>>())
          f['path'] as String,
      };
      final rules = (manifest['rules'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(rules, isNotEmpty);
      for (final r in rules) {
        expect(files, contains(r['path'] as String),
            reason: '规则 ${r['path']} 在 files[] 里没有对应资产');
      }
    });

    test('每个资产确实存在于仓库里', () {
      final files = (manifest['files'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(files, isNotEmpty);
      for (final f in files) {
        expect(File(f['asset'] as String).existsSync(), isTrue,
            reason: '${f['asset']} 不存在');
      }
    });

    test('★ 每个资产的目录都在 pubspec.yaml 的 assets 里声明过', () {
      // 这条就是 215161b 那个故障的直接防线。
      final files = (manifest['files'] as List<dynamic>).cast<Map<String, dynamic>>();
      final missing = <String>{};
      for (final f in files) {
        final asset = f['asset'] as String;
        final dir = asset.substring(0, asset.lastIndexOf('/'));
        if (!declaredAssetDirs.contains(dir)) missing.add('$dir/（影响 $asset）');
      }
      expect(missing, isEmpty,
          reason: '以下目录出现在清单里但未在 pubspec.yaml 的 assets: 下声明。\n'
              'Flutter 的目录声明不含子目录，必须单独列一行：\n  ${missing.join('\n  ')}');
    });

    test('元数据与实际资产一致（count / totalBytes 不过期）', () {
      final files = (manifest['files'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(manifest['count'], files.length, reason: 'count 与 files[] 数量不符');
      expect(manifest['ruleCount'], (manifest['rules'] as List<dynamic>).length,
          reason: 'ruleCount 与 rules[] 数量不符');
      final total = files.fold<int>(0, (a, f) => a + (f['bytes'] as num).toInt());
      expect(manifest['totalBytes'], total, reason: 'totalBytes 与逐个文件之和不符');
      for (final f in files) {
        final actual = File(f['asset'] as String).lengthSync();
        expect(f['bytes'], actual, reason: '${f['path']} 的 bytes 是旧值（实际 $actual）');
      }
    });

    test('保留了「留在站点懒加载」的前缀（扩展汉字面分片）', () {
      final keep = (manifest['keepOnSitePrefixes'] as List<dynamic>).cast<String>();
      expect(keep, isNotEmpty,
          reason: '没有 keepOnSitePrefixes，注入脚本会把站点分片规则一并删掉，'
              '扩展区汉字就只能吃系统字体（豆腐）');
      expect(keep.any((k) => k.contains('/ybh-fonts/slices/')), isTrue,
          reason: '必须保留 /ybh-fonts/slices/ —— 146 片扩展汉字面靠它按需加载');
    });

    test('没有内联「无 unicode-range 的 Sarasa 面」与站点分片的冲突设计', () {
      // 设计不变量：App 的替换样式只做基础字体（插在 <head> 靠前），
      // 站点保留的分片规则做按需补充（在后，同族同码位后声明者胜）。
      //
      // T57 之后站点把 Sarasa 基础面也切了子集（每条都带 unicode-range）；
      // 唯一的例外是 **italic 面**（0.0.28 打包的更纱真斜体，WK 西文分支）——
      // 它们与正常体分片不冲突（font-style 不同，浏览器只在斜体请求时取用），
      // 所以本条只对 **normal** 体断言：内联规则不允许出现无 unicode-range 的
      // 正常体 Sarasa 面（那才是把分片压掉、扩展区汉字变豆腐的写法）。
      final rules = (manifest['rules'] as List<dynamic>).cast<Map<String, dynamic>>();
      final unbounded = rules.where((r) =>
          r['family'] == 'Sarasa UI SC' &&
          r['style'] != 'italic' &&
          ((r['unicodeRange'] as String?)?.isEmpty ?? true));
      expect(unbounded, isEmpty,
          reason: '内联清单里不应有「无 unicode-range 的正常体 Sarasa 面」——'
              '它会与站点分片规则冲突（同族同码位后声明者胜）');
    });
  });
}

/// 解析 pubspec.yaml 里 `flutter: assets:` 段声明的目录。
///
/// 只做文本解析（不引 yaml 依赖）：这一段是扁平的 `- 路径` 列表。
List<String> _parseAssetDirs(String pubspec) {
  final lines = const LineSplitter().convert(pubspec);
  final out = <String>[];
  var inAssets = false;
  var assetsIndent = -1;
  for (final line in lines) {
    final trimmed = line.trimRight();
    if (trimmed.trim().isEmpty || trimmed.trimLeft().startsWith('#')) continue;
    final indent = trimmed.length - trimmed.trimLeft().length;
    final body = trimmed.trim();
    if (body == 'assets:') {
      inAssets = true;
      assetsIndent = indent;
      continue;
    }
    if (!inAssets) continue;
    if (indent <= assetsIndent) {
      inAssets = false;
      continue;
    }
    if (body.startsWith('- ')) {
      var p = body.substring(2).trim();
      if (p.endsWith('/')) p = p.substring(0, p.length - 1);
      out.add(p);
    }
  }
  return out;
}
