---
name: evidence-upload
description: Use when publishing visual evidence through Pylot assets for a PR, issue, report, mission, or conversation.
argument-hint: "[--evidence-class <class>] [--conversation <conversation-id>] [--alt <text>]"
user-invocable: true
allowed-tools: Bash, Read
---

# evidence-upload

Publish a local image, recording, or other accepted evidence file through the
Pylot asset lifecycle and return the resulting reference or public URL.

## Workflow

1. Read the owning repo's playbook and determine its evidence policy and the
   intended destination.
2. Invoke or read `pylot-cli`, then follow its **Assets** section exactly. It is
   the single source for supported actions, flags, retention, and upload transport.
3. Return the receipt required by the destination, including the asset id and
   any reference needed by the reviewer or conversation.

If the repo playbook defines no Pylot asset policy, do not invent one. Use the
repo's accepted evidence host and state what was used.

## Critical Rules

- Use `pylot-cli` as the single source of truth; do not copy its commands into
  this skill or call Pylot gateway asset endpoints directly.
- An upload problem is advisory unless the owning repo explicitly makes evidence
  a gate. Report the missing evidence instead of concealing it or failing an
  otherwise valid PR.
