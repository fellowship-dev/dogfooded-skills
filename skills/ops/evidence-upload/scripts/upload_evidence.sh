#!/usr/bin/env bash
# upload_evidence.sh — upload screenshots/GIFs/videos to the public evidence
# bucket and print a public URL plus a ready-to-paste Markdown line per file.
#
# Usage:
#   upload_evidence.sh [--repo owner/repo] [--prefix path] [--alt text]
#                      [--url-only] [--dry-run] FILE...
#
# Credentials and target come ONLY from the environment (never from arguments):
#   EVIDENCE_AWS_ACCESS_KEY_ID, EVIDENCE_AWS_SECRET_ACCESS_KEY,
#   EVIDENCE_BUCKET, EVIDENCE_REGION, EVIDENCE_PUBLIC_BASE_URL
#
# Key layout: <owner>/<repo>/<YYYY>/<MM>/<sha256-first-16>-<sanitized-basename>
# (--prefix replaces the <YYYY>/<MM> segment; unsafe characters become "-").
#
# Output (stdout), per file: the public URL, then a Markdown line.
#   --url-only prints only the URL. --dry-run prints the key and URL without
#   network access. Progress and errors go to stderr.
# Exit: 0 all uploaded and verified; 1 at least one file failed; 2 usage/config.
set -euo pipefail

die() { printf 'evidence-upload: %s\n' "$*" >&2; exit 2; }
warn() { printf 'evidence-upload: %s\n' "$*" >&2; }

REPO="" PREFIX="" ALT="" URL_ONLY=0 DRY_RUN=0
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die "--repo needs owner/repo"; REPO="$2"; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; PREFIX="$2"; shift 2 ;;
    --alt) [ $# -ge 2 ] || die "--alt needs a value"; ALT="$2"; shift 2 ;;
    --url-only) URL_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; FILES+=("$@"); break ;;
    -*) die "unknown option: $1 (credentials are read from EVIDENCE_* env vars only)" ;;
    *) FILES+=("$1"); shift ;;
  esac
done
[ ${#FILES[@]} -gt 0 ] || die "no files given. Usage: upload_evidence.sh [--repo owner/repo] [--prefix path] [--alt text] [--url-only] [--dry-run] FILE..."

missing=()
for v in EVIDENCE_AWS_ACCESS_KEY_ID EVIDENCE_AWS_SECRET_ACCESS_KEY EVIDENCE_BUCKET EVIDENCE_REGION EVIDENCE_PUBLIC_BASE_URL; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
[ ${#missing[@]} -eq 0 ] || die "evidence upload secret is not configured for this environment (missing: ${missing[*]}). Ask the owner to provision the EVIDENCE_* env secret; do not substitute other credentials."

case "$EVIDENCE_REGION" in *[!a-z0-9-]*) die "EVIDENCE_REGION is not a valid AWS region" ;; esac
case "$EVIDENCE_BUCKET" in *[!a-z0-9.-]*) die "EVIDENCE_BUCKET is not a valid bucket name" ;; esac
BASE="${EVIDENCE_PUBLIC_BASE_URL%/}"

if [ -z "$REPO" ]; then
  origin=$(git remote get-url origin 2>/dev/null) || die "no --repo given and no git origin remote found"
  REPO=$(printf '%s' "$origin" | sed -E 's#^.*github\.com[:/]+##; s#\.git$##; s#/+$##')
fi
printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "repo must be owner/repo, got: $REPO"
if [ -z "$PREFIX" ]; then
  PREFIX=$(date -u +%Y/%m)
fi
# Sanitize: unsafe characters (e.g. spaces in flow names) become "-".
PREFIX=$(printf '%s' "$PREFIX" | sed -E 's#[^A-Za-z0-9_./-]+#-#g; s#/+#/#g; s#^/##; s#/$##')
[ -n "$PREFIX" ] || die "--prefix is empty after sanitizing"
case "/$PREFIX/" in */../*|*/./*) die "--prefix may not contain . or .. segments" ;; esac

if [ "$DRY_RUN" -eq 0 ]; then
  command -v curl >/dev/null 2>&1 || die "curl is required (>= 7.75 for --aws-sigv4)"
  cv=$(curl --version | head -1 | awk '{print $2}')
  cmaj=${cv%%.*}; crest=${cv#*.}; cmin=${crest%%.*}
  if [ "${cmaj:-0}" -lt 7 ] || { [ "$cmaj" -eq 7 ] && [ "${cmin:-0}" -lt 75 ]; }; then
    die "curl $cv is too old; --aws-sigv4 needs curl >= 7.75. Install a newer curl."
  fi
fi

sha256_full() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d" " -f1
  else shasum -a 256 "$1" | cut -d" " -f1; fi
}
sha16() { sha256_full "$1" | cut -c1-16; }

content_type() {
  local ext
  ext=$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')
  case "$ext" in
    png) echo image/png ;;
    jpg|jpeg) echo image/jpeg ;;
    gif) echo image/gif ;;
    webp) echo image/webp ;;
    mp4) echo video/mp4 ;;
    webm) echo video/webm ;;
    pdf) echo application/pdf ;;
    txt) echo 'text/plain; charset=utf-8' ;;
    *) return 1 ;;
  esac
}

CFG=""
cleanup() { [ -n "$CFG" ] && rm -f "$CFG"; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM
if [ "$DRY_RUN" -eq 0 ]; then
  # Credentials go to curl through a 0600 config file, never on the command line.
  CFG=$(umask 077; mktemp "${TMPDIR:-/tmp}/evidence-upload.XXXXXX")
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  printf 'user = "%s:%s"\n' "$(esc "$EVIDENCE_AWS_ACCESS_KEY_ID")" "$(esc "$EVIDENCE_AWS_SECRET_ACCESS_KEY")" > "$CFG"
fi

rc=0
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then warn "FAILED $f: not a readable file"; rc=1; continue; fi
  if ! ct=$(content_type "$f"); then
    warn "FAILED $f: unsupported extension (png, jpg, jpeg, gif, webp, mp4, webm, pdf, txt)"; rc=1; continue
  fi
  name=$(basename "$f" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^[.-]+//')
  [ -n "$name" ] || name="file.${f##*.}"
  sum=$(sha256_full "$f")
  key="${REPO}/${PREFIX}/${sum:0:16}-${name}"
  url="${BASE}/${key}"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'key: %s\nurl: %s\n' "$key" "$url"; continue
  fi

  put_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 300 \
    -K "$CFG" --aws-sigv4 "aws:amz:${EVIDENCE_REGION}:s3" \
    -H "Content-Type: ${ct}" \
    -H "x-amz-content-sha256: ${sum}" \
    -H "Cache-Control: public, max-age=31536000, immutable" \
    -T "$f" "https://${EVIDENCE_BUCKET}.s3.${EVIDENCE_REGION}.amazonaws.com/${key}" 2>/dev/null) || put_code="${put_code:-000}"
  if [ "$put_code" != "200" ]; then
    warn "FAILED $f: upload returned HTTP $put_code"; rc=1; continue
  fi
  head_code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 60 "$url" 2>/dev/null) || head_code="${head_code:-000}"
  if [ "$head_code" != "200" ]; then
    warn "FAILED $f: uploaded but public URL returned HTTP $head_code"; rc=1; continue
  fi

  printf '%s\n' "$url"
  if [ "$URL_ONLY" -eq 0 ]; then
    label="${ALT:-$(basename "$f")}"
    case "$ct" in
      image/*) printf '![%s](%s)\n' "$label" "$url" ;;
      *) printf '[%s](%s)\n' "$label" "$url" ;;
    esac
  fi
done
exit "$rc"
