#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KINDCTL="$ROOT/bin/kindctl"
TEST_PATTERN="${TEST_PATTERN:-}"

pass=0
fail=0

log() { printf '%s\n' "$*"; }
fail_msg() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "${1:-}" = "${2:-}" ] || fail_msg "expected [$2], got [$1]"; }
assert_ne() { [ "${1:-}" != "${2:-}" ] || fail_msg "did not expect [$1]"; }
assert_contains() { case "${1:-}" in *"$2"*) return 0;; *) fail_msg "expected to find [$2] in [$1]";; esac; }
assert_file_exists() { [ -e "$1" ] || fail_msg "expected file to exist: $1"; }
assert_not_exists() { [ ! -e "$1" ] || fail_msg "expected path not to exist: $1"; }
assert_mode() {
  local mode
  mode="$(stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1")"
  assert_eq "$mode" "$2"
}

new_tmp() { mktemp -d "${TMPDIR:-/tmp}/kindctl-test.XXXXXX"; }

source_kindctl() {
  # shellcheck source=/dev/null
  source "$KINDCTL"
}

json_get() {
  local file="$1" expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json, sys
file, expr = sys.argv[1], sys.argv[2]
data = json.load(open(file))
cur = data
for part in expr.split('.'):
    if not part:
        continue
    cur = cur[part]
print(cur if not isinstance(cur, bool) else str(cur).lower())
PY
}

json_has_cluster() {
  local file="$1" name="$2"
  python3 - "$file" "$name" <<'PY'
import json, sys
print('yes' if sys.argv[2] in json.load(open(sys.argv[1])).get('clusters', {}) else 'no')
PY
}

make_fake_bin() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/kind" <<'FAKE_KIND'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$FAKE_STATE/clusters" "$FAKE_STATE/containers" "$FAKE_STATE/running"
printf 'kind' >> "$FAKE_LOG"; for a in "$@"; do printf ' [%s]' "$a" >> "$FAKE_LOG"; done; printf '\n' >> "$FAKE_LOG"
cmd="${1:-} ${2:-}"
shift $(( $# >= 2 ? 2 : $# ))
case "$cmd" in
  "get clusters")
    find "$FAKE_STATE/clusters" -type f -maxdepth 1 -print 2>/dev/null | sed 's|.*/||' | sort
    ;;
  "create cluster")
    name=""; kubeconfig=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --kubeconfig) kubeconfig="$2"; shift 2 ;;
        --config|--image) shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$name" ] && [ -n "$kubeconfig" ] || exit 64
    [ ! -e "$FAKE_STATE/clusters/$name" ] || { echo "already exists" >&2; exit 1; }
    mkdir -p "$(dirname "$kubeconfig")"
    printf 'apiVersion: v1\ncurrent-context: kind-%s\n' "$name" > "$kubeconfig"
    touch "$FAKE_STATE/clusters/$name" "$FAKE_STATE/containers/$name-id" "$FAKE_STATE/running/$name-id"
    ;;
  "delete cluster")
    name=""; kubeconfig=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --kubeconfig) kubeconfig="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$name" ] || exit 64
    rm -f "$FAKE_STATE/clusters/$name" "$FAKE_STATE/containers/$name-id" "$FAKE_STATE/running/$name-id"
    ;;
  "export kubeconfig")
    name=""; kubeconfig=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --kubeconfig) kubeconfig="$2"; shift 2 ;;
        --internal) shift ;;
        *) shift ;;
      esac
    done
    [ -n "$name" ] && [ -n "$kubeconfig" ] || exit 64
    mkdir -p "$(dirname "$kubeconfig")"
    printf 'apiVersion: v1\ncurrent-context: kind-%s\n' "$name" > "$kubeconfig"
    ;;
  "load docker-image")
    exit 0
    ;;
  *)
    echo "fake kind unsupported: $cmd $*" >&2
    exit 64
    ;;
esac
FAKE_KIND
  chmod +x "$dir/kind"

  cat > "$dir/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$FAKE_STATE/clusters" "$FAKE_STATE/containers" "$FAKE_STATE/running"
printf 'docker' >> "$FAKE_LOG"; for a in "$@"; do printf ' [%s]' "$a" >> "$FAKE_LOG"; done; printf '\n' >> "$FAKE_LOG"
cmd="${1:-}"; shift || true
case "$cmd" in
  info) exit 0 ;;
  ps)
    all=false; quiet=false; label=""; format=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -a|--all) all=true; shift ;;
        -q|--quiet) quiet=true; shift ;;
        --filter)
          case "$2" in label=io.x-k8s.kind.cluster=*) label="${2#label=io.x-k8s.kind.cluster=}" ;; label=io.x-k8s.kind.cluster) label="__any__" ;; esac
          shift 2 ;;
        --format) format="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    names=""
    if [ "$label" = "__any__" ] || [ -z "$label" ]; then
      names="$(find "$FAKE_STATE/containers" -type f -maxdepth 1 -print 2>/dev/null | sed 's|.*/||; s/-id$//' | sort || true)"
    else
      [ -e "$FAKE_STATE/containers/$label-id" ] && names="$label" || names=""
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      id="$name-id"
      if [ "$all" = false ] && [ ! -e "$FAKE_STATE/running/$id" ]; then
        continue
      fi
      if [ -n "$format" ]; then
        printf '%s 0.0.0.0:8080->80/tcp\n' "$name-control-plane"
      elif [ "$quiet" = true ]; then
        printf '%s\n' "$id"
      else
        printf '%s %s\n' "$id" "$name"
      fi
    done <<EOF_NAMES
$names
EOF_NAMES
    ;;
  stop)
    for id in "$@"; do rm -f "$FAKE_STATE/running/$id"; printf '%s\n' "$id"; done
    ;;
  start)
    for id in "$@"; do touch "$FAKE_STATE/running/$id"; printf '%s\n' "$id"; done
    ;;
  *)
    echo "fake docker unsupported: $cmd $*" >&2
    exit 64
    ;;
esac
FAKE_DOCKER
  chmod +x "$dir/docker"

  cat > "$dir/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl KUBECONFIG=%s' "${KUBECONFIG:-}" >> "$FAKE_LOG"; for a in "$@"; do printf ' [%s]' "$a" >> "$FAKE_LOG"; done; printf '\n' >> "$FAKE_LOG"
printf 'kubectl-ok %s\n' "${KUBECONFIG:-}"
FAKE_KUBECTL
  chmod +x "$dir/kubectl"
}

setup_fake_env() {
  TEST_TMP="$(new_tmp)"
  export HOME="$TEST_TMP/home"
  export FAKE_STATE="$TEST_TMP/state"
  export FAKE_LOG="$TEST_TMP/fake.log"
  mkdir -p "$HOME" "$FAKE_STATE" "$TEST_TMP/bin"
  : > "$FAKE_LOG"
  make_fake_bin "$TEST_TMP/bin"
  export PATH="$TEST_TMP/bin:$PATH"
}

test_derivation_git_subdir_same_name() {
  setup_fake_env; source_kindctl
  repo="$TEST_TMP/repo"; mkdir -p "$repo/sub"; git -C "$repo" init -q
  cd "$repo"; kindctl_derive ""; root_name="$KINDCTL_NAME"; root_root="$KINDCTL_ROOT"
  cd "$repo/sub"; kindctl_derive ""; assert_eq "$KINDCTL_NAME" "$root_name"; assert_eq "$KINDCTL_ROOT" "$root_root"
}

test_derivation_worktrees_distinct() {
  setup_fake_env; source_kindctl
  repo="$TEST_TMP/repo"; wt="$TEST_TMP/repo-wt"; mkdir -p "$repo"; git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com; git -C "$repo" config user.name Test
  echo x > "$repo/file"; git -C "$repo" add file; git -C "$repo" commit -q -m init
  git -C "$repo" worktree add -q "$wt"
  cd "$repo"; kindctl_derive ""; n1="$KINDCTL_NAME"
  cd "$wt"; kindctl_derive ""; n2="$KINDCTL_NAME"
  assert_ne "$n1" "$n2"
}

test_derivation_duplicate_basenames_distinct() {
  setup_fake_env; source_kindctl
  mkdir -p "$TEST_TMP/a/api" "$TEST_TMP/b/api"
  cd "$TEST_TMP/a/api"; kindctl_derive ""; n1="$KINDCTL_NAME"
  cd "$TEST_TMP/b/api"; kindctl_derive ""; n2="$KINDCTL_NAME"
  assert_ne "$n1" "$n2"
}

test_derivation_non_git_marker_walkup() {
  setup_fake_env; source_kindctl
  mkdir -p "$TEST_TMP/repo/.kind" "$TEST_TMP/repo/sub/dir"
  cd "$TEST_TMP/repo/sub/dir"; kindctl_derive ""; expected_root="$(cd "$TEST_TMP/repo" && pwd -P)"; assert_eq "$KINDCTL_ROOT" "$expected_root"
}

test_derivation_tag_validation_and_length() {
  setup_fake_env; source_kindctl
  mkdir -p "$TEST_TMP/repo"; cd "$TEST_TMP/repo"
  if kindctl_normalize_tag "!!!!" >/dev/null 2>&1; then fail_msg "symbol-only tag should fail"; fi
  long="This_IS_A_Very_Long_Tag_With_Symbols_And_Uppercase"
  kindctl_derive "$long"
  [ "${#KINDCTL_TAG}" -le 16 ] || fail_msg "tag too long: $KINDCTL_TAG"
  [ "${#KINDCTL_NAME}" -le 50 ] || fail_msg "name too long: $KINDCTL_NAME"
  container_name="${KINDCTL_NAME}-control-plane"
  [ "${#container_name}" -le 64 ] || fail_msg "container name too long"
}

test_registry_modes_and_ownership() {
  setup_fake_env; source_kindctl
  kindctl_registry_upsert "a" "$TEST_TMP/repo" "$HOME/.kube/kind/a.kubeconfig" "kind-a" "" ready true
  assert_mode "$HOME/.kube/kind" 700
  assert_mode "$HOME/.kube/kind/registry.json" 600
  kindctl_registry_is_owned a
  if kindctl_registry_is_owned missing; then fail_msg "missing entry should not be owned"; fi
  kindctl_registry_upsert "u" "$TEST_TMP/repo" "$HOME/.kube/kind/u.kubeconfig" "kind-u" "" ready false
  if kindctl_registry_is_owned u; then fail_msg "unmanaged entry should not be owned"; fi
}

test_registry_concurrent_writes_preserve_entries() {
  setup_fake_env
  for i in 1 2 3 4 5 6 7 8; do
    HOME="$HOME" PATH="$PATH" bash -c "source '$KINDCTL'; kindctl_registry_upsert n$i '$TEST_TMP/r$i' '$HOME/.kube/kind/n$i.kubeconfig' kind-n$i '' ready true" &
  done
  wait
  python3 - "$HOME/.kube/kind/registry.json" <<'PY'
import json, sys
clusters=json.load(open(sys.argv[1]))['clusters']
missing=[f'n{i}' for i in range(1,9) if f'n{i}' not in clusters]
assert not missing, missing
PY
}

test_lifecycle_create_setup_ready_and_no_global_config_touch() {
  setup_fake_env
  repo="$TEST_TMP/repo"; mkdir -p "$repo/.kind" "$HOME/.kube"
  printf 'original\n' > "$HOME/.kube/config"
  cat > "$repo/.kind/setup.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n%s\n%s\n%s\n' "$KUBECONFIG" "$KINDCTL_CLUSTER" "$KINDCTL_CONTEXT" "$KINDCTL_ROOT" > setup.env
SH
  chmod +x "$repo/.kind/setup.sh"
  cd "$repo"
  "$KINDCTL" create --tag dev >/tmp/kindctl-create.out
  name="$(find "$FAKE_STATE/clusters" -type f -maxdepth 1 -print | sed 's|.*/||')"
  assert_file_exists "$HOME/.kube/kind/$name.kubeconfig"
  assert_eq "$(json_get "$HOME/.kube/kind/registry.json" "clusters.$name.setup_status")" ready
  assert_contains "$(cat "$repo/setup.env")" "$HOME/.kube/kind/$name.kubeconfig"
  assert_eq "$(cat "$HOME/.kube/config")" "original"
  assert_contains "$(cat "$FAKE_LOG")" "--kubeconfig"
  if grep -F "$HOME/.kube/config" "$FAKE_LOG" >/dev/null; then fail_msg "global kubeconfig was passed to fake tools"; fi
}

test_lifecycle_hook_failure_preserves_registry_failed() {
  setup_fake_env
  repo="$TEST_TMP/repo"; mkdir -p "$repo/.kind"
  cat > "$repo/.kind/setup.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 42
SH
  chmod +x "$repo/.kind/setup.sh"
  cd "$repo"
  if "$KINDCTL" create 2>"$TEST_TMP/err"; then fail_msg "create should fail when hook fails"; fi
  name="$(find "$FAKE_STATE/clusters" -type f -maxdepth 1 -print | sed 's|.*/||')"
  assert_eq "$(json_get "$HOME/.kube/kind/registry.json" "clusters.$name.setup_status")" failed
  assert_contains "$(cat "$TEST_TMP/err")" "setup hook failed"
}

test_lifecycle_delete_owned_and_refuse_unowned() {
  setup_fake_env; repo="$TEST_TMP/repo"; mkdir -p "$repo"; cd "$repo"
  if "$KINDCTL" delete 2>"$TEST_TMP/err"; then fail_msg "delete should refuse unowned cluster"; fi
  assert_contains "$(cat "$TEST_TMP/err")" "non-registry-owned"
  "$KINDCTL" create >/dev/null
  name="$(find "$FAKE_STATE/clusters" -type f -maxdepth 1 -print | sed 's|.*/||')"
  "$KINDCTL" delete >/dev/null
  assert_not_exists "$FAKE_STATE/clusters/$name"
  assert_eq "$(json_has_cluster "$HOME/.kube/kind/registry.json" "$name")" no
  assert_not_exists "$HOME/.kube/kind/$name.kubeconfig"
}

test_safety_path_exec_kubectl_scoped() {
  setup_fake_env; repo="$TEST_TMP/repo"; mkdir -p "$repo"; cd "$repo"
  if "$KINDCTL" path 2>"$TEST_TMP/err"; then fail_msg "path should be strict"; fi
  assert_contains "$(cat "$TEST_TMP/err")" "kindctl create"
  "$KINDCTL" create --tag s >/dev/null
  path="$($KINDCTL path --tag s)"
  assert_contains "$path" "$HOME/.kube/kind/"
  assert_eq "$($KINDCTL ctx --tag s)" "--kubeconfig $path"
  assert_contains "$($KINDCTL env --tag s)" "export KUBECONFIG='"
  out="$($KINDCTL exec --tag s -- env)"
  assert_contains "$out" "KUBECONFIG=$path"
  "$KINDCTL" kubectl --tag s get nodes >/dev/null
  assert_contains "$(cat "$FAKE_LOG")" "kubectl KUBECONFIG=$path [get] [nodes]"
}

test_safety_strict_missing_for_cluster_targeting_commands() {
  setup_fake_env; repo="$TEST_TMP/repo"; mkdir -p "$repo"; cd "$repo"
  commands=(
    "path"
    "ctx"
    "env"
    "exec -- env"
    "kubectl get nodes"
    "load image:dev"
    "hibernate"
    "resume"
  )
  for cmd in "${commands[@]}"; do
    if "$KINDCTL" $cmd >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
      fail_msg "expected strict failure for: $cmd"
    fi
    assert_contains "$(cat "$TEST_TMP/err")" "kindctl create"
  done
}

test_operate_load_hibernate_resume_and_list() {
  setup_fake_env; repo="$TEST_TMP/repo"; mkdir -p "$repo"; cd "$repo"
  "$KINDCTL" create --tag op >/dev/null
  name="$(find "$FAKE_STATE/clusters" -type f -maxdepth 1 -print | sed 's|.*/||')"
  "$KINDCTL" load --tag op image:dev
  "$KINDCTL" hibernate --tag op >/dev/null
  "$KINDCTL" resume --tag op >/dev/null
  log_text="$(cat "$FAKE_LOG")"
  assert_contains "$log_text" "kind [load] [docker-image] [image:dev] [--name] [$name]"
  assert_contains "$log_text" "label=io.x-k8s.kind.cluster=$name"
  list="$($KINDCTL list --workspace)"
  assert_contains "$list" "$name"
  assert_contains "$list" "running"
}

test_operate_list_all_marks_unmanaged() {
  setup_fake_env; repo="$TEST_TMP/repo"; mkdir -p "$repo"; cd "$repo"
  mkdir -p "$FAKE_STATE/clusters" "$FAKE_STATE/containers" "$FAKE_STATE/running"
  touch "$FAKE_STATE/clusters/unmanaged" "$FAKE_STATE/containers/unmanaged-id" "$FAKE_STATE/running/unmanaged-id"
  touch "$FAKE_STATE/clusters/service-abcdef" "$FAKE_STATE/containers/service-abcdef-id" "$FAKE_STATE/running/service-abcdef-id"
  list="$($KINDCTL list --all)"
  assert_contains "$list" $'unmanaged\tunmanaged'
  assert_contains "$list" $'service-abcdef\tunknown'
}

test_operate_nuke_and_prune_never_delete_unmanaged() {
  setup_fake_env; repo="$TEST_TMP/repo"; mkdir -p "$repo"; cd "$repo"
  "$KINDCTL" create --tag keep >/dev/null
  owned="$(find "$FAKE_STATE/clusters" -type f -maxdepth 1 -print | sed 's|.*/||')"
  touch "$FAKE_STATE/clusters/unmanaged" "$FAKE_STATE/containers/unmanaged-id" "$FAKE_STATE/running/unmanaged-id"
  printf 'no\n' | "$KINDCTL" nuke >/dev/null 2>&1
  assert_file_exists "$FAKE_STATE/clusters/$owned"
  "$KINDCTL" nuke --yes >/dev/null
  assert_not_exists "$FAKE_STATE/clusters/$owned"
  assert_file_exists "$FAKE_STATE/clusters/unmanaged"

  "$KINDCTL" create --tag dead >/dev/null
  dead_name="$(find "$FAKE_STATE/clusters" -type f -maxdepth 1 -print | sed 's|.*/||' | grep -- '-dead$')"
  dead_kube="$HOME/.kube/kind/$dead_name.kubeconfig"
  rm -f "$FAKE_STATE/clusters/$dead_name" "$FAKE_STATE/containers/$dead_name-id" "$FAKE_STATE/running/$dead_name-id"
  "$KINDCTL" prune --dead --yes >/dev/null
  assert_eq "$(json_has_cluster "$HOME/.kube/kind/registry.json" "$dead_name")" no
  assert_not_exists "$dead_kube"
  assert_file_exists "$FAKE_STATE/clusters/unmanaged"
}

test_doctor_regenerates_kubeconfig_and_does_not_adopt_arbitrary() {
  setup_fake_env; source_kindctl
  repo="$TEST_TMP/repo"; mkdir -p "$repo"; cd "$repo"; kindctl_derive ""
  # Owned live cluster with missing kubeconfig.
  mkdir -p "$FAKE_STATE/clusters" "$FAKE_STATE/containers" "$FAKE_STATE/running"
  touch "$FAKE_STATE/clusters/$KINDCTL_NAME" "$FAKE_STATE/containers/$KINDCTL_NAME-id" "$FAKE_STATE/running/$KINDCTL_NAME-id"
  kindctl_registry_upsert "$KINDCTL_NAME" "$KINDCTL_ROOT" "$KINDCTL_KUBECONFIG" "$KINDCTL_CONTEXT" "$KINDCTL_TAG" ready true
  rm -f "$KINDCTL_KUBECONFIG"
  # Arbitrary unmanaged live cluster.
  touch "$FAKE_STATE/clusters/other" "$FAKE_STATE/containers/other-id" "$FAKE_STATE/running/other-id"
  out="$($KINDCTL doctor)"
  assert_file_exists "$KINDCTL_KUBECONFIG"
  assert_contains "$out" "re-export kubeconfig: $KINDCTL_NAME"
  assert_contains "$out" "unmanaged: other"
  assert_eq "$(json_has_cluster "$HOME/.kube/kind/registry.json" other)" no
  assert_mode "$HOME/.kube/kind" 700
  assert_mode "$HOME/.kube/kind/registry.json" 600
}

test_doctor_reregisters_current_exact_and_reports_name_drift() {
  setup_fake_env; source_kindctl
  repo="$TEST_TMP/repo"; mkdir -p "$repo"; cd "$repo"; kindctl_derive ""
  mkdir -p "$FAKE_STATE/clusters" "$FAKE_STATE/containers" "$FAKE_STATE/running"
  touch "$FAKE_STATE/clusters/$KINDCTL_NAME" "$FAKE_STATE/containers/$KINDCTL_NAME-id" "$FAKE_STATE/running/$KINDCTL_NAME-id"
  out="$($KINDCTL doctor)"
  assert_contains "$out" "re-register current workspace: $KINDCTL_NAME"
  kindctl_registry_is_owned "$KINDCTL_NAME"

  kindctl_registry_upsert wrong-name "$repo" "$HOME/.kube/kind/wrong.kubeconfig" kind-wrong-name "" ready true
  out="$($KINDCTL doctor)"
  assert_contains "$out" "name-drift: wrong-name"
}

test_doctor_missing_tool_preflight_is_clear() {
  TEST_TMP="$(new_tmp)"; mkdir -p "$TEST_TMP/bin"
  ln -s "$(command -v python3)" "$TEST_TMP/bin/python3"
  if PATH="$TEST_TMP/bin" HOME="$TEST_TMP/home" /bin/bash "$KINDCTL" doctor >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    fail_msg "doctor should fail when tools are missing"
  fi
  err="$(cat "$TEST_TMP/err")"
  assert_contains "$err" "missing: kind"
  assert_contains "$err" "missing: docker"
  assert_contains "$err" "missing: kubectl"
  assert_contains "$err" "doctor preflight failed"
}

test_skill_templates_exist_and_are_valid() {
  [ -f "$ROOT/SKILL.md" ] || fail_msg "missing SKILL.md"
  [ -f "$ROOT/templates/cluster.yaml" ] || fail_msg "missing template cluster.yaml"
  [ -x "$ROOT/templates/setup.sh" ] || fail_msg "setup template not executable"
  assert_contains "$(cat "$ROOT/SKILL.md")" "kindctl kubectl"
  assert_contains "$(cat "$ROOT/SKILL.md")" "local k8s"
  assert_contains "$(cat "$ROOT/templates/setup.sh")" "set -euo pipefail"
  python3 - "$ROOT/templates/cluster.yaml" <<'PY'
import sys
text=open(sys.argv[1]).read()
assert 'kind: Cluster' in text
assert 'apiVersion: kind.x-k8s.io/v1alpha4' in text
PY
}

run_one() {
  local name="$1"
  if [ -n "$TEST_PATTERN" ] && [[ "$name" != *"$TEST_PATTERN"* ]]; then
    return 0
  fi
  printf 'test %s ... ' "$name"
  if ( "$name" ); then
    printf 'ok\n'
    pass=$((pass + 1))
  else
    printf 'not ok\n'
    fail=$((fail + 1))
  fi
}

for name in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  run_one "$name"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
