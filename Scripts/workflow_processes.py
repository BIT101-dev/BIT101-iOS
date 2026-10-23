#!/usr/bin/env python3
"""Hold workflow locks until their process group finishes."""
import fcntl
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

SCRIPT = str(Path(__file__).absolute())


def active_member_states(groups: set[int], *, workers_only: bool = False) -> dict[int, str]:
    if not groups: return {}
    snapshot = subprocess.check_output(['ps', '-ww', '-axo', 'pid=,pgid=,stat=,args='], text=True, start_new_session=True)
    members = {}
    for line in snapshot.splitlines():
        fields = line.split(None, 3)
        if len(fields) < 4: continue
        try: pid, group = map(int, fields[:2])
        except ValueError: continue
        if group not in groups or fields[2].startswith('Z'): continue
        program, _, arguments = fields[3].partition(' ')
        supervisor = Path(program).name.lower().startswith('python') and arguments.lstrip().removeprefix('-B ').startswith(SCRIPT + ' ')
        if workers_only and (pid == os.getpid() or supervisor): continue
        members[pid] = fields[2]
    return members


def active_members(groups: set[int], *, workers_only: bool = False) -> set[int]:
    return set(active_member_states(groups, workers_only=workers_only))


def signal_groups(groups: set[int], signum: int) -> None:
    for group in groups:
        try: os.killpg(group, signum)
        except ProcessLookupError: pass


def stop_groups(groups: set[int], *, grace_seconds: float = 5, workers_only: bool = False,
                signum: int = signal.SIGTERM) -> None:
    if not active_members(groups, workers_only=workers_only): return
    signal_groups(groups, signum)
    deadline = time.monotonic() + grace_seconds
    forced = False
    announced = False
    while active_members(groups, workers_only=workers_only):
        if forced and not announced:
            states = active_member_states(groups, workers_only=workers_only)
            if states:
                print('[等待] 强制结束后仍有进程；保留工作流锁，等待系统完成回收：'
                    + ', '.join(f'{pid} ({state})' for pid, state in sorted(states.items())), file=sys.stderr, flush=True)
                announced = True
        if not forced and time.monotonic() >= deadline:
            signal_groups(groups, signal.SIGKILL)
            forced = True
        time.sleep(0.1)


def finish_process_group(group: int, *, grace_seconds: float = 5) -> bool:
    if not active_members({group}): return True
    stop_groups({group}, grace_seconds=grace_seconds)
    print('[失败] 前台任务结束后遗留进程，已完成回收。', file=sys.stderr)
    return False


def supervise(command: list[str], environment: dict, *, owns_process_group: bool,
              deadline: float, grace_seconds: float = 5 * 60, clock=time.monotonic) -> int:
    interrupted = None
    def interrupt(signum, _frame):
        nonlocal interrupted
        interrupted = signum
    previous = {signum: signal.signal(signum, interrupt) for signum in (signal.SIGINT, signal.SIGTERM)}
    process = None
    finished = False
    try:
        process = subprocess.Popen(command, env=environment, start_new_session=owns_process_group)
        while True:
            expired = owns_process_group and clock() >= deadline
            if interrupted is not None or expired:
                if expired: print('[超时] 工作流已达到执行预算，正在恢复与结束。', flush=True)
                group = process.pid if owns_process_group else os.getpgrp()
                stop_groups({group}, grace_seconds=grace_seconds, workers_only=not owns_process_group,
                    signum=interrupted or signal.SIGTERM)
                process.wait()
                finished = True
                return 124 if expired else 128 + interrupted
            try:
                status = process.wait(timeout=0.1)
            except subprocess.TimeoutExpired:
                continue
            if interrupted is not None or owns_process_group and clock() >= deadline: continue
            status = status if status >= 0 else 128 - status
            if owns_process_group and not finish_process_group(process.pid, grace_seconds=grace_seconds):
                status = status or 1
            finished = True
            return status
    finally:
        if process is not None and not finished:
            stop_groups({process.pid if owns_process_group else os.getpgrp()}, grace_seconds=grace_seconds,
                workers_only=not owns_process_group, signum=interrupted or signal.SIGTERM)
            process.wait()
        for signum, handler in previous.items(): signal.signal(signum, handler)


def main(arguments: list[str]) -> int:
    if arguments[:1] == ['terminate-groups']:
        stop_groups({int(value) for value in arguments[1:] if int(value) > 0})
        return 0
    if len(arguments) == 2 and arguments[0] == 'finish-group':
        return 0 if finish_process_group(int(arguments[1])) else 1
    lock_path, flag, script_path, *parameters = arguments
    lock_path = Path(lock_path)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open('a') as lock:
        timeout = float(os.environ.get('BIT101_WORKFLOW_TIMEOUT_SECONDS', 45 * 60))
        deadline = float(os.environ.get('BIT101_WORKFLOW_DEADLINE', time.monotonic() + timeout))
        if not math.isfinite(timeout) or timeout <= 0 or not math.isfinite(deadline):
            raise ValueError('工作流预算与截止时间需要有限正数。')
        announced = False
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not announced:
                    print('[等待] 既有工作流正在使用固定产物与设备。', flush=True)
                    announced = True
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    print('[超时] 工作流锁等待已达到执行预算。', flush=True)
                    return 124
                time.sleep(min(0.1, remaining))
        environment = dict(os.environ, **{flag: '1', 'BIT101_WORKFLOW_DEADLINE': str(deadline)})
        script = Path(script_path)
        owns_process_group = not any(os.environ.get(name) == '1'
            for name in ('BIT101_DEVICE_WORKFLOW_LOCK_HELD', 'BIT101_EXTENDED_TESTS_LOCK_HELD'))
        return supervise(['zsh', '-c', script.read_text(), str(script), *parameters], environment,
            owns_process_group=owns_process_group, deadline=deadline)


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
