#!/usr/bin/env bash
# Stan: an orchestrator + worker(s) on OpenCode
# Usage: ./setup.sh   (run from the root of the project where you want to use Stan)
grep -q "$(printf '\r')" "$0" 2>/dev/null && { t=$(mktemp); tr -d '\r' <"$0" >"$t"; exec bash "$t" "$@"; } # self-heal CRLF
set -euo pipefail

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
info() { printf "  %s\n" "$1"; }

bold "Setup: Stan (orchestrator) + worker on OpenCode"
echo ""

# ── 1. Check that OpenCode is installed ──────────────────────────
if ! command -v opencode >/dev/null 2>&1; then
  read -rp "OpenCode is not installed. Install it now? [Y/n] " yn
  if [[ "${yn:-Y}" =~ ^[Yy]?$ ]]; then
    curl -fsSL https://opencode.ai/install | bash
    export PATH="$HOME/.opencode/bin:$PATH"
  else
    echo "Install it with: curl -fsSL https://opencode.ai/install | bash"
    exit 1
  fi
fi

# ── 2. Where should the agents live? repo or global ──────────────
echo ""
bold "Where do you want to install Stan?"
info "1) This repo only (.opencode/agents/ here)"
info "2) Global (~/.config/opencode/agents/, available in every project)"
read -rp "Option [1]: " scope
scope="${scope:-1}"
case "$scope" in
  1) AGENTS_DIR=".opencode/agents"; SCOPE_LABEL="this repo" ;;
  2) AGENTS_DIR="$HOME/.config/opencode/agents"; SCOPE_LABEL="global (all your projects)" ;;
  *) echo "Invalid option"; exit 1 ;;
esac
info "Installing at: $SCOPE_LABEL"

# ── 3. Pick a model: a filterable list from "opencode models" ────
# Shows a text-filtered list and lets you pick by number, or type a
# provider/model directly if you already know it.
pick_model() {
  local role="$1" chosen=""
  echo "" >&2
  bold "Model for $role" >&2
  while [[ -z "$chosen" ]]; do
    read -rp "  Filter (part of the name, e.g. 'codex', 'claude', 'deepseek'), or Enter to see all: " filter
    local tmp
    tmp="$(mktemp)"
    if [[ -n "$filter" ]]; then
      opencode models 2>/dev/null | grep -i -- "$filter" > "$tmp" || true
    else
      opencode models 2>/dev/null > "$tmp" || true
    fi
    local count
    count=$(wc -l < "$tmp" | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
      echo "  No matches for '$filter'. Try another filter." >&2
      rm -f "$tmp"
      continue
    fi
    if [[ "$count" -gt 40 ]]; then
      echo "  $count matches: too many to list. Narrow down the filter." >&2
      rm -f "$tmp"
      continue
    fi
    nl -ba -w3 -s') ' "$tmp" >&2
    read -rp "  Number, a 'provider/model' directly, or Enter to filter again: " sel
    if [[ -z "$sel" ]]; then
      rm -f "$tmp"; continue
    elif [[ "$sel" =~ ^[0-9]+$ ]]; then
      chosen=$(sed -n "${sel}p" "$tmp")
      if [[ -z "$chosen" ]]; then echo "  Number out of range." >&2; fi
    else
      chosen="$sel"
    fi
    rm -f "$tmp"
  done
  printf '%s' "$chosen"
}

STAN_MODEL=$(pick_model "Stan (planner)")
info "Stan: $STAN_MODEL"
WORKER_MODEL=$(pick_model "worker (executor)")
info "Worker: $WORKER_MODEL"

if [[ "$STAN_MODEL" == "$WORKER_MODEL" ]]; then
  echo "" >&2
  bold "Heads up: Stan and the worker use the same model." >&2
  info "It works, but you lose the point of having a cheaper/faster executor." >&2
fi

# ── 4. Create the agents ──────────────────────────────────────────
mkdir -p "$AGENTS_DIR"

cat > "$AGENTS_DIR/stan.md" <<EOF
---
description: Plans complex tasks, breaks them into briefs, and reviews the workers' results
mode: primary
model: $STAN_MODEL
permission:
  edit: deny
  write: deny
---
You are Stan, the orchestrator. You never do the work yourself: you
delegate it to the @stan-worker subagent.

For every subtask, write a self-contained brief with four fields:
objective, inputs (exact files), constraints (project-wide conventions),
and success_criteria.

success_criteria is NEVER prose ("the tests pass"): it's a list of
literal shell commands the worker can run as-is, each of which must exit
with code 0 if the subtask is correct. If you need to check that
something is ABSENT, write the command already negated (e.g.
'! grep -q "\"packageManager\": \"npm" api/package.json') instead of
describing the absence in words.

Never pass your conversation history to the worker. Only the brief.
The worker replies with a structured RESULT: status, summary, and
verification (the real output of those commands). Decide based on that:
- status: success → you can close the subtask.
- status: blocked → the worker has a question; answer it and resend the brief.
- status: failed → the check genuinely didn't pass; decide whether to
  retry the brief with more context or escalate it. Don't mark it as done.
Only open the full artifacts for the final review, or if something doesn't add up.
EOF

cat > "$AGENTS_DIR/stan-worker.md" <<EOF
---
description: Executes concrete subtasks defined in a brief from Stan. Fast and cheap.
mode: subagent
model: $WORKER_MODEL
# 0.1 instead of 0: keeps creativity to a minimum so the worker sticks to
# the brief and stays reproducible. Some "reasoning" models (o1/o3, the
# gpt-5-codex family, etc.) ignore this field or only accept a fixed 1 —
# if your worker is one of those, this value simply has no effect.
temperature: 0.1
---
You receive a brief with objective, inputs, constraints, and
success_criteria (shell commands, not prose). Do exactly that, nothing
else.

If the brief is ambiguous, don't start working: return a RESULT with
status blocked and your question in summary.

When you're done, actually RUN each success_criteria command yourself —
don't assume the result. Always end with this block, and nothing after
it:

RESULT:
  status: success | failed | blocked
  summary: <one line: what you did, or what your question is>
  verification: <the real output of the success_criteria commands, or
    the relevant excerpt if it's long; "n/a" if status is blocked>
EOF

info "Created $AGENTS_DIR/stan.md and $AGENTS_DIR/stan-worker.md"

# AGENTS.md only makes sense at repo scope (conventions for THAT project)
if [[ "$scope" == "1" ]]; then
  if [[ ! -f AGENTS.md ]]; then
    cat > AGENTS.md <<'EOF'
# Project conventions

<!-- This file is shared context for EVERY call.
     Include only what's stable: stack, style, test commands.
     Nothing task-specific belongs here. -->
EOF
    info "Created AGENTS.md (fill it in with your repo's conventions)"
  fi
else
  echo ""
  info "Global install: AGENTS.md is not created (it's per-repo). Add one"
  info "at the root of each project where you use Stan if you want to give it context."
fi

# ── 5. Done ────────────────────────────────────────────────────────
echo ""
bold "Done. Next steps:"
info "1. opencode          (Tab until you reach the 'stan' agent)"
info "2. Ask for something divisible and watch it write briefs and delegate to @stan-worker"
echo ""
info "Scope:  $SCOPE_LABEL"
info "Stan:   $STAN_MODEL"
info "Worker: $WORKER_MODEL"
