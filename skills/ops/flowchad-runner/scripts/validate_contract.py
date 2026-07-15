#!/usr/bin/env python3
"""Validate FlowChad environment and interactive-flow contracts."""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from urllib.parse import urlparse

try:
    import yaml
except ImportError as exc:  # pragma: no cover - exercised by the CLI environment
    raise SystemExit("PyYAML is required: python3 -m pip install pyyaml") from exc


TEMPLATE_MARKERS = {"booster-pack", "example", "template", "changeme", "localhost"}
INTERACTIVE_ACTIONS = {"click", "fill", "submit", "hover", "scroll", "select", "upload"}
CAPTCHA_ASSERTIONS = {"renders", "token", "submission", "success-ui", "backend-boundary"}
I18N_REGIONS = {"header", "main", "form", "footer"}


@dataclass(frozen=True)
class Finding:
    severity: str
    code: str
    path: str
    message: str


def load_yaml(path: Path) -> dict:
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise ValueError(f"cannot read YAML: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"expected a YAML mapping: {path}")
    return value


def add(findings: list[Finding], severity: str, code: str, path: str, message: str) -> None:
    findings.append(Finding(severity, code, path, message))


def is_safe_production_url(value: object) -> bool:
    if not isinstance(value, str):
        return False
    parsed = urlparse(value)
    host = (parsed.hostname or "").lower()
    return parsed.scheme == "https" and bool(host) and host not in {"localhost", "127.0.0.1", "::1"}


def nested(mapping: dict, *keys: str, default=None):
    value: object = mapping
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            return default
        value = value[key]
    return value


def as_string_set(value: object) -> set[str]:
    if not isinstance(value, list):
        return set()
    return {str(item).strip().lower() for item in value if str(item).strip()}


def flow_steps(flow: dict) -> list[dict]:
    steps = flow.get("steps", [])
    return [step for step in steps if isinstance(step, dict)] if isinstance(steps, list) else []


def is_interactive(flow: dict) -> bool:
    if flow.get("interactive") is True:
        return True
    for step in flow_steps(flow):
        action = str(step.get("action", "")).strip().lower()
        if action in INTERACTIVE_ACTIONS or step.get("captcha") is True:
            return True
    return False


def has_captcha(flow: dict) -> bool:
    return any(step.get("captcha") is True for step in flow_steps(flow))


def validate_flow(name: str, path: Path, flow: dict, mode: str, findings: list[Finding]) -> None:
    prefix = str(path)
    interactive = is_interactive(flow)
    captcha = has_captcha(flow)

    if mode in {"production", "preview", "cron"} and interactive:
        evidence = nested(flow, "evidence", "browser")
        if evidence != "required":
            add(findings, "error", "interactive-browser-evidence-required", prefix,
                f"interactive flow {name!r} must set evidence.browser: required")

    if mode in {"production", "cron"} and captcha:
        for index, step in enumerate(flow_steps(flow), start=1):
            if step.get("captcha") is True and step.get("optional") is True:
                add(findings, "error", "production-captcha-optional", f"{prefix}:steps[{index}]",
                    "production CAPTCHA steps cannot be optional")
        assertions = as_string_set(nested(flow, "contract", "captcha", default=[]))
        missing = CAPTCHA_ASSERTIONS - assertions
        if missing:
            add(findings, "error", "captcha-contract-incomplete", prefix,
                "CAPTCHA contract is missing: " + ", ".join(sorted(missing)))

    if nested(flow, "contract", "kind") == "i18n":
        regions = as_string_set(nested(flow, "contract", "visible_regions", default=[]))
        missing = I18N_REGIONS - regions
        if missing:
            add(findings, "error", "i18n-visible-copy-incomplete", prefix,
                "i18n flow must assert visible translated copy in: " + ", ".join(sorted(missing)))
        locales = as_string_set(nested(flow, "contract", "locales", default=[]))
        if len(locales) < 2:
            add(findings, "error", "i18n-locales-incomplete", prefix,
                "i18n flow must name at least two locales")


def select_affected_flows(flows_dir: Path, changed_files: list[str]) -> list[str]:
    affected: list[str] = []
    for path in sorted(flows_dir.glob("*.yml")):
        try:
            flow = load_yaml(path)
        except ValueError:
            continue
        patterns = flow.get("affects", [])
        if not isinstance(patterns, list):
            continue
        if any(
            fnmatch.fnmatchcase(changed_file, str(pattern))
            for changed_file in changed_files
            for pattern in patterns
        ):
            affected.append(path.stem)
    return affected


def validate(
    config_path: Path,
    flows_dir: Path,
    mode: str,
    expected_repo: str | None,
    changed_files: list[str] | None = None,
) -> dict:
    findings: list[Finding] = []
    try:
        config = load_yaml(config_path)
    except ValueError as exc:
        return {"status": "invalid", "mode": mode, "findings": [asdict(Finding(
            "error", "config-unreadable", str(config_path), str(exc)))], "checked_flows": []}

    repo = nested(config, "identity", "repo")
    if not isinstance(repo, str) or not re.fullmatch(r"[^/\s]+/[^/\s]+", repo):
        add(findings, "error", "identity-missing", str(config_path),
            "identity.repo must be an explicit org/repo")
    else:
        lowered = repo.lower()
        if any(marker in lowered for marker in TEMPLATE_MARKERS):
            add(findings, "error", "template-identity", str(config_path),
                f"identity.repo is still template-shaped: {repo}")
        if expected_repo and repo.lower() != expected_repo.lower():
            add(findings, "error", "identity-mismatch", str(config_path),
                f"identity.repo {repo!r} does not match requested repo {expected_repo!r}")

    environments = config.get("environments")
    if not isinstance(environments, dict):
        add(findings, "error", "environments-missing", str(config_path),
            "define local, preview, and production environments explicitly")
        environments = {}
    for required in ("local", "preview", "production"):
        if required not in environments:
            add(findings, "error", f"environment-{required}-missing", str(config_path),
                f"environments.{required} must be explicit")

    production_url = nested(environments, "production", "url")
    if not is_safe_production_url(production_url):
        add(findings, "error", "production-url-invalid", str(config_path),
            "environments.production.url must be a non-local HTTPS URL")

    local_captcha = nested(environments, "local", "captcha", "mode")
    if local_captcha not in {"disabled", "required"}:
        add(findings, "error", "local-captcha-implicit", str(config_path),
            "environments.local.captcha.mode must explicitly be disabled or required")

    preview_mode = nested(environments, "preview", "mode")
    if preview_mode not in {"on-demand", "existing", "disabled"}:
        add(findings, "error", "preview-mode-invalid", str(config_path),
            "environments.preview.mode must be on-demand, existing, or disabled")

    for env_name in ("preview", "production"):
        site_key = nested(environments, env_name, "captcha", "site_key")
        if isinstance(site_key, str) and site_key != site_key.strip():
            add(findings, "error", "captcha-site-key-whitespace", str(config_path),
                f"environments.{env_name}.captcha.site_key has leading/trailing whitespace")

    critical = nested(config, "smoke", "critical", default=[])
    if not isinstance(critical, list) or not critical:
        add(findings, "error", "critical-smoke-empty", str(config_path),
            "smoke.critical must name the cron-compatible critical flow set")
        critical = []

    checked: list[str] = []
    captcha_critical = False
    for raw_name in critical:
        name = str(raw_name).strip()
        if not name:
            continue
        path = flows_dir / f"{name}.yml"
        if not path.is_file():
            add(findings, "error", "critical-flow-missing", str(path),
                f"critical flow {name!r} does not exist")
            continue
        try:
            flow = load_yaml(path)
        except ValueError as exc:
            add(findings, "error", "flow-unreadable", str(path), str(exc))
            continue
        checked.append(name)
        captcha_critical = captcha_critical or has_captcha(flow)
        validate_flow(name, path, flow, mode, findings)

    if mode in {"production", "cron"} and captcha_critical:
        if nested(environments, "production", "captcha", "mode") != "required":
            add(findings, "error", "production-captcha-not-required", str(config_path),
                "a critical CAPTCHA flow requires environments.production.captcha.mode: required")

    errors = sum(item.severity == "error" for item in findings)
    warnings = sum(item.severity == "warning" for item in findings)
    affected = select_affected_flows(flows_dir, changed_files) if changed_files is not None else None
    return {
        "status": "valid" if errors == 0 else "invalid",
        "mode": mode,
        "repo": repo,
        "production_url": production_url,
        "checked_flows": checked,
        "affected_flows": affected,
        "counts": {"errors": errors, "warnings": warnings},
        "findings": [asdict(item) for item in findings],
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path(".flowchad/config.yml"))
    parser.add_argument("--flows-dir", type=Path, default=Path(".flowchad/flows"))
    parser.add_argument("--mode", choices=("local", "preview", "production", "cron"), required=True)
    parser.add_argument("--repo", help="expected org/repo identity")
    parser.add_argument("--changed-files", type=Path,
                        help="newline-delimited PR paths; emits affected_flows from each flow's affects globs")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    changed_files = None
    if args.changed_files:
        changed_files = [
            line.strip() for line in args.changed_files.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    result = validate(args.config, args.flows_dir, args.mode, args.repo, changed_files)
    if args.format == "json":
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(f"FlowChad contract: {result['status'].upper()} ({args.mode})")
        for item in result["findings"]:
            print(f"[{item['severity'].upper()}] {item['code']}: {item['message']} ({item['path']})")
        if not result["findings"]:
            print("No contract violations found.")
    return 0 if result["status"] == "valid" else 1


if __name__ == "__main__":
    raise SystemExit(main())
