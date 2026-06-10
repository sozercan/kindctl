# kindctl — Plan & Design

A skill + bundled bash wrapper for **creating and operating multiple `kind` clusters across many repos and worktrees, without any of them ever overriding the active kubecontext or polluting `~/.kube/config`.**

Status: design updated with phase gates, ready to implement.
Verified against: `kind v0.32.0` (go1.26.3, darwin/arm64), docker 29.5.2.

---

## 1. The problem

`kind create cluster --name foo` does three things at once:

1. Starts Docker containers (`foo-control-plane`, `foo-worker`, …).
2. **Writes** the cluster/user/context into `~/.kube/config`.
3. **Flips `current-context`** to `kind-foo`.

With N repos each doing this, the global kubeconfig becomes a shared mutable global:

- `current-context` = "whoever ran `kind create`/`kubectl config use-context` last." Open an old terminal for repo A and `kubectl` silently targets repo B's cluster.
- Contexts **accumulate and go stale**. Deleting a cluster doesn't always reap its context, and a Docker/machine restart leaves contexts pointing at clusters that no longer exist.

### This is not hypothetical — evidence from this machine

```
$ kubectl config get-contexts -o name | grep '^kind-'
kind-guac
kind-kubeairunway-gw-validate
kind-orka
kind-orka-agent-substrate-e2e
kind-orka-substrate

$ kind get clusters
orka-agent-substrate-e2e
```

**Five `kind-*` contexts in the global config; exactly one cluster actually exists.** The other four are orphaned, stomping each other's "active" status and cluttering every `kubectl` tab-completion. That is the exact failure mode kindctl eliminates.

---

## 2. Locked decisions

These were resolved during design and are **not open**:

| Decision | Choice | Rationale |
|---|---|---|
| Primary operator | **Agents (Claude Code)**, humans secondary | Drives the stateless design below |
| Global `~/.kube/config` | **Never written, never read for state** | The entire point |
| Kubeconfig store | **Central `~/.kube/kind/`**, directory `0700`, files `0600` | Keeps client certs out of working trees; survives worktree churn |
| Workspace key | **Per-worktree path hash** | Two worktrees of one repo get distinct clusters automatically |
| Cluster identity | **Derived name + optional sanitized `--tag`; no arbitrary `--name` override in v1** | Keeps every per-workspace operation stateless and repeatable |
| Scoping backbone | **Stateless wrapper** passing `--kubeconfig` every call | Correct under Claude Code's per-call env reset (see §4) |
| Escape hatch for raw tools | **Passthrough subcommand** (`kindctl exec`/`kindctl kubectl`) | Scopes `KUBECONFIG` for a single child process |
| Registry role | **Ownership ledger + reconcilable status cache** | Bulk destructive ops must only touch proven kindctl-managed clusters |
| Implementation language | **Bash wrapper**, with tiny `python3` snippets for JSON registry edits | Readable glue around kind/docker/kubectl; safe JSON without requiring `jq`; no build step |

---

## 3. Verified `kind` behavior (v0.32.0)

The whole design rests on these, all confirmed from the installed binary:

```
create cluster   --kubeconfig string   sets kubeconfig path instead of $KUBECONFIG or $HOME/.kube/config
                 --name string         cluster name, overrides KIND_CLUSTER_NAME, config (default "kind")
                 --config string       path to a kind config file
                 --image string        node docker image to use for booting the cluster
delete cluster   --kubeconfig string   (same isolation)
                 --name string
export kubeconfig --kubeconfig string  sets kubeconfig path instead of $KUBECONFIG or $HOME/.kube/config
                 --internal            use internal address instead of external
                 --name string         the cluster context name (default "kind")
load docker-image --name string
```

Critical guarantees this gives us:

- **`--kubeconfig <file>` fully isolates the write.** Docs: *"When specified, only that file is loaded. The flag may only be set once and no merging takes place."* → the global config is never touched.
- **API server port is random by default** (`networking.apiServerPort` unset) → multiple live clusters never collide on the API port.
- **Cluster name limit = 50 chars** (`clusterNameMax` in kind source; it's a warning, not a hard error, because kind appends `-control-plane` (14) and hostnames cap at 64). We stay safely under it.
- **`--name` overrides the config file's `name:`** → kindctl always passes a derived `--name`, so our naming wins regardless of what a repo's `cluster.yaml` says.
- **`kind export kubeconfig`** can regenerate any cluster's kubeconfig on demand → a kubeconfig file is a disposable *projection*, never precious. `--internal` gives the container-network address for use from inside other containers (e.g. CI, dind).

**Implication: `kind` is the live source of truth; kubeconfig files are disposable projections; the registry records kindctl ownership and cached reverse-mapping metadata.**

---

## 4. Why stateless wrapper is the *only* correct backbone (not just preferred)

Claude Code's Bash tool **resets shell state between calls** but **re-sources the profile**. So `export KUBECONFIG=…` set in tool-call N is gone by tool-call N+1. A process can only learn its scoped config two ways:

1. the `--kubeconfig` flag, or
2. a `KUBECONFIG` env var set **in that same invocation**.

Persistent shell state is off the table. Therefore:

- **Stateless wrapper** (resolve path internally, pass `--kubeconfig` every call) → correct by construction. ✅
- direnv on `cd` → hooks the *interactive* prompt; the non-interactive Bash tool often won't fire it, and it writes `.envrc` into every worktree. Human-only nicety. (Also: `direnv` is **not installed** on this machine.)
- Subshell launcher (kubie-style) → the subshell dies when the command returns; can't keep an agent "inside" it across tool calls. Human-only.
- Manual `eval $(... env)` → must be re-run every tool call or raw calls silently hit global. The agent will forget.

The wrapper's one hole — **anything not run through it** (raw `kubectl`, `helm`, `k9s`, Tilt/Skaffold) — is closed by the **passthrough subcommand**, which sets `KUBECONFIG` for that one child process.

---

## 5. The derivation (the heart of the design)

Deterministic, recomputable from any shell or agent tool-call with **zero stored state**:

```sh
# 1. Workspace root — unique per git worktree.
#    Non-git fallback walks upward for an existing .kind/ marker, then uses pwd -P.
workspace_root="$(git rev-parse --show-toplevel 2>/dev/null || find_kind_marker_or_pwd)"

# 2. Short stable hash of the absolute root path
hash6="$(printf '%s' "$workspace_root" | shasum -a 256 | cut -c1-6)"

# 3. Optional cluster tag — sanitized, capped, and hash-suffixed if long
raw_tag="${KINDCTL_TAG:-}"              # populated by --tag T; empty by default
tag=""
if [ -n "$raw_tag" ]; then
  tag="$(printf '%s' "$raw_tag" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
  [ -n "$tag" ] || die "--tag must contain at least one [a-z0-9] character after sanitization"
  if [ "${#tag}" -gt 16 ]; then
    tag_hash="$(printf '%s' "$tag" | shasum -a 256 | cut -c1-4)"
    tag="$(printf '%s' "$tag" | cut -c1-11)-$tag_hash"   # 16 chars total
  fi
fi

# 4. Human-readable base, capped to leave room for hash + optional tag
suffix="-${hash6}"
[ -n "$tag" ] && suffix="${suffix}-${tag}"
base_cap=$((50 - ${#suffix}))
[ "$base_cap" -gt 40 ] && base_cap=40

base="$(basename "$workspace_root" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//' \
        | cut -c1-"$base_cap")"
[ -n "$base" ] || base="repo"

# 5. Derived identifiers
name="${base}${suffix}"                         # e.g. myrepo-2440c3 or myrepo-2440c3-db
context="kind-${name}"                          # what Tilt/Skaffold/k9s must pin
kubeconfig="$HOME/.kube/kind/${name}.kubeconfig" # 0600
```

**Length math:**

- Default: 40-char base + `-` + 6-char hash = **47 ≤ 50**.
- With tag: tag slug is **≤16**; base is dynamically re-capped so `base + -hash6 + -tag` is **≤50**.
- Control-plane container = `name` + `-control-plane`, so max is 50 + 14 = **64**, the hostname limit.

**Why hash the path, not the repo name:**

- Two **worktrees** of one repo → different `--show-toplevel` → different hash → different clusters. No manual disambiguation.
- Two **unrelated repos** that happen to share a basename (`api`, `app`) → different paths → different hash → no collision.
- Running `kindctl` from **any subdirectory** of a git repo → `--show-toplevel` returns the repo root → **same** cluster. (Desired: the cluster belongs to the repo, not your cwd.)

**Forward vs reverse mapping — the robustness payoff:**

- *Forward* ("I'm in this repo → what's my cluster?") is **pure derivation** — it never needs the registry for the current workspace's name/path/context.
- *Reverse* ("given all clusters, which repo owns each?") needs the registry because the name embeds a one-way hash.
- Destructive operations use the derived target, but ownership-sensitive deletes (`delete`, `prune`, `nuke`) require a registry-owned entry. If the registry is lost, `doctor` can re-register the current workspace's exact derived live cluster; arbitrary existing clusters remain unknown/unmanaged.

**Non-git fallback caveat:** outside a git repo, kindctl walks upward looking for an existing `.kind/` marker dir and uses that as the root if found; otherwise it uses `pwd -P`, so subdirectories can derive different clusters. Documented limitation.

**Optional cluster tag (multiple clusters per repo):** `--tag db` → `name="${base}-${hash6}-db"`. Default tag is empty (the repo's primary cluster). Every command that targets one cluster accepts the same `--tag`; there is no arbitrary `--name` override in v1.

---

## 6. File layout

```
~/.kube/
  config                          # GLOBAL — kindctl NEVER touches this
  kind/                           # 0700
    <name>.kubeconfig             # one isolated file per cluster, 0600
    registry.json                 # ownership ledger + status cache, 0600
    .lock/                        # mkdir-based lock while updating registry

<repo>/.kind/                     # optional, per-repo, committed to the repo
  cluster.yaml                    # native kind config (k8s version, nodes, extraPortMappings)
  setup.sh                        # optional post-create hook
```

### Registry schema (`~/.kube/kind/registry.json`)

```json
{
  "version": 1,
  "clusters": {
    "myrepo-2440c3": {
      "root": "/Users/sozercan/projects/myrepo",
      "kubeconfig": "/Users/sozercan/.kube/kind/myrepo-2440c3.kubeconfig",
      "context": "kind-myrepo-2440c3",
      "tag": "",
      "git": true,
      "managed": true,
      "setup_status": "ready",
      "created": "2026-06-10T22:00:00Z",
      "updated": "2026-06-10T22:03:00Z"
    }
  }
}
```

The registry is an **ownership ledger plus cache**:

- `kind` remains the live source of truth for whether containers/clusters exist.
- kubeconfig files remain disposable projections and can be regenerated with `kind export kubeconfig`.
- registry entries prove kindctl ownership for cluster-targeting operations; destructive/bulk operations never act without that proof.
- `setup_status` is one of `pending`, `ready`, or `failed`; absence is treated as legacy/unknown.
- if the registry is deleted, `doctor` can rebuild live status from `kind get clusters` + Docker, but cannot reconstruct every repo `root` or prove ownership of arbitrary clusters. Such clusters are marked `unknown`/`unmanaged` until `doctor` is run from the exact matching workspace.

### Registry update rules

- Run with `umask 077`.
- Create `~/.kube/kind` as `0700`.
- Create `registry.json` and kubeconfigs as `0600`; `doctor` re-asserts modes.
- Protect every registry read-modify-write with a portable `mkdir "$store/.lock"` lock and a cleanup trap.
- Write JSON through a temp file in the same directory, `chmod 600`, then atomic `mv` over `registry.json`.
- Use embedded `python3` for JSON parsing/updating; do not hand-edit JSON with `sed`.

---

## 7. Command surface

| Command | Behavior |
|---|---|
| `kindctl create [--config F] [--tag T] [--k8s-version vX.Y.Z]` | Derive name → `kind create cluster --name <name> --kubeconfig <scoped> [--config .kind/cluster.yaml] [--image kindest/node:vX.Y.Z]` → immediately register ownership with `setup_status=pending` → run `.kind/setup.sh` if present → mark `setup_status=ready`. If setup fails, mark `setup_status=failed`, keep the cluster, and exit non-zero with remediation. Errors if the cluster already exists. |
| `kindctl delete [--tag T]` | Derive name → require registry ownership for that exact name → guardrail-check context → `kind delete cluster --name <name> --kubeconfig <scoped>` → deregister → `rm` the kubeconfig file. If the registry was lost, run `kindctl doctor` from the workspace first to re-register the exact derived live cluster. |
| `kindctl exec [--tag T] -- <cmd…>` | **Escape hatch.** Requires a registry-owned cluster and kubeconfig to exist. Runs `KUBECONFIG=<scoped> exec "$@"` — scopes one child process only. |
| `kindctl kubectl [--tag T] <args…>` | Sugar for `kindctl exec -- kubectl <args…>`. Requires a registry-owned cluster and kubeconfig to exist. |
| `kindctl path [--tag T]` | Strict: requires a registry-owned cluster and kubeconfig to exist, then prints the scoped kubeconfig path. |
| `kindctl ctx [--tag T]` | Strict: requires a registry-owned cluster and kubeconfig to exist, then prints `--kubeconfig <path>` to splice into any raw command. |
| `kindctl env [--tag T]` | Strict: requires a registry-owned cluster and kubeconfig to exist, then prints `export KUBECONFIG=<path>` for humans to `eval`. Optional human sugar. |
| `kindctl list [--workspace \| --all]` | Reconciles registry with `kind get clusters` + Docker run-state. Flags running/stopped/dead-root/dead-cluster/unknown/unmanaged. |
| `kindctl load <image> [--tag T]` | Requires a registry-owned cluster to exist, then runs `kind load docker-image <image> --name <name>`. |
| `kindctl hibernate [--tag T]` / `kindctl resume [--tag T]` | Requires registry ownership, then `docker stop`/`start` containers selected by kind's cluster label (`io.x-k8s.kind.cluster=<name>`) rather than by name glob. Parks idle clusters without deleting them. |
| `kindctl doctor` | Preflight (kind/docker/kubectl/python3 present, daemon up) · reconcile registry · re-export lost kubeconfigs (`kind export kubeconfig`) · opportunistically re-register the current workspace's derived cluster if it exists · find orphans/unknowns · detect hash collisions · fix `0700`/`0600` perms. |
| `kindctl prune --workspace` | Delete the current workspace's cluster(s), after printing the target list and requiring confirmation unless `--yes`. |
| `kindctl prune --dead` | Remove registry entries + kubeconfig files for clusters that no longer exist. Does not touch live unknown/unmanaged clusters. |
| `kindctl nuke` | Delete **all registry-owned kindctl-managed** clusters, with confirmation. Never touches unknown/unmanaged kind clusters. |

### Post-create hook contract (`.kind/setup.sh`)

Run after a successful `kind create` and after the registry already contains an ownership entry. If present and executable, it receives:

```
KUBECONFIG=<scoped path>          # so kubectl/helm in the hook hit the right cluster, zero global config
KINDCTL_CLUSTER=<name>
KINDCTL_CONTEXT=kind-<name>
KINDCTL_ROOT=<workspace_root>
```

Typical contents: install an ingress controller, `kind load` images, `kubectl apply` base manifests.

If the hook fails, kindctl:

1. marks the registry entry `setup_status=failed`,
2. exits non-zero,
3. prints the scoped remediation commands (`kindctl delete`, rerun setup through `kindctl exec`, etc.), and
4. does **not** silently delete the cluster unless a future explicit `--rollback-on-setup-failure` flag is added.

---

## 8. Safety / guardrails (matters most for agent use)

- **No arbitrary `--name` override in v1.** A caller cannot point kindctl at `sertac-aks` or any non-derived cluster by spelling a name.
- **`kind-` context guard.** Every destructive op refuses any target context not prefixed `kind-`.
- **Registry-scoped bulk ops.** `nuke` and broad `prune` only touch registry-owned kindctl-managed clusters. They will not reap pre-existing kind clusters they do not own (e.g. the existing `orka-agent-substrate-e2e`).
- **Explicit creation only.** `exec`/`path`/`ctx`/`env`/`kubectl` on a missing or non-registry-owned cluster **error** with `run: kindctl create` or `run: kindctl doctor`; they never silently spin up or adopt a cluster.
- **Confirmation on bulk ops.** `nuke` and `prune` print the target list and require confirmation (or `--yes` for non-interactive agent runs).
- **Concurrent-safe registry writes.** Registry updates use a lock, temp-file write, `chmod 600`, and atomic `mv`.
- **`0700`/`0600` permissions.** Store dir is `0700`; kubeconfig files and registry are `0600`; `doctor` re-asserts.
- **Global config untouched, always.** No code path reads or writes `~/.kube/config`. Tests snapshot it before/after the suite and assert byte-identical.

---

## 9. Ports & ingress

- **API server:** left to kind's default random port → never collides across clusters. No action needed.
- **Ingress (80/443):** the real constraint. Only one cluster can bind host `:80`/`:443` at a time.
- **v1 behavior:** kindctl does **not** mutate `.kind/cluster.yaml` and does not invent dynamic port mappings. Per-repo config stays native kind YAML; kindctl only injects `--name`.
- Options for ingress:
  1. One ingress-enabled cluster live at a time (simplest; `hibernate` the others).
  2. Manually choose distinct `extraPortMappings.hostPort` values per repo/worktree in `.kind/cluster.yaml`.
- `kindctl doctor` reports host-port bindings of running kind containers to surface conflicts.
- Future: generated temp config overlays or template rendering for hash-derived ingress host ports. This is explicitly out of v1 to preserve the "native kind config only" rule.

---

## 10. Per-repo config (`.kind/cluster.yaml`)

Native kind config — **no bespoke format**. kindctl does not edit this file; it only passes the derived `--name`. Example:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
# name: omitted on purpose — kindctl always overrides via derived --name
nodes:
  - role: control-plane
    image: kindest/node:v1.30.0
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080          # manually choose distinct host ports if clusters run concurrently
        protocol: TCP
  - role: worker
```

`--k8s-version vX.Y.Z` maps to `--image kindest/node:vX.Y.Z`. Exact-digest pinning (`@sha256:…`) goes in `cluster.yaml` for reproducibility.

---

## 11. Edge cases & handling

| Case | Handling |
|---|---|
| Two worktrees of one repo | Distinct path → distinct hash → distinct clusters. Automatic. |
| Duplicate repo basenames (`api`, `api`) | Distinct path → distinct hash. No collision. |
| Run from a subdirectory (git) | `--show-toplevel` normalizes to repo root → same cluster. |
| Run from a subdirectory (non-git) | Walk upward for `.kind/`; if none, cwd-derived and documented as potentially different. |
| Repo directory deleted, cluster remains | Orphan/dead-root. `doctor`/`list` flag "registry root no longer exists." |
| Docker/machine restart stops clusters | `kindctl resume` starts containers selected by kind's `io.x-k8s.kind.cluster=<name>` label. `list` shows stopped state. |
| Lost/corrupted kubeconfig file | `doctor` re-runs `kind export kubeconfig --kubeconfig <scoped>`. |
| Registry deleted | Current-workspace derivation still knows the target name/path, but destructive ownership is lost. `list --all` marks existing clusters `unknown`/`unmanaged`; `delete`/`nuke` will not touch them until `doctor` re-registers the current workspace's exact derived live cluster. |
| Name > 50 chars | Base is dynamically capped; tag slug is capped/hash-suffixed; total name length is ≤50. Cannot exceed unless kind's own limits change. |
| Hash collision (different roots → same name) | Vanishingly unlikely (24-bit over dozens of entries); `doctor` detects registry roots mapping to one name and warns. Use `--tag` as a manual disambiguator if ever hit. |
| Cluster name already exists on host | `create` surfaces kind's "already exists" error; suggests `kindctl doctor` if this is a registry-loss recovery case, `delete` if it is yours, or `--tag` for another cluster. |
| `.kind/setup.sh` fails | Registry already owns the cluster; entry is marked `setup_status=failed`; command exits non-zero with remediation. |
| `kind`/`docker`/`kubectl`/`python3` absent or daemon down | `doctor` and commands preflight with a clear remediation message. |
| Tilt/Skaffold/k9s bypass the wrapper | They must pin context `kind-<name>` or kubeconfig from `kindctl ctx`/`path`; recipe in SKILL.md. |
| Pre-existing unmanaged kind clusters | Ignored by `nuke`/`prune`; visible in `list --all` marked `unmanaged`. |
| Concurrent agents update registry | Lock + atomic write prevents lost updates/corruption. |

---

## 12. Skill packaging

This repo (`~/projects/kindctl`) is the source of truth; it gets symlinked into `~/.claude/skills/` (matching the existing skill convention, where skills are symlinks).

```
~/projects/kindctl/
├── PLAN.md                 # this document
├── SKILL.md                # frontmatter triggers + mental model + command reference + recipes
├── Makefile                # test/lint/integration entrypoints
├── bin/
│   └── kindctl             # the bash wrapper (single file)
├── templates/
│   ├── cluster.yaml        # starter per-repo kind config
│   └── setup.sh            # starter post-create hook
└── test/
    ├── kindctl.bats        # unit tests for pure functions, strictness, registry helpers
    ├── integration.bats    # opt-in kind/docker integration smoke tests
    └── fixtures/           # throwaway repos, fake kind/docker/kubectl fixtures

~/.claude/skills/kindctl -> ~/projects/kindctl     # symlink (install step)
```

**SKILL.md** teaches:

1. The mental model: kind is global to the Docker daemon; the global kubeconfig is never touched; one isolated file per cluster.
2. The golden rule for agents: **never run bare `kubectl`/`helm` against a kind cluster — route through `kindctl kubectl` / `kindctl exec`.**
3. Command reference (from §7), including strict missing-cluster behavior and `--tag` usage.
4. Recipes: create-with-ingress, load-local-image, the Tilt/Skaffold "pin context to `kind-<name>`" recipe, hibernate-to-free-RAM, doctor-after-reboot, recovering from a failed setup hook.
5. Trigger phrases (frontmatter): "kind cluster", "spin up a cluster", "local k8s", multi-repo / multi-worktree cluster work.

**Invocation:** the skill calls `bin/kindctl` by absolute path. Optional human convenience: symlink `bin/kindctl` → `~/.local/bin/kindctl` so it's callable bare in any terminal.

---

## 13. Defaults chosen (vetoable, but decided)

- Bash single-file wrapper, with embedded `python3` only for JSON registry reads/writes.
- Explicit `create` (never auto-spawn).
- No arbitrary `--name` override in v1; use sanitized/capped `--tag` for multiple clusters per repo.
- Per-repo config = native kind `cluster.yaml` + optional `setup.sh`; kindctl does not mutate repo config.
- Central store `~/.kube/kind/`: directory `0700`, files `0600`, `umask 077`.
- Registry is an ownership ledger plus cache; bulk destructive ops are registry-scoped.
- Ingress is one-cluster-at-a-time by default; manual distinct host ports if concurrent ingress is needed.
- `hibernate`/`resume` included in v1, selecting containers by kind's `io.x-k8s.kind.cluster=<name>` label rather than name glob.

---

## 14. Out of scope (v1) / future

- Auto-switching for humans via direnv (not installed here; can add an opt-in `.envrc` one-liner `export KUBECONFIG="$(kindctl path)"` later).
- Arbitrary `--name` override or an explicit adoption workflow for arbitrary unmanaged clusters.
- Generated temp config overlays / templates for hash-derived ingress host ports.
- Non-kind providers (k3d, minikube).
- Cross-machine sync of clusters (clusters are inherently local to the Docker daemon).
- A TUI/`list --watch`.
- Importing `sigs.k8s.io/kind` as a Go library to drop the kind binary dependency (explicitly rejected: 5× the code, couples to kind internals, still shells to docker).

---

## 15. Implementation plan (phased, with actionable exit criteria)

Each phase must leave the repo in a shippable state: docs match behavior, `bin/kindctl` is executable, and the relevant tests pass. A phase is **not done** because code exists; it is done only when its exit criteria are satisfied.

### Common test conventions

- `make test` runs fast tests only: pure Bash function tests, mocked `kind`/`docker`/`kubectl`, registry JSON tests, and global-config untouched assertions. It must not create real Docker containers.
- `make test-integration` runs opt-in real kind/docker tests. It creates disposable clusters with `--tag ci` under a temporary `HOME`, then deletes them. It may be skipped during inner-loop development, but it is required before declaring v1 complete.
- `make lint` runs `bash -n` on `bin/kindctl`; if `shellcheck` is installed, it also runs `shellcheck bin/kindctl`.
- Tests run with a temporary `HOME` unless a test explicitly asserts the real user's `~/.kube/config` is unchanged.
- `bin/kindctl` must be sourceable by Bats for pure function tests: define functions first, put CLI execution behind a `main "$@"` guard.

### Phase 1 — Skeleton + derivation

**Build actions**

- Create executable `bin/kindctl` with `set -euo pipefail`, `umask 077`, help text, command dispatch, and shared error helpers.
- Implement root detection:
  1. git root via `git rev-parse --show-toplevel`,
  2. otherwise nearest upward `.kind/` marker,
  3. otherwise `pwd -P`.
- Implement derivation functions for `root`, `hash6`, sanitized/capped `base`, sanitized/capped `tag`, `name`, `context`, and `kubeconfig`.
- Implement strict `path`, `ctx`, and `env` command stubs that derive the target but fail until the cluster is known/owned.

**Exit criteria**

- `bin/kindctl --help` exits 0 and lists every v1 command.
- `bin/kindctl path` in a repo with no cluster exits non-zero and prints a remediation containing `kindctl create`.
- Unit tests prove:
  - git subdirectories derive the same root/name as the repo root;
  - two git worktrees derive different hashes/names;
  - duplicate basenames at different absolute paths derive different names;
  - non-git `.kind/` marker walk-up uses the marker directory as root;
  - empty/symbol-only tags are rejected;
  - long tags are capped/hash-suffixed;
  - every generated cluster name is ≤50 chars;
  - generated control-plane container names are ≤64 chars.
- Verification commands pass:

```sh
make lint
make test TEST_PATTERN=derivation
```

### Phase 2 — Store + registry

**Build actions**

- Create `~/.kube/kind` as `0700` on demand.
- Initialize `registry.json` as `0600` with schema version `1`.
- Implement registry read/write helpers using embedded `python3`, never `sed` JSON edits.
- Implement portable locking with `mkdir "$store/.lock"`, cleanup traps, timeout/error messaging, temp-file write, `chmod 600`, and atomic `mv`.
- Implement registry ownership checks for exact derived names.

**Exit criteria**

- Fresh commands create the store directory with mode `0700`.
- Registry writes produce valid JSON and preserve unrelated cluster entries.
- Concurrent registry writes do not corrupt JSON or lose entries.
- Lock cleanup happens on normal exit and on command failure.
- Unit tests prove registry ownership checks distinguish `managed: true`, missing entries, and unmanaged/unknown entries.
- Verification commands pass:

```sh
make lint
make test TEST_PATTERN=registry
```

### Phase 3 — Lifecycle: create/delete/setup hook

**Build actions**

- Implement `create` with `--config`, `--tag`, and `--k8s-version`.
- Use `.kind/cluster.yaml` automatically when present unless `--config F` is supplied.
- Run `kind create cluster --name <derived> --kubeconfig <scoped>` and never call kind without `--kubeconfig` for create/delete/export operations.
- Register ownership immediately after successful `kind create` with `setup_status=pending`.
- Run executable `.kind/setup.sh` with scoped `KUBECONFIG`, `KINDCTL_CLUSTER`, `KINDCTL_CONTEXT`, and `KINDCTL_ROOT`.
- Mark `setup_status=ready` on hook success and `setup_status=failed` on hook failure.
- Implement `delete` requiring registry ownership, then deregister and remove the scoped kubeconfig.

**Exit criteria**

- Mock tests prove the exact `kind create cluster` argv includes derived `--name` and scoped `--kubeconfig`.
- Mock tests prove `create` never writes or reads `~/.kube/config`.
- Mock tests prove `.kind/setup.sh` receives the expected environment.
- Hook failure leaves the registry entry present with `setup_status=failed` and exits non-zero.
- `delete` refuses missing/unowned clusters before invoking `kind delete`.
- `delete` removes the registry entry and scoped kubeconfig for owned clusters.
- Verification commands pass:

```sh
make lint
make test TEST_PATTERN=lifecycle
```

### Phase 4 — Passthrough + safety

**Build actions**

- Implement `exec -- <cmd…>` by setting `KUBECONFIG=<scoped>` for exactly one child process.
- Implement `kubectl [--tag T] <args…>` as sugar for `exec -- kubectl <args…>`.
- Enforce missing/non-owned cluster errors for `exec`, `kubectl`, `path`, `ctx`, `env`, `load`, `hibernate`, and `resume`.
- Implement `kind-` context guard for destructive operations.
- Implement confirmation prompts and `--yes` for bulk/destructive operations that target more than one cluster.

**Exit criteria**

- Mock tests prove `exec` passes scoped `KUBECONFIG` to the child and does not export it beyond that process.
- Mock tests prove `kubectl get nodes` invokes `kubectl get nodes` with only scoped `KUBECONFIG`.
- Strict commands fail with actionable remediation when the derived cluster is missing or not registry-owned.
- Destructive commands refuse any computed/loaded context that does not start with `kind-`.
- Bulk commands without `--yes` prompt and do nothing when confirmation is declined.
- Verification commands pass:

```sh
make lint
make test TEST_PATTERN=safety
```

### Phase 5 — Operate: load/hibernate/resume/list

**Build actions**

- Implement `load <image>` as `kind load docker-image <image> --name <derived>` after ownership checks.
- Implement `hibernate` and `resume` using Docker label selection: `io.x-k8s.kind.cluster=<name>`.
- Implement `list --workspace` and `list --all` with registry + live kind/docker reconciliation.
- Surface statuses: `running`, `stopped`, `dead-root`, `dead-cluster`, `setup-failed`, `unknown`, and `unmanaged`.

**Exit criteria**

- Mock tests prove `load` invokes `kind load docker-image` with the derived name.
- Mock tests prove `hibernate`/`resume` select containers by label, not name glob.
- `list --workspace` shows only current-workspace owned clusters.
- `list --all` shows owned clusters and marks non-owned live kind clusters as `unmanaged`/`unknown` without modifying them.
- Dead roots and dead clusters are displayed distinctly.
- Verification commands pass:

```sh
make lint
make test TEST_PATTERN=operate
```

### Phase 6 — doctor

**Build actions**

- Implement preflight checks for `kind`, `docker`, `kubectl`, `python3`, and Docker daemon availability.
- Reconcile registry entries with `kind get clusters` and Docker state.
- Re-export missing/corrupt kubeconfigs for registry-owned live clusters using `kind export kubeconfig --name <name> --kubeconfig <scoped>`.
- Re-register only the current workspace's exact derived live cluster when registry ownership was lost.
- Detect dead roots, dead clusters, unknown/unmanaged live clusters, hash/name collisions, setup failures, and permission drift.
- Report running kind host-port bindings to help diagnose ingress conflicts.

**Exit criteria**

- Mock tests prove missing tools produce clear remediation and non-zero exit.
- Mock tests prove missing owned kubeconfigs are regenerated with scoped `--kubeconfig`.
- Mock tests prove `doctor` does not adopt arbitrary unmanaged clusters.
- Mock tests prove current-workspace re-registration only happens when the live cluster name exactly equals the derived name.
- Permission drift is fixed back to store `0700` and files `0600`.
- Verification commands pass:

```sh
make lint
make test TEST_PATTERN=doctor
```

### Phase 7 — Skill + templates + install path

**Build actions**

- Create `SKILL.md` with frontmatter triggers and clear operator rules.
- Document the golden rule: never run bare `kubectl`/`helm` against kind clusters; use `kindctl kubectl` or `kindctl exec`.
- Add `templates/cluster.yaml` and `templates/setup.sh` starters.
- Add install instructions for symlinking the skill into `~/.claude/skills/kindctl` and optionally symlinking `bin/kindctl` into `~/.local/bin/kindctl`.
- Ensure SKILL.md invokes `bin/kindctl` by absolute path or a resolved skill-relative path, not by assuming shell aliases.

**Exit criteria**

- `SKILL.md` includes trigger phrases for kind/local-k8s/multi-worktree cluster work.
- `SKILL.md` includes create, use, load image, hibernate/resume, doctor-after-reboot, ingress, failed-setup recovery, and delete recipes.
- Templates are valid/executable as appropriate: `cluster.yaml` parses as kind YAML; `setup.sh` is executable and starts with `set -euo pipefail`.
- Verification commands pass:

```sh
make lint
make test TEST_PATTERN=skill
```

### Phase 8 — End-to-end integration and release gate

**Build actions**

- Add real kind/docker integration tests behind `make test-integration`.
- Add a final smoke script or documented command sequence for manual verification.
- Run all tests from a clean checkout.

**Exit criteria**

- Fast test suite passes:

```sh
make lint
make test
```

- Integration suite passes on a machine with kind/docker/kubectl/python3:

```sh
make test-integration
```

- Manual smoke passes from a throwaway repo:

```sh
tmprepo="$(mktemp -d)"
cd "$tmprepo"
git init
kindctl create --tag smoke
kindctl kubectl --tag smoke get nodes
kindctl load --tag smoke busybox:latest || true   # allowed to fail only if image is absent locally
kindctl hibernate --tag smoke
kindctl resume --tag smoke
kindctl doctor
kindctl delete --tag smoke
```

- The user's global kubeconfig is byte-identical before and after tests:

```sh
before="$(mktemp)"
after="$(mktemp)"
cp "$HOME/.kube/config" "$before" 2>/dev/null || :
make test
make test-integration
cp "$HOME/.kube/config" "$after" 2>/dev/null || :
cmp -s "$before" "$after"
```

- After integration cleanup, no test clusters remain:

```sh
kind get clusters | grep -E 'kindctl|smoke|ci' && exit 1 || true
```

---

## 16. V1 release checklist

V1 is complete only when every item below is true:

- [ ] `bin/kindctl` implements all commands in §7.
- [ ] `SKILL.md`, `templates/`, `test/`, and `Makefile` exist as described in §12.
- [ ] `make lint` passes.
- [ ] `make test` passes without Docker side effects.
- [ ] `make test-integration` passes and cleans up after itself.
- [ ] `~/.kube/config` is byte-identical before/after the full suite.
- [ ] Registry/store permissions are proven: store `0700`, registry and kubeconfigs `0600`.
- [ ] Registry concurrency test passes without lost updates.
- [ ] Hook failure test proves `setup_status=failed` and preserved ownership.
- [ ] Strict missing/non-owned cluster tests pass for `exec`, `kubectl`, `path`, `ctx`, `env`, `load`, `hibernate`, and `resume`.
- [ ] `nuke`/`prune` tests prove unmanaged kind clusters are never deleted.
- [ ] `doctor` tests prove lost kubeconfigs are regenerated and arbitrary unmanaged clusters are not adopted.
- [ ] A fresh agent can read `SKILL.md` and correctly choose `kindctl` over raw `kind`/bare `kubectl` for a local kind-cluster task.

---

## 17. The cardinal invariant (one line to remember)

> **No `kindctl` code path — and no tool the skill tells you to run — ever reads or writes `~/.kube/config`. Every cluster lives in its own `~/.kube/kind/<name>.kubeconfig`, addressed by a deterministic worktree-path hash plus optional sanitized tag.**
