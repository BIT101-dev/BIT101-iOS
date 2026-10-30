#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  echo "Scripts/run-extended-tests.sh                    自动选机、运行完整行为测试"
  echo "Scripts/run-extended-tests.sh modules            本机模块测试"
  echo "Scripts/run-extended-tests.sh simulator info|prepare|build-ui|preview|restore|inspect|app|release-runtime|ui|merge [用例]  授权后的模拟器验收及 CI 分片汇总"
  echo "Scripts/run-extended-tests.sh simulator runtime 平台 版本或构建号  下载并安装 Apple silicon 运行时"
  echo "Scripts/run-extended-tests.sh simulator runtime info；runtime upgrade|prune [平台] 版本  默认维护 iOS"
  echo "Scripts/run-extended-tests.sh simulator devices prune 保留设备UDID...  回收闲置设备及空闲运行时"
  echo "Scripts/run-extended-tests.sh simulator devices clean 设备UDID...  保留登录与设置，清理缓存和临时文件"
  echo "Scripts/run-extended-tests.sh release-runtime    正式编译条件下的真机组装合同"
  echo "Scripts/run-extended-tests.sh catalyst-release-runtime  正式编译条件下的 Catalyst 组装合同"
  echo "Scripts/run-extended-tests.sh ui [用例关键词]...  真机 UI 测试，多个筛选合并执行"
  echo "Scripts/run-extended-tests.sh build [宿主]        编译测试宿主，默认 release"
  echo "Scripts/run-extended-tests.sh report [json|coverage] 读取测试结果、用例树或覆盖率"
  echo "Scripts/run-extended-tests.sh cache [info]        缓存维护与分项占用查询"
  echo "性能：performance baseline 批准人；performance current；report performance-schema。"
  echo "分组：release-runtime、catalyst-release-runtime、schedule、infrastructure、login、extensions、catalyst；组后可直接填写测试类/方法。"
  echo "宿主：release、release-runtime、ui、network-smoke、icloud-smoke、modules、catalyst、catalyst-release-runtime。"
  echo "专项：verify [--sms] [--self-test] [分组]... 聚合已授权专项；默认含真机、线上社区写入、iCloud 往返和归档。"
  echo "日常定向回归示例：verify audit modules；专项可单独执行 verify network、verify community-writes、verify icloud。"
  echo "诊断：diagnostics；report|screenshot|activities 测试类/方法。"
  echo "附件：activities '测试类/方法()' [json]；screenshot '测试类/方法()' [附件标识]。"
  exit 0
fi
WORKFLOW_STARTED_SECONDS=$SECONDS

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/BIT101-iOS.xcodeproj"
source "$ROOT_DIR/Scripts/script-support.sh"
export BIT101_WORKFLOW_STARTED_AT="${BIT101_WORKFLOW_STARTED_AT:-$(python3 "$ROOT_DIR/Scripts/test_results.py" start)}"
DERIVED_ROOT="$ROOT_DIR/.build/extended-automation"
if [[ "${1:-}" == simulator ]]; then
  exec zsh "$ROOT_DIR/Scripts/simulator-tests.sh" "${@:2}"
fi
if [[ "${1:-}" == cache ]]; then
  if [[ $# -eq 2 && "$2" == info ]]; then
    exec python3 "$ROOT_DIR/Scripts/compiler_cache.py" "$ROOT_DIR" --info
  fi
  [[ $# -eq 1 ]] || { echo "用法：Scripts/run-extended-tests.sh cache [info]" >&2; exit 64; }
  bit101_acquire_artifact_lock "$0" "$@"
  bit101_build_cache --maintenance
  exit 0
fi
if [[ "${1:-}" == performance ]]; then
  bit101_acquire_artifact_lock "$0" "$@"
  python3 "$ROOT_DIR/Scripts/validation_performance.py" "${@:2}"
  exit 0
fi
if [[ "${1:-}" == report || "${1:-}" == screenshot || "${1:-}" == activities || "${1:-}" == diagnostics ]]; then
  case "$1" in
    report) [[ $# -le 2 ]] || { echo "用法：Scripts/run-extended-tests.sh report [json|coverage|测试类/方法]" >&2; exit 64; } ;;
    diagnostics) [[ $# -eq 1 ]] || { echo "用法：Scripts/run-extended-tests.sh diagnostics" >&2; exit 64; } ;;
    activities) [[ $# -eq 2 || ( $# -eq 3 && "$3" == json ) ]] || { echo "用法：Scripts/run-extended-tests.sh activities 测试类/方法 [json]" >&2; exit 64; } ;;
    screenshot) [[ $# -eq 2 || $# -eq 3 ]] || { echo "用法：Scripts/run-extended-tests.sh screenshot 测试类/方法 [附件标识]" >&2; exit 64; } ;;
    *) [[ $# -eq 2 ]] || { echo "请提供测试类/方法。" >&2; exit 64; } ;;
  esac
  case "$1:${2:-}" in
    report:|report:json|report:coverage|report:performance|report:performance-run|report:performance-schema|activities:*) ;;
    *) bit101_acquire_artifact_lock "$0" "$@" ;;
  esac
  python3 "$ROOT_DIR/Scripts/test_results.py" report "$DERIVED_ROOT/test-results.xcresult" "${2:-}" "$1" "$ROOT_DIR/Scripts" "${3:-}"
  exit 0
fi

SCRIPT_PATH="$0"
SCRIPT_ARGS=("$@")
acquire_test_lock() {
  if $GENERIC_BUILD || [[ "$BUILD_ONLY" == true && ( "$MODE" == modules || "$MODE" == catalyst || "$MODE" == catalyst-release-runtime ) ]] \
      || [[ "$MODE" == verify && "$verification_needs_device" == false ]]; then
    bit101_acquire_artifact_lock "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
  else
    bit101_acquire_workflow_lock "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
  fi
}
TEST_BUNDLE="BIT101-iOSTests"
TEST_SCHEME="BIT101-iOS"
RESULT_BUNDLE="$DERIVED_ROOT/test-results.xcresult"
typeset -aU TEST_SELECTIONS
TEST_SELECTIONS=()
BUILD_ONLY=false
GENERIC_BUILD=false
TEST_DURATION_SECONDS=0

MODE="all"
if [[ "${1:-}" == build ]]; then
  BUILD_ONLY=true
  shift
  MODE="${1:-release}"
  if (( $# > 0 )); then shift; fi
  case "$MODE" in
    release|release-runtime|ui|network-smoke|icloud-smoke) GENERIC_BUILD=true ;;
    modules|catalyst|catalyst-release-runtime) ;;
    *) echo "编译宿主：release、release-runtime、ui、network-smoke、icloud-smoke、modules、catalyst、catalyst-release-runtime。" >&2; exit 64 ;;
  esac
fi
if ! $BUILD_ONLY && [[ $# -gt 0 ]]; then
  case "$1" in
    all|release-runtime|network-smoke|schedule|infrastructure|login|extensions|ui|catalyst|catalyst-release-runtime|modules|verify)
      MODE="$1"
      shift
      ;;
  esac
fi

if [[ "$MODE" == ui ]]; then bit101_set_workflow_budget ui; fi
export BIT101_VALIDATION_INPUT_IDENTITY

if [[ "$MODE" == "verify" ]]; then
  verification_network_args=(all)
  verification_audit_args=()
  while [[ "${1:-}" == --sms || "${1:-}" == --self-test ]]; do
    case "$1" in
      --sms) verification_network_args=(all sms) ;;
      --self-test) verification_audit_args=(--self-test) ;;
    esac
    shift
  done
  typeset -aU verification_groups
  verification_groups=("$@")
  if (( ${#verification_groups[@]} == 0 )); then
    verification_groups=("${(@f)$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" verify-defaults)}")
  fi
  verification_needs_device=false
  for group in "${verification_groups[@]}"; do
    case "$group" in
      all|release-runtime|ui|network|community-writes|ddl|icloud) verification_needs_device=true ;;
      modules|catalyst|catalyst-release-runtime|build-archive|audit) ;;
      *) echo "验证组：modules all release-runtime catalyst catalyst-release-runtime ui network community-writes ddl icloud build-archive audit" >&2; exit 64 ;;
    esac
  done
  for group in "${verification_groups[@]}"; do
    case "$group" in
      network) "$ROOT_DIR/Scripts/release-network-smoke.sh" --check-config "${verification_network_args[@]}" ;;
      community-writes|ddl) "$ROOT_DIR/Scripts/release-network-smoke.sh" --check-config "$group" ;;
    esac
  done
  bit101_set_workflow_budget "${verification_groups[@]}"
  acquire_test_lock
  print -r -- "[验证分组] ${(j:, :)verification_groups}"
  if $verification_needs_device; then
    bit101_require_device || exit 1
  fi
  verification_audit_pid=
  if (( ${verification_groups[(Ie)audit]} )); then verification_groups=(audit ${verification_groups:#audit}); fi

  trap bit101_finish_verification EXIT ZERR
  trap 'exit 130' INT
  trap 'exit 143' TERM
  typeset -a completed_result_groups=()

  for group in "${verification_groups[@]}"; do
    case "$group" in
      modules|catalyst|catalyst-release-runtime) bit101_verify_step "$group" "$0" "$group" ;;
      all|release-runtime|ui) bit101_verify_step "$group" "$0" "$group" ;;
      network) bit101_verify_step network "$ROOT_DIR/Scripts/release-network-smoke.sh" "${verification_network_args[@]}" ;;
      community-writes) bit101_verify_step community-writes "$ROOT_DIR/Scripts/release-network-smoke.sh" community-writes ;;
      ddl) bit101_verify_step ddl "$ROOT_DIR/Scripts/release-network-smoke.sh" ddl ;;
      icloud) bit101_verify_step icloud "$ROOT_DIR/Scripts/run_icloud_cross_device_smoke.sh" ;;
      build-archive) bit101_verify_step build-archive "$ROOT_DIR/Scripts/build-install-device.sh" archive ;;
      audit) bit101_verify_step audit "$ROOT_DIR/Scripts/run-static-audit.sh" "${verification_audit_args[@]}" ;;
    esac
  done
  exit 0
fi

if [[ "$MODE" == "ui" ]]; then
  TEST_BUNDLE="BIT101-iOSUITests"
  TEST_SCHEME="BIT101-iOS-UIAutomation"
fi

for selection in "$@"; do
  [[ "$selection" != -* ]] || { echo "请直接填写测试类/方法；编译使用 build 宿主。" >&2; exit 64; }
  if [[ "$MODE" != ui && "$selection" != [A-Z]* ]]; then
    echo "请填写测试类/方法，或通过 --help 查看操作。" >&2
    exit 64
  fi
done
TEST_SELECTIONS=("$@")
if [[ "$MODE" == network-smoke && "$BUILD_ONLY" == false && ${#TEST_SELECTIONS[@]} -eq 0 ]]; then
  echo "请提供定向网络测试类或方法。" >&2; exit 64
fi
if [[ "$MODE" == ui && ${#TEST_SELECTIONS[@]} -gt 0 ]]; then
  selections="$(bit101_ui_test_selections "${TEST_SELECTIONS[@]}")" || exit 64
  TEST_SELECTIONS=("${(@f)selections}")
fi
if [[ "$BUILD_ONLY" == true && ${#TEST_SELECTIONS[@]} -gt 0 ]]; then
  echo "宿主编译直接使用对应操作名。" >&2
  exit 64
fi

validation_scope=full
unset BIT101_VALIDATION_EXPECTED_TESTS
if (( ${#TEST_SELECTIONS[@]} > 0 )); then
  validation_scope=selected
  BIT101_VALIDATION_EXPECTED_TESTS="$(python3 "$ROOT_DIR/Scripts/test_results.py" select "$MODE" "${TEST_SELECTIONS[@]}")" || exit 64
  export BIT101_VALIDATION_EXPECTED_TESTS
fi
if [[ "$MODE" == schedule || "$MODE" == infrastructure || "$MODE" == login || "$MODE" == extensions ]] \
    && (( ${#TEST_SELECTIONS[@]} == 0 )); then
  selections="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" suites "$MODE")" || exit 1
  TEST_SELECTIONS=("${(@f)selections}")
fi
validation_group="$MODE"
if $BUILD_ONLY; then validation_group="build-$MODE"; fi
if [[ "$MODE" == "modules" ]]; then
  acquire_test_lock
elif $GENERIC_BUILD; then
  acquire_test_lock
  TEST_DESTINATION="generic/platform=iOS"
  SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
elif [[ "$MODE" == catalyst || "$MODE" == catalyst-release-runtime ]]; then
  acquire_test_lock
  TEST_DESTINATION="platform=macOS,variant=Mac Catalyst"
  SIGNING_ARGS=("${(@f)$(bit101_catalyst_signing_arguments)}")
else
  acquire_test_lock
  bit101_require_device || exit 1
  TEST_DESTINATION="platform=iOS,id=$BIT101_XCODE_DEVICE_ID"
  SIGNING_ARGS=(-allowProvisioningUpdates)
fi
BIT101_VALIDATION_RUN_ID="$(uuidgen)"
BIT101_VALIDATION_INPUT_IDENTITY="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest "$validation_group")"
export BIT101_VALIDATION_RUN_ID BIT101_VALIDATION_INPUT_IDENTITY
typeset -a retained_result_groups=()
finish_validation() {
  local validation_status=$?
  trap - EXIT ZERR INT TERM
  export BIT101_VALIDATION_ELAPSED_SECONDS="$(( SECONDS - WORKFLOW_STARTED_SECONDS ))"
  if [[ "$validation_group" == modules && "$BUILD_ONLY" == false ]] && (( validation_status )); then
    python3 "$ROOT_DIR/Scripts/test_results.py" module-metrics "" "$DERIVED_ROOT/test-metrics.txt" "$ROOT_DIR" "$validation_status" || true
  fi
  if ! $BUILD_ONLY; then
    local workflow_seconds=$(( SECONDS - WORKFLOW_STARTED_SECONDS ))
    if [[ -f "$DERIVED_ROOT/test-metrics.txt" ]]; then
      print -r -- "$validation_group 工作流总耗时：${workflow_seconds} 秒" >> "$DERIVED_ROOT/test-metrics.txt"
    fi
    echo "[测试工作流] ${workflow_seconds} 秒"
  fi
  python3 "$ROOT_DIR/Scripts/validation_evidence.py" record "$validation_group" "$validation_status" "$validation_scope" || validation_status=$?
  if (( ${#retained_result_groups[@]} )); then
    python3 "$ROOT_DIR/Scripts/validation_performance.py" retain-selected "$validation_group" "${retained_result_groups[@]}" || validation_status=$?
  fi
  exit "$validation_status"
}
trap finish_validation EXIT ZERR
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$MODE" == ui && ${#TEST_SELECTIONS[@]} -gt 0 ]]; then
  echo "[筛选] ${#TEST_SELECTIONS[@]} 项 UI 用例 · 同一批次执行"
fi

mkdir -p "$DERIVED_ROOT"
if ! $BUILD_ONLY; then
  if [[ "$MODE" != modules && "${BIT101_VALIDATION_RESULT_BATCH_HELD:-0}" != 1 ]]; then
    if [[ "$validation_scope" == selected ]]; then
      retained_result_groups=("${(@f)$(python3 "$ROOT_DIR/Scripts/validation_performance.py" begin-selected)}")
      retained_result_groups=("${(@)retained_result_groups:#}")
    else
      retained_result_groups=("${(@f)$(python3 "$ROOT_DIR/Scripts/validation_performance.py" begin-full "$validation_group")}")
      retained_result_groups=("${(@)retained_result_groups:#}")
    fi
  fi
  python3 - "$ROOT_DIR/Scripts" "$DERIVED_ROOT/diagnostics" <<'PYDIAGNOSTICS'
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from validation_artifacts import clear_diagnostic_exports
clear_diagnostic_exports(Path(sys.argv[2]))
PYDIAGNOSTICS
  rm -f "$DERIVED_ROOT/test-metrics.txt" "$DERIVED_ROOT/test-failures.txt"
  if [[ "$MODE" == ui ]]; then : > "$DERIVED_ROOT/ui-tests.log"; fi
fi

if [[ "$MODE" == "modules" ]]; then
  if $BUILD_ONLY; then
    echo "[编译] 模块消费者 · macOS 原生 Release"
    bit101_run_logged "$DERIVED_ROOT/$validation_group.log" "模块编译" \
      xcrun swift build --build-tests -Xswiftc -enable-testing \
        --package-path "$ROOT_DIR" \
        --scratch-path "$DERIVED_ROOT" \
        --configuration release
  else
    echo "[测试] 模块消费者 · macOS 原生 Release"
    MODULE_FILTER_ARGS=()
    if (( ${#TEST_SELECTIONS[@]} > 0 )); then
      module_filter="$(python3 "$ROOT_DIR/Scripts/test_results.py" module-filter "${TEST_SELECTIONS[@]}")"
      MODULE_FILTER_ARGS=(--filter "$module_filter")
    fi
    rm -f "$DERIVED_ROOT/module-events.jsonl"
    bit101_run_logged "$DERIVED_ROOT/$validation_group.log" "模块离线测试" \
      xcrun swift test --enable-code-coverage \
        --event-stream-version 0 --event-stream-output-path "$DERIVED_ROOT/module-events.jsonl" \
        --package-path "$ROOT_DIR" \
        --scratch-path "$DERIVED_ROOT" \
        --configuration release "${MODULE_FILTER_ARGS[@]}"
    if ! CODECOV_PATH="$(xcrun swift test --show-codecov-path --package-path "$ROOT_DIR" --scratch-path "$DERIVED_ROOT" --configuration release 2>> "$DERIVED_ROOT/$validation_group.log")"; then
      echo "[失败] 模块覆盖率路径 · $DERIVED_ROOT/$validation_group.log" >&2
      exit 1
    fi
    python3 "$ROOT_DIR/Scripts/test_results.py" module-metrics "$CODECOV_PATH" "$DERIVED_ROOT/test-metrics.txt" "$ROOT_DIR"
  fi
  exit 0
fi

ui_test_plan() {
  python3 "$ROOT_DIR/Scripts/test_results.py" ui-plan "$DERIVED_ROOT/Build/Products"
}

run_tests() {
  local group="$1"
  local log="$DERIVED_ROOT/$validation_group.log"
  local conditions="$2"
  local only_testing=("-only-testing:$TEST_BUNDLE")
  local failure_summary
  local exit_code
  local diagnostics="never"
  local test_action=test
  local execution_args=()
  local coverage_args=(-enableCodeCoverage YES ENABLE_CODE_COVERAGE=YES)
  local started_at=$SECONDS
  if $BUILD_ONLY; then
    test_action=build-for-testing
  else
    execution_args+=(-resultBundlePath "$RESULT_BUNDLE")
    rm -f "$DERIVED_ROOT/Build/ProfileData/"*/*.profdata(N)
  fi
  if ! $BUILD_ONLY; then
    execution_args+=(-parallel-testing-enabled NO)
  fi
  if (( ${#TEST_SELECTIONS[@]} > 0 )); then
    only_testing=()
    local selection
    local resolved_selections
    resolved_selections="$(bit101_xcode_test_selections "$MODE" "${TEST_SELECTIONS[@]}")" || return 64
    for selection in "${(@f)resolved_selections}"; do
      only_testing+=("-only-testing:$TEST_BUNDLE/$selection")
    done
  elif [[ "$group" != "all-tests" && "$group" != "ui-tests" ]]; then
    if [[ "$MODE" == release-runtime || "$MODE" == catalyst-release-runtime ]]; then
      only_testing=()
      for selection in ${(f)"$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" runtime-suites)"}; do
        only_testing+=("-only-testing:$TEST_BUNDLE/$selection")
      done
    else
      only_testing=("-only-testing:$TEST_BUNDLE/$group")
    fi
  fi

  local project_args=(-project "$PROJECT" -scheme "$TEST_SCHEME" -configuration Release -derivedDataPath "$DERIVED_ROOT")
  if [[ "$BUILD_ONLY" == false ]]; then project_args+=(ONLY_ACTIVE_ARCH=YES); fi
  if [[ "$MODE" == ui && "$BUILD_ONLY" == false ]]; then
    if ! bit101_run_logged "$DERIVED_ROOT/ui-tests-build.log" "UI 宿主编译" xcodebuild build-for-testing -quiet \
      "${project_args[@]}" -destination "$TEST_DESTINATION" \
      "BIT101_WORKFLOW_CONDITIONS=$conditions" "${coverage_args[@]}" \
      ENABLE_TESTABILITY=YES SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
      "${only_testing[@]}" "${SIGNING_ARGS[@]}"; then
      return 1
    fi
    local ui_plan_path
    ui_plan_path="$(ui_test_plan)" || return 1
    project_args=(-xctestrun "$ui_plan_path" -derivedDataPath "$DERIVED_ROOT")
    test_action=test-without-building
  fi
  if [[ "$BUILD_ONLY" == false && "$MODE" != catalyst && "$MODE" != catalyst-release-runtime ]]; then
    bit101_invalidate_restore || return $?
  fi
  if [[ "$BUILD_ONLY" == false ]]; then execution_args+=(-test-timeouts-enabled YES); fi
  local inventory_label="$MODE · 完整库存"
  if (( ${#TEST_SELECTIONS[@]} > 0 )); then inventory_label="$MODE · 定向回归 · ${#TEST_SELECTIONS[@]} 个筛选"; fi
  echo "[$test_action] $inventory_label"
  if bit101_run_logged "$log" "$inventory_label 输出" xcodebuild "$test_action" -quiet \
    "${project_args[@]}" \
    -destination "$TEST_DESTINATION" \
    -collect-test-diagnostics "$diagnostics" \
    "BIT101_WORKFLOW_CONDITIONS=$conditions" \
    "${coverage_args[@]}" \
    ENABLE_TESTABILITY=YES \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    "${execution_args[@]}" \
    "${only_testing[@]}" \
    "${SIGNING_ARGS[@]}"; then
    exit_code=0
  else
    exit_code=$?
  fi
  TEST_DURATION_SECONDS=$(( SECONDS - started_at ))

  if (( exit_code != 0 )) && ! $BUILD_ONLY; then
    echo "测试失败：$group" >&2
    failure_summary="$(python3 "$ROOT_DIR/Scripts/test_results.py" failures "$RESULT_BUNDLE"    )"
    if [[ -n "$failure_summary" ]]; then
      printf '%s\n' "$failure_summary" > "$DERIVED_ROOT/test-failures.txt"
      if (( ${#${(f)failure_summary}} <= 40 )); then
        print -r -- "$failure_summary"
      else
        echo "失败摘要共 ${#${(f)failure_summary}} 行 · $DERIVED_ROOT/test-failures.txt"
      fi
    fi
  fi

  if (( exit_code != 0 )); then
    if ! $BUILD_ONLY; then record_metrics; fi
    exit 1
  fi
}

record_metrics() {
  python3 "$ROOT_DIR/Scripts/test_results.py" native-metrics "$RESULT_BUNDLE" "$DERIVED_ROOT/test-metrics.txt" "$MODE" "$TEST_DURATION_SECONDS" "${BIT101_XCODE_DEVICE_ID:-}" "$ROOT_DIR"
}

CONDITIONS="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" conditions "$MODE")"

case "$MODE" in
  release)
    run_tests all-tests "$CONDITIONS"
    ;;
  release-runtime|catalyst-release-runtime)
    run_tests ReleaseRuntimeContractTests "$CONDITIONS"
    ;;
  network-smoke)
    run_tests ReleaseNetworkSmokeTests "$CONDITIONS"
    ;;
  icloud-smoke)
    run_tests ICloudCrossDeviceSmokeTests "$CONDITIONS"
    ;;
  all)
    run_tests all-tests "$CONDITIONS"
    ;;
  schedule)
    run_tests ExtendedSchedulePolicyTests "$CONDITIONS"
    ;;
  infrastructure)
    run_tests NetworkDiagnosticSupportTests "$CONDITIONS"
    ;;
  login)
    run_tests ExtendedLoginTests "$CONDITIONS"
    ;;
  extensions)
    run_tests ExternalScheduleInfrastructureTests "$CONDITIONS"
    ;;
  ui)
    run_tests ui-tests "$CONDITIONS"
    ;;
  catalyst)
    run_tests all-tests "$CONDITIONS"
    ;;
esac

if $BUILD_ONLY; then
  if [[ "$MODE" == ui ]]; then ui_test_plan >/dev/null; fi
  echo "测试宿主编译完成，可通过同一入口批量执行用例。"
else
  record_metrics
fi
