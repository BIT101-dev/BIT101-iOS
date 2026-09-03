#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="$root/BIT101-iOS"
report="$root/.build/explanatory-text-report.txt"

mkdir -p "$(dirname "$report")"
{
    printf '%s\n' '# 可能属于解释性文案的 SwiftUI 文本（仅报告，不自动删除）'
    printf '%s\n\n' '# 请逐项确认是否确实多余。'

    printf '%s\n' '## Section footer'
    rg -n -U -C 2 'footer[[:space:]]*:[[:space:]]*\{' "$source_root" --glob '*.swift' || true
    printf '\n%s\n' '## 解释性 Text'
    rg -n -C 1 'Text\("[^"\n]*(开启后|默认|支持|请|输入|用于|避免|说明|提示|不会|可以|只能|否则|当前|下次|共用|表示)[^"\n]*"\)' "$source_root" --glob '*.swift' || true
} > "$report"

count="$( (rg -c '^[^#].*:[0-9]+[:-]' "$report" || true) | awk -F: '{ total += $NF } END { print total + 0 }')"
printf '[报告] 解释性文案候选 %s 条：%s\n' "$count" "$report"
