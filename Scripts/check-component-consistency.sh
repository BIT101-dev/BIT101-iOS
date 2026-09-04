#!/usr/bin/env bash
set -euo pipefail

root="BIT101-iOS"
shared="$root/Shared/DesignSystem/AppCommentComposerComponents.swift"
shared_avatar="$root/Shared/DesignSystem/AppAvatarComponents.swift"
shared_comments="$root/Shared/DesignSystem/AppCommentComponents.swift"
shared_controls="$root/Shared/DesignSystem/AppContentControlComponents.swift"
shared_tags="$root/Shared/DesignSystem/AppTagComponents.swift"
shared_state="$root/Shared/Infrastructure/AppStateComponents.swift"
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

for item in \
  "$shared_comments:struct AppCommentAvatarView" \
  "$shared_comments:struct AppCommentIdentityHeader" \
  "$shared_comments:struct AppCommentActionBar" \
  "$shared_comments:struct AppCommentBubble" \
  "$shared_comments:struct AppCommentRowContainer" \
  "$shared_controls:struct AppSegmentedPicker" \
  "$shared_controls:struct AppTopSegmentedPicker" \
  "$shared_controls:struct AppOrderedSearchBar" \
  "$shared_controls:struct AppSearchBarContainer" \
  "$shared_avatar:struct AppAvatarView" \
  "$shared_tags:enum AppTagChipVariant" \
  "$shared_tags:struct AppTagChip" \
  "$shared_state:struct AppFailureState" \
  "$shared_state:struct AppEmptyState" \
  "$root/Shared/DesignSystem/AppRefreshStatusComponents.swift:struct AppRefreshStatusRow" \
  "$root/Shared/DesignSystem/AppFeedComponents.swift:struct AppFeedRow"; do
  file="${item%%:*}"
  pattern="${item#*:}"
  if ! rg -q --fixed-strings "$pattern" "$file"; then
    printf '[失败] 缺少公共 UI 组件：%s (%s)\n' "$file" "$pattern"
    exit 1
  fi
done

for file in "$root/Score/ScoreRootView.swift" "$root/Schedule/ScheduleDDLViews.swift"; do
  if ! rg -q --fixed-strings 'AppRefreshStatusRow' "$file"; then
    printf '[失败] 数据页面未复用更新时间/刷新公共行：%s\n' "$file"
    exit 1
  fi
done

if ! rg -q --fixed-strings 'AppRefreshStatusRow' "$root/Schedule/CourseScheduleTabView.swift"; then
  printf '[失败] 课表更新时间必须直接复用主 List 的公共行\n'
  exit 1
fi

for file in \
  "$root/Course/CourseRootView.swift" \
  "$root/Score/ScoreRootView.swift" \
  "$root/Schedule/ScheduleDDLViews.swift" \
  "$root/Schedule/FreeClassroomViews.swift" \
  "$root/Mine/MineRootView.swift"; do
  if ! rg -q --fixed-strings 'appGroupedListStyle()' "$file"; then
    printf '[失败] 分组列表必须复用唯一公共布局：%s\n' "$file"
    exit 1
  fi
done

direct_states="$(rg -n 'ContentUnavailableView' "$root" --glob '*.swift' \
  | rg -v 'Shared/Infrastructure/AppStateComponents\.swift|Schedule/FreeClassroomViews\.swift' || true)"
if [[ -n "$direct_states" ]]; then
  printf '[失败] 页面不得直接实现空态/失败态：\n%s\n' "$direct_states"
  exit 1
fi

for file in \
  "$root/Gallery/GalleryFeedViews.swift" \
  "$root/Gallery/GalleryPosterDetailView.swift" \
  "$root/Gallery/GalleryComposerView.swift"; do
  if ! rg -q --fixed-strings 'AppTagChip' "$file"; then
    printf '[失败] 标签页面未复用公共标签组件：%s\n' "$file"
    exit 1
  fi
done

for file in \
  "$root/Course/CourseRootView.swift" \
  "$root/Course/CourseHistoryGradesViews.swift" \
  "$root/Course/CourseCommentViews.swift" \
  "$root/Gallery/GalleryFeedViews.swift" \
  "$root/Gallery/GalleryMessagesView.swift" \
  "$root/Gallery/GalleryCommentViews.swift" \
  "$root/Mine/MineRootView.swift" \
  "$root/Paper/PaperRootView.swift" \
  "$root/Paper/PaperSearchViews.swift" \
  "$root/Paper/PaperCommentViews.swift" \
  "$root/Score/ScoreRootView.swift"; do
  if ! rg -q --fixed-strings 'AppFailureState' "$file"; then
    printf '[失败] 失败状态未复用公共组件：%s\n' "$file"
    exit 1
  fi
done

for file in \
  "$root/Gallery/GalleryFeedViews.swift" \
  "$root/Gallery/GalleryPosterDetailView.swift" \
  "$root/Gallery/GalleryMessagesView.swift" \
  "$root/Mine/MineRootView.swift" \
  "$root/Paper/PaperSummaryViews.swift" \
  "$root/Paper/PaperDetailView.swift" \
  "$root/Settings/SettingsAccountViews.swift"; do
  if ! rg -q --fixed-strings 'AppAvatarView' "$file"; then
    printf '[失败] 头像页面未复用公共头像组件：%s\n' "$file"
    exit 1
  fi
done
legacy_avatars="$(rg -n 'GalleryAvatarView|PaperSummaryAvatar|CachedRemoteImage\(url:.*avatar' "$root" --glob '*.swift' || true)"
if [[ -n "$legacy_avatars" ]]; then
  printf '[失败] 页面不得重复实现头像加载容器：\n%s\n' "$legacy_avatars"
  exit 1
fi

for file in \
  "$root/Gallery/GalleryFeedViews.swift" \
  "$root/Paper/PaperRootView.swift" \
  "$root/Paper/PaperSearchViews.swift" \
  "$root/Mine/MineRootView.swift"; do
  if ! rg -q --fixed-strings 'AppFeedRow' "$file"; then
    printf '[失败] 信息流页面未复用公共行容器：%s\n' "$file"
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

# 三类评论必须共享头像、标题、操作行、气泡和主项容器，业务差异只能留在内容闭包内。
for file in \
  "$root/Course/CourseCommentViews.swift" \
  "$root/Gallery/GalleryCommentViews.swift" \
  "$root/Paper/PaperCommentViews.swift"; do
  for pattern in AppCommentRowContainer AppCommentBubble AppCommentIdentityHeader AppCommentActionBar AppCommentAvatarView; do
    if ! rg -q --fixed-strings "$pattern" "$file"; then
      printf '[失败] 评论页面未复用公共结构：%s (%s)\n' "$file" "$pattern"
      exit 1
    fi
  done
  if rg -q 'private struct (Course|Gallery|Paper)CommentBubble|private struct CourseCommentAvatarView' "$file"; then
    printf '[失败] 评论页面重复实现气泡或头像：%s\n' "$file"
    exit 1
  fi
done

# 文章和话廊搜索栏必须共享排序菜单、输入框、清空按钮和顶部材质。
for file in "$root/Gallery/GallerySearchView.swift" "$root/Paper/PaperSearchViews.swift"; do
  for pattern in AppOrderedSearchBar AppSearchBarContainer; do
    if ! rg -q --fixed-strings "$pattern" "$file"; then
      printf '[失败] 搜索页面未复用公共组件：%s (%s)\n' "$file" "$pattern"
      exit 1
    fi
  done
  if rg -q 'struct (Gallery|Paper)SearchBar' "$file"; then
    printf '[失败] 搜索页面重复实现搜索栏：%s\n' "$file"
    exit 1
  fi
done

for file in \
  "$root/Gallery/GalleryRootView.swift" \
  "$root/Gallery/GalleryMessagesView.swift" \
  "$root/Score/ScoreRootView.swift" \
  "$root/Paper/PaperRootView.swift" \
  "$root/Schedule/ScheduleRootView.swift"; do
  if ! rg -q --fixed-strings 'AppTopSegmentedPicker' "$file"; then
    printf '[失败] 顶部内容切换未复用公共 segmented 控件：%s\n' "$file"
    exit 1
  fi
done

for file in "$root/Gallery/GalleryRootView.swift" "$root/Paper/PaperRootView.swift"; do
  if ! rg -q --fixed-strings 'variant: .stacked' "$file"; then
    printf '[失败] 叠加顶部栏必须使用紧凑公共变体：%s\n' "$file"
    exit 1
  fi
done

if ! rg -q --fixed-strings 'AppDesignSystem.TopBar.contentGap' "$root/Schedule/CourseScheduleTabView.swift"; then
  printf '[失败] 课表上下内容间隙必须使用公共约束令牌\n'
  exit 1
fi

if ! rg -q --fixed-strings 'AppDesignSystem.Radius.grouped' "$root/Schedule/ScheduleCalendarViews.swift"; then
  printf '[失败] 课表主体必须使用与 List 分组内容一致的公共圆角\n'
  exit 1
fi

for file in "$root/Schedule/ScheduleEditingSupport.swift"; do
  if ! rg -q --fixed-strings 'AppSegmentedPicker' "$file"; then
    printf '[失败] segmented 控件未复用公共基础组件：%s\n' "$file"
    exit 1
  fi
done

# segmented 的具体样式只允许在公共组件内部声明，页面统一使用语义组件。
segmented="$(rg -n '\.pickerStyle\(\.segmented\)' "$root" --glob '*.swift' \
  | rg -v 'Shared/DesignSystem/AppContentControlComponents\.swift' || true)"
if [[ -n "$segmented" ]]; then
  printf '[失败] 页面不得重复实现 segmented 样式：\n%s\n' "$segmented"
  exit 1
fi

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
