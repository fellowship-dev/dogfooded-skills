#!/usr/bin/env python3
"""Fixture harness for the cto-review VISUAL-evidence gate (CONTEXT.md step 5.6).

Companion to test_evidence_gate.py, which covers the STAGING gate at step 5.5.

Unlike that harness, this one does not re-implement the gate's regexes in Python:
both layers are EXTRACTED VERBATIM from CONTEXT.md and executed in bash, so a
fixture can only pass if the deployed text passes. Mutate either block in
CONTEXT.md and fixtures here go red.

Two layers:

  TRIGGER  — the `UI_TRIGGER=$(...)` block. Answers "does this diff have a
             user-facing surface?" from the changed-file list plus the optional
             per-repo `.pylot/ui-paths` globs. This is the layer that keeps the
             gate generous: on the last 45 fellowship-dev/pylot PRs it answered
             "none" for 39 of them, so those PRs never reached the body scan.

  PARSE    — the `VIS_PARSE=` block. Answers "does this body satisfy the gate?"
             Grammar, mirroring the staging gate line for line:
               heading  ^#{1,4}\\s.*[Vv]isual\\s+[Ee]vidence  (case/decoration tolerant)
               waiver   literal `N/A` within 3 lines of the heading
               pending  `> pending` within 2 lines blocks
               evidence >=1 image URL INSIDE the section (heading -> next heading)

Why this gate exists (2026-08-03, fellowship-dev/pylot#2834 child 8): the
requirement was repo prose only — docs/sdlc.md claimed template, skill, and CTO
review "reinforce each other" while this skill contained zero visual/screenshot
text. Enforcement fell to an LLM reading CLAUDE.md, which produced 29 consecutive
"human action required" comments on one PR (pylot#2802) over 53 hours.

Run: python3 test_visual_gate.py   (exit 0 = all green)
"""
import shlex
import subprocess
import sys
from pathlib import Path

CONTEXT = Path(__file__).parent / "CONTEXT.md"


def extract(first_marker: str, last_marker: str) -> str:
    """A block from CONTEXT.md, verbatim, from the line containing first_marker
    through the first following line containing last_marker."""
    lines = CONTEXT.read_text().splitlines()
    start = next(i for i, ln in enumerate(lines) if first_marker in ln)
    end = next(i for i, ln in enumerate(lines[start:], start) if last_marker in ln)
    return "\n".join(lines[start:end + 1])


def trigger_block() -> str:
    return extract("UI_TRIGGER=$(printf", '|| echo "none")')


def parse_block() -> str:
    # VIS_PARSE is a double-quoted bash assignment; it ends on the lone closing quote.
    lines = CONTEXT.read_text().splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.strip().startswith("VIS_PARSE="))
    end = next(i for i, ln in enumerate(lines[start + 1:], start + 1) if ln.strip() == '"')
    return "\n".join(lines[start:end + 1])


def run_trigger(changed_files: list, ui_paths: str) -> str:
    script = "\n".join([
        f"CHANGED_FILES={shlex.quote(chr(10).join(changed_files))}",
        f"UI_PATHS={shlex.quote(ui_paths)}",
        trigger_block(),
        'printf "%s" "$UI_TRIGGER"',
    ])
    out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30)
    return out.stdout.strip()


def run_parse(body: str) -> str:
    script = "\n".join([
        parse_block(),
        f"PR_BODY={shlex.quote(body)}",
        'printf "%s" "$PR_BODY" | python3 -c "$VIS_PARSE"',
    ])
    out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30)
    return out.stdout.strip()


# ---------------------------------------------------------------------------
# TRIGGER fixtures — (label, changed_files, ui_paths, expected_prefix)
# "none" means WAIVED: the gate never reads the body.
# ---------------------------------------------------------------------------
PYLOT_UI_PATHS = "ui/src/**\nui/public/**\nui/next.config.ts\n!ui/src/app/api/**\n"

TRIGGER_FIXTURES = [
    # --- the generous waiver: these must never block ------------------------
    ("t1) gateway-only backend PR (pylot#2822) — waived",
     ["gateway/gateway.mts", "gateway/modules/connectors/slack/read-api.mts",
      "tests/gateway-slack-read.test.mts"], "", "none"),
    ("t2) backend + migration + docs (pylot#2825) — waived",
     ["docs/identity.md", "gateway/db.mts",
      "gateway/migrations/0063-slack-link-declines.sql"], "", "none"),
    ("t3) docs-only (pylot#2836) — waived",
     ["docs/visual-evidence.md"], "", "none"),
    ("t4) skill markdown only — waived",
     ["skills/ops/cto-review/SKILL.md"], "", "none"),
    ("t5) infra/CDK TypeScript — waived (.ts is not a UI extension)",
     ["infra/lib/stack.ts"], "", "none"),

    # --- real UI surface: these must trigger ---------------------------------
    ("t6) .tsx page (pylot#2802, the case study) — triggers on extension",
     ["specs/2617/spec.md", "ui/src/app/o/[org]/automations/page.tsx",
      "ui/src/hooks/useAutomations.ts"], "", "ext:"),
    ("t7) same PR WITH .pylot/ui-paths — glob wins, still triggers",
     ["specs/2617/spec.md", "ui/src/app/o/[org]/automations/page.tsx"],
     PYLOT_UI_PATHS, "glob:"),
    ("t8) bare .css — triggers on extension",
     ["app/assets/main.css"], "", "ext:"),
    ("t9) .erb template — triggers on extension",
     ["app/views/layouts/application.html.erb"], "", "ext:"),

    # --- what .pylot/ui-paths BUYS: no UI extension anywhere in the diff -----
    ("t10) hook-only diff, NO ui-paths — waived (the gap the file closes)",
     ["ui/src/hooks/useMissions.ts"], "", "none"),
    ("t11) hook-only diff, WITH ui-paths — triggers via glob",
     ["ui/src/hooks/useMissions.ts"], PYLOT_UI_PATHS, "glob:"),
    ("t12) deleted public SVGs, WITH ui-paths — triggers via glob",
     ["ui/public/file.svg", "ui/public/globe.svg"], PYLOT_UI_PATHS, "glob:"),
    ("t13) ui/next.config.ts (the #1182 OAuth proxy), WITH ui-paths — triggers",
     ["ui/next.config.ts"], PYLOT_UI_PATHS, "glob:"),

    # --- exclusions ---------------------------------------------------------
    ("t14) *.example.tsx (booster-pack#748) — excluded, waived",
     ["backend/src/admin/app.example.tsx"], "", "none"),
    ("t15) *.test.tsx / *.stories.tsx only — excluded, waived",
     ["ui/src/components/Card.test.tsx", "ui/src/components/Card.stories.tsx"], "", "none"),
    ("t16) *.d.ts — excluded, waived (mirrors the staging gate's *.d.mts rule)",
     ["ui/types/globals.d.ts"], "", "none"),
    ("t17) '!' exclusion wins over the built-in extension default",
     ["ui/src/app/api/version/route.ts", "ui/src/app/legacy/page.tsx"],
     "!ui/src/app/**\n", "none"),
    ("t18) explicit glob OVERRIDES the built-in NOT_UI exclusion",
     ["ui/next.config.ts"], "ui/next.config.ts\n", "glob:"),
    ("t19) ui/CLAUDE.md under a precise list — waived (blanket ui/** would not)",
     ["ui/CLAUDE.md", "ui/README.md", "ui/package-lock.json"], PYLOT_UI_PATHS, "none"),

    # --- degradation --------------------------------------------------------
    ("t20) empty ui-paths (fetch failed / file absent) — extension default still applies",
     ["ui/src/app/page.tsx"], "", "ext:"),
    ("t21) comments and blank lines in ui-paths are ignored",
     ["ui/src/hooks/x.ts"], "# a comment\n\n  \nui/src/**\n", "glob:"),
    ("t22) empty diff — waived, never blocks",
     [], "", "none"),
]


# ---------------------------------------------------------------------------
# PARSE fixtures — (label, body, expected_prefix)
# ---------------------------------------------------------------------------
PARSE_FIXTURES = [
    # --- waiver -------------------------------------------------------------
    ("p1) canonical waiver", "## Summary\nx\n\n## Visual Evidence\n\nN/A — no user-facing surface\n\n## Test plan\n", "PASS"),
    ("p2) waiver on the heading line itself", "## Visual Evidence\nN/A\n", "PASS"),
    ("p3) h3 + emoji + suffix heading (decoration tolerant)", "### 📸 Visual Evidence — after rework\nN/A — backend only\n", "PASS"),
    ("p4) lowercase heading", "#### visual evidence\nn/a\n", "PASS"),
    ("p5) N/A FOUR lines from the heading — does NOT waive (3-line window)",
     "## Visual Evidence\n\nblah\nblah\nN/A — no user-facing surface\n", "BLOCK"),

    # --- embedded evidence --------------------------------------------------
    ("p6) child 6 canonical double-link form", "## Visual Evidence\n\n[![after](https://hooks.fellowship.dev/a/AbC)](https://hooks.fellowship.dev/a/AbC)\n", "PASS"),
    ("p7) plain markdown image in a Before/After table",
     "## Visual Evidence\n| Before | After |\n|---|---|\n| ![b](https://x/1.png) | ![a](https://x/2.png) |\n", "PASS"),
    ("p8) raw <img> tag", '## Visual Evidence\n<img src="https://x/1.png" width="400">\n', "PASS"),
    ("p9) evidence AFTER the summary, section not first", "## Summary\ntext\n\n## Visual Evidence\n![s](https://x/a.png)\n", "PASS"),

    # --- blocks -------------------------------------------------------------
    ("p10) no Visual Evidence section at all (pylot#2802's actual body)", "## Summary\njust text\n## Test plan\n- [ ] x\n", "BLOCK"),
    ("p11) empty PR-template scaffold does NOT pass",
     "## Visual Evidence\n\n<!-- Run /evidence-upload to capture and embed screenshots. -->\n\n| Before | After |\n|--------|-------|\n|        |       |\n", "BLOCK"),
    ("p12) '> pending' placeholder blocks", "## Visual Evidence\n> pending\n", "BLOCK"),
    ("p13) image OUTSIDE the section does not count",
     "## Visual Evidence\n\nnothing here\n\n## Test plan\n![x](https://x/1.png)\n", "BLOCK"),
    ("p14) a relative/committed image path is not an assets URL — blocks",
     "## Visual Evidence\n![b](docs/screenshots/before.png)\n", "BLOCK"),
    ("p15) empty body", "", "BLOCK"),

    # --- self-pass guard ----------------------------------------------------
    # The gate's own rejection comment must never satisfy the gate. It describes
    # the heading in prose instead of writing it at column 0, so the comment scan
    # (which selects only comments matching the heading regex) never picks it up.
    ("p16) the rejection comment's own text carries no column-0 heading",
     "Missing visual evidence. This PR changes a user-facing surface, so its Visual Evidence\n"
     "section must carry at least one embedded image — or the waiver.\n\n"
     "3. add a level-2 heading reading `Visual Evidence` to the PR body, followed by a line reading:\n\n"
     "       N/A — no user-facing surface\n", "BLOCK"),
]


def main() -> int:
    ok = True
    print("-- TRIGGER layer (extracted from CONTEXT.md step 5.6) --")
    for label, files, paths, want in TRIGGER_FIXTURES:
        got = run_trigger(files, paths)
        passed = got.startswith(want)
        ok = ok and passed
        print(f"[{'green' if passed else 'RED  '}] {label}")
        if not passed:
            print(f"        want {want!r}*\n        got  {got!r}")

    print("-- PARSE layer (extracted from CONTEXT.md step 5.6) --")
    for label, body, want in PARSE_FIXTURES:
        got = run_parse(body)
        passed = got.startswith(want)
        ok = ok and passed
        print(f"[{'green' if passed else 'RED  '}] {label}")
        if not passed:
            print(f"        want {want}:*\n        got  {got!r}")

    print()
    print("ALL GREEN" if ok else "FAILURES PRESENT")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
