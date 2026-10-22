"""Verify shared device selection through public shell configuration and cached identity pairs."""
import json
import shlex
import subprocess
from pathlib import Path


def device_discovery_boundary_findings() -> list[str]:
    support = Path(__file__).with_name('script-support.sh')
    findings = []
    def candidate(name, transport, tunnel='connected', pairing='paired', reality='physical'):
        return dict(identifier=name, hardwareProperties=dict(udid=name, deviceType='iPhone', reality=reality),
            connectionProperties=dict(transportType=transport, tunnelState=tunnel, pairingState=pairing),
            deviceProperties=dict(name=name))

    def select(devices, setup='', requested=''):
        snapshot = shlex.quote(json.dumps({'result': {'devices': devices}}))
        code = f'source {shlex.quote(str(support))}\n'
        code += 'unset BIT101_XCODE_DEVICE_ID BIT101_DEVICETCL_DEVICE_ID BIT101_DEVICE_TRANSPORT BIT101_DEVICE_NAME\n'
        code += setup + '\n'
        code += f'bit101_device_snapshot() {{ print -r -- {snapshot}; }}\nbit101_find_device {shlex.quote(requested)} || exit 1\n'
        code += 'print -r -- "$BIT101_XCODE_DEVICE_ID:$BIT101_DEVICETCL_DEVICE_ID"\n'
        return subprocess.run(['zsh', '-c', code], capture_output=True, text=True)

    for devices, expected in (
        ([candidate('wireless', 'localNetwork'), candidate('wired', 'wired')], 'wired'),
        ([candidate('wireless', 'localNetwork'), candidate('offline', None)], 'wireless'),
        ([candidate('pending', 'wired', 'disconnected'), candidate('connected', 'wired')], 'connected'),
        ([candidate('pending', 'wired', 'disconnected'), candidate('wireless', 'localNetwork')], 'wireless'),
        ([candidate('b', 'wired'), candidate('a', 'wired')], 'a'),
        ([candidate('a', 'wired'), candidate('b', 'wired')], 'a'),
        ([candidate('unpaired', 'wired', pairing='unpaired'), candidate('virtual', 'wired', reality='virtual')], ''),
    ):
        result = select(devices)
        if (expected and (result.returncode or result.stdout.strip() != f'{expected}:{expected}')) \
                or (not expected and result.returncode != 1):
            findings.append('设备自测：连接状态、有线优先、稳定排序及真实配对范围')
    for requested, devices, cached, expected in (
        ('phone-a', [candidate('phone-b', 'wired'), candidate('phone-a', 'localNetwork')], 'phone-b', 'phone-a'),
        ('phone-a', [candidate('phone-b', 'wired')], 'phone-b', ''),
        ('phone-a', [candidate('phone-a', 'wired')], 'phone-a', 'phone-a'),
        ('', [], 'phone-b', 'phone-b'),
    ):
        setup = f'BIT101_XCODE_DEVICE_ID={cached} BIT101_DEVICETCL_DEVICE_ID=cached-pair BIT101_DEVICE_TRANSPORT=wired BIT101_DEVICE_NAME={cached}'
        result = select(devices, setup, requested)
        paired = expected if requested else 'cached-pair'
        if (expected and (result.returncode or result.stdout.strip() != f'{expected}:{paired}')) \
                or (not expected and result.returncode != 1):
            findings.append('设备自测：指定原执行设备时刷新身份配对，聚合流程复用已选设备')
    for devices, expected in (([candidate('phone-b', 'wired'), candidate('phone-a', 'localNetwork')], 'phone-a'),
            ([candidate('phone-b', 'wired')], '')):
        result = select(devices, 'BIT101_XCODE_DEVICE_ID=phone-a')
        if (expected and (result.returncode or result.stdout.strip() != f'{expected}:{expected}')) \
                or (not expected and result.returncode != 1):
            findings.append('设备自测：单个公开 UDID 配置约束全部真机入口')
    return findings
