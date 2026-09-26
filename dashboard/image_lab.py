"""Read-only, bounded ComfyUI telemetry for the Cockpit Overview."""

import json
import urllib.request


MODEL_ID = "qwen-image-lab"
MAX_RESPONSE_BYTES = 4 * 1024 * 1024


def comfy_json(base: str, path: str, timeout: float = 2.0):
    # The base comes from the service environment, never from a browser request.
    with urllib.request.urlopen(base.rstrip("/") + path, timeout=timeout) as response:
        raw = response.read(MAX_RESPONSE_BYTES + 1)
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ValueError("ComfyUI response exceeded telemetry limit")
    return json.loads(raw)


def workflow_model(prompt):
    """Name the diffusion weights selected by a workflow, without its prompts."""
    if not isinstance(prompt, dict):
        return None
    for node in prompt.values():
        if not isinstance(node, dict) or node.get("class_type") != "UNETLoader":
            continue
        name = node.get("inputs", {}).get("unet_name")
        if isinstance(name, str) and name:
            return name.replace("\\", "/").rsplit("/", 1)[-1]
    return None


def queue_model(entry):
    # ComfyUI queue entries are [number, prompt_id, workflow, metadata, outputs].
    return workflow_model(entry[2]) if isinstance(entry, list) and len(entry) > 2 else None


def history_summary(history):
    rows = []
    if not isinstance(history, dict):
        raise ValueError("ComfyUI history was not an object")
    for record in history.values():
        if not isinstance(record, dict):
            continue
        prompt = record.get("prompt")
        model = queue_model(prompt)
        status = record.get("status") or {}
        if not isinstance(status, dict):
            continue
        state = status.get("status_str")
        messages = status.get("messages") or []
        started = ended = None
        for item in messages:
            if not isinstance(item, list) or len(item) < 2 or not isinstance(item[1], dict):
                continue
            stamp = item[1].get("timestamp")
            if not isinstance(stamp, (int, float)):
                continue
            if item[0] == "execution_start":
                started = stamp
            elif item[0] in ("execution_success", "execution_error", "execution_interrupted"):
                ended = stamp
        duration = round((ended - started) / 1000, 1) if started is not None and ended is not None and ended >= started else None
        rows.append({"model": model, "status": state, "duration_seconds": duration,
                     "finished_ms": ended or (prompt[3].get("create_time") if isinstance(prompt, list) and len(prompt) > 3 and isinstance(prompt[3], dict) else None)})
    rows.sort(key=lambda row: row["finished_ms"] or 0, reverse=True)
    return {"last": rows[0] if rows else None,
            "sample_size": len(rows),
            "successful": sum(row["status"] == "success" for row in rows),
            "failed": sum(row["status"] not in (None, "success") for row in rows)}


def snapshot(controller_request, base: str, get_json=comfy_json):
    """Keep three sources independent so one failure cannot hide the others."""
    result = {"node_id": "local", "controller": None, "queue": None, "history": None}
    try:
        status, body = controller_request("GET", "/v1/status", timeout=4.0)
        if status != 200:
            raise ValueError(f"controller returned HTTP {status}")
        result["controller"] = next((model for model in body.get("models", [])
                                     if model.get("id") == MODEL_ID), None)
    except (OSError, ValueError, KeyError) as exc:
        result["controller_error"] = str(exc)[:120]

    try:
        queue = get_json(base, "/queue")
        running, pending = queue["queue_running"], queue["queue_pending"]
        if not isinstance(running, list) or not isinstance(pending, list):
            raise ValueError("invalid ComfyUI queue")
        result["queue"] = {"running": len(running), "pending": len(pending),
                           "running_model": queue_model(running[0]) if running else None}
    except (OSError, ValueError, KeyError, TypeError) as exc:
        result["queue_error"] = str(exc)[:120]

    try:
        result["history"] = history_summary(get_json(base, "/history?max_items=12"))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        result["history_error"] = str(exc)[:120]
    return result
