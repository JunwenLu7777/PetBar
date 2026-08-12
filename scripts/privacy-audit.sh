#!/bin/zsh
set -euo pipefail

ROOT="${THREADHELM_PRIVACY_AUDIT_ROOT:-${0:A:h:h}}"
LOCAL_PATH_PATTERN='(/Users/[^/[:space:]]+|[A-Za-z]:\\Users\\[^\\[:space:]]+)'
SENSITIVE_PATTERN='(com\.jing|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'
PATTERN="($LOCAL_PATH_PATTERN|$SENSITIVE_PATTERN)"
HISTORICAL_LOCAL_PATH_RECORD="docs/superpowers/plans/2026-08-12-remove-chatbird-pet.md"

# 扫描全部走 rg，且每次调用都在 if 条件里——set -e 对 if 条件豁免，所以 rg
# 缺失时退出码 127 会被当成"没有命中"，审计会一个文件都没查却报告通过。
# 先确认依赖存在，把静默失效变成明确失败。
if ! command -v rg >/dev/null 2>&1; then
  echo "隐私审计无法运行：未找到 ripgrep（rg）。" >&2
  echo "      缺少它会让扫描静默失效，因此这里直接判失败；请先安装 ripgrep。" >&2
  exit 1
fi

typeset -i findings=0

audit_candidates() {
  # Root-level local QA files are not release inputs. Audit every tracked file,
  # plus untracked files from directories copied or compiled into the package.
  git -C "$ROOT" ls-files -z
  git -C "$ROOT" ls-files --others --exclude-standard -z -- \
    macos/ThreadHelm \
    macos/package
}

while IFS= read -r -d '' file; do
  [[ -f "$ROOT/$file" ]] || continue
  case "$file" in
    scripts/privacy-audit.sh|*.png|*.gif|*.webp|*.jpg|*.icns|*.zip) continue ;;
  esac
  audit_pattern="$PATTERN"
  if [[ "$file" == "$HISTORICAL_LOCAL_PATH_RECORD" ]]; then
    # Preserve the historical plan verbatim, but continue checking it for
    # credentials and email addresses. It is not a current release input.
    audit_pattern="$SENSITIVE_PATTERN"
  fi
  if rg -n -i "$audit_pattern" "$ROOT/$file"; then
    findings=1
  fi
done < <(audit_candidates)

for release in "$ROOT"/build/release/ThreadHelm-macOS-arm64-*(N); do
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
