#!/usr/bin/env bash
# Durable, non-notifying terminal receipts for Stage 04 exact-head failures.
# Source this file; it intentionally performs no GitHub reads or mutations.

dc_write_nonpromotion_receipt() {
  local decision=$1 output_dir=$2 reviewed_head_sha=$3 live_head_sha=$4
  local receipt_id=$5 restart_count=$6 comment_cursor=${7:-} reason=${8:-}

  mkdir -p "$output_dir"
  case "$decision" in
    restart)
      printf 'restart_count: 1\nfrom_head_sha: %s\nto_head_sha: %s\nreceipt_id: %s\ncomment_cursor: %s\n' \
        "$reviewed_head_sha" "$live_head_sha" "$receipt_id" "$comment_cursor" \
        > "$output_dir/restart.md"
      echo "[pylot] outcome=\"double-check restart required: PR HEAD moved after review\" status=blocked"
      ;;
    blocked)
      [ -n "$reason" ] || reason="exact-head receipt unavailable or superseded"
      printf 'blocked: true\nreason: %s\nreviewed_head_sha: %s\nlive_head_sha: %s\nreceipt_id: %s\nrestart_count: %s\ncomment_cursor: %s\n' \
        "$reason" "$reviewed_head_sha" "${live_head_sha:-unavailable}" "$receipt_id" \
        "$restart_count" "$comment_cursor" > "$output_dir/blocked.md"
      echo "[pylot] outcome=\"double-check blocked: exact-head receipt unavailable or superseded\" status=blocked"
      ;;
    *)
      echo "unknown nonpromotion decision: $decision" >&2
      return 64
      ;;
  esac
}
