"""Combine cumulative UI control snapshots across App process restarts."""
import json

IDENTITY_SCOPE = "testCaseNavigationPresentationAndOccurrence"


def merge(snapshots: list[dict], processes: set[str]) -> dict:
    observed, disabled, checked, unidentified = set(), set(), set(), set()
    visited = {}
    captured = set()
    for snapshot in snapshots:
        process = snapshot.get("processIdentifier")
        if type(process) is not int or process <= 0 or snapshot.get("scope") != "mounted-controls" \
                or snapshot.get("identityScope") != IDENTITY_SCOPE:
            raise ValueError("UI 库存需要所属 App 进程及完整身份范围。")
        captured.add(str(process))
        prefix = f"{process}:"
        for key, destination in (("observedControls", observed), ("disabledControls", disabled),
                ("checkedDisabledControls", checked), ("unidentifiedInstances", unidentified)):
            values = snapshot.get(key)
            if not isinstance(values, list) or any(not isinstance(value, str) or not value for value in values):
                raise ValueError(f"UI 库存需要完整的 {key} 标识集合。")
            destination.update(prefix + value for value in values)
        controls = snapshot.get("visitedControls")
        if not isinstance(controls, list): raise ValueError("UI 库存需要访问记录。")
        for control in controls:
            if not isinstance(control, dict) or not isinstance(control.get("instance"), str) or not control["instance"] \
                    or not isinstance(control.get("actions"), list) or not control["actions"] \
                    or any(not isinstance(action, str) or not action.strip() for action in control["actions"]):
                raise ValueError("UI 访问记录需要独立身份与动作。")
            instance = prefix + control["instance"]
            actions = set(visited.get(instance, {}).get("actions", [])) | set(control["actions"])
            visited[instance] = dict(control, instance=instance, actions=sorted(actions))
    if not captured or captured != processes:
        raise ValueError("UI 库存需要覆盖本批全部交互场景 App 进程。")
    if visited.keys() - observed:
        raise ValueError("UI 访问记录需要对应先前捕获的控件观察。")
    return {"scope": "mounted-controls", "identityScope": IDENTITY_SCOPE,
        "processIdentifiers": sorted(captured), "observed": len(observed), "visited": len(visited),
        "pending": sorted(observed - visited.keys()), "visitedControls": [visited[key] for key in sorted(visited)],
        "disabledObserved": len(disabled), "pendingDisabled": sorted(disabled - checked),
        "unidentifiedControls": len(unidentified)}


def self_test() -> None:
    def snapshot(process, observed, visited=(), disabled=(), checked=(), unidentified=()):
        return {"processIdentifier": process, "scope": "mounted-controls", "identityScope": IDENTITY_SCOPE,
            "observedControls": list(observed), "disabledControls": list(disabled),
            "checkedDisabledControls": list(checked), "unidentifiedInstances": list(unidentified),
            "visitedControls": [{"instance": key, "identifier": key, "scope": f"Journey{process}/testRun",
                "actions": ["tap"]} for key in visited]}
    first = snapshot(10, ["same", "later"], ["same"], disabled=["disabled"], unidentified=["missing-id"])
    completed = snapshot(10, ["same", "later"], ["same", "later"], checked=["disabled"])
    restarted = snapshot(20, ["same"], ["same"])
    # 诊断输出可以跨文件重新排序；同进程集合合并保留随后完成的访问。
    result = merge([completed, first, restarted, restarted], {"10", "20"})
    assert result["observed"] == result["visited"] == 3 and result["pending"] == []
    assert {row["scope"] for row in result["visitedControls"]} == {"Journey10/testRun", "Journey20/testRun"}
    assert result["unidentifiedControls"] == 1 and result["pendingDisabled"] == []
    earlier_pending = merge([first, restarted], {"10", "20"})
    assert earlier_pending["pending"] == ["10:later"] and earlier_pending["pendingDisabled"] == ["10:disabled"]
    other_process = snapshot(20, ["same"], ["same"], checked=["disabled"])
    assert merge([first, other_process], {"10", "20"})["pendingDisabled"] == ["10:disabled"]
    additional_action = json.loads(json.dumps(completed))
    additional_action["visitedControls"][0]["actions"] = ["scroll"]
    assert merge([completed, additional_action], {"10"})["visitedControls"][1]["actions"] == ["scroll", "tap"]
    for actions in ([], [""], [" "], ["tap", ""], [1]):
        malformed = json.loads(json.dumps(completed))
        malformed["visitedControls"][0]["actions"] = actions
        try: merge([malformed], {"10"})
        except ValueError: pass
        else: raise AssertionError("控件访问需要实际动作证据")
    for snapshots, processes in (([first], {"10", "20"}), ([], set()),
            ([dict(first, processIdentifier=0)], {"0"}), ([dict(first, observedControls=None)], {"10"}),
            ([snapshot(10, [], ["fabricated"])], {"10"})):
        try: merge(snapshots, processes)
        except ValueError: pass
        else: raise AssertionError("UI 库存需要完整进程与标识集合")
