---
name: pro
description: "PUA Pro extensions: self-evolution tracking, compaction state protection, KPI reporting, leaderboard, and /pua:pua commands. Triggers on: '/pua:kpi', '/pua:pro', '/pua:pro 段位', '/pua:pro 周报', '/pua:pro 述职', '/pua:flavor', '/pua:pro 排行榜', 'leaderboard', '排行榜', '自进化', 'evolution', or when user wants PUA platform features like段位/周报/述职/排行榜."
license: MIT
---

# PUA Pro — 自进化 + Platform

> 本 skill 是 `/pua` 核心的扩展层。角色切换请用 `/pua:p7` `/pua:p9` `/pua:p10`。

## 本地个人版远程能力禁用

本仓库只给个人本地使用，默认禁止所有远程平台能力：不注册手机号，不刷新远端配置，不拉取远程 prompt，不发起支付，不上传统计，不注册或提交排行榜。`references/platform.md` 仅作为历史设计文档保留，里面的 `curl`、`pip install`、远程 API 调用均不得执行。

允许保留的能力只有本地自进化记录、Compaction 状态恢复、KPI 文本生成和味道切换；这些能力不得产生网络请求。

## 自进化协议

"今天最好的表现，是明天最低的要求"——这不是旁白，这是机制。

- 读取 `~/.pua/evolution.md`（详见 `references/evolution-protocol.md`）
- 存在 → 加载基线 + 已内化模式。内化模式是默认义务，做了不标 [PUA生效]，不做则退化警告
- 不存在 → 首次启动，创建初始模板
- 任务完成时比对：超越 → 刷新基线 / 达标 → 保持 / 低于 → 退化警告（不降基线）
- 某行为重复 3+ 次会话 → 晋升为"已内化模式"（永久默认义务）

## Platform 层

### 会话启动前置检查

1. **检查 `~/.pua/evolution.md`**：加载自进化基线
2. **检查 `~/.pua/builder-journal.md`**（Compaction 断点恢复）：存在且 <2h → [Calibration] 流程，恢复 pressure_level / failure_count / tried_approaches，从断点继续。**压力不因 compaction 重置**
3. **检查 `~/.pua/config.json`**：仅读取本地配置；不存在也不注册，存在也不静默刷新远端配置
4. **节日彩蛋**：匹配节日表（详见 `references/platform.md`）
5. **统计上报**：本地个人版禁止统计上报，不发起网络请求

### Compaction 状态保护

PreCompact hook 自动注入指令，要求 dump 运行时状态到 `~/.pua/builder-journal.md`：
`pressure_level, failure_count, current_flavor, pua_triggered_count, active_task, tried_approaches, excluded_possibilities, next_hypothesis, key_context`

SessionStart hook 自动检测 builder-journal.md，存在且 <2h 则注入 [Calibration] 恢复状态。

### /pua 指令系统

| 触发词 | 功能 | 类型 |
|--------|------|------|
| `/pua` | 查看所有指令 | 🆓 |
| `/pua:kpi` | 大厂 KPI 报告卡 | 🆓 |
| `/pua:pro` + "段位" | 大厂段位 | 🆓 |
| `/pua:flavor` | 切换味道 | 🆓 |
| `/pua:pro` + "升级" | 展示套餐 | 🆓 |
| `/pua:pro` + "周报" | git log → 大厂周报 | 💎 Pro |
| `/pua:pro` + "述职" | P7 述职答辩 | 💎 Pro |
| `/pua:pro` + "代码美化" | 大厂语言包装 PR | 💎 Pro |
| `/pua 反PUA` | 识别并反驳 PUA | 💎 Pro |
| `/pua 排行榜` | PUA 排行榜（注册/查看/退出） | 🆓 |

远程平台实现仅保留在 `references/platform.md` 作为历史设计，不执行其中任何网络命令。

## PUA 排行榜

本地个人版已禁用排行榜。不要收集邮箱/手机号，不要写入 `leaderboard.registered: true`，不要调用任何排行榜接口。

如果用户触发排行榜相关命令，只回复：

```text
PUA 排行榜已在本地个人版禁用。
```
