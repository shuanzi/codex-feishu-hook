#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
XDG_CONFIG_HOME_VALUE="${XDG_CONFIG_HOME:-$HOME/.config}"
PRIVATE_DIR="$XDG_CONFIG_HOME_VALUE/codex-feishu"
TARGET_SCRIPT="$CODEX_HOME/hooks/codex_feishu_notify.py"
PRIVATE_CONFIG="$PRIVATE_DIR/config.json"
HOOKS_FILE="$CODEX_HOME/hooks.json"
HOOK_STATE="$PRIVATE_DIR/user-hook-state.json"

WEBHOOK_URL="${FEISHU_WEBHOOK_URL:-}"
SIGN_SECRET="${FEISHU_SIGN_SECRET:-}"
INCLUDE_SUMMARY=true
INCLUDE_CWD=true
SUMMARY_MAX_CHARS=600
TIMEOUT_SECONDS=4
PROJECT_NAME=""
TAG=""
TITLE="✅ Codex 本轮已完成"
SEND_TEST=false

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

Options:
  --webhook-url URL        Feishu custom-bot webhook URL.
  --sign-secret SECRET     Optional Feishu signature secret.
  --no-summary             Do not include the final Codex response summary.
  --include-summary        Include the final Codex response summary (default).
  --include-cwd            Include the absolute working directory (default).
  --no-cwd                 Do not include the working directory.
  --summary-max-chars N    Maximum summary length, 0-4000 (default: 600).
  --timeout-seconds N      HTTP timeout, >0 and <=30 (default: 4).
  --project-name NAME      Override the project name in notifications.
  --tag TEXT               Add a tag to notifications.
  --title TEXT             Override the notification title.
  --send-test              Send a real test message after installation.
  -h, --help               Show this help.

Environment:
  FEISHU_WEBHOOK_URL, FEISHU_SIGN_SECRET, CODEX_HOME, XDG_CONFIG_HOME
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --webhook-url)
      [[ $# -ge 2 ]] || { echo "missing value for --webhook-url" >&2; exit 2; }
      WEBHOOK_URL="$2"; shift 2 ;;
    --sign-secret)
      [[ $# -ge 2 ]] || { echo "missing value for --sign-secret" >&2; exit 2; }
      SIGN_SECRET="$2"; shift 2 ;;
    --no-summary)
      INCLUDE_SUMMARY=false; shift ;;
    --include-summary)
      INCLUDE_SUMMARY=true; shift ;;
    --include-cwd)
      INCLUDE_CWD=true; shift ;;
    --no-cwd)
      INCLUDE_CWD=false; shift ;;
    --summary-max-chars)
      [[ $# -ge 2 ]] || { echo "missing value for --summary-max-chars" >&2; exit 2; }
      SUMMARY_MAX_CHARS="$2"; shift 2 ;;
    --timeout-seconds)
      [[ $# -ge 2 ]] || { echo "missing value for --timeout-seconds" >&2; exit 2; }
      TIMEOUT_SECONDS="$2"; shift 2 ;;
    --project-name)
      [[ $# -ge 2 ]] || { echo "missing value for --project-name" >&2; exit 2; }
      PROJECT_NAME="$2"; shift 2 ;;
    --tag)
      [[ $# -ge 2 ]] || { echo "missing value for --tag" >&2; exit 2; }
      TAG="$2"; shift 2 ;;
    --title)
      [[ $# -ge 2 ]] || { echo "missing value for --title" >&2; exit 2; }
      TITLE="$2"; shift 2 ;;
    --send-test)
      SEND_TEST=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [[ -z "$WEBHOOK_URL" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Feishu webhook URL: " WEBHOOK_URL
  else
    echo "--webhook-url is required in non-interactive mode" >&2
    exit 2
  fi
fi

python3 - "$WEBHOOK_URL" "$SUMMARY_MAX_CHARS" "$TIMEOUT_SECONDS" <<'PY'
import sys

url, summary_raw, timeout_raw = sys.argv[1:]
if not url.startswith("https://"):
    raise SystemExit("webhook URL must start with https://")
try:
    summary = int(summary_raw)
except ValueError:
    raise SystemExit("summary-max-chars must be an integer")
if not 0 <= summary <= 4000:
    raise SystemExit("summary-max-chars must be between 0 and 4000")
try:
    timeout = float(timeout_raw)
except ValueError:
    raise SystemExit("timeout-seconds must be numeric")
if not 0 < timeout <= 30:
    raise SystemExit("timeout-seconds must be greater than 0 and at most 30")
PY

# Validate the Hook file and any previously recorded managed state before
# writing runtime or private configuration files.
HOOKS_FILE="$HOOKS_FILE" HOOK_STATE="$HOOK_STATE" TARGET_SCRIPT="$TARGET_SCRIPT" python3 <<'PY'
import json
import os
import shlex
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"codex-feishu-hook: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_json(path: Path, label: str, default: object) -> object:
    if not path.exists():
        return default
    try:
        with path.open(encoding="utf-8") as file:
            return json.load(file)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")


def managed_group(target_script: Path) -> dict[str, object]:
    command = f"python3 {shlex.quote(str(target_script))}"
    return {
        "hooks": [
            {
                "type": "command",
                "command": command,
                "timeout": 5,
                "statusMessage": "Sending Feishu completion notification",
            }
        ]
    }


def stop_groups(value: object) -> list[object]:
    if not isinstance(value, dict):
        fail("hooks.json root must be a JSON object")
    hooks = value.get("hooks", {})
    if not isinstance(hooks, dict):
        fail("hooks.json hooks field must be a JSON object")
    groups = hooks.get("Stop", [])
    if not isinstance(groups, list):
        fail("hooks.Stop must be a JSON array")
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            fail("hooks.Stop entries must contain a hooks array")
    return groups


hooks_path = Path(os.environ["HOOKS_FILE"])
state_path = Path(os.environ["HOOK_STATE"])
group = managed_group(Path(os.environ["TARGET_SCRIPT"]))
hooks_value = load_json(hooks_path, "hooks JSON", {"hooks": {}})
groups = stop_groups(hooks_value)
state_value = load_json(state_path, "managed Hook state", None)

if state_value is not None:
    if not isinstance(state_value, dict) or state_value.get("hook_group") != group:
        fail("managed Hook state does not match this installation")
    if groups.count(group) != 1:
        fail("managed Feishu Stop Hook is missing or duplicated")
else:
    for existing_group in groups:
        for handler in existing_group["hooks"]:
            if isinstance(handler, dict) and handler.get("command") == group["hooks"][0]["command"]:
                fail("existing unmanaged Feishu Stop Hook found; remove or adopt it manually")
PY

mkdir -p "$CODEX_HOME/hooks" "$CODEX_HOME/log" "$PRIVATE_DIR"
chmod 700 "$CODEX_HOME/hooks" "$CODEX_HOME/log" "$PRIVATE_DIR"
install -m 755 "$PACKAGE_DIR/bin/codex_feishu_notify.py" "$TARGET_SCRIPT"

TEMP_CONFIG="$(mktemp "$PRIVATE_DIR/.config.json.XXXXXX")"
WEBHOOK_URL="$WEBHOOK_URL" \
SIGN_SECRET="$SIGN_SECRET" \
INCLUDE_SUMMARY="$INCLUDE_SUMMARY" \
INCLUDE_CWD="$INCLUDE_CWD" \
SUMMARY_MAX_CHARS="$SUMMARY_MAX_CHARS" \
TIMEOUT_SECONDS="$TIMEOUT_SECONDS" \
PROJECT_NAME="$PROJECT_NAME" \
TAG="$TAG" \
TITLE="$TITLE" \
TEMP_CONFIG="$TEMP_CONFIG" \
python3 <<'PY'
import json
import os
from pathlib import Path

payload = {
    "enabled": True,
    "webhook_url": os.environ["WEBHOOK_URL"],
    "sign_secret": os.environ["SIGN_SECRET"],
    "title": os.environ["TITLE"],
    "project_name": os.environ["PROJECT_NAME"],
    "tag": os.environ["TAG"],
    "include_summary": os.environ["INCLUDE_SUMMARY"].lower() == "true",
    "summary_max_chars": int(os.environ["SUMMARY_MAX_CHARS"]),
    "include_cwd": os.environ["INCLUDE_CWD"].lower() == "true",
    "timeout_seconds": float(os.environ["TIMEOUT_SECONDS"]),
}
Path(os.environ["TEMP_CONFIG"]).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
chmod 600 "$TEMP_CONFIG"
mv -f "$TEMP_CONFIG" "$PRIVATE_CONFIG"

HOOKS_FILE="$HOOKS_FILE" HOOK_STATE="$HOOK_STATE" TARGET_SCRIPT="$TARGET_SCRIPT" python3 <<'PY'
import json
import os
import shlex
import stat
import tempfile
from pathlib import Path


def fail(message: str) -> None:
    print(f"codex-feishu-hook: {message}", file=os.sys.stderr)
    raise SystemExit(2)


def load_json(path: Path, label: str, default: object) -> object:
    if not path.exists():
        return default
    try:
        with path.open(encoding="utf-8") as file:
            return json.load(file)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")


def write_json(path: Path, value: object, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            json.dump(value, file, ensure_ascii=False, indent=2)
            file.write("\n")
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


hooks_path = Path(os.environ["HOOKS_FILE"])
state_path = Path(os.environ["HOOK_STATE"])
target_script = Path(os.environ["TARGET_SCRIPT"])
command = f"python3 {shlex.quote(str(target_script))}"
group = {
    "hooks": [
        {
            "type": "command",
            "command": command,
            "timeout": 5,
            "statusMessage": "Sending Feishu completion notification",
        }
    ]
}
hooks_value = load_json(hooks_path, "hooks JSON", {"hooks": {}})
if not isinstance(hooks_value, dict):
    fail("hooks.json root must be a JSON object")
hooks = hooks_value.setdefault("hooks", {})
if not isinstance(hooks, dict):
    fail("hooks.json hooks field must be a JSON object")
groups = hooks.setdefault("Stop", [])
if not isinstance(groups, list):
    fail("hooks.Stop must be a JSON array")
for existing_group in groups:
    if not isinstance(existing_group, dict) or not isinstance(existing_group.get("hooks"), list):
        fail("hooks.Stop entries must contain a hooks array")

state_value = load_json(state_path, "managed Hook state", None)
if state_value is not None:
    if not isinstance(state_value, dict) or state_value.get("hook_group") != group:
        fail("managed Hook state does not match this installation")
    if groups.count(group) != 1:
        fail("managed Feishu Stop Hook is missing or duplicated")
else:
    for existing_group in groups:
        for handler in existing_group["hooks"]:
            if isinstance(handler, dict) and handler.get("command") == command:
                fail("existing unmanaged Feishu Stop Hook found; remove or adopt it manually")
    groups.append(group)
    hooks_mode = stat.S_IMODE(hooks_path.stat().st_mode) if hooks_path.exists() else 0o600
    write_json(hooks_path, hooks_value, hooks_mode)
    write_json(state_path, {"version": 1, "hook_group": group}, 0o600)
PY

printf 'Installed notifier: %s\n' "$TARGET_SCRIPT"
printf 'Private config:    %s\n' "$PRIVATE_CONFIG"
printf 'User Hook config:  %s\n' "$HOOKS_FILE"
printf 'Restart Codex, then use /hooks to review and trust the new Stop Hook.\n'

if [[ "$SEND_TEST" == true ]]; then
  TEST_EVENT=$(printf '{"hook_event_name":"Stop","turn_id":"install-test","cwd":%s,"last_assistant_message":"Codex 飞书通知安装测试成功。"}' "$(python3 -c 'import json,os; print(json.dumps(os.getcwd()))')")
  printf '%s' "$TEST_EVENT" | CODEX_FEISHU_STRICT=1 CODEX_FEISHU_CONFIG="$PRIVATE_CONFIG" "$TARGET_SCRIPT"
  printf 'Test notification sent successfully.\n'
fi
