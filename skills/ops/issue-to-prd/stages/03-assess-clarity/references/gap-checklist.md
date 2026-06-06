# Gap Checklist — 8 Sections

Ported from `build-prd`. Check each section against the issue for stage 03 clarity assessment.

| Section | Required | What to look for |
|---------|----------|------------------|
| Problem Statement | Yes | Why does this matter? What pain exists? |
| User Stories | Yes | Who needs it and why? |
| Success Metrics | Yes | How do we measure success? |
| Scope (in + out) | Yes | What's included and explicitly excluded? |
| Technical Constraints | Yes | Limitations, integrations, patterns? |
| Mockups/Examples | No | Visual references if available |
| Dependencies | No | Related features or systems |
| Timeline | No | Priority or deadline |

## Verdict rules
- `clear`: all 5 required sections covered (even implicitly from context)
- `needs-questions`: any required section missing OR ambiguous

## Implicit coverage
A section can be "covered" without a formal header. If the intent is clear from the issue body
and the codebase context, count it as covered. Only flag when genuinely ambiguous.
