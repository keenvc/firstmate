#!/usr/bin/env python3
"""Firstmate-owned OpenHands (SDK) crewmate driver.

Contract owner for the openhands harness launch surface: bin/fm-spawn.sh's
launch_template is the caller and this driver is what runs in the crewmate
pane. It is a headless batch process, not a vendor TUI, so firstmate owns
every signal it emits and no hook layer is needed anywhere.

Lifecycle:
  - The LLM profile (LLM_API_KEY, LLM_MODEL) is loaded from the --llm-env
    file (active-home config/openhands-llm.env, chmod 600, never committed).
    The key is never printed, logged, or written to the run log.
  - The SDK's own state root (profile store, sessions) lands under a
    per-process temporary HOME, never the operator's real HOME: the store
    has no environment override, a host running the OpenHands server
    container can carry a root-owned ~/.openhands the SDK cannot mkdir
    into, and a shared store would leak state across tasks. The temp HOME
    is removed at exit; the conversation's durable state is the worktree.
  - The positional brief, when present, is the first message. Afterwards
    stdin is read line by line: every non-empty line is a follow-up message
    (the steering surface), the literal /exit or /quit exits, and EOF exits.
  - Every run appends one JSONL pair to the --run-log sidecar
    (state/<id>.openhands-run, truncated by the spawn so a relaunch never
    folds a predecessor's open run):
      {"ts": <iso8601>, "event": "run_started", "run": <n>}
      {"ts": <iso8601>, "event": "run_terminal", "run": <n>, "terminal": "completed"|"cancelled"}
    This file is the single owner of that record format; bin/fm-busy-lib.sh
    owns the fold (an unmatched run_started is busy, a trailing run_terminal
    is idle, anything else is unknown).
  - Every finished run, completed or cancelled, touches --turn-end
    (state/<id>.turn-ended), the turn-end signal the supervisor consumes.
  - SIGINT (the control plane's interrupt key, C-c) cancels the in-flight
    run: the pair is closed with terminal=cancelled, the conversation is
    closed, and the driver exits 130. Worktree state is preserved; the
    resume path is a deterministic relaunch, never a native resume.

Pane rows, the rendered surface firstmate reads (keep the literals stable;
the working row is the verified delivery signature,
FM_DELIVERY_OPENHANDS_BUSY_REGEX_DEFAULT in bin/fm-composer-lib.sh):
  [fm-openhands] working
  [fm-openhands] idle
  [fm-openhands] cancelled

The pane shows firstmate rows alone. The SDK's cli_mode rendering floods its
own stdout/stderr with rich panels (system prompt, tool schemas, token
counters - hundreds of lines within seconds of a run opening), which would
bury those rows far past a delivery guard's read window, so the driver
points the SDK's output at --sdk-log (default <run-log>.sdk.log, chmod 600,
append) and keeps the pane for its own rows: emit() writes through a saved
copy of the pane's stdout, so a row reaches the pane no matter where fd 1
points after the redirect. --selftest never redirects; emit falls back to
sys.stdout there.

Exit codes: 0 normal exit; 2 missing, unreadable, or incomplete --llm-env;
3 the OpenHands SDK is not importable by this interpreter; 130 interrupted.

--selftest exercises the run-log, turn-end, and stdin contract with a stub
run and no SDK import, so portable CI and the live guard can prove the
firstmate-owned half of the adapter without credentials. --selftest-hold
<seconds> holds the stub run open so the interrupt guard can land a SIGINT
mid-run deterministically.
"""

import argparse
import datetime
import json
import os
import shutil
import sys
import tempfile
import time

WORKING_ROW = "[fm-openhands] working"
IDLE_ROW = "[fm-openhands] idle"
CANCELLED_ROW = "[fm-openhands] cancelled"
EXIT_COMMANDS = ("/exit", "/quit")

# The saved pane stdout. The SDK's cli_mode rendering floods the pane with
# its own panels (system prompt, tool schemas, token counters - hundreds of
# lines within seconds of a run opening), which buries any firstmate-owned
# row far past a delivery guard's read window. The driver therefore points
# the SDK's stdout/stderr at a per-task log file and keeps the pane for its
# own rows alone: emit() writes through this saved descriptor so the rows
# reach the pane no matter where fd 1 points, and every rendered assertion
# firstmate makes becomes deterministic. --selftest never redirects, so emit
# falls back to sys.stdout.
PANE_FD = -1


def emit(row):
    line = (row + "\n").encode("utf-8", "replace")
    if PANE_FD >= 0:
        os.write(PANE_FD, line)
    else:
        sys.stdout.write(row + "\n")
        sys.stdout.flush()


def quiet_pane(sdk_log_path):
    """Send the SDK's output to the log file; keep the pane for our rows."""
    global PANE_FD
    PANE_FD = os.dup(1)
    log_fd = os.open(sdk_log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.dup2(log_fd, 1)
    os.dup2(log_fd, 2)
    os.close(log_fd)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def load_llm_profile(path):
    """Parse the env-file profile; the caller owns refusal messaging."""
    profile = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            profile[key.strip()] = value.strip()
    return profile


class RunLog:
    """Append-only JSONL run lifecycle records; the format owner is here."""

    def __init__(self, path):
        self.path = path
        self.count = 0

    def started(self):
        self.count += 1
        self._append({"ts": now_iso(), "event": "run_started", "run": self.count})

    def terminal(self, terminal):
        self._append(
            {
                "ts": now_iso(),
                "event": "run_terminal",
                "run": self.count,
                "terminal": terminal,
            }
        )

    def _append(self, record):
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")


def touch(path):
    if path:
        with open(path, "a", encoding="utf-8"):
            pass


# The SDK resolves its state root (profile store, sessions) from HOME with no
# environment override for the profile store, and two hosts facts make the
# operator's real HOME the wrong place for it: a host running the OpenHands
# server container can carry a root-owned ~/.openhands the SDK cannot mkdir
# into (the failure is a PermissionError inside Conversation construction),
# and a shared profile store would leak state across tasks. A per-process
# temporary HOME solves both and keeps every run deterministic; the
# conversation's durable state is the worktree, so nothing of value is lost
# when it is removed at exit.
SDK_HOME = ""


def ensure_sdk_home():
    global SDK_HOME
    if SDK_HOME:
        return
    SDK_HOME = tempfile.mkdtemp(prefix="fm-openhands-home.")
    os.environ["HOME"] = SDK_HOME


def cleanup_sdk_home():
    global SDK_HOME
    if SDK_HOME:
        shutil.rmtree(SDK_HOME, ignore_errors=True)
        SDK_HOME = ""


class StubConversation:
    """The --selftest stand-in: same surface, no SDK, no credentials."""

    def __init__(self, hold=0.0):
        self.messages = []
        self.hold = hold

    def send_message(self, message):
        self.messages.append(message)

    def run(self):
        if self.hold > 0:
            time.sleep(self.hold)
        return None

    def close(self):
        return None


def run_turn(conversation, log, turn_end, message):
    log.started()
    emit(WORKING_ROW)
    try:
        conversation.send_message(message)
        conversation.run()
    except KeyboardInterrupt:
        log.terminal("cancelled")
        emit(CANCELLED_ROW)
        touch(turn_end)
        raise
    log.terminal("completed")
    emit(IDLE_ROW)
    touch(turn_end)


def main():
    parser = argparse.ArgumentParser(
        description="Firstmate OpenHands crewmate driver (see module docstring)."
    )
    parser.add_argument("brief", nargs="?", default="")
    parser.add_argument("--model", default="")
    parser.add_argument("--llm-env", default=os.environ.get("FM_OPENHANDS_LLM_ENV", ""))
    parser.add_argument("--turn-end", default="")
    parser.add_argument("--run-log", required=True)
    parser.add_argument(
        "--sdk-log",
        default="",
        help="where the SDK's own output lands; defaults to <run-log>.sdk.log",
    )
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument(
        "--selftest-hold",
        type=float,
        default=0.0,
        help="stub-run seconds for --selftest; the interrupt guard holds a run open",
    )
    args = parser.parse_args()

    if args.selftest:
        conversation = StubConversation(hold=args.selftest_hold)
    else:
        if not args.llm_env or not os.path.isfile(args.llm_env):
            sys.stderr.write(
                "error: --llm-env is required and must name the active home's "
                "config/openhands-llm.env profile file\n"
            )
            return 2
        try:
            profile = load_llm_profile(args.llm_env)
        except OSError as error:
            sys.stderr.write("error: could not read %s: %s\n" % (args.llm_env, error))
            return 2
        api_key = profile.get("LLM_API_KEY", "")
        model = args.model or profile.get("LLM_MODEL", "")
        if not api_key or not model:
            sys.stderr.write(
                "error: %s must define non-empty LLM_API_KEY and LLM_MODEL "
                "(the key is never printed)\n" % args.llm_env
            )
            return 2
        os.environ.setdefault("OPENHANDS_SUPPRESS_BANNER", "1")
        ensure_sdk_home()
        quiet_pane(args.sdk_log or (args.run_log + ".sdk.log"))
        try:
            from openhands.sdk import Conversation, LLM
            from openhands.tools import get_default_agent
        except ImportError as error:
            # stderr now feeds the sdk log, so the pane gets the refusal too.
            emit("error: the OpenHands SDK is not importable by this interpreter: %s" % error)
            return 3
        llm = LLM(model=model, api_key=api_key)
        agent = get_default_agent(llm=llm, cli_mode=True)
        conversation = Conversation(agent=agent, workspace=os.getcwd())

    log = RunLog(args.run_log)
    if args.brief:
        run_turn(conversation, log, args.turn_end, args.brief)

    for line in sys.stdin:
        text = line.strip()
        if text in EXIT_COMMANDS:
            break
        if not text:
            continue
        run_turn(conversation, log, args.turn_end, text)

    conversation.close()
    return 0


if __name__ == "__main__":
    rc = 0
    try:
        rc = main()
    except KeyboardInterrupt:
        # A run in flight has already closed its own pair; this covers an
        # interrupt at the idle stdin loop, where no run is open.
        emit(CANCELLED_ROW)
        rc = 130
    finally:
        cleanup_sdk_home()
    sys.exit(rc)
