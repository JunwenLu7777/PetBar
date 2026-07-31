#!/bin/zsh
set -euo pipefail

ROOT="${CHATBIRD_PRIVACY_AUDIT_ROOT:-${0:A:h:h}}"
PATTERN='(/Users/[^/[:space:]]+|[A-Za-z]:\\Users\\[^\\[:space:]]+|com\.jing|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'

typeset -i findings=0

audit_candidates() {
  # Root-level local QA files are not release inputs. Audit every tracked file,
  # plus untracked files from directories copied or compiled into the package.
  git -C "$ROOT" ls-files -z
  git -C "$ROOT" ls-files --others --exclude-standard -z -- \
    shared/pet/chatbird-nt \
    shared/preview/chatbird-nt \
    macos/ChatBirdQuotaPanel \
    macos/package
}

while IFS= read -r -d '' file; do
  [[ -f "$ROOT/$file" ]] || continue
  case "$file" in
    scripts/privacy-audit.sh|*.png|*.gif|*.webp|*.jpg|*.icns|*.zip) continue ;;
  esac
  if rg -n -i "$PATTERN" "$ROOT/$file"; then
    findings=1
  fi
done < <(audit_candidates)

for release in "$ROOT"/build/release/ChatBird-NT-macOS-Universal-*(N); do
  while IFS= read -r -d '' file; do
    case "$file" in
      *.png|*.gif|*.webp|*.jpg|*.icns|*.zip) continue ;;
    esac
    if rg -n -i "$PATTERN" "$file"; then
      findings=1
    fi
  done < <(find "$release" -type f -print0)
done

if (( findings > 0 )); then
  echo "隐私审计失败：发现可能的个人路径、邮箱或凭据。" >&2
  exit 1
fi

for archive in "$ROOT"/dist/*.zip(N); do
  if /usr/bin/unzip -Z1 "$archive" | rg -i '(^|/)(\.env|panel\.log|panel-health\.json|.*-Check\.txt|__MACOSX)(/|$)'; then
    echo "隐私审计失败：压缩包包含日志、状态或环境文件：$archive" >&2
    exit 1
  fi
done

echo "隐私审计通过。"
