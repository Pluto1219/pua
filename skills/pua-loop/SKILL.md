---
name: pua-loop
description: "PUA Loop 已在本地个人版禁用。Triggers on: '/pua:pua-loop', '自动循环', 'loop mode', '一直跑', '自动迭代'."
license: MIT
---

# PUA Loop — 已禁用

本仓库是个人本地版，PUA Loop 已禁用。

禁止执行 `scripts/setup-pua-loop.sh`，禁止创建 `~/.claude/pua/loop-*.md`，禁止保存或运行用户提供的验证命令，禁止通过 Stop hook 阻塞会话结束。

如果用户触发 `/pua:pua-loop`，只输出：

```text
PUA Loop 已在本地个人版禁用；请改用手动验证命令。
```
