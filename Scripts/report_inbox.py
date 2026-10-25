#!/usr/bin/env python3
"""Archive feedback incrementally and maintain its local inventory."""
import json
import base64
import pathlib
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from command_output import show_report

import time


def delete_local_report(folder, key):
    import shutil
    folder = pathlib.Path(folder)
    filename = report_filename(key)
    for parent in (folder, folder / '.incoming'):
        for path in parent.glob('*/*/report_*.json'):
            if path.name == filename:
                path.unlink()
                shutil.rmtree(path.parent / (path.stem + '_附件'), ignore_errors=True)
    processed_path = folder / 'report-keys.txt'
    if processed_path.is_file():
        retained = [line for line in processed_path.read_text().splitlines() if line not in {key, 'pruned-file:' + filename}]
        processed_path.write_text('\n'.join(retained) + ('\n' if retained else ''))
    for path in (folder / 'error-report.json', folder / '.incoming/report.json',
                 folder / 'error-report-keys.json', folder / 'summary.txt'):
        path.unlink(missing_ok=True)
    refresh_archive_index(folder)


def report_filename(key):
    return key.replace(':', '_') + '.json'


def latest_failed_ci_runs(runs):
    """Select the newest completed run per workflow, branch and event from GitHub's ordered list."""
    seen, failures = set(), []
    for run in runs:
        if run['status'] != 'completed': continue
        key = (run['workflowDatabaseId'], run['headBranch'], run['event'])
        if key in seen: continue
        seen.add(key)
        if run['conclusion'] in {'failure', 'timed_out', 'startup_failure', 'action_required'}: failures.append(run)
    return failures


def normalize_github_issues(arguments):
    path = pathlib.Path(arguments[0])
    pages = json.loads(path.read_text())
    issues = [item for page in pages for item in page if item.get('pull_request') is None]
    path.write_text(json.dumps(issues, ensure_ascii=False) + '\n')


def refresh_archive_index(folder, compact=None):
    folder = pathlib.Path(folder)
    index_path = folder / 'archive-index.json'
    try: previous = json.loads(index_path.read_text())
    except (OSError, ValueError): previous = {}
    if not isinstance(previous, dict): previous = {}
    records = {}
    for path in folder.glob('*/*/report_*.json'):
        key = path.relative_to(folder).as_posix()
        info = path.stat()
        old = previous.get(key, {})
        if not isinstance(old, dict): old = {}
        if old.get('modified') == info.st_mtime_ns and old.get('bytes') == info.st_size and (compact is None or old.get('compacted')):
            records[key] = old
            continue
        if compact: compact(path)
        try:
            saved = json.loads(path.read_text())
            report = saved.get('report') if isinstance(saved, dict) else None
            if not isinstance(report, dict): continue
        except (OSError, ValueError): continue
        info = path.stat()
        records[key] = dict(modified=info.st_mtime_ns, bytes=info.st_size, compacted=compact is not None,
            category='用户建议' if report.get('mode') == 'suggestion' else '错误报告', source=path.relative_to(folder).parts[0])
    if records != previous:
        staging = folder / '.incoming'
        staging.mkdir(parents=True, exist_ok=True)
        incoming = staging / 'archive-index.json'
        incoming.write_text(json.dumps(records, ensure_ascii=False) + '\n')
        incoming.replace(index_path)
    return records


def prune_archive(folder, days):
    if days < 1: raise ValueError('归档保留天数需要大于零。')
    folder = pathlib.Path(folder)
    deadline = time.time_ns() - days * 86_400 * 1_000_000_000
    removed = 0
    removed_names = set()
    import shutil
    for name, item in refresh_archive_index(folder).items():
        if item['modified'] >= deadline: continue
        path = folder / name
        path.unlink()
        removed_names.add(path.name)
        shutil.rmtree(path.parent / (path.stem + '_附件'), ignore_errors=True)
        removed += 1
    processed_path = folder / 'report-keys.txt'
    processed = set(processed_path.read_text().splitlines()) if processed_path.is_file() else set()
    processed.update('pruned-file:' + name for name in removed_names)
    processed_path.write_text('\n'.join(sorted(processed)) + ('\n' if processed else ''))
    refresh_archive_index(folder)
    print(f'本地归档已按 {days} 天保留范围清理：{removed} 份。')


def archive_reports(arguments):
    keys_path = pathlib.Path(arguments[0])
    staging_dir = pathlib.Path(arguments[1])
    worker_dir = pathlib.Path(arguments[2])
    namespace_id = arguments[3]
    processed_path = pathlib.Path(arguments[4])

    output_dir = staging_dir.parent

    items = json.loads(keys_path.read_text(encoding="utf-8"))
    processed = {
        line.strip()
        for line in processed_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    } if processed_path.exists() else set()
    local_reports = {path.name: path for path in output_dir.glob("*/*/report_*.json")}
    remote_keys = {item['name'] for item in items if item.get('name', '').startswith('report:')}
    remote_files = {report_filename(key) for key in remote_keys}
    processed = {key for key in processed if (
        key.removeprefix('pruned-file:') in remote_files if key.startswith('pruned-file:')
        else key in remote_keys or report_filename(key) in local_reports)}

    def attachment_suffix(attachment):
        kind = attachment.get("contentType", "image/jpeg")
        return {"image/jpeg": ".jpg", "image/png": ".png", "image/heic": ".heic"}.get(kind, ".bin") if isinstance(kind, str) else ".bin"

    def attachment_file(report_path, index, attachment):
        return report_path.parent / (report_path.stem + "_附件") / f"图片-{index:02d}{attachment_suffix(attachment)}"

    def attachment_reference(attachment, asset):
        attributes = asset.stat()
        return {key: value for key, value in attachment.items() if key != "data"} | {
            "bytes": attributes.st_size, "fileModified": attributes.st_mtime_ns,
            "localFile": asset.relative_to(asset.parent.parent).as_posix()}

    def compact_archived_report(path):
        incoming = staging_dir / "report.json"
        try:
            saved = json.loads(path.read_text())
            attachments = saved["report"].get("attachments", [])
            if not isinstance(attachments, list): return
            changed = False
            for index, attachment in enumerate(attachments, 1):
                if not isinstance(attachment, dict) or not isinstance(attachment.get("data"), str): continue
                asset = attachment_file(path, index, attachment)
                try:
                    data = base64.b64decode(attachment["data"], validate=True)
                    if asset.read_bytes() != data: continue
                    attachments[index - 1] = attachment_reference(attachment, asset)
                    changed = True
                except (OSError, ValueError): continue
            if changed:
                incoming.write_text(json.dumps(saved, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                incoming.replace(path)
        except (OSError, ValueError, KeyError, TypeError, AttributeError): pass
        finally:
            incoming.unlink(missing_ok=True)

    refresh_archive_index(output_dir, compact_archived_report)

    def cache_complete(item):
        key = item["name"]
        path = local_reports.get(report_filename(key))
        if 'pruned-file:' + report_filename(key) in processed: return True
        if key not in processed or path is None: return False
        try:
            saved = json.loads(path.read_text())
            delivery = saved.get("emailDelivery", {})
            status = delivery.get("status")
            remote_status = item.get("metadata", {}).get("emailStatus")
            if status == "pending" or remote_status and status != remote_status: return False
            attachments = saved["report"].get("attachments", [])
            if not isinstance(attachments, list) or saved.get("inboxAttachmentErrors"): return False
            for index, attachment in enumerate(attachments, 1):
                asset = attachment_file(path, index, attachment)
                attributes = asset.stat()
                if attributes.st_size != attachment["bytes"]: return False
                if "data" in attachment:
                    if asset.read_bytes() != base64.b64decode(attachment["data"], validate=True): return False
                elif attributes.st_mtime_ns != attachment["fileModified"]: return False
            return True
        except (OSError, ValueError, KeyError, TypeError, AttributeError): return False

    keys_to_fetch = [item["name"] for item in items if item.get("name", "").startswith("report:") and not cache_complete(item)]

    def fetch(key):
        result = subprocess.run(
            [
                str(worker_dir / "node_modules/.bin/wrangler"), "kv", "key", "get", key,
                "--remote", "--namespace-id", namespace_id, "--text",
            ],
            cwd=worker_dir,
            check=False,
            capture_output=True,
            text=True,
        )
        filename = report_filename(key)
        if result.returncode:
            detail = result.stderr.strip()
            print(f"读取报告失败：{key}{f'：{detail}' if detail else ''}", file=sys.stderr)
            return key, False, None
        try:
            item = json.loads(result.stdout)
            report = item["report"]
            if not isinstance(report, dict):
                raise ValueError("report 需要对象结构")
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            print(f"报告 JSON 解析失败：{key}", file=sys.stderr)
            return key, False, None
        category = "用户建议" if report.get("mode") == "suggestion" else "错误报告"
        development = report.get("isDevelopmentBuild")
        source = "开发版" if development is True else "正式版" if development is False else "来源未知"
        category_dir = staging_dir / source / category
        category_dir.mkdir(parents=True, exist_ok=True)
        attachments = report.get("attachments", [])
        attachment_errors = 0
        if isinstance(attachments, list) and attachments:
            attachment_dir = category_dir / f"{pathlib.Path(filename).stem}_附件"
            attachment_dir.mkdir(parents=True, exist_ok=True)
            downloaded_attachments = []
            for index, attachment in enumerate(attachments, 1):
                if not isinstance(attachment, dict) or not isinstance(attachment.get("data"), str):
                    downloaded_attachments.append({"original": attachment, "error": "附件格式异常"})
                    attachment_errors += 1
                    continue
                try:
                    data = base64.b64decode(attachment["data"], validate=True)
                except (ValueError, base64.binascii.Error) as error:
                    downloaded_attachments.append(dict(attachment, error=f"附件解码失败：{error}"))
                    attachment_errors += 1
                    continue
                extension = attachment_suffix(attachment)
                asset = attachment_dir / f"图片-{index:02d}{extension}"
                asset.write_bytes(data)
                downloaded_attachments.append(
                    attachment_reference(attachment, asset)
                )
            report["attachments"] = downloaded_attachments
            item["report"] = report
            if attachment_errors:
                item["inboxAttachmentErrors"] = attachment_errors
            result_text = json.dumps(item, ensure_ascii=False, indent=2)
        else:
            if not isinstance(attachments, list):
                attachment_errors = 1
                item["inboxAttachmentErrors"] = 1
                result_text = json.dumps(item, ensure_ascii=False, indent=2)
            else:
                result_text = result.stdout
        destination = category_dir / filename
        destination.write_text(result_text, encoding="utf-8")
        return key, attachment_errors == 0, destination

    def save_processed():
        incoming = staging_dir / 'report-keys.txt'
        incoming.write_text("\n".join(sorted(processed)) + ("\n" if processed else ""), encoding="utf-8")
        incoming.replace(processed_path)

    downloaded_reports = 0
    incomplete = set()
    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(fetch, key): key for key in keys_to_fetch}
        for future in as_completed(futures):
            key, complete = futures[future], False
            try:
                key, complete, report_path = future.result()
                if report_path is not None:
                    assets = report_path.parent / (report_path.stem + '_附件')
                    for path in [*assets.glob('*'), report_path]:
                        destination = output_dir / path.relative_to(staging_dir)
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        os.replace(path, destination)
                    downloaded_reports += 1
            except OSError as error:
                complete = False
                print(f"报告读取或归档失败：{key}：{error}", file=sys.stderr)
            if complete: processed.add(key)
            else: processed.discard(key); incomplete.add(key)
            try: save_processed()
            except OSError as error:
                processed.discard(key)
                incomplete.add(key)
                print(f"报告处理记录保存失败：{key}：{error}", file=sys.stderr)
    if not keys_to_fetch: save_processed()
    refresh_archive_index(output_dir)
    print(downloaded_reports)
    if incomplete:
        print(f"报告处理待重试：{len(incomplete)} 份，成功内容已归档，附件错误随正文保存。", file=sys.stderr)
        sys.exit(1)


def publish_summary(arguments):
    issues_path = pathlib.Path(arguments[0])
    issues = json.loads(issues_path.read_text(encoding="utf-8")) if issues_path.exists() else []
    report_dir = pathlib.Path(arguments[1])
    summary_path = pathlib.Path(arguments[2])
    new_report_count = int(arguments[3])
    issues_state, ci_state, cloudflare_state = arguments[5:8]
    ci_path = pathlib.Path(arguments[4])
    ci_runs = json.loads(ci_path.read_text(encoding="utf-8")) if ci_path.exists() else []

    lines = [f"GitHub Issues：{len(issues)} · {issues_state}"]
    for issue in issues:
        lines.append(f"  #{issue['number']} [{issue['state']}] {issue['title']}  {issue['url']}")
    lines.append("")
    lines.append(f"GitHub CI：{len(ci_runs)} 条失败运行 · {ci_state}")
    for run in ci_runs:
        lines.append(
            f"  #{run.get('databaseId')} [{run.get('workflowName')}] "
            f"{run.get('displayTitle')}  {run.get('url')}"
        )
        diagnostic = next((line for line in run.get("failedLog", "").splitlines()
            if any(marker in line.lower() for marker in ("error:", "##[error]", "failed", "failure"))), None)
        if diagnostic:
            lines.append(f"    {diagnostic}")
    lines.append("")
    records = refresh_archive_index(report_dir)
    current_counts = {kind: sum(item['category'] == kind for item in records.values()) for kind in ('错误报告', '用户建议')}
    current_sources = {kind: sum(item['source'] == kind for item in records.values()) for kind in ('开发版', '正式版', '来源未知')}
    try:
        remote_keys = json.loads((report_dir / 'error-report-keys.json').read_text())
        remote_count = sum(1 for item in remote_keys if item['name'].startswith('report:'))
        remote_inventory = f"远端现存 {remote_count} 条"
    except (OSError, ValueError, KeyError, TypeError):
        remote_inventory = "远端列表待读取"
    lines.append(
        f"Cloudflare 报告：{remote_inventory}，本次拉取 {new_report_count} 条 · {cloudflare_state}"
    )
    lines.append(
        f"本地归档：错误报告 {current_counts['错误报告']}，用户建议 {current_counts['用户建议']}；"
        f"开发版 {current_sources['开发版']}，正式版 {current_sources['正式版']}，来源未知 {current_sources['来源未知']}"
    )

    summary = "\n".join(lines) + "\n"
    summary_path.write_text(summary, encoding="utf-8")
    show_report(summary_path, '反馈汇总')


if __name__ == '__main__':
    action, *arguments = sys.argv[1:]
    if action == 'archive': archive_reports(arguments)
    elif action == 'summary': publish_summary(arguments)
    elif action == 'prune': prune_archive(arguments[0], int(arguments[1]))
    elif action == 'issues': normalize_github_issues(arguments)
    else: raise SystemExit('反馈归档操作需要 archive、summary、prune 或 issues。')
