#!/usr/bin/env bash
set -euo pipefail

root="BIT101-iOS"
haptic_file="$root/Shared/DesignSystem/AppHapticFeedback.swift"
required=(
  "$haptic_file:func appSelectionFeedback"
  "$haptic_file:sensoryFeedback(.selection, trigger:"
  "$haptic_file:func appImpactFeedback"
  "$haptic_file:sensoryFeedback(.impact, trigger:"
  "$root/Shared/DesignSystem/AppDesignSystem.swift:appImpactFeedback"
  "$root/Shared/DesignSystem/AppContentControlComponents.swift:appSelectionFeedback"
  "$root/Shell/AppShellView.swift:appSelectionFeedback"
  "$root/Schedule/ScheduleCalendarViews.swift:appSelectionFeedback"
  "$root/Schedule/ScheduleCalendarViews.swift:appImpactFeedback"
  "$root/Map/CampusMapScreen.swift:appImpactFeedback"
)

for item in "${required[@]}"; do
  file="${item%%:*}"
  pattern="${item#*:}"
  if ! rg -q --fixed-strings "$pattern" "$file"; then
    printf '[失败] 缺少系统触感：%s\n' "$file"
    exit 1
  fi
done

# 所有选择控件（原生和自绘）共用一条“文件登记 + 原生控件就地绑定”的规则。
selection_files="$({
  rg -l '\bPicker[[:space:]]*\(|\bToggle[[:space:]]*\(' "$root" --glob '*.swift' || true
  rg -l 'checkmark\.circle\.fill|checkmark\.square\.fill|toggleTag\(|selectedTags|setRating\(' "$root" --glob '*.swift' || true
} | sort -u)"
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  if ! rg -q --fixed-strings 'appSelectionFeedback' "$file"; then
    printf '[失败] 选择控件缺少公共触感修饰器：%s\n' "$file"
    exit 1
  fi
done <<< "$selection_files"

while IFS=: read -r file line _; do
  [[ -n "$file" && -n "$line" ]] || continue
  next_line="$(awk -v start="$line" 'NR > start && $0 ~ /(^|[^[:alnum:]_])(Picker|Toggle)[[:space:]]*\(/ { print NR; exit }' "$file")"
  [[ -n "$next_line" ]] || next_line=$((line + 28))
  end_line=$((next_line - 1))
  if ! sed -n "${line},${end_line}p" "$file" | rg -q --fixed-strings 'appSelectionFeedback'; then
    printf '[失败] 原生选择控件未就地接入公共触感：%s:%s\n' "$file" "$line"
    exit 1
  fi
done < <(rg -n '\b(Picker|Toggle)[[:space:]]*\(' "$root" --glob '*.swift' || true)

components=(
  "$root/Shared/DesignSystem/AppDesignSystem.swift:struct AppFloatingActionButton: View"
  "$root/Map/CampusMapScreen.swift:struct FloatingMapLabelButton: View"
)
for item in "${components[@]}"; do
  file="${item%%:*}"
  start="${item#*:}"
  if ! rg -q -U "(?s)${start}.*?appImpactFeedback" "$file"; then
    printf '[失败] 右下角操作按钮缺少触感：%s\n' "$file"
    exit 1
  fi
done

direct="$(rg -n '\.sensoryFeedback\(|UIFeedbackGenerator|UI(Selection|Impact|Notification)FeedbackGenerator|impactOccurred\(|selectionChanged\(|notificationOccurred\(|AudioServicesPlaySystemSound|kSystemSoundID_Vibrate|CHHapticEngine|NSHapticFeedbackManager|WKInterfaceDevice.*\.play' "$root" --glob '*.swift' || true)"
if [[ -n "$direct" ]] && grep -v 'Shared/DesignSystem/AppHapticFeedback.swift' <<< "$direct"; then
  printf '[失败] 页面不得绕过公共触感修饰器\n'
  exit 1
fi

# 设计系统只允许 selection/impact 两种公共修饰器；其余触感 API 统一视为非预期实现。
unexpected="$(rg -n '\.app[A-Za-z]+Feedback\(' "$root" --glob '*.swift' | rg -v '\.app(Selection|Impact)Feedback\(' || true)"
if [[ -n "$unexpected" ]]; then
  printf '[失败] 发现未登记的公共触感调用：\n%s\n' "$unexpected"
  exit 1
fi

# 公共接口只能在设计系统中声明，页面不能复制一套同名实现。
definitions="$(rg -n 'func app(Selection|Impact)Feedback' "$root" --glob '*.swift' || true)"
if [[ -n "$definitions" ]] && grep -v 'Shared/DesignSystem/AppHapticFeedback.swift' <<< "$definitions"; then
  printf '[失败] 公共触感接口不得在其他文件重复声明\n'
  exit 1
fi

printf '[通过] haptic-consistency\n'
