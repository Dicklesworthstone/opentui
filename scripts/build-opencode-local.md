# build-opencode-local.sh

This script builds local OpenTUI, links it into an OpenCode checkout, and
optionally builds an OpenCode release binary.

You can also use it to benchmark startup.

## Usage examples

### 1) Build + link + run OpenCode in dev mode

```bash
./scripts/build-opencode-local.sh --run
```

### 2) Build + link + build OpenCode release binary

```bash
./scripts/build-opencode-local.sh --release
```

### 3) Benchmark OpenCode startup with local OpenTUI

Use separate worktrees and point `--opentui` to each:

```bash
./scripts/build-opencode-local.sh \
  --opentui ~/path/to/wt/0-1-77 \
  --opencode ~/src/opencode \
  --release --bench --bench-mode tui-ready --bench-runs 5
```

Then compare the results with the same command but pointing to a different OpenTUI worktree:

```bash
./scripts/build-opencode-local.sh \
  --opentui ~/path/to/wt/0-1-78 \
  --opencode ~/src/opencode \
  --release --bench --bench-mode tui-ready --bench-runs 5
```

## Restore npm-installed OpenTUI in OpenCode

```bash
bun install --cwd /path/to/opencode
```
