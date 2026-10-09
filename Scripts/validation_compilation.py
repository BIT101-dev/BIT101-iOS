"""Evaluate Swift conditional compilation with the selected production toolchain."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from functools import cache
from validation_environment import environment_context
from validation_policy import NETWORK_GROUPS

ROOT = Path(__file__).resolve().parents[1]


@cache
def compilation_condition(condition: str, group: str) -> bool:
    condition = condition.strip()
    group = group.removeprefix("build-")
    group = {"release": "all", "network-smoke": "network", "icloud-smoke": "icloud"}.get(group, group)
    if any(character in condition for character in "\n\r#;{}"):
        raise ValueError(f"编译条件需要单行 Swift 表达式：{condition}")
    enabled = {"DEBUG", "EXTENDED_AUTOMATION", "BIT101_AUTOMATED_TESTING"} if group in {
        "all", "catalyst", "schedule", "infrastructure", "login", "extensions"} else {
        "EXTENDED_AUTOMATION", "BIT101_AUTOMATED_TESTING", "BIT101_UI_TESTING"} if group == "ui" else set()
    if group in NETWORK_GROUPS: enabled = {"RELEASE_NETWORK_SMOKE"}
    if group in {"icloud", "icloud-cleanup"}: enabled = {"ICLOUD_CROSS_DEVICE_SMOKE"}
    catalyst = group in {"catalyst", "catalyst-release-runtime"}
    native = group == "modules"
    architecture = os.uname().machine if native or catalyst else "arm64"
    sdk_name = "macosx" if native or catalyst else "iphoneos"
    target = f"{architecture}-apple-macosx14.0" if native else f"{architecture}-apple-ios17.0" + ("-macabi" if catalyst else "")
    # 本地包模块由项目依赖图提供；系统框架由所选 SDK 与编译器求值。
    condition = re.sub(r"\bcanImport\(\s*([A-Za-z_]\w*)\s*\)",
        lambda match: "true" if (ROOT / "Modules" / match[1]).is_dir() else match[0], condition)
    environment = environment_context("modules" if native else "build-ui")
    signature = hashlib.sha256(json.dumps([condition, target, sorted(enabled), environment,
        Path(__file__).read_text()], sort_keys=True).encode()).hexdigest()
    cache_root = ROOT / ".build/static-audit"
    cache_root.mkdir(parents=True, exist_ok=True)
    with (cache_root / "compilation-conditions.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache_path = cache_root / "compilation-conditions.json"
        recorded = json.loads(cache_path.read_text()) if cache_path.is_file() else {}
        if signature in recorded: return recorded[signature]
        compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True).strip()
        sdk_path = Path(sdk)
        frameworks = ["-F", str(sdk_path.parent.parent / "Library/Frameworks")]
        if catalyst:
            frameworks += ["-F", str(sdk_path / "System/iOSSupport/System/Library/Frameworks"),
                "-I", str(sdk_path / "System/iOSSupport/usr/include")]
        module_cache = ROOT / ".build/compiler-cache/ModuleCache.noindex"
        module_cache.mkdir(parents=True, exist_ok=True)
        source = f'#if {condition}\n#error("BIT101_CONDITION_TRUE")\n#else\n#error("BIT101_CONDITION_FALSE")\n#endif\n'
        with (module_cache.parent / "cache.lock").open("a") as compiler_lock:
            fcntl.flock(compiler_lock, fcntl.LOCK_EX)
            result = subprocess.run([compiler, "-typecheck", "-target", target, "-sdk", sdk,
                "-module-cache-path", str(module_cache), *frameworks, *[flag for value in sorted(enabled) for flag in ("-D", value)], "-"],
                input=source, capture_output=True, text=True)
        errors = set(re.findall(r"error: ([^\n]+)", result.stderr))
        if errors not in ({"BIT101_CONDITION_TRUE"}, {"BIT101_CONDITION_FALSE"}):
            raise ValueError(f"Swift 编译条件求值失败：{condition}\n{result.stderr.strip()}")
        value = errors == {"BIT101_CONDITION_TRUE"}
        recorded[signature] = value
        cache_path.write_text(json.dumps(recorded, sort_keys=True) + "\n")
        return value
