---
name: taskmaestro
description: Use when orchestrating parallel Claude Code instances across tmux panes with git worktree isolation — managing multiple concurrent development tasks visually
argument-hint: <start|assign|status|watch|send|stop> [args...]
user-invocable: true
---

# TaskMaestro — tmux 패널 오케스트레이터

현재 tmux 세션의 기존 패널들에서 Claude Code를 병렬로 실행하고, 이 패널(지휘자)에서 제어한다.
각 패널은 독립된 git worktree에서 작업하며, 지휘자가 작업 지시, 상태 감시를 수행한다.

**전제 조건:** 지휘자(이 Claude Code)가 tmux 패널 중 하나에서 실행 중이어야 하며, 나머지 패널들이 이미 열려있어야 한다.

## Arguments 파싱

`$ARGUMENTS`를 파싱하여 서브커맨드와 인수를 분리한다:

- `start [--repo <path>] [--base <branch>] [--panes <1,2,3>]`
- `assign <패널번호> "<작업 지시>"`
- `status`
- `watch`
- `send <패널번호> "<텍스트>"`
- `stop [패널번호|all]`

서브커맨드에 해당하는 섹션으로 이동한다.

## 현재 tmux 환경 감지

모든 서브커맨드에서 먼저 실행:

```bash
# 현재 tmux 소켓, 세션, 윈도우 정보를 자동 감지
TMUX_SOCKET=$(tmux display-message -p '#{socket_path}')
# 소켓 이름 추출 (경로에서 마지막 부분)
SOCKET_NAME=$(basename "$TMUX_SOCKET")
SESSION=$(tmux display-message -p '#{session_name}')
WIN_IDX=$(tmux display-message -p '#{window_index}')
MY_PANE=$(tmux display-message -p '#{pane_index}')
```

> tmux 명령어에서 `-L` 플래그는 소켓 이름을 사용한다. `tmux -L "$SOCKET_NAME" send-keys ...` 형태로 사용.

---

## Worker Completion Signaling (RESULT.json)

Workers write a `RESULT.json` file to their worktree root upon task completion,
providing a structured and reliable signal to the conductor. This file is the
**primary detection mechanism** in watch mode; `capture-pane` serves only as a fallback.

### RESULT.json Schema

```json
{
  "status": "success | failure | error",
  "issue": "#123",
  "pr_number": 42,
  "pr_url": "https://github.com/org/repo/pull/42",
  "timestamp": "2026-03-22T01:13:00.000Z",
  "cost": "$0.45",
  "error": null
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `status` | `"success" \| "failure" \| "error"` | ✅ | `success`: PR created, `failure`: task failed (tests, build, etc.), `error`: unexpected crash |
| `issue` | `string \| null` | ❌ | Related issue number (e.g. `"#123"`) |
| `pr_number` | `number \| null` | ❌ | Created PR number |
| `pr_url` | `string \| null` | ❌ | Created PR URL |
| `timestamp` | `string` | ✅ | ISO 8601 completion time |
| `cost` | `string \| null` | ❌ | Session cost estimate (e.g. `"$0.45"`) |
| `error` | `string \| null` | ❌ | Error message (when `status` is `"error"`) |

### File Path Rules

- Location: `<repo>/.taskmaestro/wt-<N>/RESULT.json` (each worker's worktree root)
- Workers write this file **just before session end** (after commit/PR creation)
- The conductor detects worker completion by checking for this file's existence
- **RESULT.json must NEVER be committed to git** — it is an ephemeral per-worktree artifact

### 2-Tier Detection Strategy

1. **Primary**: Check `RESULT.json` in each worktree — fast, structured, reliable
2. **Fallback**: `capture-pane` prompt-pattern matching — only when no RESULT.json exists

### Worker Completion Protocol

Include this instruction in every worker task directive:

> When your task is complete (PR created or error encountered), write a `RESULT.json`
> file to the worktree root with the appropriate status and fields.

---

## Shell Script Safety Rules

### Array Indexing Ban

Array indexing behaves differently between bash and zsh, causing silent bugs:

```bash
# ❌ BANNED — index mismatch between shells
# bash: arr[0] is first element
# zsh:  arr[1] is first element (0-indexed requires setopt)
PANES=(1 2 3)
echo "${PANES[0]}"  # Different result in bash vs zsh!

# ✅ REQUIRED — explicit key:value mapping
PANE_1_TASK="implement API"
PANE_2_TASK="write tests"
# Or use associative arrays with explicit keys
```

**Rule:** Never use numeric array indexing in shell scripts. Use explicit variable names or associative arrays with string keys.

---

## Session Management

### Compact Cadence

For long-running orchestration sessions, context can grow large. Follow these guidelines:

- **Watch mode** produces periodic status reports — keep them concise (summary table only)
- **Conductor decisions** should be logged to `~/.claude/taskmaestro-state.json`, not kept in conversation context
- When the conductor's context gets large, summarize completed waves and focus on the current wave
- CronCreate jobs are tied to the current Claude Code session and auto-expire after 7 days
- If the session ends or expires, watch mode stops — run `/taskmaestro watch` again to restart

---

## Subcommand: start

`/taskmaestro start [--repo <path>] [--base <branch>] [--panes <1,2,3>]`

현재 세션의 기존 패널들에 worktree + Claude Code를 세팅한다.

### Step 1: 인수 파싱 및 기본값 설정

- `--repo`: 대상 레포 경로 (기본값: 현재 작업 디렉토리)
- `--base`: 베이스 브랜치 (기본값: 현재 브랜치)
- `--panes`: 사용할 패널 번호 목록 (기본값: 지휘자 패널을 제외한 모든 패널)

### Step 2: 사전 검증

```bash
# repo가 git 레포인지 확인
git -C "$REPO" rev-parse --git-dir
```

에러 시 "대상 경로가 git 레포지토리가 아닙니다" 출력 후 중단.

```bash
# 사용 가능한 패널 목록 확인 (지휘자 패널 제외)
tmux -L "$SOCKET_NAME" list-panes -t "$SESSION:$WIN_IDX" -F '#{pane_index} #{pane_current_command}'
```

지휘자 패널($MY_PANE)을 제외한 패널들이 워커 대상이 된다. `--panes`로 지정하지 않으면 모든 비활성 패널을 사용한다.

**워커 패널이 없는 경우:** 지휘자 패널만 존재하면, 첫 번째 숫자 인수(기본값 3)만큼 새 패널을 생성한다:

```bash
PANE_COUNT=${1:-3}  # 기본 3개
DIR=$(cd "$REPO" && pwd)

for ((i = 0; i < PANE_COUNT; i++)); do
  tmux -L "$SOCKET_NAME" split-window -t "$SESSION:$WIN_IDX" -c "$DIR"
  tmux -L "$SOCKET_NAME" select-layout -t "$SESSION:$WIN_IDX" tiled
done

# 지휘자 패널로 포커스 복귀
tmux -L "$SOCKET_NAME" select-pane -t "$SESSION:$WIN_IDX.$MY_PANE"
```

생성 후 다시 패널 목록을 조회하여 워커 패널을 결정한다.

### Step 3: 기존 상태 파일 확인

```bash
cat ~/.claude/taskmaestro-state.json 2>/dev/null
```

이미 활성 세션이 존재하면 AskUserQuestion으로 사용자에게 질문:
- "기존 세션에 연결" → 기존 세션 정보를 로드하고 종료
- "기존 세션 정리 후 새로 생성" → 기존 worktree/세션을 정리하고 계속 진행

### Step 4: worktree 생성

```bash
TIMESTAMP=$(date +%s)
DIR=$(cd "$REPO" && pwd)
BASE_BRANCH="${BASE:-$(git -C "$DIR" branch --show-current)}"

mkdir -p "$DIR/.taskmaestro"

# .gitignore에 .taskmaestro/ 추가
grep -qxF '.taskmaestro/' "$DIR/.gitignore" 2>/dev/null || echo '.taskmaestro/' >> "$DIR/.gitignore"

# 각 워커 패널에 대해 worktree 생성
for PANE_IDX in $WORKER_PANES; do
  BRANCH="taskmaestro/$TIMESTAMP/pane-$PANE_IDX"
  WT_PATH="$DIR/.taskmaestro/wt-$PANE_IDX"
  if [ -d "$WT_PATH" ]; then
    if git -C "$DIR" worktree list | grep -q "$WT_PATH"; then
      git -C "$DIR" worktree remove "$WT_PATH" --force
    else
      rm -rf "$WT_PATH"
    fi
  fi
  git -C "$DIR" worktree add "$WT_PATH" -b "$BRANCH" "$BASE_BRANCH"
done
```

### Step 5: 각 패널에 Claude Code 실행

```bash
for PANE_IDX in $WORKER_PANES; do
  tmux -L "$SOCKET_NAME" send-keys -t "$SESSION:$WIN_IDX.$PANE_IDX" \
    "unset CLAUDECODE && cd $DIR/.taskmaestro/wt-$PANE_IDX && claude --dangerously-skip-permissions" Enter
done
```

> **중요:** 지휘자 Claude Code 세션의 tmux 패널은 `CLAUDECODE` 환경변수를 상속받아 중첩 실행이 차단된다. `unset CLAUDECODE`로 해제해야 한다.

### Step 6: 초기 프롬프트 자동 처리

Claude Code 시작 시 trust 프롬프트와 약관 동의 프롬프트가 나타날 수 있다:

```bash
# 10초 대기 후 trust 프롬프트 승인 (Enter = "Yes, I trust")
sleep 10
for PANE_IDX in $WORKER_PANES; do
  tmux -L "$SOCKET_NAME" send-keys -t "$SESSION:$WIN_IDX.$PANE_IDX" Enter
done

# 3초 대기 후 약관 동의 프롬프트 처리 (Down → "Yes, I accept" → Enter)
sleep 3
for PANE_IDX in $WORKER_PANES; do
  tmux -L "$SOCKET_NAME" send-keys -t "$SESSION:$WIN_IDX.$PANE_IDX" Down
done
sleep 1
for PANE_IDX in $WORKER_PANES; do
  tmux -L "$SOCKET_NAME" send-keys -t "$SESSION:$WIN_IDX.$PANE_IDX" Enter
done
```

> 이미 동의한 환경에서는 이 프롬프트가 나타나지 않을 수 있다. send-keys는 무해하게 무시된다.

10초 대기 후 각 패널의 Claude Code가 프롬프트(`❯`) 상태인지 capture-pane으로 확인한다.

### Step 7: 상태 파일 기록

`~/.claude/taskmaestro-state.json`에 세션 정보를 기록한다.

```json
{
  "socket_name": "workspace-1",
  "session": "workspace-1",
  "window_index": 0,
  "conductor_pane": 0,
  "repo": "절대경로",
  "base_branch": "브랜치",
  "created_at": "ISO timestamp",
  "watch_cron_id": null,
  "panes": [
    {"index": 1, "worktree": "절대경로/.taskmaestro/wt-1", "branch": "taskmaestro/ts/pane-1", "task": null, "status": "idle"},
    {"index": 2, "worktree": "절대경로/.taskmaestro/wt-2", "branch": "taskmaestro/ts/pane-2", "task": null, "status": "idle"},
    {"index": 3, "worktree": "절대경로/.taskmaestro/wt-3", "branch": "taskmaestro/ts/pane-3", "task": null, "status": "idle"}
  ]
}
```

### Step 8: watch 자동 시작

CronCreate로 30초 주기 cron job을 생성하여 watch 모드를 자동 시작한다.
생성된 cron job ID를 상태 파일의 `watch_cron_id`에 기록한다.

프롬프트: 각 패널의 상태를 capture-pane으로 확인하고, 에러 상태 패널이 있으면 사용자에게 알린다.

### Step 9: 결과 보고

사용자에게 보고:
```
TaskMaestro 시작 완료!

  세션: workspace-1
  레포: /path/to/repo
  지휘자: 패널 0
  워커: 패널 1, 2, 3
  베이스: main

/taskmaestro assign <번호> "작업" 으로 작업을 배정하세요.
/taskmaestro status 로 상태를 확인하세요.
```

---

## Subcommand: assign

`/taskmaestro assign <패널 번호> "<작업 지시>"`

특정 패널의 Claude Code에 새 작업을 배정한다. 상태 파일의 task/status를 업데이트한다.

### Step 1: 상태 파일 로드 및 검증

```bash
cat ~/.claude/taskmaestro-state.json
```

소켓/세션/윈도우 정보를 가져온다.
패널 번호가 워커 패널 목록에 포함되는지 검증한다. 지휘자 패널이거나 존재하지 않는 패널이면 에러 출력 후 중단.

### Step 2: 작업 전송 (3-tier context delivery)

The conductor uses a 3-tier fallback chain to deliver task context to workers,
solving the problem of `send-keys` truncating long prompts:

**Tier 1 (preferred): TASK.md file**

Write the full task directive to the worker's worktree, then send a short prompt:

```bash
# Write TASK.md to worktree root
cat > "$REPO/.taskmaestro/wt-$PANE/TASK.md" << 'TASKEOF'
# Task: <task description>

<full task context, acceptance criteria, file list, etc.>

---
[MANDATORY PRE-PUSH VERIFICATION]
Before pushing, run and pass ALL checks:
1. yarn prettier --write .
2. yarn lint --fix
3. yarn type-check
4. yarn test

[COMPLETION PROTOCOL]
When done, write RESULT.json to the worktree root with status/issue/pr_number/etc.
TASKEOF

# Send short prompt referencing TASK.md
tmux -L "$SOCKET_NAME" send-keys -t "$SESSION:$WIN_IDX.$PANE" \
  "Read TASK.md in the current directory and execute the task described in it. Follow ALL instructions including pre-push verification and completion protocol." Enter
```

**Tier 2 (fallback): GitHub issue reference**

When the task has a corresponding GitHub issue:
```bash
tmux -L "$SOCKET_NAME" send-keys -t "$SESSION:$WIN_IDX.$PANE" \
  "Read the issue with gh issue view <NUMBER> and implement it. Write RESULT.json when done." Enter
```

**Tier 3 (last resort): Inline prompt**

For short, simple tasks that fit in a single send-keys:
```bash
tmux -L "$SOCKET_NAME" send-keys -t "$SESSION:$WIN_IDX.$PANE" "<작업 지시>" Enter
```

> **Note:** TASK.md is an ephemeral artifact — it must NEVER be committed to git.

### Step 3: 상태 파일 업데이트

해당 패널의 task와 status를 업데이트한다:
- `task`: 작업 지시 내용
- `status`: "working"

### Step 4: 결과 보고

```
패널 $PANE에 작업을 배정했습니다: "<작업 지시>"
```

---

## Subcommand: send

`/taskmaestro send <패널 번호> "<텍스트>"`

특정 패널에 텍스트를 직접 전송한다.
이미 진행 중인 작업에 후속 지시나 응답을 보낼 때 사용한다.
assign과 달리 상태 파일의 task/status를 변경하지 않는다.

### Step 1: 상태 파일 로드 및 검증

소켓/세션/윈도우 정보를 가져온다.
패널 번호 유효성 검증.

### Step 2: 텍스트 전송

```bash
tmux -L "$SOCKET_NAME" send-keys -t "$SESSION:$WIN_IDX.$PANE" "<텍스트>" Enter
```

### Step 3: 결과 보고

```
패널 $PANE에 전송 완료: "<텍스트>"
```

---

## Subcommand: status

`/taskmaestro status`

모든 워커 패널의 현재 상태를 수집하여 요약 보고한다.

### Step 1: 상태 파일 로드

```bash
cat ~/.claude/taskmaestro-state.json
```

### Step 2: RESULT.json 확인 (1차 감지)

각 워커 패널의 worktree에서 RESULT.json 존재 여부를 먼저 확인한다:

```bash
for PANE_IDX in $WORKER_PANES; do
  RESULT_FILE="$REPO/.taskmaestro/wt-$PANE_IDX/RESULT.json"
  if [ -f "$RESULT_FILE" ]; then
    STATUS=$(cat "$RESULT_FILE" | jq -r '.status')
    PR_NUMBER=$(cat "$RESULT_FILE" | jq -r '.pr_number // empty')
    # → status 값에 따라 적절한 상태 아이콘과 메시지 표시
  fi
done
```

### Step 3: capture-pane fallback (2차 감지)

RESULT.json이 없는 패널에 대해서만 capture-pane으로 상태를 확인한다:

```bash
for PANE_IDX in $NO_RESULT_PANES; do
  tmux -L "$SOCKET_NAME" capture-pane -t "$SESSION:$WIN_IDX.$PANE_IDX" -p -S -30 | tail -15
done
```

캡처된 내용을 분석:
- 마지막 줄에 Claude Code 프롬프트 (`❯` 또는 `>` 로 시작하는 입력 대기) → "idle"
- 도구 실행 중 (스피너, 코드 출력 진행 중) → "working"
- 에러 패턴 (`Error`, `error`, `failed`, `FAIL`) → "error"

### Step 4: Cross-Validation

RESULT.json and capture-pane MUST agree. When they conflict, flag as uncertain:

| RESULT.json | Pane State | Verdict |
|-------------|------------|---------|
| `success` | idle (❯) | ✅ Confirmed done |
| `success` | active | ⚠️ UNCERTAIN — investigate |
| absent | idle | Needs nudge |
| absent | active (tokens flowing) | 🔄 Confirmed working |
| `failure`/`error` | any | ❌ Failed/Error |

### Step 5: Evidence-Based Status Report

Every status line MUST include parenthetical evidence:

```
TaskMaestro Status (workspace-1):

  Pane 1: ✅ done - "API endpoints" → PR #42 (RESULT.json: success, pane idle ✓)
  Pane 2: 🔄 working - "Auth feature" (active: ✽ Implementing… · ↓ 5.3k tokens)
  Pane 3: ⚠️ uncertain - "Cache layer" (RESULT.json exists BUT pane still active)
  Pane 4: ❌ error - "DB migration" (error in last 30 lines: "ModuleNotFoundError")
  Pane 5: ⏸️ idle - no task assigned (❯ prompt visible, no RESULT.json)
```

**Status icons:**

| Status | Icon | Description |
|--------|------|-------------|
| done (RESULT.json success + pane idle) | ✅ | Confirmed complete |
| working (pane active, tokens flowing) | 🔄 | Confirmed working |
| idle (no task, ❯ prompt) | ⏸️ | Awaiting assignment |
| error/failure | ❌ | Task failed |
| uncertain (RESULT.json + pane active) | ⚠️ | Cross-validation conflict |

**Rules:**
- Never report bare ✅ without evidence
- Active spinner + token flow = confirmed working
- "thinking" alone ≠ working — check token count changes between cycles
- Error scan depth: **30+ lines** (not just last 8)
- RESULT.json + pane active = UNCERTAIN (investigate before reporting done)

---

## Subcommand: watch

`/taskmaestro watch`

주기적 감시 모드를 토글한다 (시작/중지).

### Detection Strategy (2-tier)

The watch cron prompt uses a 2-tier detection strategy:

```
# Tier 1: Check RESULT.json in each worktree (fast, structured)
for PANE_IDX in $WORKER_PANES; do
  RESULT_FILE="$REPO/.taskmaestro/wt-$PANE_IDX/RESULT.json"
  if [ -f "$RESULT_FILE" ]; then
    # Parse status and report
    STATUS=$(jq -r '.status' "$RESULT_FILE")
    case "$STATUS" in
      success) report "Pane $PANE_IDX: ✅ done" ;;
      failure) report "Pane $PANE_IDX: ❌ failed" ;;
      error)   report "Pane $PANE_IDX: ❌ error" ;;
    esac
  fi
done

# Tier 2: capture-pane fallback for panes without RESULT.json
for PANE_IDX in $NO_RESULT_PANES; do
  tmux capture-pane ... | analyze idle/working/error
done
```

### 시작 (watch_cron_id가 null인 경우)

1. 상태 파일에서 정보 로드
2. CronCreate로 30초 주기 cron job 생성:
   - 프롬프트: 먼저 각 워커의 RESULT.json을 확인하고, 없는 패널에 대해서만 capture-pane으로 상태 확인. 에러 상태 패널이 있으면 사용자에게 알린다. Claude Code가 비정상 종료된 패널이 있으면 재시작 여부를 사용자에게 질문한다.
3. cron job ID를 상태 파일의 `watch_cron_id`에 기록
4. 보고: "Watch 모드를 시작합니다 (30초 주기). 중지하려면 `/taskmaestro watch`를 다시 실행하세요."

### 중지 (watch_cron_id가 존재하는 경우)

1. 상태 파일에서 `watch_cron_id` 확인
2. CronDelete로 해당 cron job 제거
3. `watch_cron_id`를 null로 업데이트
4. 보고: "Watch 모드를 중지했습니다."

### Auto-Nudge Protocol

When a pane is detected as idle (❯ prompt visible) but its task status is "working",
the watch loop automatically prods the worker back into action using escalating levels:

| Nudge # | Action | Message |
|---------|--------|---------|
| 1 | Gentle continue | `send-keys "continue" Enter` |
| 2 | Specific continue | `send-keys "continue with the next incomplete task" Enter` |
| 3+ | Explicit instruction | Send full task context with specific next step |

Implementation in the watch cron prompt:

```
For each pane where status == "working":
  Check if idle (❯ prompt visible via capture-pane)
  If idle:
    nudge_count[pane] += 1
    if nudge_count <= 1:
      send-keys "continue" Enter
    elif nudge_count == 2:
      send-keys "continue with the next incomplete task" Enter
    else:
      send-keys with explicit instruction including task context from state file
    Report: "Pane N: IDLE → auto-nudged (#count)"
  Else:
    nudge_count[pane] = 0  # Reset on active detection
```

**Stall detection:** A pane is considered stalled if idle for 3+ consecutive watch cycles (90s+).
After 3 nudges with no response, report to user for manual intervention.

### 제한 사항

CronCreate job은 현재 Claude Code 세션에 종속되며, 7일 후 자동 만료된다.
세션이 종료되거나 만료 시 watch도 중단된다. 재시작하려면 `/taskmaestro watch`를 다시 실행한다.

---

## Subcommand: stop

`/taskmaestro stop [패널 번호|all]`

Claude Code를 종료하고 worktree를 정리한다.

### 인수 파싱

- 인수 없음 또는 `all`: 모든 워커 패널 종료
- 숫자: 해당 패널만 종료

### 단일 패널 종료

1. 패널 번호가 워커 패널인지 검증. 아니면 에러 출력 후 중단.
2. 해당 패널에 Claude Code 종료 전송:
   ```bash
   tmux -L "$SOCKET_NAME" send-keys -t "$SESSION:$WIN_IDX.$PANE" "/exit" Enter
   ```
3. 5초 대기 후 worktree 정리:
   ```bash
   # uncommitted changes 확인
   if git -C "$WORKTREE_PATH" diff --quiet && git -C "$WORKTREE_PATH" diff --cached --quiet; then
     git -C "$REPO" worktree remove "$WORKTREE_PATH"
   else
     # AskUserQuestion으로 사용자에게 알림
     # "패널 N의 worktree에 커밋되지 않은 변경사항이 있습니다. 강제 삭제할까요?"
     # Yes → git worktree remove --force
     # No → worktree 보존, 경로 안내
   fi
   ```
4. 패널 닫기:
   ```bash
   tmux -L "$SOCKET_NAME" kill-pane -t "$SESSION:$WIN_IDX.$PANE"
   ```
5. 상태 파일에서 해당 패널 정보 제거
6. 보고: `패널 N을 종료했습니다. (브랜치 taskmaestro/xxx/pane-N 유지됨)`

### 전체 종료 (all)

1. watch cron 중지 (활성 상태인 경우 CronDelete)
2. 각 워커 패널에 `/exit` 전송
3. 5초 대기
4. 각 worktree 정리 (uncommitted changes 확인 포함)
5. 워커 패널들 닫기 (역순으로):
   ```bash
   for PANE_IDX in $(echo "$WORKER_PANES" | sort -rn); do
     tmux -L "$SOCKET_NAME" kill-pane -t "$SESSION:$WIN_IDX.$PANE_IDX"
   done
   ```
6. `.taskmaestro/` 디렉토리가 비었으면 삭제:
   ```bash
   rmdir "$REPO/.taskmaestro" 2>/dev/null
   ```
7. 상태 파일 초기화
8. 보고:
   ```
   TaskMaestro 종료 완료.
     정리된 워커: N개
     유지된 브랜치: taskmaestro/xxx/pane-1, pane-2, ...
   ```

> **주의:** `stop all`은 tmux 세션을 종료하지 않는다. 패널들은 그대로 남아있으며 zsh 상태로 돌아간다.
