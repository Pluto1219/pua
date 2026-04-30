#!/bin/bash
# File: hooks/pua-loop-hook.sh
# Summary: 本地个人版禁用自动 loop Stop hook，避免会话结束时执行任何验证命令。
# Dependencies: 无。
# Constraints: 禁止读取 loop state、禁止执行用户配置命令、禁止阻塞 Stop。
# Performance notes: O(1) 立即退出，避免 Stop 阶段被自动迭代逻辑拖住。

# 个人本地版安全开关：禁止自动循环和 hook 侧命令执行。
# 如果未来要重新启用，必须显式恢复旧实现并重新注册 hooks/hooks.json 的 Stop hook。
exit 0
