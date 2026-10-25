"""Exercise workflow ownership, deadlines and process-group cleanup."""
import fcntl
import os
from pathlib import Path
import re
import shutil
import shlex
import signal
import subprocess
import sys
import time
from contextlib import redirect_stderr
from io import StringIO
from unittest.mock import patch

SCRIPT_ROOT = Path(__file__).resolve().parent
ROOT = SCRIPT_ROOT.parent


def workflow_lock_boundary_findings() -> list[str]:
    "验证竞争工作流排队及父子流程锁复用。"
    import workflow_processes as subject
    with patch.object(subject.os, 'getuid', return_value=501), patch.object(subject.subprocess, 'check_output',
            return_value='501 10 1 10\n501 11 10 11\n501 12 11 11\n0 13 11 13\n501 14 13 14\n501 20 1 20\n'):
        assert subject.descendant_groups(10) == {10, 11, 14}
    with patch.object(subject.os, 'getuid', return_value=501), patch.object(subject.subprocess, 'check_output',
            return_value='501 10 10 S /fixture/worker\n0 13 13 S /System/daemon\n0 15 10 S /System/helper\n501 16 10 Z /fixture/finished\n'):
        assert subject.active_member_states({10, 13}) == {10: 'S'}
    for signum, workers_only, expected in ((signal.SIGTERM, False, 11), (signal.SIGTERM, True, 10), (signal.SIGKILL, False, 10)):
        with patch.object(subject, 'group_members', return_value={10: ('S', False), 11: ('S', True)}), \
                patch.object(subject.os, 'kill') as killed:
            subject.signal_groups({10}, signum, workers_only=workers_only)
            killed.assert_called_once_with(expected, signum)
    with patch.object(subject, 'active_members', side_effect=[{123}, {123}, {123}, {123}, set()]), \
            patch.object(subject, 'active_member_states', return_value={123: 'U'}), \
            patch.object(subject, 'signal_groups') as signals, patch.object(subject.time, 'monotonic', return_value=0), \
            patch.object(subject.time, 'sleep'), redirect_stderr(output := StringIO()):
        subject.stop_groups({123}, grace_seconds=0)
        assert [call.args[1] for call in signals.call_args_list] == [signal.SIGTERM, signal.SIGKILL]
        assert output.getvalue().count('123 (U)') == 1 and '保留工作流锁' in output.getvalue()
    import select
    import shlex
    import time
    fixture = ROOT / ".build/static-audit/workflow-lock-self-test"
    worker, release = fixture / "worker.sh", fixture / "release"
    processes, findings = [], []
    environment = dict(os.environ)
    optimization = subprocess.run(["zsh", "-c", 'source "$1"; python3 -c "assert False"',
        "assertion-contract", str(SCRIPT_ROOT / "script-support.sh")],
        env=dict(environment, PYTHONOPTIMIZE="1"), capture_output=True, text=True)
    if optimization.returncode == 0 or "AssertionError" not in optimization.stderr:
        findings.append("工作流环境自测：Python 自测断言沿默认优化级别执行")
    environment.pop("BIT101_EXTENDED_TESTS_LOCK_HELD", None)
    environment.pop("BIT101_DEVICE_WORKFLOW_LOCK_HELD", None)
    environment.pop("BIT101_WORKFLOW_DEADLINE", None)
    environment["BIT101_LOCK_TEST_CHECKOUT"] = str(fixture)
    try:
        shutil.rmtree(fixture, ignore_errors=True)
        fixture.mkdir(parents=True, exist_ok=True); os.mkfifo(release)
        support = (SCRIPT_ROOT / "script-support.sh").read_text().replace(
            '"$HOME/Library/Caches/BIT101-iOS/device-workflow.lock"', shlex.quote(str(fixture / "device-workflow.lock")))
        dispatch = (SCRIPT_ROOT / 'build-install-device.sh').read_text().split('if [[ "$ACTION" == install', 1)[1].split('\nif [[ "$ACTION" == install', 1)[0]
        test_lock = re.search(r'(?ms)^acquire_test_lock\(\) \{.*?^\}', (SCRIPT_ROOT / 'run-extended-tests.sh').read_text())[0]
        worker.write_text('ROOT_DIR="$BIT101_LOCK_TEST_CHECKOUT"\n' + support + '\nBIT101_SCRIPTS_DIR=' + shlex.quote(str(SCRIPT_ROOT)) + '\n' + test_lock + '\n'
                         'case "${1:-}" in aggregate) MODE=verify; verification_needs_device=false; BUILD_ONLY=false; GENERIC_BUILD=false; SCRIPT_PATH="$0"; SCRIPT_ARGS=("$@"); acquire_test_lock; if [[ "${BIT101_DEVICE_WORKFLOW_LOCK_HELD:-0}" != 1 ]]; then print artifacts-held; read -r reply < "$ROOT_DIR/release"; MODE=modules; acquire_test_lock; fi ;;\n'
                         'modules|catalyst|catalyst-release-runtime) MODE="$1"; BUILD_ONLY=false; GENERIC_BUILD=false; SCRIPT_PATH="$0"; SCRIPT_ARGS=("$@"); acquire_test_lock ;; *)\n'
                         'ACTION=install; case "${1:-}" in artifact) ACTION=build ;; mac) ACTION=mac ;; esac\n'
                         + 'if [[ "$ACTION" == install' + dispatch + '\n;; esac\n'
                         'if [[ "${1:-}" == startup ]]; then read -r reply < "$ROOT_DIR/release"; fi\n'
                         'if [[ "${1:-}" == signal || "${1:-}" == budget ]]; then\n'
                         '  trap \'print cleanup; if [[ "$1" == signal ]]; then read -r reply < "$ROOT_DIR/release"; fi; exit 143\' TERM\n'
                         'fi\nif [[ "${1:-}" == budget ]]; then print "deadline=$BIT101_WORKFLOW_DEADLINE"; fi\nprint entered\n'
                         'case "${1:-}" in hold|signal|budget) read -r reply < "$ROOT_DIR/release" ;; esac\n')
        def line(process):
            value = bytearray()
            deadline = time.monotonic() + 5
            while (remaining := deadline - time.monotonic()) > 0:
                if not select.select([process.stdout], [], [], remaining)[0]: return "timeout"
                character = os.read(process.stdout.fileno(), 1)
                if not character or character == b"\n": return value.decode().strip()
                value.extend(character)
            return "timeout"
        burst = subprocess.Popen([sys.executable, '-c', 'print("one\\ntwo", flush=True); input()'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        processes.append(burst)
        if (line(burst), line(burst)) != ('one', 'two'):
            raise ValueError('连续状态行按已到达的字节读取')
        burst.communicate(input='done\n', timeout=5)
        aggregate = subprocess.Popen(['zsh', str(worker), 'aggregate'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS='2'))
        processes.append(aggregate)
        if line(aggregate) != 'artifacts-held': raise ValueError('聚合流程取得产物锁')
        direct = subprocess.Popen(['zsh', str(worker), 'modules'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS='2'))
        processes.append(direct)
        if not line(direct).startswith('[等待]'): raise ValueError('单独流程等待同一工作区产物')
        with release.open('w') as stream: stream.write('done\n')
        aggregate_output, _ = aggregate.communicate(timeout=5)
        direct_output, _ = direct.communicate(timeout=5)
        if aggregate.returncode or direct.returncode or aggregate_output.strip() != 'entered' or direct_output.strip() != 'entered':
            raise ValueError('聚合与单独流程沿同一锁顺序完成')
        first = subprocess.Popen(["zsh", str(worker), "hold"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(first)
        if line(first) != "entered":
            raise ValueError("首个工作流取得锁")
        other_checkout = dict(environment, BIT101_LOCK_TEST_CHECKOUT=str(fixture / "other-checkout"))
        independent = subprocess.run(["zsh", str(worker), "artifact"], capture_output=True, text=True,
            env=other_checkout, timeout=5)
        if independent.returncode or independent.stdout.strip() != 'entered':
            raise ValueError('独立工作区的本机流程与真机流程并行')
        competing = subprocess.Popen(["zsh", str(worker), "artifact"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS='0.5'))
        processes.append(competing)
        output, _ = competing.communicate(timeout=5)
        if competing.returncode != 124 or 'entered' in output:
            raise ValueError('同一工作区的本机与真机流程共用固定产物锁')
        seconds = [subprocess.Popen(["zsh", str(worker), mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=other_checkout)
                   for mode in ('mac', 'modules', 'catalyst', 'catalyst-release-runtime')]
        processes.extend(seconds)
        if any(not line(second).startswith("[等待]") for second in seconds):
            raise ValueError("竞争工作流在执行前排队")
        with release.open("w") as stream:
            stream.write("done\n")
        first.communicate(timeout=5)
        for second in seconds:
            output, _ = second.communicate(timeout=5)
            if first.returncode or second.returncode or output.strip() != "entered": raise ValueError("锁释放后继续执行并复用父流程锁")
        first = subprocess.Popen(["zsh", str(worker), "signal"], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(first)
        if line(first) != "entered":
            raise ValueError("信号测试取得工作流锁")
        first.terminate()
        if line(first) != "cleanup":
            raise ValueError("外层信号传递到执行子进程")
        second = subprocess.Popen(["zsh", str(worker)], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env=other_checkout)
        processes.append(second)
        for lock_path in (fixture / 'device-workflow.lock', fixture / '.build/extended-automation.lock'):
            with lock_path.open('a') as handle:
                try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: continue
                raise ValueError(f"子进程清理期间保持工作流锁：{lock_path.name}")
        with release.open("w") as stream:
            stream.write("done\n")
        first.communicate(timeout=5)
        output, _ = second.communicate(timeout=5)
        entered = [row for row in output.splitlines() if not row.startswith('[等待]')]
        if first.returncode != 143 or second.returncode or entered != ["entered"]:
            raise ValueError("信号清理完成后释放锁并保持退出状态")
        first = subprocess.Popen(["zsh", str(worker), "hold"], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=environment)
        processes.append(first)
        if line(first) != "entered": raise ValueError("超时竞争测试取得锁")
        second = subprocess.Popen([sys.executable, '-B', str(SCRIPT_ROOT / 'workflow_processes.py'),
            str(fixture / 'device-workflow.lock'), 'BIT101_DEVICE_WORKFLOW_LOCK_HELD', str(worker)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(other_checkout, BIT101_WORKFLOW_TIMEOUT_SECONDS="0.5"))
        processes.append(second)
        output, error = second.communicate(timeout=5)
        if second.returncode != 124 or "[超时]" not in output or "entered" in output:
            raise ValueError(f"竞争工作流沿等待预算结束：{second.returncode} · {output.strip()} · {error.strip()}")
        with release.open("w") as stream: stream.write("done\n")
        first.communicate(timeout=5)
        for mode in ('startup', 'signal'):
            timed = subprocess.Popen(["zsh", str(worker), mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS="0.5"))
            processes.append(timed)
            timed_events = []
            while event := line(timed):
                if event not in {'entered', 'cleanup'} and not event.startswith('[超时]'):
                    raise ValueError(f'执行预算需要已知的生命周期事件：{event}')
                timed_events.append(event)
                if event == 'cleanup':
                    with release.open('w') as stream: stream.write('done\n')
            timed.communicate(timeout=5)
            if not any(event.startswith('[超时]') for event in timed_events) \
                    or 'entered' in timed_events and ('cleanup' not in timed_events or mode == 'startup'):
                raise ValueError('执行预算覆盖启动阶段，已启动工作流完成恢复清理')
            recovered = subprocess.run(["zsh", str(worker)], capture_output=True, text=True, env=environment, timeout=5)
            if timed.returncode != 124 or recovered.returncode or recovered.stdout.strip() != "entered":
                raise ValueError("超时恢复完成后释放全局与工作区锁")
        first = subprocess.Popen(["zsh", str(worker), "hold"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=environment)
        processes.append(first)
        if line(first) != "entered": raise ValueError("共享预算测试取得锁")
        deadline = time.monotonic() + 2
        second = subprocess.Popen(["zsh", str(worker), "budget"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=dict(environment, BIT101_WORKFLOW_TIMEOUT_SECONDS="2", BIT101_WORKFLOW_DEADLINE=str(deadline)))
        processes.append(second)
        if not line(second).startswith("[等待]"): raise ValueError("共享预算测试进入排队")
        time.sleep(0.4)
        with release.open("w") as stream: stream.write("done\n")
        first.communicate(timeout=5)
        output, _ = second.communicate(timeout=5)
        if second.returncode != 124 or "entered" not in output or "cleanup" not in output or f"deadline={deadline}" not in output:
            raise ValueError("等待与执行沿同一截止时间消费预算")
        findings.extend(process_group_boundary_findings(fixture, line))
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        findings.append(f"工作流锁自测：{error}")
    finally:
        descriptor = os.open(release, os.O_RDWR | os.O_NONBLOCK) if release.exists() else None
        try:
            if descriptor is not None: os.write(descriptor, b'done\n' * (len(processes) * 2))
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=5)
        finally:
            if descriptor is not None: os.close(descriptor)
        shutil.rmtree(fixture, ignore_errors=True)
    return findings


def process_group_boundary_findings(fixture: Path, read_line) -> list[str]:
    from workflow_processes import active_members, finish_process_group
    worker = fixture / 'worker.sh'
    artifact = fixture / '.build/extended-automation.lock'
    device = fixture / 'device-workflow.lock'
    stubborn = 'import os,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print(os.getpid(), flush=True); time.sleep(60)'
    child_command = shlex.join([sys.executable, '-c', stubborn])
    for exit_status, expected in ((0, 1), (7, 7)):
        command = [sys.executable, '-c', 'import os,subprocess,sys; child = subprocess.Popen('
            + repr([sys.executable, '-c', stubborn]) + ', stdout=subprocess.PIPE, text=True); '
            + 'ready = child.stdout.readline().strip(); print(os.getpgrp(), ready, flush=True); '
            + f'sys.exit({exit_status})']
        program = f'''import fcntl,os,sys,time
sys.path.insert(0, {str(SCRIPT_ROOT)!r})
from workflow_processes import supervise
with open({str(artifact)!r}, 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    raise SystemExit(supervise({command!r}, dict(os.environ), owns_process_group=True, deadline=time.monotonic()+5, grace_seconds=0.2))
'''
        controller = subprocess.Popen([sys.executable, '-c', program], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        group = None
        try:
            group, descendant = map(int, read_line(controller).split())
            controller.wait(timeout=5)
            assert not active_members({group}), '自然退出与失败退出均在释放锁前回收后台工作'
            assert controller.returncode == expected, (exit_status, controller.returncode)
        finally:
            if group is not None:
                try: os.killpg(group, signal.SIGKILL)
                except ProcessLookupError: pass
            if controller.poll() is None: controller.kill()
            controller.communicate(timeout=5)
    worker.write_text("trap 'exit 0' TERM\n" + child_command + ' &\nwait\n')
    program = f'''import fcntl, os, select, sys
sys.path.insert(0, {str(SCRIPT_ROOT)!r})
from workflow_processes import supervise
with open({str(artifact)!r}, 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    environment = dict(os.environ, BIT101_EXTENDED_TESTS_LOCK_HELD='1')
    environment.pop('BIT101_DEVICE_WORKFLOW_LOCK_HELD', None)
    command = [sys.executable, {str(SCRIPT_ROOT / 'workflow_processes.py')!r}, {str(device)!r}, 'BIT101_DEVICE_WORKFLOW_LOCK_HELD', {str(worker)!r}]
    def clock():
        ready = select.select([int(sys.argv[1])], [], [], 0)[0]
        if ready and sys.argv[2] == 'exception': raise RuntimeError('supervisor fixture failure')
        return 2.0 if ready else 0.0
    raise SystemExit(supervise(command, environment, owns_process_group=True, deadline=1.0, grace_seconds=0.2, clock=clock))
'''
    for mode, expected in (('timeout', 124), ('signal', 143), ('foreign-interrupt', 130), ('exception', 1)):
        isolated = shlex.join([sys.executable, '-c', 'import subprocess; child = subprocess.Popen('
            + repr([sys.executable, '-c', stubborn]) + ', start_new_session=True); child.wait()'])
        worker.write_text("trap 'exit 0' TERM\n" + (isolated if mode == 'foreign-interrupt' else child_command) + ' &\nwait\n')
        control, trigger = os.pipe()
        controller = subprocess.Popen([sys.executable, '-c', program, str(control), mode], pass_fds=(control,),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        os.close(control)
        group = None
        try:
            descendant = int(read_line(controller))
            group = os.getpgid(descendant)
            if mode == 'foreign-interrupt': assert descendant in active_members({group})
            else: assert group not in active_members({group}, workers_only=True)
            if mode in ('timeout', 'exception'): os.write(trigger, b'expire')
            else: controller.send_signal(signal.SIGINT if mode == 'foreign-interrupt' else signal.SIGTERM)
            deadline = time.monotonic() + 5
            while controller.poll() is None and time.monotonic() < deadline:
                for path in (artifact, device):
                    with path.open('a') as lock:
                        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError: continue
                        assert descendant not in active_members({group}), '后台工作退出后释放锁'
                time.sleep(0.1)
            output, error = controller.communicate(timeout=5)
            assert controller.returncode == expected, (mode, output, error)
            assert not active_members({group}), (mode, group)
        finally:
            os.close(trigger)
            if group is not None:
                try: os.killpg(group, signal.SIGKILL)
                except ProcessLookupError: pass
            if controller.poll() is None: controller.kill()
            controller.communicate(timeout=5)
    worker.write_text(child_command + ' &\n')
    leader = subprocess.Popen(['zsh', str(worker)], start_new_session=True, stdout=subprocess.PIPE, text=True)
    try:
        assert int(read_line(leader)) > 0
        leader.wait(timeout=5)
        with redirect_stderr(StringIO()): assert not finish_process_group(leader.pid, grace_seconds=0.2)
        assert not active_members({leader.pid})
    finally:
        try: os.killpg(leader.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        leader.wait(timeout=5)
        leader.stdout.close()
    return []
