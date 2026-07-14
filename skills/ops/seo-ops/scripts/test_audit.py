#!/usr/bin/env python3

import gzip
import importlib.util
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

MODULE_PATH = Path(__file__).with_name("audit.py")
SPEC = importlib.util.spec_from_file_location("seo_ops_audit", MODULE_PATH)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        status, headers, body = self.server.responses.get(  # type: ignore[attr-defined]
            self.path, (404, {"Content-Type": "text/plain"}, b"not found")
        )
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


class Site:
    def __init__(self, responses=None):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.responses = responses or {}
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def start(self):
        self.thread.start()
        return self

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def page(canonical):
    return f"""<!doctype html><html lang="en"><head>
    <title>Example</title><meta name="description" content="Example description">
    <meta property="og:title" content="Example"><meta property="og:description" content="Example description">
    <meta property="og:url" content="{canonical}"><link rel="canonical" href="{canonical}">
    <script type="application/ld+json">{{"@context":"https://schema.org","@type":"WebSite"}}</script>
    </head><body><h1>Example</h1><img src="/logo.png" alt="Logo"></body></html>""".encode()


class AuditTests(unittest.TestCase):
    def test_clean_page_and_valid_sitemap(self):
        site = Site().start()
        try:
            root = site.origin + "/"
            site.server.responses.update({
                "/": (200, {"Content-Type": "text/html"}, page(root)),
                "/robots.txt": (200, {"Content-Type": "text/plain"}, f"User-agent: *\nAllow: /\nSitemap: {root}sitemap.xml\n".encode()),
                "/sitemap.xml": (200, {"Content-Type": "application/xml"}, f"<?xml version='1.0'?><urlset xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'><url><loc>{root}</loc></url></urlset>".encode()),
            })
            report = AUDIT.audit_site(SimpleNamespace(url=root, compare_origin=[], max_pages=1, timeout=5))
            self.assertEqual(report["counts"]["Critical"], 0)
            high_codes = [item["code"] for item in report["findings"] if item["severity"] == "High"]
            self.assertEqual(high_codes, ["not-https"])
        finally:
            site.close()

    def test_duplicate_origin_is_critical(self):
        canonical = Site().start()
        alternate = Site().start()
        try:
            root = canonical.origin + "/"
            for site in (canonical, alternate):
                site.server.responses.update({
                    "/": (200, {"Content-Type": "text/html"}, page(root)),
                    "/robots.txt": (200, {"Content-Type": "text/plain"}, b"User-agent: *\nAllow: /\n"),
                    "/sitemap.xml": (200, {"Content-Type": "application/xml"}, b"<urlset xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'></urlset>"),
                })
            report = AUDIT.audit_site(SimpleNamespace(url=root, compare_origin=[alternate.origin], max_pages=1, timeout=5))
            self.assertIn("duplicate-host", [item["code"] for item in report["findings"]])
        finally:
            canonical.close()
            alternate.close()

    def test_curl_transport_decodes_gzip(self):
        site = Site().start()
        try:
            root = site.origin + "/"
            site.server.responses["/"] = (200, {"Content-Type": "text/html", "Content-Encoding": "gzip"}, gzip.compress(page(root)))
            response = AUDIT.fetch(root, 5)
            parsed = AUDIT.parse_html(response)
            self.assertEqual(parsed.title, "Example")
            self.assertEqual(parsed.lang, "en")
        finally:
            site.close()


if __name__ == "__main__":
    unittest.main()
