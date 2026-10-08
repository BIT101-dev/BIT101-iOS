"""Capture the toolchain and host/device inputs used by validation workflows."""
import json
import os
import platform
import plistlib
import subprocess
from functools import cache
from pathlib import Path

DEVICE_GROUPS = {"all", "release-runtime", "ui", "schedule", "infrastructure", "login", "extensions",
                 "network", "ddl", "school-sms", "community-writes", "community-cleanup", "icloud", "restore", "manual-device"}


def complete_environment(group: str, context: dict) -> bool:
    if not (context.get("host") and context.get("developer") and context.get("xcode")
            and context.get("compiler", {}).get("modified") and context.get("sdks")
            and all(sdk.get("Version") for sdk in context["sdks"].values())):
        return False
    if group in DEVICE_GROUPS:
        device = context.get("device") or {}
        return all(device.get(key) for key in ("identifier", "systemVersion", "systemBuild"))
    return True


def toolchain_identity(context: dict) -> dict:
    return {"xcode": context.get("xcode"), "toolchains": context.get("toolchains"),
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
    frontend_path = os.environ.get("SWIFT_FRONTEND")
    if not frontend_path and os.environ.get("TOOLCHAINS"):
        frontend_path = subprocess.check_output(["xcrun", "--find", "swift-frontend"], text=True).strip()
    frontend = Path(frontend_path or developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend").resolve()
    compiler = {"path": str(frontend)}
    if frontend.is_file():
        stat = frontend.stat()
        compiler.update(size=stat.st_size, modified=stat.st_mtime_ns)
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
    if group in DEVICE_GROUPS:
        context["device"] = device_environment()
    return context
