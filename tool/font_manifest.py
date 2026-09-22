#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
字体清单（manifest.json）生成 / 校验
====================================

背景（T30 字体本地化）
----------------------
App 把站点自托管字体打进安装包，用 `data:` URI 顶掉站点规则。清单
`assets/fonts/manifest.json` 是「站点 CSS 里的哪条 @font-face 要由本机哪份
资产顶替」的唯一真值，`lib/src/data/embedded_fonts.dart` 按它生成替换 CSS。

为什么需要这个脚本
------------------
清单原来是由 `D:\\hanzigen\\deploy_fonts.py` / `deploy_slices.py` **增量追加**出来的，
于是产生了三类漂移（2026-09-22 实测）：

1. **站点 CSS 改了，清单没跟**：站点把全部 `font-display` 由 `swap` 改成
   `optional`（提交 804ec2ec），并收窄了 emoji 的 `unicode-range`
   （修「裸 ☂ 变彩色」），清单里仍是旧值 —— 19 条内联面全部不一致。
2. **清单元数据失真**：`count` / `totalBytes` 停在最初那版（16 / 5 645 068），
   而 `files` 里 147 个分片的 `bytes` 是**瘦身前**的旧值（46.43 MB vs 实际 13.21 MB）。
3. **清单引用了没进包的资产**：`slices/` 与 `emoji/` 没有写进 `pubspec.yaml`，
   `rootBundle.load` 直接抛异常 ⇒ `prepare()` 整体失败 ⇒ **字体本地化全线失效**。

本脚本以**站点 CSS 为唯一真值**重新生成清单，并把「内联 / 留在站点懒加载 / 丢弃」
三类显式化：

* `inline` —— 本地 `assets/fonts/<rel>` 存在 ⇒ 打进包，用 data: URI 供给。
* `lazy`   —— `slices/`（146 片扩展汉字面 + prio）。站点 CSS 里保留它们的
  @font-face，WebView 只在真的出现扩展区汉字时才去下那一小片（~95 KB）。
  **不内联**：内联会让每次导航注入的 base64 CSS 多 17.6 MB，而站点语料
  实际只用 6 个扩展字（已由 3.5 KB 的 ExtB 覆盖）。
* `dropped` —— 站点声明了但本地没有资产（Sarasa J/K/HC/TC 全量族、TH-Tshyn、
  未打包的字重）。App 侧把对应 @font-face **整条删除**，渲染回退系统字体：
  既不下载，也不留悬挂引用。

用法
----
    python tool/font_manifest.py --check      # 只报告漂移（CI / 提交前）
    python tool/font_manifest.py --write      # 重新生成 manifest.json + 清单报告

`--check` 有漂移时退出码为 1。

参数
----
`--css`     站点主题的 ybh.css（默认读 E:\\dsh\\SakurairoYBH\\css\\ybh.css）
`--assets`   App 字体资产目录（默认 assets/fonts）
`--report`   清单报告落盘位置（默认 docs/T30-字体清单.md）
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

REPO = Path(__file__).resolve().parent.parent
DEFAULT_CSS = Path(r'E:\dsh\SakurairoYBH\css\ybh.css')

APP_FONTS = REPO / 'assets' / 'fonts'
MANIFEST = APP_FONTS / 'manifest.json'
REPORT = REPO / 'docs' / 'T30-字体清单.md'

SITE_PREFIX = '/wp-content/uploads/ybh-fonts/'

#: 站点 CSS 里保留、App 不内联的目录（相对 SITE_PREFIX）。
#: 生成清单时写进 `keepOnSitePrefixes`，由注入脚本转成 `keep` 前缀，
#: 命中这些前缀的站点 @font-face **不删**，交给浏览器按 unicode-range 懒加载。
LAZY_DIRS = ('slices',)

#: 同样留在站点、但按**单条 URL** 保留的面孔。
#:
#: `slice/SarasaUiSC-ExtB.woff2`（3.5 KB，站点实际用到的 6 个扩展字）必须留：
#: 它的 unicode-range 与 s000/s005/s006/s083/s091 五片**真的重叠**，而同族
#: unicode-range 命中时**后声明者胜**。App 的替换样式插在 `<head>` 靠前位置，
#: 站点样式在后 —— 所以这 6 个字实际由站点自己那条 ExtB 供给（3.5 KB），
#: 内联进 App 也永远不会赢，只会白占体积。
#:
#: ⚠️ 因此有个必须保持的不变量：**App 的替换样式只做「基础字体」，站点保留下来的
#: 规则做「按需补充」**。不要为了抢优先级把替换样式挪到 `<head>` 末尾 ——
#: 那会让无 unicode-range 的 `*.subset` 面压过站点分片，扩展区汉字反而全变豆腐。
LAZY_PATHS = ('slice/SarasaUiSC-ExtB.woff2',)

#: 站点 load 的 FontAwesome 不在 ybh-fonts 下（在插件目录里，注入脚本的
#: `/ybh-fonts/` 前缀匹配不到），所以它不能从站点 CSS 推导，只能显式补。
#: 这三份资产 + 三个族名与站点插件里声明的一致，用于保证正文图标离线可用。
EXTRA_RULES = [
    dict(path='fontawesome/webfonts/fa-brands-400.woff2',
         family='Font Awesome 6 Brands', weight='400', style='normal',
         display='block', unicodeRange=None),
    dict(path='fontawesome/webfonts/fa-regular-400.woff2',
         family='Font Awesome 6 Free', weight='400', style='normal',
         display='block', unicodeRange=None),
    dict(path='fontawesome/webfonts/fa-solid-900.woff2',
         family='Font Awesome 6 Free', weight='900', style='normal',
         display='block', unicodeRange=None),
    dict(path='fontawesome/webfonts/fa-brands-400.woff2',
         family='Font Awesome 5 Brands', weight='400', style='normal',
         display='block', unicodeRange=None),
    dict(path='fontawesome/webfonts/fa-solid-900.woff2',
         family='Font Awesome 5 Free', weight='900', style='normal',
         display='block', unicodeRange=None),
    dict(path='fontawesome/webfonts/fa-regular-400.woff2',
         family='Font Awesome 5 Free', weight='400', style='normal',
         display='block', unicodeRange=None),
    dict(path='fontawesome/webfonts/fa-solid-900.woff2',
         family='FontAwesome', weight='400', style='normal',
         display='block', unicodeRange=None),
    dict(path='fontawesome/webfonts/fa-brands-400.woff2',
         family='FontAwesome', weight='400', style='normal',
         display='block', unicodeRange=None),
    dict(path='fontawesome/webfonts/fa-regular-400.woff2',
         family='FontAwesome', weight='400', style='normal',
         display='block', unicodeRange=None),
]

_FACE_RE = re.compile(r'@font-face\s*\{(.*?)\}', re.S)
_URL_RE = re.compile(r"url\(\s*['\"]?([^'\")]+)")
_FAMILY_RE = re.compile(r"font-family:\s*['\"]?([^;'\"]+)")
_WEIGHT_RE = re.compile(r'font-weight:\s*([^;}]+)')
_STYLE_RE = re.compile(r'font-style:\s*([^;}]+)')
_DISPLAY_RE = re.compile(r'font-display:\s*([^;}]+)')
_RANGE_RE = re.compile(r'unicode-range:\s*([^;}]+)')


def _g(rx: re.Pattern[str], body: str) -> str | None:
    m = rx.search(body)
    return m.group(1).strip() if m else None


def parse_site_faces(css_text: str) -> list[dict]:
    """按文档顺序解析站点 CSS 里所有指向 ybh-fonts 的 @font-face。"""
    faces: list[dict] = []
    for body in _FACE_RE.findall(css_text):
        m = _URL_RE.search(body)
        if not m or SITE_PREFIX not in m.group(1):
            continue
        rel = m.group(1).split(SITE_PREFIX, 1)[1]
        faces.append(dict(
            path=rel,
            family=_g(_FAMILY_RE, body),
            weight=_g(_WEIGHT_RE, body),
            style=_g(_STYLE_RE, body),
            display=_g(_DISPLAY_RE, body),
            unicodeRange=_g(_RANGE_RE, body),
        ))
    return faces


def _sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


SITE_BASE = 'https://www.yibianhui.cn' + SITE_PREFIX


def _curl(url: str, dst: Path) -> str:
    """下载到 dst，返回 HTTP 状态码。

    必须带 `--noproxy '*'`：本机沙箱有白名单代理，走代理访问本站会返 0 字节
    （见 handoff/YBH-全线交接总文档 §2.4）。
    """
    r = subprocess.run(
        ['curl.exe', '-sS', '--noproxy', '*', '--max-time', '180',
         '-o', str(dst), '-w', '%{http_code}', url],
        capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=300)
    return (r.stdout or '').strip()


def sync_from_site(files: list[dict], apply: bool) -> tuple[int, int, list[str]]:
    """把本地资产与**线上同路径文件**逐字节比对（本仓库的「线上 == 本地」铁律）。

    为什么必须做：站点侧字体是**会被继续子集化**的 —— 2026-09-20 把
    NotoColorEmoji 从 1.86 MB 子集到 2.7 KB、Klee One 从 1.83 MB 到 0.6 MB。
    本地资产不跟着换，安装包就白白多背 3.1 MB，而每次导航注入的替换 CSS
    多 4.1 MB（base64）。字节不一致就是不一致，不做「大概一样」的判断。

    返回 (相同数, 不同数, 报告行)。
    """
    tmp = Path(tempfile.mkdtemp(prefix='ybh-fonts-'))
    same = diff = 0
    lines: list[str] = []
    try:
        for f in files:
            rel = f['path']
            local = APP_FONTS / rel
            dst = tmp / rel.replace('/', '_')
            code = _curl(SITE_BASE + rel, dst)
            if code != '200' or not dst.is_file():
                lines.append('  [!] %-50s 线上取不到（HTTP %s）' % (rel, code))
                continue
            site_bytes = dst.stat().st_size
            local_bytes = local.stat().st_size if local.is_file() else -1
            if local.is_file() and _sha256(dst) == _sha256(local):
                same += 1
                continue
            diff += 1
            lines.append('  [%s] %-50s 本地 %d B → 线上 %d B（%+d）'
                         % ('已同步' if apply else '不一致', rel, local_bytes,
                            site_bytes, local_bytes - site_bytes))
            if apply:
                local.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(dst, local)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return same, diff, lines


def build(faces: list[dict]) -> tuple[dict, dict]:
    """把站点面孔分成 inline / lazy / dropped，并算出清单。"""
    inline_rules: list[dict] = []
    inline_files: dict[str, dict] = {}
    lazy: list[dict] = []
    dropped: list[dict] = []

    for f in faces:
        top = f['path'].split('/')[0] if '/' in f['path'] else ''
        fp = APP_FONTS / f['path']
        if top in LAZY_DIRS or f['path'] in LAZY_PATHS:
            lazy.append(f)
            continue
        if not fp.is_file():
            dropped.append(f)
            continue
        if f['path'] not in inline_files:
            inline_files[f['path']] = dict(
                path=f['path'],
                asset='assets/fonts/' + f['path'],
                bytes=fp.stat().st_size,
                sha256=_sha256(fp),
            )
        inline_rules.append(dict(
            path=f['path'], family=f['family'], weight=f['weight'],
            style=f['style'], display=f['display'],
            unicodeRange=f['unicodeRange'],
        ))

    # 站点推导不到的 FontAwesome：显式补，且只补本地真有资产的。
    for r in EXTRA_RULES:
        fp = APP_FONTS / r['path']
        if not fp.is_file():
            continue
        if r['path'] not in inline_files:
            inline_files[r['path']] = dict(
                path=r['path'], asset='assets/fonts/' + r['path'],
                bytes=fp.stat().st_size, sha256=_sha256(fp),
            )
        inline_rules.append(dict(r, source='extra'))

    total = sum(f['bytes'] for f in inline_files.values())
    manifest = dict(
        generatedFor='YBH Blog App · 网页字体本地化（T30）',
        generator='tool/font_manifest.py（站点 CSS 为唯一真值）',
        sitePrefix=SITE_PREFIX,
        note=('站点 CSS 里 url(…/ybh-fonts/<path>) 的 @font-face 由 App 改写为 '
              'data: URI；未列入本清单的一律回退系统字体。'
              '`keepOnSitePrefixes` 下的站点规则**不删**，按 unicode-range 懒加载。'
              '替换样式只做基础字体、站点保留规则做按需补充 —— 不要靠挪动样式位置抢优先级。'),
        keepOnSitePrefixes=([SITE_PREFIX + d + '/' for d in LAZY_DIRS]
                            + [SITE_PREFIX + p for p in LAZY_PATHS]),
        count=len(inline_files),
        ruleCount=len(inline_rules),
        totalBytes=total,
        lazyCount=len(lazy),
        lazyNote=('分片扩展汉字面（每片约 95 KB，带精确 unicode-range）+ ExtB（3.5 KB，'
                  '站点实际用到的 6 个扩展字）：都留在站点按需下载。'
                  '内联进 data: URI 会让每次导航的替换 CSS 多 17.6 MB，'
                  '而且 ExtB 与 5 个分片的 unicode-range 重叠 —— 后声明者胜，'
                  'App 内联它也赢不了站点那条。'),
        droppedCount=len(dropped),
        droppedNote=('站点声明但未打包（Sarasa J/K/HC/TC 全量族、TH-Tshyn、未选中字重）：'
                     'App 把对应 @font-face 整条删除，渲染回退系统字体 —— 既不下载，也不留悬挂引用。'),
        files=sorted(inline_files.values(), key=lambda x: x['path']),
        rules=inline_rules,
    )
    stats = dict(lazy=lazy, dropped=dropped,
                 inline_bytes=total,
                 css_bytes=int(total * 4 / 3) + 512)
    return manifest, stats


def describe(manifest: dict) -> str:
    tot = manifest['totalBytes']
    lines = [
        '清单：%d 个文件 / %d 条规则；内联 %.2f MB，替换 CSS 约 %.2f MB（base64）'
        % (manifest['count'], manifest['ruleCount'], tot / 1048576, tot * 4 / 3 / 1048576),
        '留在站点懒加载：%d 条；丢弃（回退系统字体）：%d 条'
        % (manifest['lazyCount'], manifest['droppedCount']),
    ]
    return '\n'.join(lines)


def drift(current: dict, fresh: dict) -> list[str]:
    """比较现有清单与新生成的清单，返回人类可读的差异。"""
    out: list[str] = []
    for k in ('count', 'ruleCount', 'totalBytes', 'lazyCount', 'droppedCount',
              'keepOnSitePrefixes'):
        if current.get(k) != fresh.get(k):
            out.append('%s: %r → %r' % (k, current.get(k), fresh.get(k)))

    def rk(r: dict) -> tuple:
        return (r['path'], r['family'], r.get('weight'), r.get('style'))

    cur = {rk(r): r for r in current.get('rules', [])}
    new = {rk(r): r for r in fresh['rules']}
    for k in sorted(set(cur) | set(new), key=lambda x: (x[0], str(x[2]), str(x[3]))):
        a, b = cur.get(k), new.get(k)
        if a is None:
            out.append('+ 新增规则 %s %s %s' % (k[0], k[1], k[2]))
            continue
        if b is None:
            out.append('- 移除规则 %s %s %s' % (k[0], k[1], k[2]))
            continue
        for field in ('display', 'unicodeRange'):
            if (a.get(field) or None) != (b.get(field) or None):
                out.append('%s %s %s | %s: %r → %r'
                           % (k[0], k[1], k[2], field,
                              (a.get(field) or '')[:70], (b.get(field) or '')[:70]))
    curf = {f['path'] for f in current.get('files', [])}
    newf = {f['path'] for f in fresh['files']}
    for p in sorted(newf - curf):
        out.append('+ 新增资产 %s' % p)
    for p in sorted(curf - newf):
        out.append('- 移除资产 %s' % p)
    return out


def write_report(manifest: dict, stats: dict, css_path: Path,
                 out_path: Path = REPORT) -> None:
    """写一份人看的清单（审计用；不进安装包）。"""
    lines = [
        '# T30 · App 打包字体清单（自动生成，勿手改）',
        '',
        '> 生成器：`tool/font_manifest.py --write` ｜ 真值：`%s`' % css_path,
        '> 用途：`lib/src/data/embedded_fonts.dart` 据此把站点 `@font-face` 换成 `data:` URI。',
        '',
        '## 一、总览',
        '',
        '| 项 | 值 |',
        '|---|---|',
        '| 内联（进安装包） | **%d 个文件 / %d 条规则** |' % (manifest['count'], manifest['ruleCount']),
        '| 内联原始体积 | **%.2f MB** |' % (manifest['totalBytes'] / 1048576),
        '| 生成的替换 CSS | 约 **%.2f MB**（base64，每次导航注入） |'
        % (manifest['totalBytes'] * 4 / 3 / 1048576),
        '| 留在站点懒加载 | %d 条（`%s`） |'
        % (manifest['lazyCount'], '`, `'.join(manifest['keepOnSitePrefixes'])),
        '| 丢弃（回退系统字体） | %d 条 |' % manifest['droppedCount'],
        '',
        '## 二、内联规则（%d 条）' % manifest['ruleCount'],
        '',
        '| # | 资产 | 族 | 字重 | 字形 | display | unicode-range |',
        '|---|---|---|---|---|---|---|',
    ]
    for i, r in enumerate(manifest['rules'], 1):
        ur = r.get('unicodeRange') or '（全集）'
        lines.append('| %d | `%s` | %s | %s | %s | %s | `%s` |'
                     % (i, r['path'], r['family'], r.get('weight'), r.get('style'),
                        r.get('display'), ur if len(ur) <= 120 else ur[:117] + '…'))
    lines += ['', '## 三、留在站点懒加载（%d 条）' % manifest['lazyCount'], '',
              manifest['lazyNote'], '',
              '| 资产 | 族 | 字重 | 字形 | unicode-range |', '|---|---|---|---|---|']
    for r in stats['lazy']:
        ur = r.get('unicodeRange') or ''
        lines.append('| `%s` | %s | %s | %s | `%s` |'
                     % (r['path'], r['family'], r.get('weight'), r.get('style'),
                        ur if len(ur) <= 120 else ur[:117] + '…'))
    lines += ['', '## 四、丢弃（%d 条，回退系统字体）' % manifest['droppedCount'], '',
              manifest['droppedNote'], '',
              '| 资产 | 族 | 字重 | 字形 |', '|---|---|---|---|']
    for r in stats['dropped']:
        lines.append('| `%s` | %s | %s | %s |'
                     % (r['path'], r['family'], r.get('weight'), r.get('style')))
    lines += ['',
              '## 五、复现',
              '',
              '```powershell',
              'python tool/font_manifest.py --check   # 站点 CSS 改了而清单没跟 → 非零退出',
              'python tool/font_manifest.py --write   # 重新生成 manifest.json 与本文件',
              '```',
              '',
              '改动 `pubspec.yaml` 的 `assets:` 时：**新目录必须单独列一行**'
              '（Flutter 的目录声明不含子目录）。漏了会让 `rootBundle.load` 抛异常，'
              '`EmbeddedFonts.prepare()` 整体失败 ⇒ 字体本地化静默失效（215161b 就这样栽过）。',
              '`test/font_manifest_test.dart` 会替你把这条守住。',
              '']
    out_path.write_text('\n'.join(lines), encoding='utf-8', newline='\n')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--css', default=str(DEFAULT_CSS))
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--sync-site', action='store_true',
                    help='把内联资产与线上同路径文件逐字节比对；不一致就报告')
    ap.add_argument('--apply', action='store_true',
                    help='配合 --sync-site：用线上文件覆盖本地资产（改完需再跑 --write）')
    ap.add_argument('--report', default=str(REPORT))
    a = ap.parse_args()

    css_path = Path(a.css)
    if not css_path.is_file():
        print('[!] 站点 CSS 不存在：%s' % css_path)
        return 2
    faces = parse_site_faces(css_path.read_text(encoding='utf-8'))
    if not faces:
        print('[!] 在 %s 里没解析到任何 ybh-fonts @font-face' % css_path)
        return 2
    fresh, stats = build(faces)
    print('站点面孔 %d 条 → 内联 %d / 懒加载 %d / 丢弃 %d'
          % (len(faces), fresh['ruleCount'], fresh['lazyCount'], fresh['droppedCount']))

    if a.sync_site:
        print('\n=== 与线上逐字节比对（本仓库「线上 == 本地」铁律）===')
        same, diff, lines = sync_from_site(fresh['files'], a.apply)
        for ln in lines:
            print(ln)
        print('相同 %d 个，不一致 %d 个' % (same, diff))
        if diff and not a.apply:
            print('[!] 有不一致 —— 加 --apply 用线上文件覆盖本地资产，再跑 --write')
            return 1
        if diff and a.apply:
            # 资产换了，清单的 bytes/sha256 必须跟着重算。
            fresh, stats = build(faces)
            MANIFEST.write_text(json.dumps(fresh, ensure_ascii=False, indent=1) + '\n',
                                encoding='utf-8', newline='\n')
            write_report(fresh, stats, css_path, Path(a.report))
            print('已用线上资产重建清单 %s（内联 %.2f MB）'
                  % (MANIFEST, fresh['totalBytes'] / 1048576))

    print(describe(fresh))

    if not MANIFEST.is_file():
        print('[!] 现有清单不存在：%s' % MANIFEST)
        cur = {}
    else:
        cur = json.loads(MANIFEST.read_text(encoding='utf-8'))

    diffs = drift(cur, fresh) if cur else ['（无现有清单，全部按新增处理）']
    if diffs:
        print('\n与现有清单的差异 %d 处：' % len(diffs))
        for d in diffs[:80]:
            print('  ' + d)
        if len(diffs) > 80:
            print('  … 另有 %d 处' % (len(diffs) - 80))
    else:
        print('\n与现有清单一致 ✅')

    if a.write:
        MANIFEST.write_text(json.dumps(fresh, ensure_ascii=False, indent=1) + '\n',
                            encoding='utf-8', newline='\n')
        print('\n已写入 %s' % MANIFEST)
        write_report(fresh, stats, css_path, Path(a.report))
        print('已写入清单报告 %s' % a.report)
        return 0

    if a.check and diffs:
        print('\n[!] 清单与站点 CSS 不一致 —— 请跑 --write 后提交')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
