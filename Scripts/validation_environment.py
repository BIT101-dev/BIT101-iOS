"""Capture the toolchain and host/device inputs used by validation workflows."""
import json
import hashlib
import os
import platform
import plistlib
import re
import subprocess
import sys
from functools import cache
from pathlib import Path
from validation_policy import NETWORK_GROUPS

DEVICE_GROUPS = {"all", "release-runtime", "ui", "schedule", "infrastructure", "login", "extensions",
                 "icloud", "icloud-cleanup", "restore", "manual-device"} | NETWORK_GROUPS


def input_identity_complete(value: object) -> bool:
    return isinstance(value, str) and bool(re.fullmatch(
        r'(?:[0-9a-f]{64}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|git\.(?:[0-9a-f]{40}|[0-9a-f]{64})\.[A-Za-z0-9_-]+)', value))


def native_destinations_complete(rows: object, group: str, *, simulator: bool = False, expected_device: str = '') -> bool:
    expected_platform = 'iOS Simulator' if simulator else 'macOS' if group in {'catalyst', 'catalyst-release-runtime'} else 'iOS'
    return isinstance(rows, list) and bool(rows) and all(isinstance(row, dict)
        and row.get('platform') == expected_platform and isinstance(row.get('deviceIdentifier'), str)
        and bool(row['deviceIdentifier']) and (not expected_device or row['deviceIdentifier'] == expected_device) for row in rows)


def ci_commit_findings(commit: str) -> list[str]:
    expected = os.getenv('GITHUB_SHA', '')
    if not expected and os.getenv('GITHUB_ACTIONS') != 'true': return []
    if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', expected) or commit != expected:
        return ['CI 验收需要检出并绑定 GitHub 事件 SHA。']
    if os.getenv('GITHUB_ACTIONS') == 'true' and subprocess.check_output(
            ['git', 'status', '--porcelain=v1', '-z', '--untracked-files=all'], cwd=Path(__file__).resolve().parents[1]):
        return ['CI 验收需要维护文件与 GitHub 提交内容一致；请提交源码改动并清理残留源码。']
    return []


def exchange_identity(value):
    """Keep stable device/path equality in shared evidence using opaque identities."""
    def opaque(value):
        return value if re.fullmatch(r'sha256:[0-9a-f]{64}', value) else 'sha256:' + hashlib.sha256(value.encode()).hexdigest()
    def convert(value, parent=''):
        if isinstance(value, list): return [convert(item, parent) for item in value]
        if not isinstance(value, dict): return value
        result = {}
        for key, item in value.items():
            private = key in {'developer', 'deviceIdentifier', 'deviceId'} or key == 'identifier' and parent == 'device' \
                or key == 'path' and isinstance(item, str) and item.startswith('/')
            if private and isinstance(item, str) and item: result[key] = opaque(item)
            elif key == 'deviceName' or key == 'name' and parent == 'device': result[key] = 'validation-device'
            else: result[key] = convert(item, key)
        return result
    return convert(value)


def complete_environment(group: str, context: dict) -> bool:
    compiler = context.get("compiler", {})
    if not (context.get("host") and context.get("developer") and context.get("xcode")
            and isinstance(compiler, dict) and compiler.get("modified") and type(compiler.get("size")) is int
            and compiler["size"] > 0 and isinstance(compiler.get("version"), str) and compiler["version"].strip()
            and context.get("sdks")
            and all(sdk.get("Version") for sdk in context["sdks"].values())):
        return False
    if group in DEVICE_GROUPS:
        device = context.get("device") or {}
        return all(device.get(key) for key in ("identifier", "systemVersion", "systemBuild"))
    if group == "audit":
        runtimes = context.get("runtimes", {})
        return isinstance(runtimes, dict) and all(isinstance(runtimes.get(name), str) and runtimes[name].strip()
            for name in ("python", "ruby", "node", "npm", "ruff"))
    return True


def toolchain_identity(context: dict) -> dict:
    return {"xcode": context.get("xcode"), "toolchains": context.get("toolchains"),
            "compiler": {key: context.get("compiler", {}).get(key) for key in ("size", "version")},
            "sdks": {name: {key: value for key, value in sdk.items() if key != "path"}
                     for name, sdk in context.get("sdks", {}).items()}}


def plist_values(path: Path, keys: tuple[str, ...]) -> dict:
    if not path.is_file():
        return {}
    with path.open("rb") as stream:
        values = plistlib.load(stream)
    return {key: values[key] for key in keys if key in values}


@cache
def host_environment() -> dict:
    selected = os.environ.get("DEVELOPER_DIR") or "/var/db/xcode_select_link"
    developer = Path(selected).resolve()
    if developer.suffix == ".app":
        developer = (developer / "Contents/Developer").resolve()
    frontend = Path(subprocess.check_output(["xcrun", "--find", "swift-frontend"], text=True).strip()).resolve()
    compiler = {"path": str(frontend)}
    if frontend.is_file():
        stat = frontend.stat()
        compiler.update(size=stat.st_size, modified=stat.st_mtime_ns)
        compiler["version"] = subprocess.check_output([str(frontend), "--version"], text=True).strip()
    return {
        "host": dict(system=platform.system(), architecture=platform.machine(),
                     **plist_values(Path("/System/Library/CoreServices/SystemVersion.plist"), ("ProductVersion", "ProductBuildVersion"))),
        "developer": str(developer),
        "xcode": plist_values(developer.parent / "Info.plist", ("CFBundleShortVersionString", "CFBundleVersion", "DTXcodeBuild")),
        "toolchains": os.environ.get("TOOLCHAINS", ""),
        "compiler": compiler,
    }


@cache
def device_environment() -> dict | None:
    root = Path(__file__).resolve().parents[1]
    command = 'source "$1"; bit101_require_device >/dev/null || exit 1; xcrun devicectl device info details --device "$BIT101_DEVICETCL_DEVICE_ID" --quiet --json-output /dev/stdout'
    result = subprocess.run(["zsh", "-c", command, "validation-device", str(root / "Scripts/script-support.sh")],
                            capture_output=True, text=True)
    if result.returncode:
        return None
    details = json.loads(result.stdout)["result"]
    device = details.get("device", details)
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    return {
        "identifier": hardware.get("udid") or device.get("identifier"),
        "model": hardware.get("productType") or hardware.get("marketingName"),
        "systemVersion": properties.get("osVersionNumber"),
        "systemBuild": properties.get("osBuildUpdate"),
    }


@cache
def environment_context(group: str) -> dict:
    context = dict(host_environment())
    developer = Path(context["developer"])
    sdk_names = {"MacOSX"} if group in {"modules", "audit", "build-modules"} else {"MacOSX", "iPhoneOS", "WatchOS"}
    sdks = {}
    for name in sorted(sdk_names):
        sdk = developer / "Platforms" / (name + ".platform") / "Developer/SDKs" / (name + ".sdk")
        sdks[name] = dict(path=str(sdk.resolve()), **plist_values(sdk / "SDKSettings.plist",
            ("CanonicalName", "Version", "ProductBuildVersion")))
    context["sdks"] = sdks
    if group == "audit":
        context["runtimes"] = {"python": sys.version, **{name: subprocess.check_output([name, "--version"], text=True).strip()
            for name in ("ruby", "node", "npm", "ruff")}}
    if group in DEVICE_GROUPS:
        context["device"] = device_environment()
    return context
