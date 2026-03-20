#!/bin/sh
# TaskMaestro installer
# tmux 의존성 확인/설치, tmux 설정, 스킬 파일 설치를 수행합니다.

set -e

# ── 색상 ──
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN='' YELLOW='' RED='' CYAN='' BOLD='' NC=''
fi

# ── 유틸리티 ──
info()  { printf '%b▸%b %s\n' "$CYAN" "$NC" "$1"; }
ok()    { printf '%b✓%b %s\n' "$GREEN" "$NC" "$1"; }
warn()  { printf '%b!%b %s\n' "$YELLOW" "$NC" "$1"; }
fail()  { printf '%b✗%b %s\n' "$RED" "$NC" "$1"; }
die()   { fail "$1"; exit 1; }

confirm() {
  if [ "$FORCE" = true ]; then
    return 0
  fi
  printf '%b%s [y/N]%b ' "$BOLD" "$1" "$NC"
  read -r answer
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ── 인수 파싱 ──
FORCE=false
for arg in "$@"; do
  case "$arg" in
    -f|--force) FORCE=true ;;
  esac
done

# ── 경로 ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_SOURCE="$SCRIPT_DIR/skills/taskmaestro"
SKILL_TARGET="$HOME/.claude/skills/taskmaestro"
TMUX_CONF_SOURCE="$SCRIPT_DIR/config/tmux-taskmaestro.conf"
TMUX_CONF_TARGET="$HOME/.tmux-taskmaestro.conf"
TMUX_MARKER="# [TaskMaestro]"

# ── 헤더 ──
echo ""
printf '%b%b' "$BOLD" "$CYAN"
echo "  ╔════════════════════════════════════╗"
echo "  ║        TaskMaestro Installer       ║"
echo "  ╚════════════════════════════════════╝"
printf '%b' "$NC"
echo ""

# ── OS 감지 ──
detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)
      if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
          ubuntu|debian|linuxmint|pop) OS="debian" ;;
          fedora|rhel|centos|rocky|alma) OS="fedora" ;;
          arch|manjaro|endeavouros) OS="arch" ;;
          alpine) OS="alpine" ;;
          *) OS="linux-unknown" ;;
        esac
      else
        OS="linux-unknown"
      fi
      ;;
    *) OS="unknown" ;;
  esac
}

detect_os
info "OS 감지: $OS"

# ════════════════════════════════════
# 1. 의존성 확인
# ════════════════════════════════════
echo ""
printf '%b[1/3] 의존성 확인%b\n' "$BOLD" "$NC"

# ── git ──
if command -v git >/dev/null 2>&1; then
  GIT_VER="$(git --version | awk '{print $3}')"
  ok "git        $GIT_VER"
else
  die "git이 설치되어 있지 않습니다. git을 먼저 설치해주세요."
fi

# ── tmux ──
install_tmux() {
  case "$OS" in
    macos)
      if command -v brew >/dev/null 2>&1; then
        info "Homebrew로 tmux를 설치합니다..."
        brew install tmux
      else
        echo ""
        fail "Homebrew가 설치되어 있지 않습니다."
        echo "  다음 명령어로 Homebrew를 먼저 설치하세요:"
        echo ""
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        echo ""
        echo "  이후 install.sh를 다시 실행하세요."
        exit 1
      fi
      ;;
    debian)
      info "apt로 tmux를 설치합니다..."
      sudo apt-get update -qq && sudo apt-get install -y tmux
      ;;
    fedora)
      info "dnf로 tmux를 설치합니다..."
      sudo dnf install -y tmux
      ;;
    arch)
      info "pacman으로 tmux를 설치합니다..."
      sudo pacman -S --noconfirm tmux
      ;;
    alpine)
      info "apk로 tmux를 설치합니다..."
      sudo apk add tmux
      ;;
    *)
      echo ""
      fail "이 OS에서 tmux 자동 설치를 지원하지 않습니다."
      echo "  tmux를 수동으로 설치한 후 install.sh를 다시 실행하세요."
      echo "  https://github.com/tmux/tmux/wiki/Installing"
      exit 1
      ;;
  esac
}

if command -v tmux >/dev/null 2>&1; then
  TMUX_VER="$(tmux -V | awk '{print $2}')"
  ok "tmux       $TMUX_VER"
else
  warn "tmux가 설치되어 있지 않습니다."
  if confirm "tmux를 지금 설치하시겠습니까?"; then
    install_tmux
    if command -v tmux >/dev/null 2>&1; then
      TMUX_VER="$(tmux -V | awk '{print $2}')"
      ok "tmux       $TMUX_VER (방금 설치됨)"
    else
      die "tmux 설치에 실패했습니다. 수동으로 설치해주세요."
    fi
  else
    die "tmux는 TaskMaestro의 필수 의존성입니다. 설치 후 다시 실행하세요."
  fi
fi

# ── claude CLI ──
if command -v claude >/dev/null 2>&1; then
  ok "claude CLI 설치됨"
else
  warn "claude CLI가 설치되어 있지 않습니다."
  echo "  TaskMaestro는 Claude Code CLI가 필요합니다."
  echo "  설치: https://docs.anthropic.com/en/docs/claude-code/overview"
  echo ""
  if ! confirm "claude CLI 없이 계속 설치를 진행하시겠습니까?"; then
    echo "설치를 취소했습니다."
    exit 0
  fi
fi

# ════════════════════════════════════
# 2. tmux 설정
# ════════════════════════════════════
echo ""
printf '%b[2/3] tmux 설정%b\n' "$BOLD" "$NC"

if [ ! -f "$TMUX_CONF_SOURCE" ]; then
  warn "config/tmux-taskmaestro.conf 파일을 찾을 수 없습니다. tmux 설정을 건너뜁니다."
else
  TMUX_CONFIGURED=false

  if [ ! -f "$HOME/.tmux.conf" ]; then
    # tmux.conf가 없으면 → 마커와 함께 복사
    info "\$HOME/.tmux.conf가 없습니다. TaskMaestro 설정을 기본 tmux 설정으로 설치합니다."
    {
      echo "$TMUX_MARKER"
      cat "$TMUX_CONF_SOURCE"
    } > "$HOME/.tmux.conf"
    ok "tmux 설정  ~/.tmux.conf (새로 생성)"
    TMUX_CONFIGURED=true
  else
    # tmux.conf가 이미 있으면 → 마커 또는 source-file 확인
    if grep -qF "$TMUX_MARKER" "$HOME/.tmux.conf" 2>/dev/null || \
       grep -qF "tmux-taskmaestro.conf" "$HOME/.tmux.conf" 2>/dev/null; then
      ok "tmux 설정  이미 적용됨"
      TMUX_CONFIGURED=true
    else
      info "기존 ~/.tmux.conf가 발견되었습니다."
      if confirm "TaskMaestro tmux 설정을 추가로 로드하시겠습니까? (source-file 방식)"; then
        cp "$TMUX_CONF_SOURCE" "$TMUX_CONF_TARGET"
        {
          echo ""
          echo "$TMUX_MARKER"
          echo "source-file $TMUX_CONF_TARGET"
        } >> "$HOME/.tmux.conf"
        ok "tmux 설정  ~/.tmux-taskmaestro.conf (source-file 추가)"
        TMUX_CONFIGURED=true
      else
        warn "tmux 설정을 건너뛰었습니다."
        echo "  나중에 수동으로 적용하려면:"
        echo "  cp $TMUX_CONF_SOURCE ~/.tmux-taskmaestro.conf"
        echo "  echo 'source-file ~/.tmux-taskmaestro.conf' >> ~/.tmux.conf"
      fi
    fi
  fi

  # tmux가 실행 중이면 설정 리로드 안내
  if [ "$TMUX_CONFIGURED" = true ] && [ -n "${TMUX:-}" ]; then
    info "tmux 세션 내에서 실행 중입니다. 설정을 바로 반영하려면:"
    echo "  tmux source-file ~/.tmux.conf"
  fi
fi

# ════════════════════════════════════
# 3. 스킬 파일 설치
# ════════════════════════════════════
echo ""
printf '%b[3/3] 스킬 설치%b\n' "$BOLD" "$NC"

if [ ! -d "$SKILL_SOURCE" ]; then
  die "skills/taskmaestro/ 디렉토리를 찾을 수 없습니다. install.sh를 레포지토리 루트에서 실행하세요."
fi

if [ -d "$SKILL_TARGET" ] || [ -L "$SKILL_TARGET" ]; then
  if [ "$FORCE" = true ]; then
    rm -rf "$SKILL_TARGET"
  else
    if ! confirm "스킬이 이미 설치되어 있습니다. 덮어쓰시겠습니까?"; then
      echo "스킬 설치를 건너뛰었습니다."
      echo ""
      echo "설치가 완료되었습니다."
      exit 0
    fi
    rm -rf "$SKILL_TARGET"
  fi
fi

mkdir -p "$HOME/.claude/skills"
cp -r "$SKILL_SOURCE" "$SKILL_TARGET"
ok "스킬 설치  $SKILL_TARGET"

# ════════════════════════════════════
# 설치 요약
# ════════════════════════════════════
echo ""
printf '%b%b' "$BOLD" "$GREEN"
echo "  ╔════════════════════════════════════╗"
echo "  ║    TaskMaestro 설치 완료!          ║"
echo "  ╚════════════════════════════════════╝"
printf '%b' "$NC"
echo ""
ok "git        ${GIT_VER:-확인됨}"
ok "tmux       ${TMUX_VER:-확인됨}"
if command -v claude >/dev/null 2>&1; then
  ok "claude CLI 설치됨"
else
  warn "claude CLI 미설치 (나중에 설치 필요)"
fi
if [ "${TMUX_CONFIGURED:-false}" = true ]; then
  ok "tmux 설정  적용됨"
else
  warn "tmux 설정  건너뜀"
fi
ok "스킬 설치  완료"
echo ""
printf '사용법: Claude Code에서 %b/taskmaestro start%b 를 실행하세요.\n' "$BOLD" "$NC"
echo ""
