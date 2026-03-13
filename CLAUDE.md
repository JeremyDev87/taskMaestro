# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TaskMaestro는 tmux 패널 오케스트레이터 스킬이다. 현재 tmux 세션의 패널들에서 여러 Claude Code 인스턴스를 병렬로 실행하고, 지휘자(conductor) 패널에서 작업 배정·상태 감시·종료를 제어한다. 각 워커 패널은 독립된 git worktree에서 작업한다.

## Architecture

- `skills/taskmaestro/SKILL.md`: 스킬 정의 파일. `/taskmaestro` 슬래시 커맨드의 전체 동작을 기술한다.
- `install.sh`: 스킬을 `~/.claude/skills/taskmaestro/`에 설치하는 POSIX 셸 스크립트.
- 상태 파일: `~/.claude/taskmaestro-state.json`에 세션·패널·worktree 매핑 정보를 저장한다.
- Worktree 디렉토리: 대상 레포의 `.taskmaestro/wt-<패널번호>/`에 생성된다.

## Subcommands

| 커맨드 | 설명 |
|--------|------|
| `start [--repo <path>] [--base <branch>] [--panes <1,2,3>]` | 워커 패널에 worktree + Claude Code 세팅 |
| `assign <패널번호> "<작업>"` | 특정 패널에 작업 배정 |
| `send <패널번호> "<텍스트>"` | 패널에 텍스트 직접 전송 (상태 미변경) |
| `status` | 전체 워커 상태 요약 |
| `watch` | 30초 주기 감시 모드 토글 |
| `stop [패널번호\|all]` | Claude Code 종료 및 worktree 정리 |

## Key Design Decisions

- tmux `send-keys`를 통해 워커 Claude Code와 통신한다. 직접 API 호출이 아닌 터미널 입력 시뮬레이션 방식.
- `unset CLAUDECODE`로 환경변수를 해제해야 워커 패널에서 Claude Code 중첩 실행이 가능하다.
- `capture-pane`으로 패널 출력을 읽어 상태(idle/working/error)를 판단한다.
- Watch 모드는 CronCreate 기반이며, 세션 종속적이고 3일 후 자동 만료된다.
- `stop`시 uncommitted changes가 있으면 사용자에게 확인 후 처리한다.
