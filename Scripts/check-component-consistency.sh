#!/usr/bin/env bash
set -euo pipefail

root="BIT101-iOS"
shared="$root/Shared/DesignSystem/AppCommentComposerComponents.swift"
comment_files=(
  "$root/Course/CourseCommentViews.swift"
  "$root/Gallery/GalleryCommentViews.swift"
  "$root/Paper/PaperComposerViews.swift"
)
composer_files=(
  "${comment_files[@]}"
  "$root/Settings/SettingsRootView.swift"
)

for pattern in \
  'struct AppComposerContentSection' \
  'struct AppCommentComposerContentSection' \
  'struct AppComposerToolbar'; do
  if ! rg -q --fixed-strings "$pattern" "$shared"; then
    printf '[失败] 缺少公共评论组件：%s\n' "$pattern"
    exit 1
  fi
done

for file in "${comment_files[@]}"; do
  for pattern in AppCommentComposerContentSection AppComposerToolbar; do
    if ! rg -q --fixed-strings "$pattern" "$file"; then
      printf '[失败] 评论页面未复用公共组件：%s (%s)\n' "$file" "$pattern"
      exit 1
    fi
  done
done

for file in "${composer_files[@]}"; do
  if ! rg -q --fixed-strings 'AppComposerToolbar' "$file"; then
    printf '[失败] 编辑页面未复用公共工具栏：%s\n' "$file"
    exit 1
  fi
done

if ! rg -q --fixed-strings 'AppComposerContentSection' "$root/Settings/SettingsRootView.swift"; then
  printf '[失败] 开发者建议页未复用公共内容段\n'
  exit 1
fi

# 匿名评论开关只能维护在公共内容段，页面不再各自复制一份。
duplicate="$(rg -n 'Toggle\("匿名评论"' "${comment_files[@]}" || true)"
if [[ -n "$duplicate" ]]; then
  printf '[失败] 评论页面重复实现匿名评论开关：\n%s\n' "$duplicate"
  exit 1
fi

printf '[通过] component-consistency\n'
