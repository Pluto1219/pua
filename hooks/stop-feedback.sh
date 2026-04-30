#!/bin/bash
# File: hooks/stop-feedback.sh
# Summary: 本地个人版禁用 Stop 阶段反馈问卷、session 上传和排行榜上报。
# Dependencies: 无。
# Constraints: 禁止读取 transcript、禁止写 /tmp/pua-*、禁止发起任何网络请求。
# Performance notes: O(1) 立即退出，避免 Stop hook 增加会话结束延迟。

# 个人本地版安全开关：此仓库只给自己用，默认禁止所有反馈/排行榜数据流。
# 如果未来要重新启用，必须显式恢复旧实现并重新注册 hooks/hooks.json 的 Stop hook。
exit 0
