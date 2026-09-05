#!/usr/bin/env bash
set -euo pipefail

root="BIT101-iOS"
shared="$root/Shared/DesignSystem/AppCommentComposerComponents.swift"
shared_avatar="$root/Shared/DesignSystem/AppAvatarComponents.swift"
shared_comments="$root/Shared/DesignSystem/AppCommentComponents.swift"
shared_verification="$root/Shared/DesignSystem/AppVerificationComponents.swift"
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

require_component_in_files() {
  local component="$1"
  shift
  local file
  for file in "$@"; do
    if ! rg -q --fixed-strings "$component" "$file"; then
      printf '[失败] 同类页面未复用公共组件：%s -> %s\n' "$component" "$file"
      exit 1
    fi
  done
}

for pattern in \
  'struct AppCommentComposerContentSection' \
  'struct AppComposerToolbar'; do
  if ! rg -q --fixed-strings "$pattern" "$shared"; then
    printf '[失败] 缺少公共评论组件：%s\n' "$pattern"
    exit 1
  fi
done

for item in \
  "$shared_comments:struct AppCommentSectionHeader" \
  "$shared_comments:struct AppCommentIdentityHeader" \
  "$shared_comments:struct AppCommentActionBar" \
  "$shared_comments:struct AppCommentBubble" \
  "$shared_comments:struct AppCommentRowContainer" \
  "$shared_comments:struct AppCommentThread" \
  "$shared_verification:struct AppSMSVerificationSheet" \
  "$shared_controls:struct AppSegmentedPicker" \
  "$shared_controls:struct AppTopSegmentedPicker" \
  "$shared_controls:struct AppOrderedSearchBar" \
  "$shared_controls:struct AppSearchBarContainer" \
  "$shared_avatar:struct AppAvatarView" \
  "$shared_tags:enum AppTagChipVariant" \
  "$shared_tags:struct AppTagChip" \
  "$shared_state:struct AppFailureState" \
  "$shared_state:struct AppEmptyState" \
  "$root/Shared/DesignSystem/AppFixedColumnComponents.swift:struct AppFixedColumnItem" \
  "$root/Shared/DesignSystem/AppFixedColumnComponents.swift:struct AppFixedColumnRow" \
  "$root/Shared/DesignSystem/AppRefreshStatusComponents.swift:struct AppRefreshStatusRow" \
  "$root/Shared/DesignSystem/AppFeedComponents.swift:struct AppFeedRow" \
  "$root/Shared/DesignSystem/AppDesignSystem.swift:struct AppCourseEvaluationRow"; do
  file="${item%%:*}"
  pattern="${item#*:}"
  if ! rg -q --fixed-strings "$pattern" "$file"; then
    printf '[失败] 缺少公共 UI 组件：%s (%s)\n' "$file" "$pattern"
    exit 1
  fi
done

for item in \
  "$shared_state:struct AppLoadingState" \
  "$shared_state:struct AppInlineLoadingState" \
  "$shared_state:struct AppScrollStateContainer"; do
  file="${item%%:*}"
  pattern="${item#*:}"
  if ! rg -q --fixed-strings "$pattern" "$file"; then
    printf '[失败] 缺少公共状态组件：%s (%s)\n' "$file" "$pattern"
    exit 1
  fi
done

for file in \
  "$root/Course/CourseRootView.swift" \
  "$root/Course/CourseHistoryGradesViews.swift" \
  "$root/Score/ScoreRootView.swift" \
  "$root/Gallery/GalleryMessagesView.swift" \
  "$root/Mine/MineRootView.swift" \
  "$root/Paper/PaperRootView.swift" \
  "$root/Paper/PaperSearchViews.swift"; do
  if ! rg -q -e 'AppLoadingState' -e 'AppInlineLoadingState' "$file"; then
    printf '[失败] 首屏加载状态未复用公共组件：%s\n' "$file"
    exit 1
  fi
done

for file in "$root/Gallery/GalleryFeedViews.swift" "$root/Paper/PaperRootView.swift" "$root/Paper/PaperSearchViews.swift"; do
  if ! rg -q --fixed-strings 'AppScrollStateContainer' "$file"; then
    printf '[失败] 滚动页首屏状态未复用公共容器：%s\n' "$file"
    exit 1
  fi
done

require_component_in_files 'AppRefreshStatusRow' \
  "$root/Score/ScoreRootView.swift" \
  "$root/Schedule/ScheduleDDLViews.swift" \
  "$root/Schedule/CourseScheduleTabView.swift"
require_component_in_files 'AppFixedColumnRow' \
  "$root/Course/CourseRootView.swift" \
  "$root/Score/ScoreRootView.swift"
require_component_in_files 'CourseEvaluationLink' \
  "$root/Schedule/ScheduleEntryDetailView.swift" \
  "$root/Score/ScoreRootView.swift"

# 广泛盘点列表 / 表单 / 分组中的 SF Symbol；“我的”页面是用户明确保留的例外。
# 右侧状态图标可以保留，其余左侧或未分类图标一律阻断审计。
python3 - "$root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
container_pattern = re.compile(r"\b(List|Form|Section)\b")
icon_pattern = re.compile(
    r"\b(Label\s*\([^\n]*systemImage\s*:|"
    r"Button\s*\([^\n]*systemImage\s*:|"
    r"NavigationLink\s*\([^\n]*systemImage\s*:|"
    r"Image\s*\(systemName\s*:)")
right_pattern = re.compile(r"checkmark|circle|chevron|xmark|minus|star")
found = 0
violations = []
button_arrow_violations = []

print("[待确认] 列表图标候选（排除 BIT101-iOS/Mine）：")
for path in sorted(root.rglob("*.swift")):
    if "Mine" in path.parts:
        continue

    containers = []
    button_scopes = []
    depth = 0
    for line_number, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), 1):
        code = line.split("//", 1)[0]
        if container_pattern.search(code) and "{" in code:
            containers.append(depth)
        if re.search(r"\bButton\b", code) and "{" in code:
            button_scopes.append(depth)

        match = icon_pattern.search(code)
        if match and containers:
            kind = "右侧/状态候选" if right_pattern.search(code) else "左侧/位置待确认"
            print(f"  - {path}:{line_number}: {kind}: {code.strip()}")
            found += 1
            if not right_pattern.search(code):
                violations.append(f"{path}:{line_number}: {code.strip()}")
        if "chevron.right" in code and button_scopes:
            button_arrow_violations.append(f"{path}:{line_number}: {code.strip()}")

        depth += code.count("{") - code.count("}")
        while containers and depth <= containers[-1]:
            containers.pop()
        while button_scopes and depth <= button_scopes[-1]:
            button_scopes.pop()

component_sources = {
    "AppCourseEvaluationRow": root / "Shared/DesignSystem/AppDesignSystem.swift",
    "AppRefreshStatusRow": root / "Shared/DesignSystem/AppRefreshStatusComponents.swift",
    "DDLEventCard": root / "Schedule/ScheduleDDLViews.swift",
}
for component, source in component_sources.items():
    lines = source.read_text(encoding="utf-8", errors="ignore").splitlines()
    start = next((index for index, line in enumerate(lines) if f"struct {component}" in line), None)
    if start is None:
        continue
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if re.match(r"(?:private )?(?:struct|enum|extension)\b", lines[index].strip()):
            end = index
            break
    for offset, line in enumerate(lines[start:end], start + 1):
        code = line.split("//", 1)[0]
        if icon_pattern.search(code):
            kind = "右侧/状态候选" if right_pattern.search(code) else "左侧/位置待确认"
            print(f"  - {source}:{offset}: 公共组件 {component}，{kind}: {code.strip()}")
            found += 1
            if not right_pattern.search(code):
                violations.append(f"{source}:{offset}: {code.strip()}")

print(f"[待确认] 发现 {found} 个直接源码候选。")
if violations:
    print("[失败] 非 Mine 页面不得在列表/表单行直接使用未允许的左侧/未分类图标：")
    for violation in violations:
        print(f"  - {violation}")
    raise SystemExit(1)
if button_arrow_violations:
    print("[失败] 普通 Button 不得伪装成下一级导航显示右箭头；需要下一级页面时请使用 NavigationLink：")
    for violation in button_arrow_violations:
        print(f"  - {violation}")
    raise SystemExit(1)
print("[通过] 未发现未允许的列表/表单左侧或未分类图标。")
PY

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

# 三类评论必须共享头像、标题、操作行、气泡和线程结构，业务差异只能留在内容闭包内。
for file in \
  "$root/Course/CourseCommentViews.swift" \
  "$root/Gallery/GalleryCommentViews.swift" \
  "$root/Paper/PaperCommentViews.swift"; do
  for pattern in AppCommentThread AppCommentBubble AppCommentIdentityHeader AppCommentActionBar AppAvatarView; do
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

for file in "$root/Schedule/ScheduleRootView.swift" "$root/Score/ScoreRootView.swift" "$root/Settings/SettingsScheduleViews.swift"; do
  if ! rg -q --fixed-strings 'AppSMSVerificationSheet' "$file"; then
    printf '[失败] 验证码页面未复用公共组件：%s\n' "$file"
    exit 1
  fi
done

# 社区/文章时间统一使用一个公共解析器；页面不得保留第二套日期解析或格式化。
require_component_in_files 'AppDateText' \
  "$root/Course/CourseCommentViews.swift" \
  "$root/Gallery/GalleryCommentViews.swift" \
  "$root/Gallery/GalleryFeedViews.swift" \
  "$root/Gallery/GalleryMessagesView.swift" \
  "$root/Gallery/GalleryPosterDetailView.swift" \
  "$root/Paper/PaperCommentViews.swift" \
  "$root/Paper/PaperDetailView.swift" \
  "$root/Paper/PaperSummaryViews.swift"
community_date_files=(
  "$root/Course/CourseCommentViews.swift"
  "$root/Gallery/GalleryCommentViews.swift"
  "$root/Gallery/GalleryFeedViews.swift"
  "$root/Gallery/GalleryMessagesView.swift"
  "$root/Gallery/GalleryPosterDetailView.swift"
  "$root/Paper/PaperCommentViews.swift"
  "$root/Paper/PaperDetailView.swift"
  "$root/Paper/PaperSummaryViews.swift"
)
for file in "${community_date_files[@]}"; do
  duplicate_date_code="$(rg -n 'DateFormatter|ISO8601DateFormatter|RelativeDateTimeFormatter|GalleryDate|CourseDate|PaperDate' "$file" || true)"
  if [[ -n "$duplicate_date_code" ]]; then
    printf '[失败] 同类页面不得重复实现日期解析或格式化：%s\n%s\n' "$file" "$duplicate_date_code"
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

if ! rg -q -e 'AppDesignSystem\.TopBar\.contentGap' -e 'AppDesignSystem\.Spacing\.content' "$root/Schedule/CourseScheduleTabView.swift"; then
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



# 匿名评论开关只能维护在公共内容段，页面不再各自复制一份。
duplicate="$(rg -n 'Toggle\("匿名评论"' "${comment_files[@]}" || true)"
if [[ -n "$duplicate" ]]; then
  printf '[失败] 评论页面重复实现匿名评论开关：\n%s\n' "$duplicate"
  exit 1
fi

printf '[通过] component-consistency\n'
