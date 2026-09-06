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

# 扫描前抹掉登记过的非个人占位串。目前登记两类，都是自测夹具按构造
# 就不是个人信息的东西：
#   1) /Users/u/…——「u」是刻意脱敏的占位用户名，不是任何人；
#   2) …@github.com[:/]…——夹具构造的公共仓库 remote（OpenAI/Codex）。
# 夹具若引入新的撞线形状，在这里显式登记并说明来源；不要放宽下面的
# PATTERN——那会把真实命中一起放走。
mask_registered_placeholders() {
  /usr/bin/sed -E \
    -e 's#/Users/u/[^[:space:]]*#REDACTED#g' \
    -e 's#[A-Za-z0-9._%+-]+@github\.com[:/][^[:space:]]*#REDACTED#g'
}

# 单文件扫描。文本文件直接 rg；Mach-O 二进制先 strings 再 rg——二进制是
# 唯一会进用户机器的编译产物，把它整类排除等于只审了不出货的东西。
# rg 的退出码语义必须显式处理：0=命中、1=无命中、≥2=扫描出错。出错
# 要当成审计失败，不能掉进 if 条件里被当成"没命中"（这正是当年 rg
# 缺失 127 被吞的同型漏洞）。
scan_matches() {
  local file="$1" pattern="$2" rc
  case "$file" in
    *.png|*.gif|*.webp|*.jpg|*.icns|*.zip|*.pdf|*.woff2) return 1 ;;
  esac
  if /usr/bin/file "$file" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/strings -a "$file" 2>/dev/null \
      | mask_registered_placeholders \
      | rg -n -i "$pattern"
    rc=${pipestatus[3]}
  else
    mask_registered_placeholders < "$file" | rg -n -i "$pattern"
    rc=${pipestatus[2]}
  fi
  if (( rc > 1 )); then
    echo "隐私审计无法扫描：$file（扫描器退出码 $rc）" >&2
    exit 1
  fi
  return $rc
}

candidates=(
  "${(@0)$(git -C "$ROOT" ls-files -z)}"
  "${(@0)$(git -C "$ROOT" ls-files --others --exclude-standard -z -- macos/ThreadHelm macos/package)}"
)

for file in "${candidates[@]}"; do
  [[ -n "$file" && -f "$ROOT/$file" ]] || continue
  case "$file" in
    scripts/privacy-audit.sh) continue ;;
  esac
  audit_pattern="$PATTERN"
  if [[ "$file" == "$HISTORICAL_LOCAL_PATH_RECORD" ]]; then
    # Preserve the historical plan verbatim, but continue checking it for
    # credentials and email addresses. It is not a current release input.
    audit_pattern="$SENSITIVE_PATTERN"
  fi
  if scan_matches "$ROOT/$file" "$audit_pattern"; then
    findings=1
  fi
done

for release in "$ROOT"/build/release/ThreadHelm-macOS-arm64-*(N); do
  release_files=("${(@0)$(find "$release" -type f -print0)}")
  for file in "${release_files[@]}"; do
    [[ -n "$file" && -f "$file" ]] || continue
    if scan_matches "$file" "$PATTERN"; then
      findings=1
    fi
  done
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
