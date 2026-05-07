# Procedure Spec Format

A spec file is the input to the procedure-builder. It describes the procedure to generate. Write one of these, then run `/procedure-builder path/to/spec.md`.

## Required Fields

```markdown
# Procedure: <name>

<One sentence: what this procedure does end to end.>

## Target

- **Directory:** <where to write the procedure, e.g., `.claude/skills/speckit/`>
- **Arguments:** <what the operator passes when invoking, e.g., "issue-number org/repo">

## Stage 01: <name>

**Purpose:** <one sentence>

**Inputs:**
- <what this stage reads: files, API responses, arguments>

**Process:**
1. <step>
2. <step>
3. <step>

**Output:** <artifact name and format>

## Stage 02: <name>

**Purpose:** <one sentence>

**Inputs:**
- Stage 01 output: <artifact name>
- <other inputs>

**Process:**
1. <step>
2. <step>

**Output:** <artifact name and format>

## Stage NN: ...

(repeat for each stage)
```

## Optional Fields

```markdown
## Shared Context

- **<name>:** <description of cross-stage reference file>
- **<name>:** <description>

## Tool Prerequisites

- **<tool>:** <what it does, which stages need it>

## Checkpoints

- **After stage NN:** <what to review before continuing>
```

## Rules

- At least 2 stages. A single-stage process is a skill, not a procedure.
- Stage names are `lowercase-with-hyphens`, no numbers in the name (numbers are auto-prefixed).
- Every stage must have Purpose, Inputs, Process, and Output.
- Inputs must trace back to: task arguments, shared context, or a prior stage's output.
- Process steps must be concrete actions, not vague descriptions.

## Example: Minimal Spec

```markdown
# Procedure: deps-check

Scan dependency update PRs, classify risk, verify builds, and merge or flag.

## Target

- **Directory:** `.claude/skills/deps-check/`
- **Arguments:** "pr-number org/repo"

## Stage 01: classify

**Purpose:** Read the dependency update PR and classify risk level.

**Inputs:**
- PR diff via `gh pr diff`
- PR metadata via `gh pr view`

**Process:**
1. Fetch PR diff and metadata
2. Identify which dependencies changed and by how much (patch/minor/major)
3. Check for breaking change indicators in changelogs
4. Classify risk: low (patch, tests pass), medium (minor), high (major or build fail)

**Output:** `risk-classification.md` -- dependency name, old version, new version, risk level, reasoning

## Stage 02: verify

**Purpose:** Checkout the PR branch and run the build and test suite.

**Inputs:**
- Stage 01 output: `risk-classification.md`
- PR branch (checkout via git)

**Process:**
1. Checkout PR branch locally
2. Install dependencies
3. Run build
4. Run test suite
5. Record pass/fail for each step

**Output:** `verification-report.md` -- build result, test result, failures if any

## Stage 03: decide

**Purpose:** Based on risk and verification, merge automatically or flag for review.

**Inputs:**
- Stage 01 output: `risk-classification.md`
- Stage 02 output: `verification-report.md`

**Process:**
1. Read risk level and verification results
2. If low risk + all green: merge with `gh pr merge --squash`
3. If medium risk + all green: add `ready-for-review` label
4. If high risk or any failure: add `needs-manual-review` label, post comment

**Output:** `decision-report.md` -- action taken, reasoning
```
