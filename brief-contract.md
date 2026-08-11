# Example brief (what Stan generates and hands to the worker on every delegation)

objective:
  Migrate the api/ package from Node to Bun as the runtime

inputs:
  - api/package.json
  - api/bun.lockb

constraints:
  - Keep the existing scripts (start, test, build) under the same names, only change the runner underneath
  - Don't touch the code in api/src
  - Remove package-lock.json and node_modules/ from version control

success_criteria:
  - cd api && bun install
  - cd api && bun run test
  - '! grep -q "\"packageManager\": \"npm" api/package.json'

Note: each line of `success_criteria` is a literal shell command, not a
description. The worker runs it as-is; success = exit code 0. To check
for an absence (here, that `package.json` no longer declares npm as its
packageManager), the command is already negated — it's not described in
prose.

---

## What the worker replies with (never the full artifact)

Happy path:

```
RESULT:
  status: success
  summary: api/ migrated to Bun; package.json updated (packageManager: bun@1.x), bun.lockb generated, package-lock.json removed.
  verification: "bun install -> exit 0 (128 lockfile entries); bun run test -> 24 pass, 0 fail (exit 0); grep packageManager npm -> exit 1 (no match)"
```

The check genuinely fails (and the worker says so, doesn't hide it):

```
RESULT:
  status: failed
  summary: bun install and build are fine, but 3 tests fail because of an fs mock that relies on a Node-specific API.
  verification: "bun run test -> 21 pass, 3 fail (exit 1): fs-mock.test.ts, stream.test.ts, worker.test.ts"
```

Ambiguous case (the worker doesn't work blind):

```
RESULT:
  status: blocked
  summary: package.json has a postinstall script that runs node-gyp for a native binding — should I find the Bun equivalent, or leave it with Node as a fallback?
  verification: n/a
```

Stan decides based on this block, not the full artifact: if `success`,
it closes the subtask; if `failed`, it decides whether to retry the
brief with more context or escalate it; if `blocked`, it answers the
question and resends the brief. It only opens the full file if
something doesn't add up, or during the final review of the larger
task.
