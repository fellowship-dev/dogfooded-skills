#!/usr/bin/env python3

import gzip
import importlib.util
import sys
import threading
import time
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
        self.server.requests.append(self.path)
        time.sleep(self.server.delays.get(self.path, 0))
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def log_message(self, *_args):
        return


class Site:
    def __init__(self, responses=None):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.responses = responses or {}
        self.server.requests = []
        self.server.delays = {}
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
    def test_wildcard_directives_keep_stanza_and_comment_boundaries(self):
        self.assertTrue(AUDIT.blocks_wildcard_crawling("User-agent: *\nDisallow: / # intentional\n"))
        self.assertFalse(AUDIT.blocks_wildcard_crawling("User-agent: *\nDisallow: /private\nUser-agent: BadBot\nDisallow: /\n"))
        self.assertFalse(AUDIT.blocks_wildcard_crawling("User-agent: *\nDisallow: /\nAllow: /\n"))

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

    def test_robots_multi_stanza_no_false_positive(self):
        """Dropping DOTALL means a BadBot stanza's Disallow: / doesn't
        falsely match under User-agent: *.  audit_site must NOT emit
        robots-block-all for this robots.txt."""
        site = Site().start()
        try:
            root = site.origin + "/"
            robots_body = (
                "User-agent: *\nAllow: /\n"
                "\n"
                "User-agent: BadBot\nDisallow: /\n"
            ).encode()
            site.server.responses.update({
                "/": (200, {"Content-Type": "text/html"}, page(root)),
                "/robots.txt": (200, {"Content-Type": "text/plain"}, robots_body),
                "/sitemap.xml": (200, {"Content-Type": "application/xml"}, b"<urlset xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'></urlset>"),
            })
            report = AUDIT.audit_site(SimpleNamespace(url=root, compare_origin=[], max_pages=1, timeout=5))
            critical_codes = [item["code"] for item in report["findings"] if item["severity"] == "Critical"]
            self.assertNotIn("robots-block-all", critical_codes)
        finally:
            site.close()

    def test_authored_edges_preserve_sources_and_deduplicate_failed_destination(self):
        site = Site().start()
        try:
            root = site.origin + "/"
            site.server.responses.update({
                "/": (200, {"Content-Type": "text/html"}, page(root).replace(b"</body>", b'<a href="/second">Second</a><a href="/gone#first">First <b>guide</b></a></body>')),
                "/second": (200, {"Content-Type": "text/html"}, page(root + "second").replace(b"</body>", b'<a href="/gone#second">Other guide</a></body>')),
            })
            report = AUDIT.audit_site(SimpleNamespace(url=root, compare_origin=[], max_pages=3, timeout=5))
            edges = [edge for edge in report["link_edges"] if edge["destination_url"] == root + "gone"]
            self.assertEqual([(edge["source_url"], edge["literal_href"], edge["anchor"]) for edge in edges], [(root, "/gone#first", "First guide"), (root + "second", "/gone#second", "Other guide")])
            self.assertEqual(site.server.requests.count("/gone"), 1)
            self.assertTrue(all(edge["context"] == "Example" for edge in edges))
            for edge in edges:
                self.assertEqual(edge["check"]["state"], "checked")
                self.assertEqual(edge["check"]["first_status"], 404)
                self.assertEqual(edge["check"]["final_status"], 404)
                self.assertIsNone(edge["check"]["canonical"])
            self.assertIn("authored-link-http-status", [row["code"] for row in report["findings"]])
        finally:
            site.close()

    def test_declared_legacy_exact_path_chain_and_effective_page_metadata(self):
        site = Site().start()
        legacy = Site().start()
        try:
            root = site.origin + "/"
            old = legacy.origin + "/old-path"
            site.server.responses["/"] = (200, {"Content-Type": "text/html", "X-Robots-Tag": "noindex"}, page(root).replace(b"</body>", f'<a href="{old}">Old guide</a><a href="{legacy.origin}/not-declared">Other legacy page</a></body>'.encode()))
            legacy.server.responses.update({
                "/old-path": (301, {"Location": "/bridge"}, b""),
                "/bridge": (302, {"Location": root}, b""),
            })
            report = AUDIT.audit_site(SimpleNamespace(url=root, compare_origin=[], legacy_url=[old], max_pages=3, timeout=5))
            edge = report["link_edges"][0]
            self.assertEqual(edge["check"]["state"], "checked")
            self.assertEqual(edge["check"]["first_status"], 301)
            self.assertEqual([hop["location"] for hop in edge["check"]["redirects"]], ["/bridge", root])
            self.assertEqual(edge["check"]["final_status"], 200)
            self.assertEqual(edge["check"]["canonical"], root)
            self.assertEqual(edge["check"]["locale"], "en")
            self.assertIn("noindex", report["pages_sampled"][0]["robots"])
            self.assertEqual(legacy.server.requests.count("/old-path"), 1)
            self.assertNotIn("/not-declared", legacy.server.requests)
            foreign_edge = next(item for item in report["link_edges"] if item["destination_url"] == legacy.origin + "/not-declared")
            self.assertEqual(foreign_edge["check"]["reason"], "outside-scope")
        finally:
            legacy.close()
            site.close()

    def test_capped_and_foreign_edges_are_unknown_not_success(self):
        site = Site().start()
        foreign = Site().start()
        try:
            root = site.origin + "/"
            site.server.responses["/"] = (200, {"Content-Type": "text/html"}, page(root).replace(b"</body>", f'<a href="/later">Later</a><a href="{foreign.origin}/unapproved">External</a></body>'.encode()))
            report = AUDIT.audit_site(SimpleNamespace(url=root, compare_origin=[], max_pages=1, timeout=5))
            self.assertEqual([edge["check"]["reason"] for edge in report["link_edges"]], ["page-cap", "outside-scope"])
            self.assertTrue(all(edge["check"]["state"] == "unverified" and edge["check"]["final_status"] is None for edge in report["link_edges"]))
            self.assertNotIn("/later", site.server.requests)
            self.assertEqual(foreign.server.requests, [])
        finally:
            foreign.close()
            site.close()

    def test_deadline_leaves_unvisited_edge_unverified(self):
        site = Site().start()
        try:
            root = site.origin + "/"
            site.server.responses.update({
                "/": (200, {"Content-Type": "text/html"}, page(root).replace(b"</body>", b'<a href="/slow">Slow</a><a href="/later">Later</a></body>')),
                "/slow": (200, {"Content-Type": "text/html"}, page(root + "slow")),
            })
            site.server.delays["/slow"] = 0.3
            report = AUDIT.audit_site(SimpleNamespace(url=root, compare_origin=[], max_pages=3, timeout=5, deadline=0.15))
            self.assertTrue(report["coverage"]["deadline_reached"])
            self.assertNotIn("/later", site.server.requests)
            later = next(edge for edge in report["link_edges"] if edge["destination_url"] == root + "later")
            self.assertEqual(later["check"]["state"], "unverified")
            self.assertEqual(later["check"]["reason"], "deadline")
            self.assertIsNone(later["check"]["final_status"])
        finally:
            site.close()

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
