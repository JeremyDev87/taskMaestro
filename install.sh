#!/bin/sh
# TaskMaestro installer
# Copies the taskmaestro skill to ~/.claude/skills/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SCRIPT_DIR/skills/taskmaestro"
TARGET="$HOME/.claude/skills/taskmaestro"

if [ ! -d "$SOURCE" ]; then
  echo "Error: skills/taskmaestro/ 디렉토리를 찾을 수 없습니다."
  echo "install.sh를 레포지토리 루트에서 실행하세요."
  exit 1
fi

# Check for existing installation
if [ -d "$TARGET" ] || [ -L "$TARGET" ]; then
  if [ "$1" = "-f" ] || [ "$1" = "--force" ]; then
    rm -rf "$TARGET"
  else
    echo "이미 설치되어 있습니다: $TARGET"
    printf "덮어쓰시겠습니까? [y/N] "
    read -r answer
    case "$answer" in
      [yY]|[yY][eE][sS]) rm -rf "$TARGET" ;;
      *) echo "설치를 취소했습니다."; exit 0 ;;
    esac
  fi
fi

mkdir -p "$HOME/.claude/skills"
cp -r "$SOURCE" "$TARGET"

echo ""
echo "TaskMaestro 설치 완료!"
echo "  설치 경로: $TARGET"
echo ""
echo "사용법: Claude Code에서 /taskmaestro start 를 실행하세요."
