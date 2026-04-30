#!/bin/bash
# File: scripts/setup-pua-loop.sh
# Summary: 本地个人版禁用 PUA Loop 状态文件创建和验证命令持久化。
# Dependencies: 无。
# Constraints: 禁止写 ~/.claude/pua/loop-*.md，禁止保存或运行用户提供的验证命令。
# Performance notes: O(1) 立即退出，避免创建后台循环状态。

set -euo pipefail

# 个人本地版安全开关：禁止自动 loop。退出码 1 让调用方明确知道功能不可用。
echo "PUA Loop is disabled in this local personal build." >&2
exit 1
