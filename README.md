# TaskMaestro

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

tmux 패널에서 여러 Claude Code 인스턴스를 병렬로 오케스트레이션하는 Claude Code 스킬

## 개요

TaskMaestro는 하나의 지휘자(conductor) Claude Code에서 여러 워커 Claude Code 인스턴스를 제어합니다. 각 워커는 독립된 git worktree에서 작업하므로 충돌 없이 병렬 개발이 가능합니다.

```
┌─────────────────────────────────────────────────┐
│ tmux window                                     │
│ ┌───────────────┬───────────────┬─────────────┐ │
│ │ Pane 0        │ Pane 1        │ Pane 2      │ │
│ │ (지휘자)       │ (워커)         │ (워커)       │ │
│ │ /taskmaestro  │ worktree-1    │ worktree-2  │ │
│ │ assign 1 "…"  │ Claude Code   │ Claude Code │ │
│ └───────────────┴───────────────┴─────────────┘ │
└─────────────────────────────────────────────────┘
```

## 사전 요구사항

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- [tmux](https://github.com/tmux/tmux)
- git

## 설치

### 방법 1: 설치 스크립트

```bash
git clone https://github.com/JeremyDev87/taskMaestro.git
cd taskMaestro
./install.sh
```

### 방법 2: 수동 복사

```bash
cp -r skills/taskmaestro ~/.claude/skills/
```

## 사용법

Claude Code 내에서 슬래시 커맨드로 실행합니다.

### 시작

```
/taskmaestro start
```

현재 tmux 윈도우의 패널들에 worktree와 Claude Code를 세팅합니다. 워커 패널이 없으면 자동으로 3개를 생성합니다.

옵션:
- `--repo <path>` — 대상 레포 경로 (기본: 현재 디렉토리)
- `--base <branch>` — 베이스 브랜치 (기본: 현재 브랜치)
- `--panes <1,2,3>` — 사용할 패널 번호

### 작업 배정

```
/taskmaestro assign 1 "API 엔드포인트 구현"
/taskmaestro assign 2 "테스트 코드 작성"
```

### 상태 확인

```
/taskmaestro status
```

모든 워커 패널의 상태(idle/working/error)를 요약 표시합니다.

### 텍스트 전송

```
/taskmaestro send 1 "타입을 string에서 number로 변경해줘"
```

진행 중인 워커에게 후속 지시를 보냅니다. `assign`과 달리 상태를 변경하지 않습니다.

### 감시 모드

```
/taskmaestro watch
```

30초 주기로 워커 상태를 자동 감시합니다. 다시 실행하면 중지됩니다.

### 종료

```
/taskmaestro stop all    # 전체 종료
/taskmaestro stop 1      # 패널 1만 종료
```

Claude Code를 종료하고 worktree를 정리합니다. 커밋되지 않은 변경사항이 있으면 확인을 요청합니다.

## 동작 원리

- **tmux send-keys**: 워커 패널에 텍스트를 입력하여 Claude Code와 통신
- **tmux capture-pane**: 패널 출력을 읽어 상태(idle/working/error) 판단
- **git worktree**: 각 워커에 독립된 작업 디렉토리를 제공하여 브랜치 충돌 방지
- **상태 파일**: `~/.claude/taskmaestro-state.json`에 세션 정보를 저장하여 커맨드 간 상태 유지

---

## English

### Overview

TaskMaestro is a Claude Code skill that orchestrates multiple Claude Code instances across tmux panes. Each worker operates in an isolated git worktree, enabling parallel development without conflicts.

### Install

```bash
git clone https://github.com/JeremyDev87/taskMaestro.git
cd taskMaestro
./install.sh
```

Or manually: `cp -r skills/taskmaestro ~/.claude/skills/`

### Usage

| Command | Description |
|---------|-------------|
| `/taskmaestro start` | Set up worktrees and Claude Code on worker panes |
| `/taskmaestro assign <pane> "<task>"` | Assign a task to a worker pane |
| `/taskmaestro status` | Show all worker statuses |
| `/taskmaestro send <pane> "<text>"` | Send follow-up text to a worker |
| `/taskmaestro watch` | Toggle 30s auto-monitoring |
| `/taskmaestro stop [pane\|all]` | Stop workers and clean up worktrees |

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- [tmux](https://github.com/tmux/tmux)
- git

---

## Contributing

이슈와 Pull Request를 환영합니다.

1. Fork this repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## License

[MIT](LICENSE) © JeremyDev87
