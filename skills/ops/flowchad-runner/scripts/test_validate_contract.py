#!/usr/bin/env python3

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

MODULE_PATH = Path(__file__).with_name("validate_contract.py")
SPEC = importlib.util.spec_from_file_location("flowchad_validate_contract", MODULE_PATH)
assert SPEC and SPEC.loader
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)


GOOD_CONFIG = {
    "identity": {"repo": "fellowship-dev/quantic-v2"},
    "environments": {
        "local": {"url": "http://localhost:3000", "captcha": {"mode": "disabled"}},
        "preview": {"mode": "on-demand", "provider": "vercel"},
        "production": {
            "url": "https://quantic.cl",
            "captcha": {"mode": "required", "site_key_env": "NEXT_PUBLIC_TURNSTILE_SITE_KEY"},
        },
    },
    "smoke": {"critical": ["contact", "locale-switch"]},
}

CONTACT_FLOW = {
    "interactive": True,
    "affects": ["app/contact/**", "components/contact-*.tsx"],
    "evidence": {"browser": "required"},
    "contract": {"captcha": ["renders", "token", "submission", "success-ui", "backend-boundary"]},
    "steps": [
        {"name": "complete challenge", "action": "click", "captcha": True, "optional": False},
        {"name": "submit", "action": "submit", "expect": "localized success message"},
    ],
}

I18N_FLOW = {
    "interactive": True,
    "affects": ["app/**", "messages/**"],
    "evidence": {"browser": "required"},
    "contract": {
        "kind": "i18n",
        "locales": ["es", "en"],
        "visible_regions": ["header", "main", "form", "footer"],
    },
    "steps": [{"name": "switch", "action": "click", "expect": "English header copy is visible"}],
}


class ContractTests(unittest.TestCase):
    def make_tree(self, config=None, contact=None, locale=None):
        root = Path(tempfile.mkdtemp())
        flows = root / ".flowchad" / "flows"
        flows.mkdir(parents=True)
        (root / ".flowchad" / "config.yml").write_text(
            yaml.safe_dump(config or GOOD_CONFIG), encoding="utf-8"
        )
        (flows / "contact.yml").write_text(yaml.safe_dump(contact or CONTACT_FLOW), encoding="utf-8")
        (flows / "locale-switch.yml").write_text(yaml.safe_dump(locale or I18N_FLOW), encoding="utf-8")
        return root

    def validate(self, root, mode="production"):
        return VALIDATOR.validate(
            root / ".flowchad" / "config.yml",
            root / ".flowchad" / "flows",
            mode,
            "fellowship-dev/quantic-v2",
        )

    def codes(self, result):
        return {item["code"] for item in result["findings"]}

    def test_complete_production_contract_passes(self):
        result = self.validate(self.make_tree())
        self.assertEqual(result["status"], "valid")
        self.assertEqual(result["checked_flows"], ["contact", "locale-switch"])

    def test_quantic_trailing_newline_site_key_regression(self):
        config = yaml.safe_load(yaml.safe_dump(GOOD_CONFIG))
        config["environments"]["production"]["captcha"]["site_key"] = "widget-key\n"
        result = self.validate(self.make_tree(config=config))
        self.assertIn("captcha-site-key-whitespace", self.codes(result))

    def test_production_captcha_cannot_be_optional(self):
        flow = yaml.safe_load(yaml.safe_dump(CONTACT_FLOW))
        flow["steps"][0]["optional"] = True
        result = self.validate(self.make_tree(contact=flow))
        self.assertIn("production-captcha-optional", self.codes(result))

    def test_browserless_interactive_contract_is_rejected(self):
        flow = yaml.safe_load(yaml.safe_dump(CONTACT_FLOW))
        del flow["evidence"]
        result = self.validate(self.make_tree(contact=flow))
        self.assertIn("interactive-browser-evidence-required", self.codes(result))

    def test_quantic_url_and_lang_only_i18n_regression(self):
        flow = yaml.safe_load(yaml.safe_dump(I18N_FLOW))
        flow["contract"]["visible_regions"] = []
        flow["steps"][0]["expect"] = "URL is /en and html lang is en"
        result = self.validate(self.make_tree(locale=flow))
        self.assertIn("i18n-visible-copy-incomplete", self.codes(result))

    def test_template_identity_and_localhost_production_are_rejected(self):
        config = yaml.safe_load(yaml.safe_dump(GOOD_CONFIG))
        config["identity"]["repo"] = "fellowship-dev/booster-pack"
        config["environments"]["production"]["url"] = "http://localhost:3000"
        result = self.validate(self.make_tree(config=config), mode="cron")
        self.assertTrue({"template-identity", "identity-mismatch", "production-url-invalid"} <= self.codes(result))

    def test_missing_preview_target_is_rejected(self):
        config = yaml.safe_load(yaml.safe_dump(GOOD_CONFIG))
        del config["environments"]["preview"]
        result = self.validate(self.make_tree(config=config), mode="preview")
        self.assertIn("environment-preview-missing", self.codes(result))

    def test_changed_files_select_only_declared_affected_flows(self):
        root = self.make_tree()
        result = VALIDATOR.validate(
            root / ".flowchad" / "config.yml",
            root / ".flowchad" / "flows",
            "preview",
            "fellowship-dev/quantic-v2",
            ["components/contact-form.tsx", "docs/runbook.md"],
        )
        self.assertEqual(result["affected_flows"], ["contact"])

    def test_docs_only_change_selects_no_flow(self):
        root = self.make_tree()
        result = VALIDATOR.validate(
            root / ".flowchad" / "config.yml",
            root / ".flowchad" / "flows",
            "preview",
            "fellowship-dev/quantic-v2",
            ["docs/runbook.md"],
        )
        self.assertEqual(result["affected_flows"], [])


if __name__ == "__main__":
    unittest.main()
