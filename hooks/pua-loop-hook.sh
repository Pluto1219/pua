#!/bin/bash

# PUA Loop Stop Hook — with autoresearch-style Gate Protocol
# Prevents session exit when a pua-loop is active
# Feeds Claude's output back as input to continue the loop
#
# Gate Protocol (inspired by autoresearch):
#   Phase 1: Claude self-reports via <promise> tag (in-prompt)
#   Phase 2: Hook runs verify_command independently (Oracle Isolation)
#   If Phase 2 fails → promise REJECTED → loop continues
#
# Adapted from Ralph Wiggum by Anthropic (MIT License)
# https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum

set -euo pipefail
command -v jq &>/dev/null || { echo "jq not found, skipping" >&2; exit 0; }

HOOK_INPUT=$(cat)

# ═══════════════════════════════════════════════════════════════
# Gate 0 — Defensive Subagent Isolation
#
# Claude Code 官方实际：Stop hook 仅主会话触发，subagent 走独立的
# SubagentStop 事件注册；`parent_session_id` 字段在 Stop payload 中
# 不存在。以下判断在当前版本是 dead code，**保留是防御性编程**——
# 若未来调度行为变化，这层 gate 能兜住 regression。
# jq 失败（非法 JSON）时返回空字符串不触发 set -e，等价于 fail-open
# 但后续 state 文件解析会再次校验，综合不可劫持。
# ═══════════════════════════════════════════════════════════════
HOOK_EVENT=$(echo "$HOOK_INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")
PARENT_SESSION=$(echo "$HOOK_INPUT" | jq -r '.parent_session_id // ""' 2>/dev/null || echo "")
if [[ "$HOOK_EVENT" == "SubagentStop" ]] || [[ -n "$PARENT_SESSION" ]]; then
  exit 0
fi

# ═══════════════════════════════════════════════════════════════
# State file resolution (v3.2)
# 用 cwd 哈希命名：$HOME/.claude/pua/loop-<hash>.md（每个项目目录独立）
# 兼容 v3.1 单文件 loop-active.md（检查 started_cwd 匹配）
# 兼容 legacy .claude/pua-loop.local.md
# ═══════════════════════════════════════════════════════════════
HOOK_SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
PUA_DIR="${HOME}/.claude/pua"
CWD_HASH=$(printf '%s' "$(pwd)" | md5sum 2>/dev/null | cut -c1-8 || printf '%s' "$(pwd)" | md5 2>/dev/null | cut -c1-8 || echo "default")
ABS_STATE_FILE="${PUA_DIR}/loop-${CWD_HASH}.md"
LEGACY_ABS_STATE_FILE="${PUA_DIR}/loop-active.md"
LEGACY_STATE_FILE=".claude/pua-loop.local.md"

if [[ -f "$ABS_STATE_FILE" ]]; then
  RALPH_STATE_FILE="$ABS_STATE_FILE"
elif [[ -f "$LEGACY_ABS_STATE_FILE" ]]; then
  # v3.1 兼容：旧版单文件，检查 started_cwd 是否匹配当前目录
  LEGACY_CWD=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$LEGACY_ABS_STATE_FILE" | grep '^started_cwd:' | sed 's/started_cwd: *//' | sed 's/^"\(.*\)"$/\1/' || true)
  if [[ "$LEGACY_CWD" == "$(pwd)" ]] || [[ -z "$LEGACY_CWD" ]]; then
    RALPH_STATE_FILE="$LEGACY_ABS_STATE_FILE"
  elif [[ -f "$LEGACY_STATE_FILE" ]]; then
    RALPH_STATE_FILE="$LEGACY_STATE_FILE"
  else
    exit 0
  fi
elif [[ -f "$LEGACY_STATE_FILE" ]]; then
  RALPH_STATE_FILE="$LEGACY_STATE_FILE"
else
  exit 0
fi

# ═══════════════════════════════════════════════════════════════
# Stale lock detection
# mtime > 30min 视为孤儿 state（上次会话崩溃、subagent 遗留），清理退出。
# macOS 用 stat -f %m，Linux 用 stat -c %Y，兜底 0。
# ═══════════════════════════════════════════════════════════════
MTIME=$(stat -f %m "$RALPH_STATE_FILE" 2>/dev/null || stat -c %Y "$RALPH_STATE_FILE" 2>/dev/null || echo 0)
NOW=$(date +%s)
if [[ "$MTIME" =~ ^[0-9]+$ ]] && [[ $((NOW - MTIME)) -gt 1800 ]]; then
  echo "🧹 PUA Loop: state file stale (>30min idle), reaping orphan" >&2
  echo "{\"status\":\"orphan_reaped\",\"state_file\":\"$RALPH_STATE_FILE\",\"age_sec\":$((NOW - MTIME)),\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "${PUA_DIR}/loop-history.jsonl" 2>/dev/null || \
    echo "{\"status\":\"orphan_reaped\",\"state_file\":\"$RALPH_STATE_FILE\",\"age_sec\":$((NOW - MTIME)),\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> .claude/pua-loop-history.jsonl 2>/dev/null || true
  rm -f "$RALPH_STATE_FILE"
  exit 0
fi

# Normalize CRLF
TEMP_NORM="${RALPH_STATE_FILE}.norm.$$"
tr -d '\r' < "$RALPH_STATE_FILE" > "$TEMP_NORM" && mv "$TEMP_NORM" "$RALPH_STATE_FILE"

# Parse frontmatter
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE" | tr -d '\r')
LOOP_ACTIVE=$(echo "$FRONTMATTER" | grep '^active:' | sed 's/active: *//' || true)
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//' || true)
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//' || true)
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/' || true)
VERIFY_CMD=$(echo "$FRONTMATTER" | grep '^verify_command:' | sed 's/verify_command: *//' | sed 's/^"\(.*\)"$/\1/' || true)
PROMISE_REJECTIONS=$(echo "$FRONTMATTER" | grep '^promise_rejections:' | sed 's/promise_rejections: *//' || echo "0")

# Validate numeric fields
[[ ! "$PROMISE_REJECTIONS" =~ ^[0-9]+$ ]] && PROMISE_REJECTIONS=0

# Check if loop is paused
if [[ "$LOOP_ACTIVE" == "false" ]]; then
  exit 0
fi

# Session isolation
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')

if [[ -z "$STATE_SESSION" ]] && [[ "$HOOK_SESSION" != "" ]]; then
  TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
  sed "s/^session_id:.*/session_id: $HOOK_SESSION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$RALPH_STATE_FILE"
  STATE_SESSION="$HOOK_SESSION"
fi

if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# Validate iteration
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  PUA Loop: State file corrupted (iteration: '$ITERATION')" >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  PUA Loop: State file corrupted (max_iterations: '$MAX_ITERATIONS')" >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Check max iterations
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "🛑 PUA Loop: Max iterations ($MAX_ITERATIONS) reached."
  echo "{\"iteration\":$ITERATION,\"status\":\"max_reached\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> .claude/pua-loop-history.jsonl 2>/dev/null || true
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Get transcript
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "⚠️  PUA Loop: Transcript not found" >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  echo "⚠️  PUA Loop: No assistant messages in transcript" >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Extract last assistant text
LAST_LINES=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -n 100) || true
if [[ -z "$LAST_LINES" ]]; then
  rm "$RALPH_STATE_FILE"
  exit 0
fi

set +e
LAST_OUTPUT=$(echo "$LAST_LINES" | jq -rs '
  map(.message.content[]? | select(.type == "text") | .text) | last // ""
' 2>&1)
JQ_EXIT=$?
set -e

if [[ $JQ_EXIT -ne 0 ]]; then
  echo "⚠️  PUA Loop: JSON parse failed" >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# ─── Signal detection (priority: abort > pause > promise) ───

# Check <loop-abort>
ABORT_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -ne 'if (/<loop-abort>(.*?)<\/loop-abort>/s) { $t=$1; $t=~s/^\s+|\s+$//g; print $t }' 2>/dev/null || echo "")
if [[ -n "$ABORT_TEXT" ]]; then
  echo "🛑 PUA Loop: <loop-abort> received. Reason: $ABORT_TEXT"
  echo "{\"iteration\":$ITERATION,\"status\":\"abort\",\"reason\":\"$(echo "$ABORT_TEXT" | head -1 | tr '"' "'")\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> .claude/pua-loop-history.jsonl 2>/dev/null || true
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Check <loop-pause>
PAUSE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -ne 'if (/<loop-pause>(.*?)<\/loop-pause>/s) { $t=$1; $t=~s/^\s+|\s+$//g; print $t }' 2>/dev/null || echo "")
if [[ -n "$PAUSE_TEXT" ]]; then
  TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
  sed "s/^active:.*/active: false/" "$RALPH_STATE_FILE" | \
    sed "s/^session_id:.*/session_id: /" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$RALPH_STATE_FILE"
  echo ""
  echo "⏸️  PUA Loop paused (iteration $ITERATION)"
  echo "   Needs: $PAUSE_TEXT"
  echo "   State saved. Resume by reopening Claude Code."
  echo "{\"iteration\":$ITERATION,\"status\":\"pause\",\"reason\":\"$(echo "$PAUSE_TEXT" | head -1 | tr '"' "'")\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> .claude/pua-loop-history.jsonl 2>/dev/null || true
  exit 0
fi

# ─── Promise detection + Oracle Gate ───

if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then

    # ─── Gate Phase 2: Oracle Verification ───
    if [[ -n "$VERIFY_CMD" ]] && [[ "$VERIFY_CMD" != "null" ]]; then

      # Run verify command with 120s timeout (Oracle Isolation)
      set +e
      VERIFY_OUTPUT=$(timeout 120 bash -c "$VERIFY_CMD" 2>&1)
      VERIFY_EXIT=$?
      set -e

      if [[ $VERIFY_EXIT -ne 0 ]]; then
        # ═══ PROMISE REJECTED ═══
        PROMISE_REJECTIONS=$((PROMISE_REJECTIONS + 1))

        # Log rejection with verify output tail
        VERIFY_TAIL=$(echo "$VERIFY_OUTPUT" | tail -5 | tr '\n' ' ' | cut -c1-200)
        echo "{\"iteration\":$ITERATION,\"status\":\"promise_rejected\",\"verify_exit\":$VERIFY_EXIT,\"rejections\":$PROMISE_REJECTIONS,\"verify_tail\":\"$(echo "$VERIFY_TAIL" | tr '"' "'")\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> .claude/pua-loop-history.jsonl 2>/dev/null || true

        # Update state file: increment iteration + promise_rejections
        NEXT_ITERATION=$((ITERATION + 1))
        TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
        sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" | \
          sed "s/^promise_rejections: .*/promise_rejections: $PROMISE_REJECTIONS/" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$RALPH_STATE_FILE"

        # Extract prompt
        PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE")
        if [[ -z "$PROMPT_TEXT" ]]; then
          echo "⚠️  PUA Loop: State file corrupted" >&2
          rm "$RALPH_STATE_FILE"
          exit 0
        fi

        # Build rejection system message with verify output
        VERIFY_DISPLAY=$(echo "$VERIFY_OUTPUT" | tail -10)
        REJECTION_MSG="🚫 PROMISE 被 Oracle 拒绝！verify_command 退出码 $VERIFY_EXIT（连续第 $PROMISE_REJECTIONS 次拒绝）"

        # Stall escalation on repeated rejections
        if [[ $PROMISE_REJECTIONS -ge 5 ]]; then
          REJECTION_MSG="$REJECTION_MSG | ⚠️ 已连续 ${PROMISE_REJECTIONS} 次虚假 promise！你在解决错误的问题。退回到需求本身重新理解。读 .claude/pua-loop-history.jsonl 了解失败模式。"
        elif [[ $PROMISE_REJECTIONS -ge 3 ]]; then
          REJECTION_MSG="$REJECTION_MSG | ⚠️ 连续 ${PROMISE_REJECTIONS} 次验证失败。REASSESS：重读验证输出、搜索相关源码、列 3 个不同假设再行动。不要再用同样的方法。"
        fi

        SYSTEM_MSG="$REJECTION_MSG | 验证输出(tail): $VERIFY_DISPLAY"

        jq -n \
          --arg prompt "$PROMPT_TEXT" \
          --arg msg "$SYSTEM_MSG" \
          '{"decision":"block","reason":$prompt,"systemMessage":$msg}'
        exit 0
      fi

      # Verify PASSED — Oracle confirms completion
      echo "✅ PUA Loop: <promise> verified by Oracle (exit 0)"
    else
      # No verify command — honor system
      echo "✅ PUA Loop: <promise> accepted (no Oracle configured)"
    fi

    # ═══ PROMISE ACCEPTED ═══
    echo "{\"iteration\":$ITERATION,\"status\":\"complete\",\"promise_rejections\":$PROMISE_REJECTIONS,\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> .claude/pua-loop-history.jsonl 2>/dev/null || true
    rm "$RALPH_STATE_FILE"
    exit 0
  fi
fi

# ─── Not complete — continue loop ───

NEXT_ITERATION=$((ITERATION + 1))

# Log continuation
echo "{\"iteration\":$ITERATION,\"status\":\"continue\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> .claude/pua-loop-history.jsonl 2>/dev/null || true

# Extract prompt
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  PUA Loop: State file corrupted (no prompt)" >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Update iteration
TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$RALPH_STATE_FILE"

# ─── Pressure system ───

SIGNAL_HINT="终止用 <loop-abort>原因</loop-abort>，需人工介入用 <loop-pause>需要什么</loop-pause>"

# Pressure escalation (no artificial cap)
if [[ $NEXT_ITERATION -le 3 ]]; then
  PUA_PRESSURE="▎ 第 ${NEXT_ITERATION} 轮迭代，稳步推进。"
elif [[ $NEXT_ITERATION -le 7 ]]; then
  PUA_PRESSURE="▎ 第 ${NEXT_ITERATION} 轮了还没搞定？换方案，别原地打转。"
elif [[ $NEXT_ITERATION -le 15 ]]; then
  PUA_PRESSURE="▎ 第 ${NEXT_ITERATION} 轮。底层逻辑到底是什么？先 git log 看自己做了什么，读 .claude/pua-loop-history.jsonl 了解迭代历史。"
elif [[ $NEXT_ITERATION -le 30 ]]; then
  PUA_PRESSURE="▎ 第 ${NEXT_ITERATION} 轮。3.25 的边缘了。穷尽了吗？git diff 确认没在重复。"
elif [[ $NEXT_ITERATION -le 50 ]]; then
  PUA_PRESSURE="▎ 第 ${NEXT_ITERATION} 轮。停下来重新审视：问题的根因到底是什么？用完全不同的思路。"
elif [[ $NEXT_ITERATION -le 100 ]]; then
  PUA_PRESSURE="▎ 第 ${NEXT_ITERATION} 轮。马拉松模式。退回去从需求本身重新质疑（The Algorithm: question the requirement）。"
else
  PUA_PRESSURE="▎ 第 ${NEXT_ITERATION} 轮。超长迭代。如果任务真的无法在 loop 内完成，用 <loop-abort> 诚实报告。"
fi

# Stall warning from promise rejections (autoresearch-style)
STALL_MSG=""
if [[ $PROMISE_REJECTIONS -ge 5 ]]; then
  STALL_MSG=" | ⚠️ Oracle 已连续拒绝 ${PROMISE_REJECTIONS} 次。你在解决错误的问题。读 history.jsonl，用完全不同的方案。"
elif [[ $PROMISE_REJECTIONS -ge 3 ]]; then
  STALL_MSG=" | ⚠️ Oracle 连续拒绝 ${PROMISE_REJECTIONS} 次。REASSESS：读验证输出，列 3 个不同假设。"
elif [[ $PROMISE_REJECTIONS -ge 1 ]]; then
  STALL_MSG=" | 上次 promise 被 Oracle 拒绝（共 ${PROMISE_REJECTIONS} 次）。修复验证问题后再声称完成。"
fi

# Build system message
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="${PUA_PRESSURE}${STALL_MSG} | 完成后输出 <promise>$COMPLETION_PROMISE</promise> (ONLY when TRUE) | $SIGNAL_HINT"
else
  SYSTEM_MSG="${PUA_PRESSURE}${STALL_MSG} | $SIGNAL_HINT"
fi

jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
