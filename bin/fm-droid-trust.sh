#!/usr/bin/env bash
# Pre-register Factory Droid CLI's folder trust for the directory a droid spawn
# is about to launch into - the isolated task worktree of a ship or scout
# crewmate, or the seeded home of a secondmate - so the worker reaches its brief
# or charter instead of parking on "Trust this folder?".
#
# Usage: fm-droid-trust.sh <worktree> <project>
#        fm-droid-trust.sh --secondmate-home <home> <id>
#   <worktree>  the isolated task worktree this spawn launches into
#   <project>   the primary checkout that worktree belongs to
#   <home>      the seeded secondmate home this spawn launches into
#   <id>        the secondmate id that home must already be marked for
# Prints one line naming what it registered; refuses loudly on anything else.
#
# WHY THIS EXISTS. droid 0.251.0 gates a folder it has never seen behind a
# bordered "Trust this folder?" dialog whose preselected row is the trust answer,
# and no launch flag suppresses it: droid answers it by recording the folder
# under `trustedFolders` in ${HOME}/.factory/settings.json, and it honours an
# entry written there ahead of launch (verified live 2026-10-29: a
# pre-registered fresh directory launched straight into its prompt while an
# unregistered sibling parked on the dialog). Left unanswered, the dialog holds
# the launch and the brief never runs. Droid's dialog preselects the safe
# answer, so bin/fm-spawn.sh keeps a post-launch gate as the backstop: it
# answers the dialog if one renders anyway and never counts a busy turn as ready
# on a path that was neither pre-registered here nor answered there.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY and mirrors bin/fm-agy-trust.sh and
# bin/fm-claude-trust.sh. In worktree mode <worktree> must be a LINKED git
# worktree - its own git dir, sharing <project>'s common dir - whose top level is
# exactly the resolved argument. In secondmate-home mode <home> must carry a
# regular, non-symlink `.fm-secondmate-home` marker naming <id>; a secondmate
# home may be a linked worktree or a plain clone, so the git-dir test does not
# apply there. A primary checkout, a worktree of an unrelated repo, a
# subdirectory of a worktree, a plain directory, and a home directory are each
# refused with a non-zero exit, never a warning and never a silent skip.
#
# Only the launching user's own store is written: ${HOME}/.factory/settings.json
# must be a regular file this uid owns, every unrelated key and trustedFolders
# entry is preserved, and the replacement is atomic. Relative and absolute forms
# of the same directory are recorded when they differ, because droid keys the
# dialog to the directory the session starts in and a symlinked route is a
# different string.
set -u
unset CDPATH \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_INDEX_FILE \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT

usage() {
  echo "usage: fm-droid-trust.sh <worktree> <project>" >&2
  echo "       fm-droid-trust.sh --secondmate-home <home> <id>" >&2
  exit 2
}

case "${1:-}" in
  --secondmate-home)
    [ "$#" -eq 3 ] || usage
    MODE=secondmate-home
    TARGET_ARG=$2
    SUB_ID=$3
    PROJ_ARG=
    SCOPE_NOUN="secondmate home"
    ;;
  '' | -h | --help) usage ;;
  *)
    [ "$#" -eq 2 ] || usage
    MODE=worktree
    TARGET_ARG=$1
    PROJ_ARG=$2
    SUB_ID=
    SCOPE_NOUN="task worktree"
    ;;
esac

refuse() { echo "error: refusing to pre-register droid trust: $1" >&2; exit 1; }

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }
logical_dir() { (cd -- "$1" 2>/dev/null && pwd -L); }
real_file() { node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null; }

common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && real_dir "$common")
}

TARGET_REAL=$(real_dir "$TARGET_ARG") || true
[ -n "$TARGET_REAL" ] || refuse "'$TARGET_ARG' is not an accessible directory"
TARGET_LOGICAL=$(logical_dir "$TARGET_ARG") || true
[ -n "$TARGET_LOGICAL" ] || TARGET_LOGICAL=$TARGET_REAL

[ -n "${HOME:-}" ] || refuse "HOME is not set, so droid's settings store cannot be located"
HOME_REAL=$(real_dir "$HOME") || true
[ -n "$HOME_REAL" ] || refuse "HOME '$HOME' is not an accessible directory"
[ "$TARGET_REAL" != "$HOME_REAL" ] || refuse "'$TARGET_REAL' is the home directory, not a $SCOPE_NOUN"

case "$MODE" in
  worktree)
    PROJ_REAL=$(real_dir "$PROJ_ARG") || true
    [ -n "$PROJ_REAL" ] || refuse "project '$PROJ_ARG' is not an accessible directory"
    WT_TOP=$(git -C "$TARGET_REAL" rev-parse --show-toplevel 2>/dev/null) || true
    [ -n "$WT_TOP" ] || refuse "'$TARGET_REAL' is not inside a git repository"
    WT_TOP_REAL=$(real_dir "$WT_TOP") || true
    [ "$WT_TOP_REAL" = "$TARGET_REAL" ] || refuse "'$TARGET_REAL' is not a worktree root (its root is '${WT_TOP_REAL:-unresolvable}')"
    WT_GIT_DIR=$(git -C "$TARGET_REAL" rev-parse --absolute-git-dir 2>/dev/null) || true
    [ -n "$WT_GIT_DIR" ] || refuse "'$TARGET_REAL' has no resolvable git directory"
    WT_GIT_DIR=$(real_dir "$WT_GIT_DIR") || true
    [ -n "$WT_GIT_DIR" ] || refuse "'$TARGET_REAL' has an unresolvable git directory"
    WT_COMMON=$(common_dir_of "$TARGET_REAL") || true
    [ -n "$WT_COMMON" ] || refuse "'$TARGET_REAL' has no resolvable git common directory"
    [ "$WT_GIT_DIR" != "$WT_COMMON" ] || refuse "'$TARGET_REAL' is a primary checkout, not an isolated worktree"
    PROJ_COMMON=$(common_dir_of "$PROJ_REAL") || true
    [ -n "$PROJ_COMMON" ] || refuse "project '$PROJ_REAL' is not inside a git repository"
    [ "$WT_COMMON" = "$PROJ_COMMON" ] || refuse "'$TARGET_REAL' is not a worktree of project '$PROJ_REAL'"
    ;;
  secondmate-home)
    SUB_MARKER="$TARGET_REAL/.fm-secondmate-home"
    [ -f "$SUB_MARKER" ] || refuse "'$TARGET_REAL' carries no .fm-secondmate-home marker, so it is not a seeded secondmate home"
    [ ! -L "$SUB_MARKER" ] || refuse "'$SUB_MARKER' is a symlink, not a seeded secondmate-home marker"
    [ -r "$SUB_MARKER" ] || refuse "'$SUB_MARKER' is not readable"
    SUB_MARK_VALUE=$(head -n 1 "$SUB_MARKER" 2>/dev/null | tr -d '[:space:]')
    case "$SUB_MARK_VALUE" in
      *[!A-Za-z0-9._-]*) refuse "'$SUB_MARKER' holds an invalid secondmate identifier" ;;
    esac
    [ -n "$SUB_MARK_VALUE" ] || refuse "'$SUB_MARKER' is empty, so it names no secondmate"
    [ "$SUB_MARK_VALUE" = "$SUB_ID" ] || refuse "'$TARGET_REAL' is marked for secondmate '$SUB_MARK_VALUE', not '$SUB_ID'"
    ;;
esac

command -v node >/dev/null 2>&1 || refuse "node is required to record folder trust and was not found on PATH"

STORE_DIR="$HOME_REAL/.factory"
mkdir -p "$STORE_DIR" 2>/dev/null || true
STORE_DIR_REAL=$(real_dir "$STORE_DIR") || true
[ -n "$STORE_DIR_REAL" ] || refuse "droid settings directory '$STORE_DIR' does not exist and could not be created"
STORE="$STORE_DIR_REAL/settings.json"
if [ -L "$STORE" ]; then
  STORE_REAL=$(real_file "$STORE") || true
  [ -n "$STORE_REAL" ] || refuse "'$STORE' is a symlink whose target cannot be resolved"
  STORE=$STORE_REAL
fi
if [ -e "$STORE" ]; then
  [ -f "$STORE" ] || refuse "'$STORE' is not a regular file"
  [ -O "$STORE" ] || refuse "'$STORE' is not owned by this user"
  [ -w "$STORE" ] || refuse "'$STORE' is not writable"
fi

# Read-modify-write with a fingerprint check before the rename and a readback
# after it, the bin/fm-agy-trust.sh shape: droid itself rewrites this file when
# a session changes a setting, so a store that moved under us is retried and
# then refused rather than clobbered. `--settings` runtime files never touch it,
# and every unrelated key is preserved byte-for-byte through the JSON round trip.
if ! node - "$STORE" "$TARGET_LOGICAL" "$TARGET_REAL" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [store, ...wanted] = process.argv.slice(2);
const paths = [...new Set(wanted)];
const readStore = () => {
  try {
    return fs.readFileSync(store);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
};
const fingerprint = (buf) =>
  buf === null ? "absent" : crypto.createHash("sha256").update(buf).digest("hex");
const listed = (root) =>
  root.trustedFolders !== null &&
  typeof root.trustedFolders === "object" &&
  !Array.isArray(root.trustedFolders) &&
  paths.every((p) => Object.prototype.hasOwnProperty.call(root.trustedFolders, p));
const attempt = () => {
  const original = readStore();
  const before = fingerprint(original);
  let root = {};
  if (original !== null) {
    const raw = original.toString("utf8");
    if (raw.trim() !== "") {
      root = JSON.parse(raw);
      if (root === null || typeof root !== "object" || Array.isArray(root)) {
        throw new Error(`${store} is not a JSON object`);
      }
    }
  }
  if (root.trustedFolders === undefined || root.trustedFolders === null) root.trustedFolders = {};
  if (typeof root.trustedFolders !== "object" || Array.isArray(root.trustedFolders)) {
    throw new Error(`${store} has a non-object "trustedFolders" value`);
  }
  if (listed(root)) return "recorded";
  const trustedAt = new Date().toISOString();
  for (const p of paths) {
    if (!Object.prototype.hasOwnProperty.call(root.trustedFolders, p)) {
      root.trustedFolders[p] = { trustedAt };
    }
  }
  const unique = `${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const tmp = path.join(path.dirname(store), `.settings.json.fm-trust.${unique}`);
  fs.writeFileSync(tmp, `${JSON.stringify(root, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  let renamed = false;
  try {
    if (fingerprint(readStore()) !== before) return "moved";
    fs.renameSync(tmp, store);
    renamed = true;
  } finally {
    if (!renamed) fs.rmSync(tmp, { force: true });
  }
  return listed(JSON.parse(fs.readFileSync(store, "utf8"))) ? "recorded" : "dropped";
};
try {
  for (let i = 0; i < 3; i += 1) {
    const result = attempt();
    if (result === "recorded") process.exit(0);
    if (result === "moved" && i >= 1) {
      console.error(`error: ${store} was modified while folder trust was being recorded; refusing to overwrite it`);
      process.exit(1);
    }
  }
} catch (err) {
  console.error(`error: ${err.message}`);
  process.exit(1);
}
console.error(`error: ${store} did not retain folder trust for ${paths.join(", ")} after 3 attempts`);
process.exit(1);
NODE
then
  refuse "could not record folder trust for '$TARGET_LOGICAL' in '$STORE'"
fi

if [ "$TARGET_LOGICAL" != "$TARGET_REAL" ]; then
  echo "trusted: $TARGET_LOGICAL ($TARGET_REAL)"
else
  echo "trusted: $TARGET_REAL"
fi
