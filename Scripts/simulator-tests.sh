#!/bin/zsh
if [[ -z "${ZSH_EXECUTION_STRING:-}" ]]; then
  exec zsh -c "$(<"$0")" "$0" "$@"
fi
set -euo pipefail
[[ "${BIT101_SIMULATOR_AUTHORIZED:-0}" == 1 ]] || { echo "模拟器流程需要用户显式授权及 BIT101_SIMULATOR_AUTHORIZED=1。" >&2; exit 64; }
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/Scripts/script-support.sh"
operation="${1:-info}"
shift $(( $# > 0 ? 1 : 0 ))
case "$operation" in info|prepare|restore|inspect) [[ $# -eq 0 ]] || exit 64;; app|release-runtime|ui) ;; *) exit 64;; esac
TEST_SCOPE=selected
if (( $# == 0 )); then TEST_SCOPE=full; fi
bit101_acquire_workflow_lock "$0" "$operation" "$@"
DERIVED_ROOT="$ROOT_DIR/.build/extended-automation"
mkdir -p "$DERIVED_ROOT"
if SIMULATOR_DEVICE="$(python3 - "$DERIVED_ROOT/simulator-device.json" "$operation" 2>> "$DERIVED_ROOT/simulator.log" <<'PYDEVICE'
import json
import os
from pathlib import Path
import subprocess
import sys

path, operation = Path(sys.argv[1]), sys.argv[2]
def inventory(): return json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], text=True))
def runtimes(data): return [row for row in data['runtimes'] if row.get('isAvailable') and '.iOS-' in row['identifier']]
data = inventory()
available = runtimes(data)
if operation == 'info':
    print('可用 iOS 模拟器运行时：' + ', '.join(row['version'] for row in available))
    raise SystemExit(0)
if not available:
    subprocess.run(['xcodebuild', '-downloadPlatform', 'iOS'], check=True, stdout=sys.stderr, stderr=sys.stderr)
    data = inventory()
    available = runtimes(data)
if not available: raise SystemExit('iOS 模拟器运行时安装完成后需要出现在系统库存。')
if path.is_file():
    owned = json.loads(path.read_text())
    device = next((row for rows in data['devices'].values() for row in rows if row['udid'] == owned['identifier']), None)
    if device is None or not device.get('isAvailable'): raise SystemExit('项目模拟器需要恢复可用状态。')
    identifier = owned['identifier']
else:
    runtime = max(available, key=lambda row: tuple(map(int, row['version'].split('.'))))
    phone = next(row for row in runtime['supportedDeviceTypes'] if row['name'].startswith('iPhone'))
    identifier = subprocess.check_output(['xcrun', 'simctl', 'create', 'BIT101', phone['identifier'], runtime['identifier']], text=True).strip()
    path.write_text(json.dumps({'identifier': identifier, 'runtime': runtime['identifier']}) + '\n')
    device = {'state': 'Shutdown'}
if device['state'] != 'Booted': subprocess.run(['xcrun', 'simctl', 'boot', identifier], check=True, stdout=sys.stderr, stderr=sys.stderr)
if os.getenv('GITHUB_ACTIONS') == 'true':
    subprocess.run(['defaults', 'write', 'com.apple.iphonesimulator', 'ConnectHardwareKeyboard', '-bool', 'false'], check=True)
subprocess.run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], check=True, stdout=sys.stderr, stderr=sys.stderr)
developer = Path(os.getenv('DEVELOPER_DIR') or subprocess.check_output(['xcode-select', '-p'], text=True).strip())
subprocess.run(['open', '-a', str(developer.parent / 'Applications/DeviceHub.app')], check=True)
print(identifier)
PYDEVICE
)"; then
  :
else
  echo "模拟器准备失败：$DERIVED_ROOT/simulator.log" >&2
  exit 1
fi
if [[ "$operation" == info ]]; then print -r -- "$SIMULATOR_DEVICE"; exit 0; fi
if [[ "$operation" == prepare ]]; then echo "项目模拟器已就绪。"; exit 0; fi
if [[ "$operation" == inspect ]]; then
  python3 - "$SIMULATOR_DEVICE" "$ROOT_DIR/.build/screenshot.png" <<'PYINSPECT'
import json
import plistlib
from pathlib import Path
import subprocess
import sys

app = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', sys.argv[1], 'BIT101-dev.BIT101-iOS', 'app'], text=True).strip())
metadata = plistlib.loads((app / 'Info.plist').read_bytes())
binary = subprocess.check_output(['strings', str(app / metadata['CFBundleExecutable'])], text=True)
markers = ['behavior-test-host', 'release-network-smoke-host', 'icloud-cross-device-smoke-host', 'The UI automation App requires its isolated launch configuration']
print(json.dumps({'device': sys.argv[1], 'version': metadata['CFBundleShortVersionString'], 'build': metadata['CFBundleVersion'],
    'testHostMarkers': [marker for marker in markers if marker in binary]}, ensure_ascii=False))
subprocess.run(['xcrun', 'simctl', 'io', sys.argv[1], 'screenshot', sys.argv[2]], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(sys.argv[2])
PYINSPECT
  exit 0
fi
restore_application() {
  local restore_digest
  restore_digest="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" digest restore)" || return $?
  bit101_run_logged "$DERIVED_ROOT/build-release.log" "常规模拟器包编译" xcodebuild build -quiet \
    -project "$ROOT_DIR/BIT101-iOS.xcodeproj" -scheme BIT101-iOS -configuration Release -derivedDataPath "$DERIVED_ROOT" \
    -destination "platform=iOS Simulator,id=$SIMULATOR_DEVICE" BIT101_WORKFLOW_CONDITIONS= \
    "BIT101_RESTORE_INPUT_DIGEST=$restore_digest" CODE_SIGN_IDENTITY=- || return $?
  bit101_run_logged "$DERIVED_ROOT/restore.log" "常规模拟器包恢复" python3 - "$SIMULATOR_DEVICE" \
    "$DERIVED_ROOT/Build/Products/Release-iphonesimulator/BIT101-iOS.app" "$ROOT_DIR/Scripts" "$restore_digest" \
    "$ROOT_DIR/.build/screenshot.png" <<'PYRESTORE'
import json
import subprocess
import sys
import time
import uuid
subprocess.run(['xcrun', 'simctl', 'install', sys.argv[1], sys.argv[2]], check=True)
from hashlib import sha256
from pathlib import Path
import plistlib
source = Path(sys.argv[2])
info = plistlib.loads((source / 'Info.plist').read_bytes())
executable = info['CFBundleExecutable']
installed = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', sys.argv[1], 'BIT101-dev.BIT101-iOS', 'app'], text=True).strip())
if sha256((source / executable).read_bytes()).digest() != sha256((installed / executable).read_bytes()).digest():
    raise SystemExit('安装后的可执行文件需要匹配常规 Release 产物。')
sys.path.insert(0, sys.argv[3])
from validation_restore import complete, matches_app
container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', sys.argv[1], 'BIT101-dev.BIT101-iOS', 'data'], text=True).strip())
readiness = container / 'Documents/restore-readiness.json'
readiness.unlink(missing_ok=True)
run_id = str(uuid.uuid4())
launched = subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', sys.argv[1],
    'BIT101-dev.BIT101-iOS', '--restore-run-id', run_id], check=True, capture_output=True, text=True)
process_id = int(launched.stdout.rsplit(':', 1)[1].strip())
deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    if subprocess.run(['/bin/kill', '-0', str(process_id)], capture_output=True).returncode:
        raise SystemExit('常规模拟器 App 在就绪前退出，请检查启动崩溃。')
    if readiness.is_file():
        proof = json.loads(readiness.read_text())
        proof = dict(proof, kind='restore', processAlive=True, startedAt=proof.get('readyAt'), finishedAt=proof.get('readyAt'))
        if proof.get('processIdentifier') == process_id and complete(proof) and matches_app(proof, info, run_id, sys.argv[4]):
            subprocess.run(['xcrun', 'simctl', 'io', sys.argv[1], 'screenshot', sys.argv[5]],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            break
    time.sleep(1)
else:
    subprocess.run(['xcrun', 'simctl', 'io', sys.argv[1], 'screenshot', sys.argv[5]],
        check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['xcrun', 'simctl', 'spawn', sys.argv[1], 'log', 'show', '--style', 'compact', '--last', '2m',
        '--predicate', 'subsystem == "BIT101" AND (category == "RestoreReadiness" OR category == "LoginKeychain")'],
        check=False, stdout=sys.stderr, stderr=sys.stderr)
    raise SystemExit('常规模拟器 App 就绪验收超时，请检查登录恢复与场景初始化。')
PYRESTORE
}
typeset -a retained_result_groups=()
restore_on_exit() {
  local workflow_result=$?
  trap - EXIT
  if (( ${#retained_result_groups[@]} )); then
    python3 "$ROOT_DIR/Scripts/validation_performance.py" retain-evidence "${retained_result_groups[@]}" || workflow_result=$?
  fi
  if restore_application; then
    echo "常规模拟器包已恢复。"
  else
    local restore_result=$?
    if (( workflow_result == 0 )); then workflow_result=$restore_result; fi
  fi
  exit "$workflow_result"
}
if [[ "$operation" == restore ]]; then restore_application; echo "常规模拟器包已恢复。"; exit 0; fi
mode=all
scheme=BIT101-iOS
bundle=BIT101-iOSTests
configuration=Debug
selections=("$@")
if [[ "$operation" == release-runtime ]]; then
  mode=release-runtime
  configuration=Release
fi
if [[ "$operation" == ui ]]; then
  mode=ui
  scheme=BIT101-iOS-UIAutomation
  bundle=BIT101-iOSUITests
  configuration=Release
  selections=("${(@f)$(bit101_ui_test_selections "$@")}")
fi
if [[ "$TEST_SCOPE" == full ]]; then
  selections=("${(@f)$(python3 - "$ROOT_DIR/Scripts" "$mode" <<'PYINVENTORY'
import sys
sys.path.insert(0, sys.argv[1])
from validation_evidence import normalized_test_id, test_inventory
print('\n'.join(sorted(normalized_test_id(test) for test in test_inventory(sys.argv[2]))))
PYINVENTORY
)}")
fi
EXPECTED_TESTS="$(python3 - "$ROOT_DIR/Scripts" "$mode" "${selections[@]}" <<'PYSELECT'
import json, sys
sys.path.insert(0, sys.argv[1])
from validation_evidence import selected_test_inventory
print(json.dumps(sorted(selected_test_inventory(sys.argv[2], sys.argv[3:]))))
PYSELECT
)"
conditions="$(python3 "$ROOT_DIR/Scripts/validation_evidence.py" conditions "$mode")"
only_testing=()
selections=("${(@f)$(bit101_xcode_test_selections "$mode" "${selections[@]}")}")
for selection in "${selections[@]}"; do only_testing+=("-only-testing:$bundle/$selection"); done
destination="platform=iOS Simulator,id=$SIMULATOR_DEVICE"
result="$DERIVED_ROOT/test-results.xcresult"
bit101_run_logged "$DERIVED_ROOT/$mode.log" "模拟器测试宿主编译" xcodebuild build-for-testing -quiet \
  -project "$ROOT_DIR/BIT101-iOS.xcodeproj" -scheme "$scheme" -configuration "$configuration" -derivedDataPath "$DERIVED_ROOT" \
  -destination "$destination" "BIT101_WORKFLOW_CONDITIONS=$conditions" ENABLE_TESTABILITY=YES \
  -enableCodeCoverage YES ENABLE_CODE_COVERAGE=YES \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGN_IDENTITY=- "${only_testing[@]}"
plan="$(python3 - "$DERIVED_ROOT/Build/Products" "$scheme" <<'PYPLAN'
from pathlib import Path
import sys
plans = list(Path(sys.argv[1]).glob(sys.argv[2] + '_*iphonesimulator*.xctestrun'))
if not plans: raise SystemExit('模拟器编译需要生成对应的运行配置。')
print(max(plans, key=lambda path: path.stat().st_mtime))
PYPLAN
)"
retained_result_groups=("${(@f)$(python3 "$ROOT_DIR/Scripts/validation_performance.py" begin-selected)}")
retained_result_groups=("${(@)retained_result_groups:#}")
rm -f "$DERIVED_ROOT/test-metrics.txt" "$DERIVED_ROOT/test-failures.txt"
rm -f "$DERIVED_ROOT/Build/ProfileData/$SIMULATOR_DEVICE/"*.profdata(N)
test_status=0
trap restore_on_exit EXIT
bit101_run_logged "$DERIVED_ROOT/$mode.log" "模拟器测试" xcodebuild test-without-building -quiet \
  -xctestrun "$plan" -derivedDataPath "$DERIVED_ROOT" -destination "$destination" -resultBundlePath "$result" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -enableCodeCoverage YES "${only_testing[@]}" || test_status=$?
python3 - "$result" "$DERIVED_ROOT/test-metrics.txt" "$ROOT_DIR/Scripts" "$EXPECTED_TESTS" "$test_status" "$mode" "$SIMULATOR_DEVICE" "$configuration" "$TEST_SCOPE" <<'PYRESULT'
import json
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, sys.argv[3])
from validation_evidence import normalized_test_id, validate_community_write_test_output, native_case_summary, selected_test_summary_complete, native_source_coverage, coverage_complete, REPORT
from validation_environment import ci_commit_findings
from validation_coverage import regressions, policy_floors
from validation_performance import result_bundle_complete
result = Path(sys.argv[1])
if not result_bundle_complete(result):
    raise SystemExit('模拟器测试执行结束，结果包处于未完成状态；请查看 simulator.log 并重新采样。')
def read(kind): return json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', sys.argv[1]], text=True))
summary, tree = read('summary'), read('tests')
executed = set()
raw_executed = set()
def visit(value):
    if isinstance(value, dict):
        if value.get('nodeType') == 'Test Case':
            raw_executed.add(value['nodeIdentifier'])
            executed.add(normalized_test_id(value['nodeIdentifier']))
        for child in value.values(): visit(child)
    elif isinstance(value, list):
        for child in value: visit(child)
visit(tree)
expected = set(json.loads(sys.argv[4]))
scope = '完整验收' if sys.argv[9] == 'full' else '定向复验'
headline = (f"模拟器{scope}\n结果：{summary.get('result', '?')}；总计 {summary.get('totalTestCount', 0)}；"
    f"通过 {summary.get('passedTests', 0)}；失败 {summary.get('failedTests', 0)}；跳过 {summary.get('skippedTests', 0)}\n")
text = headline + "已执行用例：" + json.dumps(sorted(executed)) + '\n'
cases = native_case_summary(tree, sys.argv[6], simulator=True, device_identifier=sys.argv[7])
text += "测试实例：" + json.dumps(cases) + '\n'
for failure in summary.get('testFailures', []):
    text += f"{failure.get('testIdentifierString', '?')}: {failure.get('failureText', '?')}\n"
Path(sys.argv[2]).write_text(text)
native_summary = {'passed': summary.get('result') == 'Passed', 'totalTests': summary.get('totalTestCount'),
    'passedTests': summary.get('passedTests'), 'failedTests': summary.get('failedTests'), 'skippedTests': summary.get('skippedTests'),
    'executedTests': sorted(executed), 'testCases': cases}
if int(sys.argv[5]) or not selected_test_summary_complete(native_summary, sorted(expected), group=sys.argv[6], simulator=True):
    print(headline, file=sys.stderr, end='')
    for failure in summary.get('testFailures', []):
        message = str(failure.get('failureText', '?')).splitlines()[0]
        print(f"{failure.get('testIdentifierString', '?')}: {message}", file=sys.stderr)
    if executed != expected:
        print(f"库存差异：缺少 {sorted(expected - executed)}；额外 {sorted(executed - expected)}", file=sys.stderr)
    print(f"详细结果：{sys.argv[2]}", file=sys.stderr)
    raise SystemExit('模拟器测试需要全部用例通过，并匹配实际执行库存。')
if sys.argv[9] == 'full' and sys.argv[6] in {'all', 'ui'}:
    targets = json.loads(subprocess.check_output(['xcrun', 'xccov', 'view', '--report', '--json', sys.argv[1]], text=True))['targets']
    coverage = {row['name']: {key: row[key] for key in ('coveredLines', 'executableLines')}
        for row in targets if row['name'] == 'BIT101-iOS.app'}
    build = result.parent / 'Build'
    modules = native_source_coverage(build / 'Products' / (sys.argv[8] + '-iphonesimulator'),
        build / 'ProfileData' / sys.argv[7] / 'Coverage.profdata')
    coverage.update({'iOS/' + name: dict(coveredLines=covered, executableLines=executable)
        for name, (covered, executable) in modules.items()})
    native_summary['coverage'] = coverage
    policy = json.loads(REPORT.read_text()).get('coveragePolicy', {}) if REPORT.is_file() else {}
    failures = regressions(coverage, policy_floors(sys.argv[6], policy))
    with Path(sys.argv[2]).open('a') as metrics:
        metrics.write('覆盖率：' + json.dumps(coverage) + '\n')
    if not coverage_complete(sys.argv[6], native_summary) or failures:
        raise SystemExit('模拟器完整覆盖率需要满足版本化阈值：' + '；'.join(failures))
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
if failures := ci_commit_findings(commit): raise SystemExit('\n'.join(failures))
validate_community_write_test_output(Path(sys.argv[1]), raw_executed)
print(f"模拟器{scope}通过：{summary['passedTests']} 项。")
PYRESULT
