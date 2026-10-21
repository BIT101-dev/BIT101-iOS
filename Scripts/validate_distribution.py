#!/usr/bin/env python3
"""Check the signatures and entitlements of the exported App Store application."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid
from xml.parsers.expat import ExpatError
from validate_versions import extract_versions
from validation_provenance import sampling_evidence_current, utc_now
from validation_environment import input_identity_complete

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "build/DeviceInstall/distribution-signing.json"


def archive_provenance(info: dict) -> dict:
    return {"inputDigest": info.get("BIT101ArchiveInputDigest", ""), "runID": info.get("BIT101ArchiveRunIdentifier", "")}


def valid_archive_provenance(provenance: dict) -> bool:
    return isinstance(provenance, dict) and input_identity_complete(provenance.get("inputDigest")) \
        and isinstance(provenance.get("runID"), str) and bool(provenance["runID"].strip())


def valid_executable_uuids(rows: list) -> bool:
    if not isinstance(rows, list) or not rows: return False
    try:
        return all(isinstance(row, dict) and isinstance(row.get("architecture"), str) and row["architecture"].strip()
            and isinstance(row.get("uuid"), str) and str(uuid.UUID(row["uuid"])).upper() == row["uuid"] for row in rows) \
            and len({row["architecture"] for row in rows}) == len(rows)
    except (ValueError, TypeError, KeyError): return False


def executable_uuids(path: Path, info: dict) -> list:
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(path / info["CFBundleExecutable"])], text=True)
    rows = [{"uuid": identifier.upper(), "architecture": architecture} for identifier, architecture in
        re.findall(r"(?m)^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", output)]
    if not valid_executable_uuids(rows): raise ValueError("应用可执行文件需要有效的 Mach-O UUID")
    return sorted(rows, key=lambda row: row["architecture"])


def application_infos(application: Path) -> dict:
    bundles = [application] + sorted(path for path in application.rglob("*") if path.suffix in {".app", ".appex"} and path.is_dir())
    return {path: plistlib.loads((path / "Info.plist").read_bytes()) for path in bundles}


def privacy_manifest(bundle: Path) -> dict:
    try:
        manifest = plistlib.loads((bundle / "PrivacyInfo.xcprivacy").read_bytes())
        expected = plistlib.loads((ROOT / "BIT101-iOS/PrivacyInfo.xcprivacy").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        raise ValueError(f"隐私清单需要有效的 plist：{bundle}") from error
    required = {"NSPrivacyAccessedAPICategoryFileTimestamp": "C617.1",
        "NSPrivacyAccessedAPICategoryUserDefaults": "CA92.1"}
    rows = manifest.get("NSPrivacyAccessedAPITypes", []) if isinstance(manifest, dict) else []
    if manifest != expected or not isinstance(rows, list) or not isinstance(manifest, dict) \
            or manifest.get("NSPrivacyTracking") is not False \
            or any(not any(isinstance(row, dict) and row.get("NSPrivacyAccessedAPIType") == category
                and isinstance(row.get("NSPrivacyAccessedAPITypeReasons"), list)
                and reason in row["NSPrivacyAccessedAPITypeReasons"] for row in rows) for category, reason in required.items()):
        raise ValueError(f"隐私清单需要匹配共享资源及文件时间戳、UserDefaults 使用原因：{bundle}")
    return manifest


def production_build_metadata(application: Path, info: dict) -> dict:
    conditions = info.get('BIT101WorkflowConditions')
    if not isinstance(conditions, str) or conditions.split():
        raise ValueError('正式产物需要空工作流编译条件')
    binary = (application / info['CFBundleExecutable']).read_bytes()
    markers = [marker for marker in ('behavior-test-host', 'release-network-smoke-host', 'icloud-cross-device-smoke-host',
        'The UI automation App requires its isolated launch configuration') if marker.encode() in binary]
    if markers: raise ValueError('正式产物需要生产宿主入口')
    return {'compilationConditions': [], 'testHostMarkers': []}


def archive_build_summary(application: Path) -> dict:
    infos = application_infos(application)
    return {"passed": True, "kind": "build", "archiveProvenance": archive_provenance(infos[application]),
        "executables": {info["CFBundleIdentifier"]: executable_uuids(path, info) for path, info in infos.items()},
        "productionBuilds": {info['CFBundleIdentifier']: production_build_metadata(path, info) for path, info in infos.items()},
        "privacyManifests": {info["CFBundleIdentifier"]: privacy_manifest(path) for path, info in infos.items()}}


def catalyst_application_identity(application: Path) -> dict:
    contents = application / 'Contents'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    return {'identifier': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'],
        'executableUUIDs': executable_uuids(contents / 'MacOS', info)}


def distribution_contracts() -> dict:
    project_path = ROOT / "BIT101-iOS.xcodeproj/project.pbxproj"
    objects = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project_path)]))["objects"]
    def release_settings(identifier):
        configurations = objects[objects[identifier]["buildConfigurationList"]]["buildConfigurations"]
        return next(objects[item]["buildSettings"] for item in configurations if objects[item]["name"] == "Release")
    settings = release_settings(next(key for key, value in objects.items() if value.get("isa") == "PBXProject"))
    version, build = extract_versions(project_path.read_text())
    contracts = {}
    for key, target in objects.items():
        if target.get("isa") != "PBXNativeTarget" or target.get("productType") not in {
                "com.apple.product-type.application", "com.apple.product-type.app-extension"}:
            continue
        configuration = settings | release_settings(key)
        path = configuration["CODE_SIGN_ENTITLEMENTS"]
        path = re.sub(r"\$\((\w+)\)", lambda match: configuration[match[1]], path)
        entitlements = plistlib.loads((ROOT / path).read_bytes())
        identifier = configuration["PRODUCT_BUNDLE_IDENTIFIER"]
        platform = "watchOS" if configuration.get("SDKROOT") == "watchos" else "iOS"
        contracts[identifier] = {"team": configuration["DEVELOPMENT_TEAM"], "version": version,
            "build": str(build), "entitlements": entitlements, "extension": target["productType"].endswith("app-extension"),
            "platform": platform, "minimumOSVersion": configuration[platform.upper() + "_DEPLOYMENT_TARGET" if platform == "watchOS" else "IPHONEOS_DEPLOYMENT_TARGET"]}
    return contracts


def minimum_os_version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value): return None
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def provisioning_profile(path: Path) -> dict:
    result = subprocess.run(['security', 'cms', '-D', '-i', str(path / 'embedded.mobileprovision')],
        check=True, capture_output=True)
    profile = plistlib.loads(result.stdout)
    expiration = profile.get('ExpirationDate')
    if not isinstance(expiration, datetime): raise ValueError('分发描述文件需要有效期')
    return {'uuid': profile.get('UUID'), 'teamIdentifiers': profile.get('TeamIdentifier'),
        'entitlements': profile.get('Entitlements'),
        'expirationDate': expiration.replace(tzinfo=timezone.utc).isoformat(),
        'hasProvisionedDevices': 'ProvisionedDevices' in profile,
        'provisionsAllDevices': profile.get('ProvisionsAllDevices', False)}


def profile_entitlement_allows(allowed, claimed) -> bool:
    if isinstance(claimed, list):
        return all(profile_entitlement_allows(allowed, item) for item in claimed)
    if isinstance(allowed, list):
        return any(profile_entitlement_allows(item, claimed) for item in allowed)
    if isinstance(allowed, str) and isinstance(claimed, str):
        return allowed == claimed or (allowed.endswith('*') and '*' not in allowed[:-1] and claimed.startswith(allowed[:-1]))
    return type(allowed) is type(claimed) and allowed == claimed


def app_store_profile_complete(profile: dict, signed: dict, team: str) -> bool:
    if not isinstance(profile, dict): return False
    try:
        identifier = profile['uuid']
        if not isinstance(identifier, str) or str(uuid.UUID(identifier)).upper() != identifier.upper(): return False
        expiration = datetime.fromisoformat(profile['expirationDate'])
        entitlements = profile['entitlements']
        return expiration > utc_now() and profile.get('teamIdentifiers') == [team] \
            and profile.get('hasProvisionedDevices') is False and profile.get('provisionsAllDevices') is False \
            and isinstance(entitlements, dict) and entitlements.get('get-task-allow') is False \
            and entitlements.get('beta-reports-active') is True \
            and entitlements.get('application-identifier') == signed.get('application-identifier') \
            and entitlements.get('com.apple.developer.team-identifier') == team \
            and all(key in entitlements and profile_entitlement_allows(entitlements[key], value) for key, value in signed.items())
    except (KeyError, ValueError, TypeError):
        return False


def distribution_complete(report: dict, contracts: dict | None = None) -> bool:
    contracts = distribution_contracts() if contracts is None else contracts
    try: expected_privacy = privacy_manifest(ROOT / "BIT101-iOS")
    except ValueError: return False
    rows = report.get("bundles", [])
    if report.get("schemaVersion") != 1 or not valid_archive_provenance(report.get("archiveProvenance")) \
            or not isinstance(rows, list) or len(rows) != len(contracts) \
            or any(not isinstance(row, dict) or not isinstance(row.get("identifier"), str) for row in rows): return False
    if {row["identifier"] for row in rows} != set(contracts) \
            or not sampling_evidence_current({"startedAt": report.get("verifiedAt"), "finishedAt": report.get("verifiedAt")}): return False
    main = next((identifier for identifier, contract in contracts.items() if "com.apple.developer.icloud-services" in contract["entitlements"]), None)
    for row in rows:
        contract = contracts[row["identifier"]]
        entitlements = row.get("entitlements", {})
        if not isinstance(entitlements, dict) or row.get("signatureVerified") is not True \
                or row.get("team") != contract["team"] or entitlements.get("com.apple.developer.team-identifier") != contract["team"] \
                or entitlements.get("get-task-allow", False) is not False or row.get("version") != contract["version"] \
                or row.get("build") != contract["build"] \
                or not valid_executable_uuids(row.get("executableUUIDs")) \
                or row.get('compilationConditions') != [] or row.get('testHostMarkers') != [] \
                or row.get("privacyManifest") != expected_privacy:
            return False
        platform, supported = ('watchos', 'WatchOS') if contract['platform'] == 'watchOS' else ('iphoneos', 'iPhoneOS')
        if row.get('platform') != platform or row.get('supportedPlatforms') != [supported] \
                or minimum_os_version(row.get('minimumOSVersion')) != minimum_os_version(contract['minimumOSVersion']) \
                or not app_store_profile_complete(row.get('provisioningProfile'), entitlements, contract['team']):
            return False
        application = entitlements.get("application-identifier", "")
        suffix = "." + row["identifier"]
        if not isinstance(application, str) or not application.endswith(suffix): return False
        if any(domain.startswith('applinks:') for domain in entitlements.get('com.apple.developer.associated-domains', [])):
            source = (ROOT / 'Cloudflare/OpenWorker/worker.js').read_text().split('const AASA =', 1)[1].split(';', 1)[0]
            if application not in re.findall(r'appID:\s*"([^"]+)"', source): return False
        prefix = application[:-len(row["identifier"])]
        if not prefix.strip("."): return False
        for key, expected in contract["entitlements"].items():
            if isinstance(expected, str): expected = expected.replace("$(TeamIdentifierPrefix)", prefix)
            if entitlements.get(key) != expected: return False
        if "com.apple.developer.icloud-services" in contract["entitlements"] \
                and entitlements.get("com.apple.developer.icloud-container-environment") != "Production": return False
        if contract["extension"]:
            containers = [identifier for identifier, value in contracts.items() if not value["extension"]
                and row["identifier"].startswith(identifier + ".")]
            if not containers or row.get("containerIdentifier") != max(containers, key=len): return False
        elif row["identifier"] != main and (row.get("containerIdentifier") != main or row.get("companionIdentifier") != main):
            return False
    return True


def inspect_application(application: Path) -> dict:
    if application.suffix != ".app" or not application.is_dir():
        raise ValueError("签名验收需要最终导出产物中的 .app 目录")
    infos = application_infos(application)
    rows = []
    for path, info in infos.items():
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(path)], check=True, capture_output=True)
        metadata = subprocess.run(["codesign", "--display", "--verbose=4", str(path)], check=True, capture_output=True, text=True).stderr
        signed = subprocess.run(["codesign", "--display", "--entitlements", "-", str(path)], check=True, capture_output=True).stdout
        entitlements = plistlib.loads(signed)
        team = re.search(r"(?m)^TeamIdentifier=(.+)$", metadata)
        container = next((parent for parent in path.parents if parent in infos), None)
        rows.append({"identifier": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
            **production_build_metadata(path, info),
            "build": info["CFBundleVersion"], "team": team[1] if team else "", "entitlements": entitlements,
            "signatureVerified": True,
            "privacyManifest": privacy_manifest(path),
            "executableUUIDs": executable_uuids(path, info),
            "platform": info.get('DTPlatformName'), "supportedPlatforms": info.get('CFBundleSupportedPlatforms'),
            "minimumOSVersion": info.get('MinimumOSVersion'), "provisioningProfile": provisioning_profile(path),
            "containerIdentifier": infos[container]["CFBundleIdentifier"] if container else "",
            "companionIdentifier": info.get("WKCompanionAppBundleIdentifier", "")})
    report = {"schemaVersion": 1, "verifiedAt": utc_now().isoformat(), "archiveProvenance": archive_provenance(infos[application]), "bundles": rows}
    if not distribution_complete(report): raise ValueError("分发签名需要匹配 App Store 描述文件、目标平台、最低系统、版本、团队、扩展归属和权益")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("application", type=Path)
    args = parser.parse_args()
    try:
        REPORT.unlink(missing_ok=True)
        report = inspect_application(args.application.resolve())
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print("分发签名验收通过：App、Watch 和两种 Widget")
        return 0
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"分发签名验收失败：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
