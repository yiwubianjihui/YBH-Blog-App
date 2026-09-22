import 'package:flutter_test/flutter_test.dart';
import 'package:yibianhui_blog/src/ui/rich_text_editor.dart';

/// 查找 / 替换（T34 遗留项，对齐网页端 T33）的状态与桥接口测试。
///
/// 匹配算法在编辑器的 JS 里跑（WebView 内），这里守住两件同样重要的事：
/// ① Dart 侧解析 JS 回报的状态是否正确（面板显示「第 N / 共 M 处」靠它）；
/// ② 注入文档里确实暴露了那几个桥方法 —— 少一个，工具栏按钮就成了哑按钮。
void main() {
  group('EditorFindState', () {
    test('解析 JS 回报', () {
      final s = EditorFindState.fromJson(const {
        'query': 'YBH',
        'count': 7,
        'index': 2,
        'caseSensitive': true,
      });
      expect(s.query, 'YBH');
      expect(s.count, 7);
      expect(s.index, 2);
      expect(s.caseSensitive, isTrue);
      expect(s.position, 3, reason: 'index 是 0 基，面板显示要 +1');
      expect(s.label, '第 3 / 共 7 处');
    });

    test('未命中与未输入的提示不同', () {
      expect(
        EditorFindState.fromJson(const {'query': 'x', 'count': 0}).label,
        '未找到',
      );
      // 还没输入任何字：不显示「未找到」，否则一打开面板就像出错了。
      expect(const EditorFindState().label, '');
    });

    test('字段缺失 / 类型不对时不抛异常', () {
      final s = EditorFindState.fromJson(const {'count': 'oops'});
      expect(s.count, 0);
      expect(s.query, '');
      expect(s.caseSensitive, isFalse);
      expect(s.position, 0);
    });
  });

  group('编辑器注入文档', () {
    final html = RichTextEditor.buildHtml(dark: false, placeholder: '写点什么');

    test('暴露了查找 / 替换的桥方法', () {
      for (final fn in const [
        'find:',
        'findStep:',
        'findReplace:',
        'findClear:',
        'selectionText:',
      ]) {
        expect(html, contains(fn), reason: '注入文档里缺少 $fn');
      }
      // 控制器依赖的全局对象。
      expect(html, contains('window.YbhEditor'));
    });

    test('匹配只走文本节点，且跳过 script/style', () {
      // 这是「不会把 <a href> 或标签改坏」的实现依据。
      expect(html, contains('NodeFilter.SHOW_TEXT'));
      expect(html, contains("tag === 'script'"));
      expect(html, contains("tag === 'style'"));
    });

    test('有安全上限，避免病态查询卡死', () {
      expect(html, contains('5000'));
    });

    test('全部替换按节点从后往前改（否则偏移会失效）', () {
      expect(html, contains('byNode'));
      expect(html, contains('items.length - 1; k >= 0; k--'));
    });
  });
}
