"""Production code, script and workflow quality rules."""
from __future__ import annotations

from pathlib import Path
import ast
import importlib.util
import json
import re
import stat
import subprocess
import sys
from swift_source_index import swift_syntax_index


sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOTS = (
    ROOT / "Modules",
    ROOT / "BIT101-iOS",
    ROOT / "BIT101-iOSTests",
    ROOT / "ModuleTests",
    ROOT / "BIT101ScheduleWidgets",
    ROOT / "BIT101Watch",
    ROOT / "BIT101WatchWidgets",
)
SCRIPT_ROOT = ROOT / "Scripts"
REPORT_PATH = ROOT / ".build/code-quality-report.txt"

DIRECT_STDOUT_LOG = re.compile(r"\b(?:print|debugPrint|NSLog)\s*\(")

DIRECT_VIEW_REQUEST = re.compile(r"\bURLRequest\s*\(")
FORCE_UNWRAP = re.compile(r"\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*!(?!=)|\)\s*!(?!=)")

DIRECT_DATE_FORMATTER = re.compile(
    r"\b(?:DateFormatter|ISO8601DateFormatter|RelativeDateTimeFormatter)\s*\("
)

STDOUT_EXCEPTIONS = {"BIT101-iOS/Shared/Client/ReleaseNetworkSmoke.swift"}


def ast_has_identifier(facts: dict, name: str) -> bool:
    return name in facts["identifiers"]


def ast_has_view_request(facts: dict) -> bool:
    view_types = {
        declaration["name"]
        for declaration in facts["declarations"]
        if any(
            inherited.rsplit(".", 1)[-1] == "View"
            for inherited in declaration["inheritedTypes"]
        )
    }
    return any(
        call["value"] in {"URLRequest", "Swift.URLRequest"}
        and any(view_type in call["scope"] for view_type in view_types)
        for call in facts["calls"]
    )


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def swift_files() -> list[Path]:
    return sorted(
        path
        for source_root in SOURCE_ROOTS
        if source_root.is_dir()
        for path in source_root.rglob("*.swift")
    )


def line_number(source: str, position: int) -> int:
    return source.count("\n", 0, position) + 1


def _blank_segment(output: list[str], source: str, start: int, end: int) -> None:
    for index in range(start, min(end, len(source))):
        if source[index] != "\n":
            output[index] = " "


def mask_literals_and_comments(source: str) -> str:
    """复用模块检查器的 Swift 词法扫描，保留插值表达式与源码位置。"""
    name = "check_module_boundaries_lexer"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, SCRIPT_ROOT / "check-module-boundaries.py")
        if spec is None or spec.loader is None:
            raise RuntimeError("Swift 词法扫描器加载失败")
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name].swift_code(source)


def is_view_source(path: Path, code: str) -> bool:
    if path.name.endswith(("View.swift", "Views.swift", "Screen.swift", "Screens.swift")):
        return True
    return re.search(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b",
        code,
    ) is not None


def view_declaration_ranges(code: str) -> list[tuple[int, int]]:
    """返回真实 View 声明的范围，避免把同文件的缓存/Loader 当成 View。"""
    ranges: list[tuple[int, int]] = []
    declaration = re.compile(
        r"\b(?:struct|class|enum)\s+[A-Za-z_][A-Za-z0-9_]*\s*:[^{\n]*\bView\b[^{}]*\{"
    )
    for match in declaration.finditer(code):
        opening = code.find("{", match.start(), match.end())
        depth = 0
        for index in range(opening, len(code)):
            if code[index] == "{":
                depth += 1
            elif code[index] == "}":
                depth -= 1
                if depth == 0:
                    ranges.append((match.start(), index + 1))
                    break
    return ranges


def view_request_matches(code: str) -> list[re.Match[str]]:
    ranges = view_declaration_ranges(code)
    return [
        match
        for match in DIRECT_VIEW_REQUEST.finditer(code)
        if any(start <= match.start() < end for start, end in ranges)
    ]


def add_matches(
    findings: list[str],
    path: Path,
    source: str,
    pattern: re.Pattern[str],
    message: str,
) -> None:
    for match in pattern.finditer(source):
        findings.append(f"{relative(path)}:{line_number(source, match.start())}: {message}")


def owner_scopes(syntax_index: dict[str, dict], owner: str) -> list[tuple[dict, list[str]]]:
    return [
        (facts, declaration["scope"] + [declaration["name"]])
        for facts in syntax_index.values()
        for declaration in facts["declarations"]
        if declaration["name"] == owner
        and declaration["kind"] in {"struct", "class", "actor", "extension"}
    ]


def owner_has_call(syntax_index: dict[str, dict], owner: str, call_name: str) -> bool:
    return any(
        any(
            (call["value"] == call_name or call["value"].endswith("." + call_name))
            and call["scope"] == scope
            for call in facts["calls"]
        )
        for facts, scope in owner_scopes(syntax_index, owner)
    )


def uses_application_support_storage(member: dict) -> bool:
    return any(
        entry in member["value"]
        for entry in (
            "AppFileDirectories.applicationSupport",
            "AppFileDirectories.accountSupportFileURL",
        )
    )


def client_source_findings(path: Path, source: str, facts: dict | None = None) -> list[str]:
    production_roots = (ROOT / "Modules", ROOT / "BIT101-iOS", ROOT / "BIT101ScheduleWidgets", ROOT / "BIT101Watch", ROOT / "BIT101WatchWidgets")
    if not any(path.is_relative_to(root) for root in production_roots):
        return []
    errors: list[str] = []
    name = relative(path)
    code = mask_literals_and_comments(source)
    if name not in STDOUT_EXCEPTIONS:
        add_matches(errors, path, code, DIRECT_STDOUT_LOG, "诊断输出使用所属模块的 Logger")
    community_roots = tuple(ROOT / "Modules" / module for module in ("CourseFeature", "GalleryFeature", "PaperFeature", "MineFeature", "CommunityUI"))
    if any(path.is_relative_to(root) for root in community_roots) and is_view_source(path, code):
        add_matches(errors, path, code, DIRECT_DATE_FORMATTER, "社区日期解析统一使用 AppDateText")
    return errors


def source_findings(syntax_index: dict[str, dict] | None = None) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    review: list[str] = []
    direct_cancellation_check = re.compile(r"\berror\s+is\s+CancellationError\b")
    empty_catch = re.compile(r"\bcatch\s*\{\s*\}")
    unsafe_concurrency_escape = re.compile(
        r"\bnonisolated\s*\(\s*unsafe\s*\)|@\s*unchecked\s+Sendable"
    )

    large_files: list[str] = []
    for path in swift_files():
        source = path.read_text(encoding="utf-8")
        masked_source = mask_literals_and_comments(source)
        name = relative(path)

        errors.extend(client_source_findings(path, source, syntax_index.get(str(path)) if syntax_index else None))

        if source and not source.endswith("\n"):
            errors.append(f"{name}: 文件末尾缺少换行")
        if "\t" in source:
            errors.append(f"{name}: Swift 源码不得使用 Tab 缩进")
        if any(line.rstrip() != line for line in source.splitlines()):
            errors.append(f"{name}: 存在行尾空白")
        import_lines = [
            (match.start(), match.group(1), source.count("\n", 0, match.start()) + 1)
            for match in re.finditer(r"^import\s+([^\s]+)", source, re.MULTILINE)
        ]
        # 同一条件分支内相邻的重复 import 通常是复制残留；#if/#else 两个分支各自
        # 引入同一模块属于必要代码，不报告。
        for index, (position, module, line) in enumerate(import_lines[:-1]):
            next_position, next_module, next_line = import_lines[index + 1]
            if module == next_module and next_line - line <= 1:
                errors.append(f"{name}:{line}: 重复 import {module}")

        if re.search(r"^\s*#if\s+false\b", masked_source, re.MULTILINE):
            errors.append(f"{name}: 不应保留 #if false 死代码块")
        add_matches(errors, path, masked_source, re.compile(r"\b(?:TODO|FIXME|HACK)\b"), "请清理遗留 TODO/FIXME/HACK")

        if name != relative(ROOT / "BIT101-iOS/Shared/Client/TaskCancellation.swift"):
            add_matches(errors, path, masked_source, direct_cancellation_check, "任务取消必须通过 TaskCancellation.matches 统一识别")
        add_matches(errors, path, masked_source, empty_catch, "禁止静默吞掉异常；请记录诊断或显式处理错误")
        add_matches(errors, path, masked_source, unsafe_concurrency_escape, "禁止绕过 Swift 并发安全检查：请表达真实隔离或使用锁/Actor")
        facts = syntax_index.get(str(path)) if syntax_index else None
        if facts and ast_has_view_request(facts):
            errors.append(f"{name}: View 不应直接构造 URLRequest；请求移到 Service")
        elif facts is None:
            for match in view_request_matches(masked_source):
                errors.append(
                    f"{name}:{line_number(source, match.start())}: "
                    "View 不应直接构造 URLRequest；请求移到 Service"
                )

        force_count = len(FORCE_UNWRAP.findall(masked_source))
        if force_count:
            errors.append(f"{name}: 禁止强制解包，共 {force_count} 处；请改用 guard/if let/#require")
        source_line_count = len(source.splitlines())
        if source_line_count > 800:
            large_files.append(name)

    if large_files:
        review.append("大型文件候选（按独立生命周期拆分，不因长度机械拆分）：" + ", ".join(large_files))
    return errors, review


def script_findings() -> list[str]:
    errors: list[str] = []
    for path in sorted(SCRIPT_ROOT.glob("*")):
        if path.suffix not in {".sh", ".py"} or not path.is_file():
            continue
        source = path.read_text(encoding="utf-8")
        tree = ast.parse(source) if path.suffix == ".py" else None
        entry = path.suffix == ".sh" or any(
            isinstance(node, ast.If) and any(isinstance(item, ast.Name) and item.id == "__name__"
                for item in ast.walk(node.test)) for node in tree.body
        )
        if entry and not source.startswith("#!"):
            errors.append(f"{relative(path)}: 入口脚本需要 shebang")
        if entry and not (path.stat().st_mode & stat.S_IXUSR):
            errors.append(f"{relative(path)}: 入口脚本需要用户可执行权限")
        if tree and any(isinstance(node, ast.Import) and any(alias.name == "py_compile" for alias in node.names)
                        for node in ast.walk(tree)):
            errors.append(f"{relative(path)}: Python 语法检查使用内存 compile")
        if path.suffix == ".sh" and re.search(
            r"(?:mktemp|date[^\n]*%|uuidgen|\$\$)\s*[^\n]*(?:/|PATH|DIR|FILE|OUTPUT)", source
        ):
            errors.append(f"{relative(path)}: 输出路径需要固定类别名称")
    return errors


def automatic_school_fetch_findings(syntax_index: dict[str, dict]) -> list[str]:
    """保证启动、回前台和账号切换不会重新引入学校/WebVPN 自动请求。"""
    errors: list[str] = []
    forbidden_identifiers = (
        "SchoolDataRefreshCoordinator",
        "refreshOnEntry",
        "ScheduleAutoRefreshPreferences",
        "ScoreAutomaticRefreshPolicy",
        "autoRefreshCourses",
        "prepareClassroomIfNeeded",
        "refreshClassroomMetaInBackgroundIfNeeded",
        "claimAutomaticPreparation",
    )
    forbidden_literals = ("schedule.auto-refresh", "silent-refresh")
    for path in swift_files():
        facts = syntax_index[str(path)]
        for term in forbidden_identifiers:
            if ast_has_identifier(facts, term):
                errors.append(f"{relative(path)}: 不得重新引入学校/WebVPN 自动请求：{term}")
        for term in forbidden_literals:
            if any(term in literal["value"] for literal in facts["stringSegments"]):
                errors.append(f"{relative(path)}: 不得重新引入学校/WebVPN 自动请求：{term}")

    if owner_has_call(syntax_index, "BIT101_iOSApp", "refreshFromCloudIfNeeded"):
        errors.append("BIT101_iOSApp: 启动生命周期不得自动拉取 iCloud 数据")
    if owner_has_call(syntax_index, "ScheduleViewModel", "refreshFromCloudIfNeeded"):
        errors.append("ScheduleViewModel: 日程页面本地恢复不得自动拉取 iCloud")
    if owner_has_call(syntax_index, "ScoreListPage", "bootstrapIfNeeded"):
        errors.append("ScoreListPage: 成绩页不得自动触发学校查询")


    return errors


def audit_wiring_findings() -> list[str]:
    """检查统一静态审计入口与 CI 门禁。"""
    errors: list[str] = []
    audit_path = ROOT / "Scripts/run-static-audit.sh"
    audit_source = audit_path.read_text(encoding="utf-8")
    groups = re.search(r"^group_names=\(([^\n]+)\)$", audit_source, re.MULTILINE)
    commands = re.search(r"^group_commands=\(([^\n]+)\)$", audit_source, re.MULTILINE)
    wiring = dict(zip(groups[1].split(), commands[1].split())) if groups and commands and len(groups[1].split()) == len(commands[1].split()) else {}
    if wiring.get("checkers") != "checker_audit":
        errors.append("Scripts/run-static-audit.sh: 未接入共享索引检查器审计")
    if "check-docs.py --all" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 未接入文档引用检查")
    if wiring.get("dependency-audit") != "dependency_audit":
        errors.append("Scripts/run-static-audit.sh: 未接入锁定依赖漏洞审计")
    if "npm audit --audit-level=high" not in audit_source:
        errors.append("Scripts/run-static-audit.sh: 依赖漏洞审计门槛缺失")
    if "release-network-smoke" in audit_source:
        errors.append("Scripts/run-static-audit.sh: 静态审计不得调用网络 smoke")

    workflow_path = ROOT / ".github/workflows/ci.yml"
    if not workflow_path.is_file():
        errors.append(".github/workflows/ci.yml: CI 工作流不存在")
    else:
        errors.extend(ci_wiring_findings(workflow_path.read_text(encoding="utf-8")))
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(ROOT / "BIT101-iOS.xcodeproj/project.pbxproj"),
    ], text=True))
    errors.extend(extension_dependency_findings(project))
    for configuration in project["objects"].values():
        if configuration.get("isa") == "XCBuildConfiguration" and "SWIFT_COMPILATION_MODE" in configuration.get("buildSettings", {}):
            if "$(BIT101_WORKFLOW_CONDITIONS)" not in configuration["buildSettings"].get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""):
                errors.append("App 工程编译条件需要接入工作流变量")
    for name in ("run-extended-tests.sh", "run_icloud_cross_device_smoke.sh", "release-network-smoke.sh"):
        if "SWIFT_ACTIVE_COMPILATION_CONDITIONS=" in (SCRIPT_ROOT / name).read_text():
            errors.append(f"{name}: 工作流条件需要限定在 App 工程")

    test_script = ROOT / "Scripts/run-extended-tests.sh"
    if not test_script.is_file():
        errors.append("Scripts/run-extended-tests.sh: 真机测试入口不存在")
    else:
        test_source = test_script.read_text(encoding="utf-8")
        required_test_metrics = (
            ("-enableCodeCoverage YES", "真机测试未启用代码覆盖率"),
            ("ENABLE_CODE_COVERAGE=YES", "Release 测试构建未覆盖项目级关闭项"),
            ("xccov", "真机测试未提取代码覆盖率"),
            ("test-metrics.txt", "真机测试指标未写入固定报告"),
            ("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "发布测试编译需要 Swift 警告门禁"),
            ("GCC_TREAT_WARNINGS_AS_ERRORS=YES", "发布测试编译需要 Clang 警告门禁"),
            ("--enable-code-coverage", "模块测试需要生产源码覆盖率"),
            ("generic/platform=iOS", "测试编译需要通用 iOS 目的地"),
            ("extensions)", "缺少扩展共享逻辑测试分组"),
            ("ExternalScheduleInfrastructureTests", "扩展共享逻辑分组未执行对应测试套件"),
        )
        for marker, message in required_test_metrics:
            if marker not in test_source:
                errors.append(f"Scripts/run-extended-tests.sh: {message}")

    hook_path = ROOT / ".githooks/pre-commit"
    if not hook_path.is_file() or "Scripts/check-docs.py --all" not in hook_path.read_text(encoding="utf-8"):
        errors.append(".githooks/pre-commit: 提交前必须检查文档引用")
    return errors


def extension_dependency_findings(project: dict) -> list[str]:
    objects = project["objects"]
    targets = {value["name"]: key for key, value in objects.items() if value.get("isa") == "PBXNativeTarget"}
    errors = []
    for parent, child in (
        ("BIT101-iOS", "BIT101ScheduleWidgets"),
        ("BIT101-iOS", "BIT101Watch"),
        ("BIT101Watch", "BIT101WatchWidgets"),
    ):
        dependencies = objects.get(targets.get(parent), {}).get("dependencies", [])
        children = {objects[dependency].get("target") for dependency in dependencies}
        if targets.get(child) is None or targets[child] not in children:
            errors.append(f"project.pbxproj: {parent} 必须通过 target 依赖编译 {child}")
        if parent == "BIT101-iOS":
            for dependency in dependencies:
                edge = objects[dependency]
                if edge.get("target") == targets.get(child) and edge.get("platformFilter") != "ios":
                    errors.append(f"project.pbxproj: {child} 的 App 依赖应限定为 iOS 平台")
    return errors


def ci_wiring_findings(workflow_source: str) -> list[str]:
    errors: list[str] = []
    active_lines = [line for line in workflow_source.splitlines() if not line.lstrip().startswith("#")]
    source = "\n".join(active_lines) + "\n"

    def job_body(name: str) -> str | None:
        match = re.search(
            rf"(?ms)^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:|\Z)",
            source,
        )
        return match.group("body") if match else None

    def run_commands(job: str) -> list[str]:
        commands: list[str] = []
        lines = job.splitlines()
        for index, line in enumerate(lines):
            match = re.match(r"^        run:\s*(.*?)\s*$", line)
            if match is None:
                continue
            command = match.group(1)
            if command in {"|", "|-", ">", ">-"}:
                body: list[str] = []
                for following in lines[index + 1:]:
                    if following.strip() and len(following) - len(following.lstrip()) <= 8:
                        break
                    body.append(following.strip())
                command = " ".join(body)
            commands.append(command)
        return commands

    static_job = job_body("static-audit")
    release_job = job_body("release-build")
    catalyst_job = job_body("catalyst-tests")
    if static_job is None:
        errors.append(".github/workflows/ci.yml: CI 未声明静态审计 Job")
    elif "Scripts/run-static-audit.sh" not in run_commands(static_job):
        errors.append(".github/workflows/ci.yml: 静态审计 Job 缺少执行入口")
    if release_job is None:
        errors.append(".github/workflows/ci.yml: 缺少默认 Release 编译 Job")
        return errors
    if re.search(r"^    if:", release_job, re.MULTILINE):
        errors.append(".github/workflows/ci.yml: Release 编译 Job 必须默认执行")
    if not re.search(r"^    needs:\s*static-audit\s*$", release_job, re.MULTILINE):
        errors.append(".github/workflows/ci.yml: Release 编译 Job 必须依赖静态审计")
    if catalyst_job is None:
        errors.append(".github/workflows/ci.yml: CI 需要独立 Mac Catalyst 行为 Job")
    else:
        if re.search(r"^    if:", catalyst_job, re.MULTILINE):
            errors.append(".github/workflows/ci.yml: Mac Catalyst 行为 Job 需要默认执行")
        if not re.search(r"^    needs:\s*static-audit\s*$", catalyst_job, re.MULTILINE):
            errors.append(".github/workflows/ci.yml: Mac Catalyst 行为 Job 需要依赖静态审计")
        if "Scripts/run-extended-tests.sh catalyst" not in run_commands(catalyst_job):
            errors.append(".github/workflows/ci.yml: Mac Catalyst 行为 Job 需要执行行为用例")
    required_release_rules = (
        ("Scripts/run-extended-tests.sh build release", "CI 需要通用 iOS Release 测试构建"),
        ("Scripts/run-extended-tests.sh build ui", "CI 需要 UI 宿主与测试构建"),
        ("Scripts/run-extended-tests.sh build network-smoke", "CI 需要网络 Smoke 编译条件构建"),
        ("Scripts/run-extended-tests.sh build icloud-smoke", "CI 需要 iCloud Smoke 编译条件构建"),
    )
    release_commands = "\n".join(run_commands(release_job))
    for marker, message in required_release_rules:
        if marker not in release_commands:
            errors.append(f".github/workflows/ci.yml: {message}")
    return errors


def main(shared_syntax: dict[str, dict] | None = None, boundary_findings: list[str] | None = None) -> int:
    from code_quality_tests import checker_boundary_findings
    if sys.argv[1:] == ["--swift-syntax-index"]:
        try:
            print(json.dumps(swift_syntax_index(swift_files()), ensure_ascii=False))
            return 0
        except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
            print(f"SwiftSyntax 索引失败：{error}", file=sys.stderr)
            return 1

    if sys.argv[1:] == ["--self-test"]:
        findings = checker_boundary_findings()
        if findings:
            print("[失败] 代码质量检查器自测：", file=sys.stderr)
            print("\n".join(findings), file=sys.stderr)
            return 1
        print("[通过] 代码质量检查器自测")
        return 0

    errors: list[str] = []
    if shared_syntax is None:
        try:
            syntax_index = swift_syntax_index(swift_files())
        except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
            syntax_index = {}
            errors.append(f"SwiftSyntax 索引失败：{error}")
    else:
        syntax_index = shared_syntax
    source_errors, review = source_findings(syntax_index or None)
    errors.extend(source_errors)
    errors.extend(checker_boundary_findings() if boundary_findings is None else boundary_findings)
    errors.extend(script_findings())
    if syntax_index:
        errors.extend(automatic_school_fetch_findings(syntax_index))
    errors.extend(audit_wiring_findings())

    report_lines = [
        "# 逐份源码质量审查",
        "",
        f"扫描 Swift 文件：{len(swift_files())} 个",
        "",
        "## 需要修复",
        *(errors or ["无"]),
        "",
        "## 人工审查候选",
        *(review or ["无"]),
        "",
    ]
    report = "\n".join(report_lines)
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(report, encoding="utf-8")
    findings = [*errors, *review]
    if len(findings) <= 1000:
        if findings:
            print("\n".join(findings))
    else:
        print(f"代码质量检查共 {len(findings)} 项 · {relative(REPORT_PATH)}")

    if errors:
        return 1
    return 0


def explanatory_text_report() -> None:
    root = ROOT
    source_root = root / "BIT101-iOS"
    report = root / ".build/explanatory-text-report.txt"
    # 用户确认的文案进入白名单，其余候选写入固定报告。
    APPROVED_TEXTS = {
        "使用学校统一身份认证账号密码登录。若未注册过 BIT101 账号，将自动完成注册；密码仅会经不可逆加密后传输。",
        "本 App 尚处在开发中，不保证所有功能始终可用；如遇到问题，请联系 systemd@linux.do。开发者不对使用过程中造成的损失负责。",
        "本 App 为了完成 Apple 的合规性审查，加入了一些风味元素，功能与安卓版有所差异。",
        "换个关键词试试。",
        "请稍候",
        "先选定校区和教学楼，再刷新一次。",
        "先获取乐学日程，或手动添加一条。",
        "点击右上角的加号可以先新增一个。",
        "请调整学期或种类筛选条件。",
    }
    APPROVED_DYNAMIC = {
        ("Modules/DesignSystemKit/Sources/AppVerificationComponents.swift", "verificationHint"),
    }


    def masked(source: str) -> str:
        """保留结构字符，维持插值所在块的边界。"""
        def replace(match: re.Match[str]) -> str:
            return "".join("\n" if character == "\n" else " " for character in match.group(0))

        return re.sub(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"', replace, source)


    def block(source: str, start: int) -> str:
        structure = masked(source)
        opening = structure.find("{", start)
        if opening < 0:
            return ""
        depth = 0
        for index in range(opening, len(structure)):
            if structure[index] == "{":
                depth += 1
            elif structure[index] == "}":
                depth -= 1
                if depth == 0:
                    return source[opening + 1 : index]
        return source[opening + 1 :]


    def text_expressions(source: str, path: str) -> list[str]:
        expressions: list[str] = []
        for line in source.splitlines():
            match = re.match(r"Text\((.*)\)\s*$", line.strip())
            if not match:
                continue
            expression = match.group(1)
            if expression.startswith('"'):
                if expression[1:-1] not in APPROVED_TEXTS:
                    expressions.append(expression)
            elif expression == "verificationHint" and (path, expression) not in APPROVED_DYNAMIC:
                expressions.append(expression)
        return expressions


    footer_items: list[tuple[str, int, list[str]]] = []
    description_items: list[tuple[str, int, list[str]]] = []

    for path in sorted(source_root.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        relative_path = path.relative_to(root).as_posix()
        if path.name != "ErrorReportSupport.swift":
            for match in re.finditer(r"\bfooter\s*:\s*\{", source):
                expressions = text_expressions(block(source, match.start()), relative_path)
                if expressions:
                    footer_items.append((path.relative_to(root).as_posix(), source.count("\n", 0, match.start()) + 1, expressions))

        for match in re.finditer(r"\bdescription\s*:\s*\{", source):
            expressions = text_expressions(block(source, match.start()), relative_path)
            if expressions:
                description_items.append((relative_path, source.count("\n", 0, match.start()) + 1, expressions))

        for match in re.finditer(r"\bdescription\s*:\s*Text\((.*)\)\s*$", source, re.MULTILINE):
            expression = match.group(1)
            if expression.startswith('"') and expression[1:-1] in APPROVED_TEXTS:
                continue
            description_items.append((relative_path, source.count("\n", 0, match.start()) + 1, [expression]))


    lines = [
        "# List/Form 与 ContentUnavailableView 解释文案审查候选",
        "# 扫描 Section footer 和 ContentUnavailableView description。",
        "",
        "## Section footer",
    ]
    for path, line, expressions in footer_items:
        lines.append(f"- {path}:{line}")
        lines.extend(f"  - Text({expression})" for expression in expressions)

    lines.append("")
    lines.append("## ContentUnavailableView description")
    for path, line, expressions in description_items:
        lines.append(f"- {path}:{line}")
        lines.extend(f"  - Text({expression})" for expression in expressions)

    count = sum(len(expressions) for _, _, expressions in footer_items + description_items)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    findings = [
        f"{path}:{line}: Text({expression})"
        for path, line, expressions in footer_items + description_items
        for expression in expressions
    ]
    if len(findings) <= 1000:
        if findings:
            print("解释文案审查候选：\n" + "\n".join(findings))
    else:
        print(f"解释文案审查候选共 {count} 条 · {report.relative_to(root)}")


def combined_main() -> int:
    from code_quality_tests import checker_boundary_findings
    try:
        syntax_index = swift_syntax_index(swift_files())
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"[失败] SwiftSyntax 索引：{error}", file=sys.stderr)
        return 1
    ui_path = SCRIPT_ROOT / "check-ui-consistency.py"
    spec = importlib.util.spec_from_file_location("check_ui_consistency", ui_path)
    if spec is None or spec.loader is None:
        print(f"[失败] UI 检查器加载：{ui_path}", file=sys.stderr)
        return 1
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    quality_boundaries = checker_boundary_findings()
    ui_boundaries = [
        *module.ast_marker_boundary_findings(),
        *module.source_boundary_findings(),
        *module.map_theme_color_contract_findings(),
    ]
    ui_status = module.main(syntax_index, ui_boundaries)
    quality_status = main(syntax_index, quality_boundaries)
    explanatory_text_report()
    return int(ui_status != 0 or quality_status != 0)
