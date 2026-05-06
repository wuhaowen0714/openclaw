library;

/// InputBox — 底部输入框 + 发送按钮。
///
/// 行为:
///   - 多行 textfield，Cmd/Ctrl+Enter 发送
///   - agent 运行中: 禁用输入 + 灰化按钮
///   - 提交后清空内容

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class InputBox extends StatefulWidget {
  final bool enabled;
  final void Function(String) onSubmit;

  const InputBox({super.key, required this.enabled, required this.onSubmit});

  @override
  State<InputBox> createState() => _InputBoxState();
}

class _InputBoxState extends State<InputBox> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  void _submit() {
    final text = _ctrl.text.trim();
    if (text.isEmpty || !widget.enabled) return;
    widget.onSubmit(text);
    _ctrl.clear();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Shortcuts(
              shortcuts: {
                LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.enter): _SendIntent(),
                LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.enter): _SendIntent(),
              },
              child: Actions(
                actions: {
                  _SendIntent: CallbackAction<_SendIntent>(onInvoke: (_) {
                    _submit();
                    return null;
                  }),
                },
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  maxLines: 5,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: widget.enabled
                        ? '输入任务...（Cmd/Ctrl + Enter 发送）'
                        : '正在执行中...',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: widget.enabled ? _submit : null,
            icon: const Icon(Icons.send, size: 16),
            label: const Text('发送'),
          ),
        ],
      ),
    );
  }
}

class _SendIntent extends Intent {}
