---
name: evidence-upload
description: Use when publishing screenshots, GIFs, videos or other visual evidence for a PR, issue or report. Uploads straight to the public evidence S3 bucket and returns embeddable URLs.
argument-hint: "[--repo owner/repo] [--prefix path] [--alt text] [--url-only] FILE..."
user-invocable: true
allowed-tools: Bash, Read
metadata:
  version: 2.0.0
---

# evidence-upload

Upload local evidence files to the public evidence bucket and return a permanent
public URL plus a ready-to-paste Markdown line for each file.

**Why a bucket:** GitHub does not render repo-relative or
`raw.githubusercontent.com` images in **private** repos for viewers without a
session on that repo, and branch-hosted links die with the branch. A public,
content-addressed bucket renders everywhere — PR bodies, issue comments,
reports — and never expires.

## Public by URL — read before uploading

Anything uploaded is **publicly readable by anyone with the URL**. Never upload
secrets, tokens, customer PII or production data. Prefer synthetic or staging
data in screenshots; crop or redact before uploading. There is no delete path
for the uploader — an object, once uploaded, stays until an operator removes it.

## Configuration (environment only)

The script reads these and nothing else — never the general `AWS_*` variables,
never command-line arguments. Never print them.

| Variable | Meaning |
|---|---|
| `EVIDENCE_AWS_ACCESS_KEY_ID` / `EVIDENCE_AWS_SECRET_ACCESS_KEY` | Upload-only key (`s3:PutObject` on the bucket) |
| `EVIDENCE_BUCKET` | e.g. `fellowship-evidence-503081149087` |
| `EVIDENCE_REGION` | e.g. `us-east-1` |
| `EVIDENCE_PUBLIC_BASE_URL` | e.g. `https://fellowship-evidence-503081149087.s3.us-east-1.amazonaws.com` |

If any is missing the script exits 2 with *"evidence upload secret is not
configured for this environment"*. Report that; do not substitute other
credentials or fall back to another host.

## Usage

```bash
UPLOAD="<this skill's directory>/scripts/upload_evidence.sh"
"$UPLOAD" --alt "Checkout after fix" /tmp/evidence-after.png
# https://<bucket>.s3.<region>.amazonaws.com/acme/app/2026/10/3f9c...-evidence-after.png
# ![Checkout after fix](https://<bucket>.s3.<region>.amazonaws.com/acme/app/2026/10/3f9c...-evidence-after.png)
```

- `FILE...` — one or more files: `png jpg jpeg gif webp mp4 webm pdf txt`.
- `--repo owner/repo` — defaults to `git remote get-url origin`.
- `--prefix path` — replaces the `YYYY/MM` key segment (e.g. a flow name).
- `--alt text` — Markdown label; defaults to the file name.
- `--url-only` — print only the URL per file (for scripts).
- `--dry-run` — print the key and URL without uploading.

Key layout: `<owner>/<repo>/<YYYY>/<MM>/<sha256-first-16>-<basename>`. Keys are
content-addressed: re-uploading the same bytes yields the same URL.

The script signs a single `PUT` with `curl --aws-sigv4` (curl ≥ 7.75; no AWS CLI
or other dependency), sets `Content-Type` from the extension and
`Cache-Control: public, max-age=31536000, immutable`, passes credentials through
a temporary 0600 curl config file (never argv), then verifies the public URL
returns HTTP 200 before printing it. Images get `![alt](url)`; video, PDF and
text get `[alt](url)` (GitHub renders an `.mp4` link in a PR/issue body as a player).

Exit codes: `0` every file uploaded and verified; `1` at least one file failed
(reason on stderr, no URL printed for it); `2` usage or configuration error.

## Workflow

1. Confirm the files contain no secrets or real customer data.
2. Run the script; collect the printed URLs/Markdown lines.
3. Embed them in the PR, issue or report. Only embed URLs the script printed.

## Critical Rules

- Upload is advisory unless the owning repo makes evidence a gate. On failure,
  report the missing evidence explicitly instead of hiding it or failing an
  otherwise valid PR.
- GIFs over ~10 MB render poorly on GitHub; prefer `mp4` for long recordings.
