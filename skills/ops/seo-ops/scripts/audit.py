#!/usr/bin/env python3
"""Small, dependency-free SEO evidence collector.

This intentionally audits observable HTTP and HTML signals. It does not claim to
measure rankings, Search Console state, field performance, or rendered JavaScript.
"""

from __future__ import annotations

import argparse
import json
import re
import os
import sys
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET
from collections import deque
from dataclasses import dataclass, asdict
from html.parser import HTMLParser
from typing import Iterable
from urllib.parse import urljoin, urlparse, urlunparse

USER_AGENT = "seo-ops/0.1 (+https://github.com/fellowship-dev/dogfooded-skills)"
MAX_BODY = 2_000_000


@dataclass
class Finding:
    severity: str
    code: str
    url: str
    summary: str
    evidence: str


@dataclass
class Response:
    requested_url: str
    final_url: str
    status: int
    headers: dict[str, str]
    body: bytes
    redirects: list[dict[str, object]]
    error: str | None = None


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title = ""
        self._in_title = False
        self.lang = ""
        self.metas: list[dict[str, str]] = []
        self.links: list[dict[str, str]] = []
        self.anchors: list[str] = []
        self.authored_anchors: list[dict[str, str]] = []
        self._anchor: dict[str, str] | None = None
        self.images: list[dict[str, str]] = []
        self.h1: list[str] = []
        self._in_h1 = False
        self._h1_parts: list[str] = []
        self.jsonld: list[str] = []
        self._in_jsonld = False
        self._jsonld_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        data = {k.lower(): (v or "") for k, v in attrs}
        tag = tag.lower()
        if tag == "html":
            self.lang = data.get("lang", "")
        elif tag == "title":
            self._in_title = True
        elif tag == "meta":
            self.metas.append(data)
        elif tag == "link":
            self.links.append(data)
        elif tag == "a" and data.get("href"):
            self.anchors.append(data["href"])
            self._anchor = {"literal_href": data["href"], "anchor": "", "context": self.h1[-1] if self.h1 else ""}
            self.authored_anchors.append(self._anchor)
        elif tag == "img":
            self.images.append(data)
        elif tag == "h1":
            self._in_h1 = True
            self._h1_parts = []
        elif tag == "script" and data.get("type", "").lower() == "application/ld+json":
            self._in_jsonld = True
            self._jsonld_parts = []

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag == "a":
            self._anchor = None
        elif tag == "title":
            self._in_title = False
        elif tag == "h1" and self._in_h1:
            self.h1.append(" ".join("".join(self._h1_parts).split()))
            self._in_h1 = False
        elif tag == "script" and self._in_jsonld:
            self.jsonld.append("".join(self._jsonld_parts).strip())
            self._in_jsonld = False

    def handle_data(self, data: str) -> None:
        if self._anchor is not None:
            self._anchor["anchor"] += data
        if self._in_title:
            self.title += data
        if self._in_h1:
            self._h1_parts.append(data)
        if self._in_jsonld:
            self._jsonld_parts.append(data)


def normalized(url: str) -> str:
    parsed = urlparse(url)
    scheme = parsed.scheme.lower()
    host = (parsed.hostname or "").lower()
    port = parsed.port
    netloc = host
    if port and not ((scheme == "https" and port == 443) or (scheme == "http" and port == 80)):
        netloc = f"{host}:{port}"
    path = parsed.path or "/"
    return urlunparse((scheme, netloc, path, "", parsed.query, ""))


def fetch(url: str, timeout: float) -> Response:
    header_fd, header_path = tempfile.mkstemp(prefix="seo-ops-headers-")
    body_fd, body_path = tempfile.mkstemp(prefix="seo-ops-body-")
    os.close(header_fd)
    os.close(body_fd)
    try:
        command = [
            "curl", "-sS", "-L", "--compressed", "--max-redirs", "10", "--max-time", str(timeout),
            "--user-agent", USER_AGENT,
            "--header", "Accept: text/html,application/xml;q=0.9,*/*;q=0.8",
            "--dump-header", header_path,
            "--output", body_path,
            "--write-out", "%{http_code}\n%{url_effective}\n",
            url,
        ]
        completed = subprocess.run(command, capture_output=True, text=True, check=False)
        output = completed.stdout.splitlines()
        status = int(output[-2]) if len(output) >= 2 and output[-2].isdigit() else 0
        final_url = output[-1] if output else url
        with open(header_path, "r", encoding="iso-8859-1") as handle:
            raw_headers = handle.read()
        with open(body_path, "rb") as handle:
            body = handle.read(MAX_BODY)

        blocks = [block for block in re.split(r"\r?\n\r?\n", raw_headers) if block.startswith("HTTP/")]
        redirects: list[dict[str, object]] = []
        current_url = url
        final_headers: dict[str, str] = {}
        for block in blocks:
            lines = block.splitlines()
            match = re.match(r"HTTP/\S+\s+(\d+)", lines[0])
            block_status = int(match.group(1)) if match else 0
            block_headers: dict[str, str] = {}
            for line in lines[1:]:
                if ":" not in line:
                    continue
                key, value = line.split(":", 1)
                key = key.strip().lower()
                value = value.strip()
                block_headers[key] = f"{block_headers[key]}, {value}" if key in block_headers else value
            if 300 <= block_status < 400 and block_headers.get("location"):
                target = urljoin(current_url, block_headers["location"])
                redirects.append({"status": block_status, "from": current_url, "to": target, "location": block_headers["location"]})
                current_url = target
            elif block_status >= 200:
                final_headers = block_headers

        error = completed.stderr.strip() or None
        if completed.returncode != 0 and status == 0:
            return Response(url, final_url or url, 0, final_headers, body, redirects, error)
        return Response(url, final_url or url, status, final_headers, body, redirects, error)
    except (OSError, ValueError) as error:
        return Response(url, url, 0, {}, b"", [], str(error))
    finally:
        for path in (header_path, body_path):
            try:
                os.unlink(path)
            except OSError:
                pass


def parse_html(response: Response) -> PageParser | None:
    content_type = response.headers.get("content-type", "")
    if "html" not in content_type.lower() and not response.body.lstrip().startswith(b"<"):
        return None
    parser = PageParser()
    parser.feed(response.body.decode("utf-8", errors="replace"))
    parser.title = " ".join(parser.title.split())
    return parser


def meta(parser: PageParser, *names: str) -> str:
    wanted = {name.lower() for name in names}
    for item in parser.metas:
        key = (item.get("name") or item.get("property") or item.get("http-equiv") or "").lower()
        if key in wanted:
            return item.get("content", "").strip()
    return ""


def link_values(parser: PageParser, rel: str) -> list[dict[str, str]]:
    return [item for item in parser.links if rel in item.get("rel", "").lower().split()]


def add(findings: list[Finding], severity: str, code: str, url: str, summary: str, evidence: str) -> None:
    findings.append(Finding(severity, code, url, summary, evidence[:1000]))


def audit_page(response: Response, parser: PageParser | None, findings: list[Finding]) -> list[str]:
    url = response.final_url
    if response.status != 200:
        add(findings, "Critical" if response.status == 0 else "High", "http-status", response.requested_url, f"Page returned HTTP {response.status or 'error'}", response.error or str(response.redirects))
        return []
    if urlparse(url).scheme != "https":
        add(findings, "High", "not-https", url, "Final URL is not HTTPS", url)
    if len(response.redirects) > 1:
        add(findings, "Medium", "redirect-chain", response.requested_url, "Request uses more than one redirect", json.dumps(response.redirects))
    if not parser:
        add(findings, "High", "not-html", url, "Successful response was not parseable HTML", response.headers.get("content-type", "missing content-type"))
        return []

    canonicals = link_values(parser, "canonical")
    if not canonicals:
        add(findings, "Medium", "canonical-missing", url, "No HTML canonical found", "Rendered DOM still requires browser verification")
    elif len(canonicals) > 1:
        add(findings, "High", "canonical-multiple", url, "Multiple HTML canonicals found", json.dumps(canonicals))
    else:
        raw_canonical = canonicals[0].get("href", "")
        canonical = urljoin(url, raw_canonical)
        if normalized(canonical) != normalized(url):
            add(findings, "High", "canonical-not-self", url, "Canonical differs from the final page URL", f"canonical={canonical}; final={url}")
        if not urlparse(raw_canonical).scheme or not urlparse(raw_canonical).netloc:
            add(findings, "Medium", "canonical-relative", url, "Canonical is not absolute", raw_canonical)

    robots = " ".join([meta(parser, "robots"), response.headers.get("x-robots-tag", "")]).lower()
    if "noindex" in robots:
        add(findings, "Critical", "noindex", url, "Page tells search engines not to index it", robots)
    if not parser.title:
        add(findings, "High", "title-missing", url, "Page has no title", "")
    if not meta(parser, "description"):
        add(findings, "Medium", "description-missing", url, "Page has no meta description", "")
    if len(parser.h1) != 1:
        add(findings, "Medium", "h1-count", url, f"Page has {len(parser.h1)} H1 elements", json.dumps(parser.h1))
    if not parser.lang:
        add(findings, "Medium", "html-lang-missing", url, "HTML language is missing", "")

    alternates = [item for item in link_values(parser, "alternate") if item.get("hreflang")]
    seen_langs: set[str] = set()
    for item in alternates:
        lang = item.get("hreflang", "").lower()
        href = urljoin(url, item.get("href", ""))
        if lang in seen_langs:
            add(findings, "High", "hreflang-duplicate", url, f"Duplicate hreflang value: {lang}", href)
        seen_langs.add(lang)
        if urlparse(href).scheme != "https":
            add(findings, "High", "hreflang-not-https", url, f"Hreflang {lang} is not HTTPS", href)
    if alternates and not any(normalized(urljoin(url, item.get("href", ""))) == normalized(url) for item in alternates):
        add(findings, "High", "hreflang-no-self", url, "Hreflang cluster has no self-reference", json.dumps(alternates))

    if not meta(parser, "og:title") or not meta(parser, "og:description"):
        add(findings, "Low", "open-graph-incomplete", url, "Open Graph title/description is incomplete", "")
    og_url = meta(parser, "og:url")
    if og_url and normalized(urljoin(url, og_url)) != normalized(url):
        add(findings, "Medium", "og-url-conflict", url, "og:url differs from final URL", og_url)

    if not parser.jsonld:
        add(findings, "Info", "jsonld-static-missing", url, "No JSON-LD found in response HTML", "Browser evidence required before reporting it as missing")
    for index, raw in enumerate(parser.jsonld):
        try:
            json.loads(raw)
        except json.JSONDecodeError as error:
            add(findings, "High", "jsonld-invalid", url, f"Static JSON-LD block {index + 1} is invalid JSON", str(error))

    missing_alt = [image.get("src", "") for image in parser.images if "alt" not in image]
    if missing_alt:
        add(findings, "Medium", "image-alt-missing", url, f"{len(missing_alt)} images omit the alt attribute", json.dumps(missing_alt[:10]))

    result: list[str] = []
    host = urlparse(url).netloc.lower()
    for href in parser.anchors:
        absolute = normalized(urljoin(url, href))
        parsed = urlparse(absolute)
        if parsed.scheme in {"http", "https"} and parsed.netloc.lower() == host:
            result.append(absolute)
    return result


def discover_sitemaps(origin: str, robots: Response) -> list[str]:
    result: list[str] = []
    if robots.status == 200:
        text = robots.body.decode("utf-8", errors="replace")
        result.extend(match.strip() for match in re.findall(r"(?im)^\s*Sitemap:\s*(\S+)", text))
    if not result:
        result.extend([urljoin(origin, "/sitemap.xml"), urljoin(origin, "/sitemap_index.xml")])
    return list(dict.fromkeys(result))


def audit_site(args: argparse.Namespace) -> dict[str, object]:
    root = normalized(args.url)
    origin_parsed = urlparse(root)
    origin = f"{origin_parsed.scheme}://{origin_parsed.netloc}"
    findings: list[Finding] = []
    pages: list[dict[str, object]] = []
    declared_legacy = {normalized(url) for url in getattr(args, "legacy_url", [])}
    queue = deque(dict.fromkeys([root, *sorted(declared_legacy)]))
    queued = set(queue)
    edges: list[dict[str, object]] = []
    observations: dict[str, dict[str, object]] = {}
    deadline = time.monotonic() + getattr(args, "deadline", 300.0)

    def bounded_fetch(url: str) -> Response:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return Response(url, url, 0, {}, b"", [], "collection deadline reached")
        return fetch(url, min(args.timeout, remaining))

    while queue and len(pages) < args.max_pages and time.monotonic() < deadline:
        target = queue.popleft()
        response = bounded_fetch(target)
        parser = parse_html(response)
        internal = audit_page(response, parser, findings)
        canonical_links = link_values(parser, "canonical") if parser else []
        canonical = urljoin(response.final_url, canonical_links[0]["href"]) if len(canonical_links) == 1 and canonical_links[0].get("href") else None
        first_status = response.redirects[0]["status"] if response.redirects else response.status
        observations[target] = {
            "state": "checked", "reason": None, "first_status": first_status or None,
            "redirects": response.redirects, "final_url": response.final_url,
            "final_status": response.status or None, "canonical": canonical,
            "locale": (parser.lang or None) if parser else None, "error": response.error,
        }
        pages.append({
            "requested_url": target,
            "final_url": response.final_url,
            "status": response.status,
            "redirects": response.redirects,
            "title": parser.title if parser else "",
            "lang": parser.lang if parser else "",
            "canonical": canonical,
            "first_status": first_status,
            "robots": " ".join(filter(None, [meta(parser, "robots") if parser else "", response.headers.get("x-robots-tag", "")])),
            "error": response.error,
        })
        if parser:
            for anchor in parser.authored_anchors:
                destination = normalized(urljoin(response.final_url, anchor["literal_href"]))
                if urlparse(destination).scheme not in {"http", "https"}:
                    continue
                in_scope = urlparse(destination).netloc.lower() == origin_parsed.netloc.lower() or destination in declared_legacy
                edges.append({"source_url": response.final_url, **anchor, "anchor": " ".join(anchor["anchor"].split()), "destination_url": destination, "_in_scope": in_scope})
        for candidate in internal:
            if urlparse(candidate).netloc.lower() != origin_parsed.netloc.lower() and candidate not in declared_legacy:
                continue
            if candidate not in queued and len(queued) < args.max_pages * 5:
                queued.add(candidate)
                queue.append(candidate)

    robots_url = urljoin(origin, "/robots.txt")
    robots = bounded_fetch(robots_url)
    if robots.status != 200:
        add(findings, "Medium", "robots-unavailable", robots_url, f"robots.txt returned HTTP {robots.status or 'error'}", robots.error or "")
    else:
        robots_text = robots.body.decode("utf-8", errors="replace")
        if re.search(r"(?im)User-agent:\s*\*.*?Disallow:\s*/\s*(?:$|\n)", robots_text):
            add(findings, "Critical", "robots-block-all", robots_url, "robots.txt appears to block all crawling", robots_text[:500])

    sitemap_results: list[dict[str, object]] = []
    for sitemap_url in discover_sitemaps(origin, robots):
        response = bounded_fetch(sitemap_url)
        row: dict[str, object] = {"url": sitemap_url, "status": response.status, "valid_xml": False}
        if response.status == 200:
            try:
                root_node = ET.fromstring(response.body)
                row["valid_xml"] = True
                row["root"] = root_node.tag
            except ET.ParseError as error:
                add(findings, "High", "sitemap-invalid", sitemap_url, "Sitemap is not valid XML", str(error))
        sitemap_results.append(row)
    if not any(row["status"] == 200 and row["valid_xml"] for row in sitemap_results):
        add(findings, "High", "sitemap-missing", origin, "No valid sitemap was discovered", json.dumps(sitemap_results))

    compare_results: list[dict[str, object]] = []
    for compare_origin in args.compare_origin:
        compare_url = urljoin(compare_origin.rstrip("/") + "/", origin_parsed.path.lstrip("/"))
        if origin_parsed.query:
            compare_url += "?" + origin_parsed.query
        response = bounded_fetch(compare_url)
        compare_results.append({"requested_url": compare_url, "final_url": response.final_url, "status": response.status, "redirects": response.redirects})
        if response.status == 200 and urlparse(response.final_url).netloc.lower() != origin_parsed.netloc.lower():
            add(findings, "Critical", "duplicate-host", compare_url, "Alternate origin serves content instead of redirecting to the canonical origin", f"final={response.final_url}; redirects={json.dumps(response.redirects)}")
        elif response.status == 200 and not response.redirects:
            add(findings, "Critical", "alternate-host-200", compare_url, "Alternate origin returns 200 without a canonical-host redirect", response.final_url)
        elif response.redirects and len(response.redirects) > 1:
            add(findings, "Medium", "alternate-host-chain", compare_url, "Alternate-origin redirect takes more than one hop", json.dumps(response.redirects))

    for edge in edges:
        in_scope = edge.pop("_in_scope")
        destination = edge["destination_url"]
        observed = observations.get(destination)
        if observed is not None and in_scope:
            edge["check"] = dict(observed)
            if observed["final_status"] is None:
                edge["check"]["state"] = "unverified"
                edge["check"]["reason"] = "deadline" if time.monotonic() >= deadline else "transport-error"
            if observed["final_status"] is not None and observed["final_status"] != 200:
                add(findings, "High", "authored-link-http-status", edge["source_url"], "Authored link destination did not return HTTP 200", json.dumps(edge))
        else:
            edge["check"] = {
                "state": "unverified", "reason": "outside-scope" if not in_scope else "deadline" if time.monotonic() >= deadline else "page-cap",
                "first_status": None, "redirects": [], "final_url": None,
                "final_status": None, "canonical": None, "locale": None, "error": None,
            }

    severity_order = {"Critical": 0, "High": 1, "Medium": 2, "Low": 3, "Info": 4}
    findings.sort(key=lambda item: (severity_order[item.severity], item.url, item.code))
    return {
        "tool": "seo-ops",
        "version": "0.2",
        "root": root,
        "pages_sampled": pages,
        "link_edges": edges,
        "coverage": {"page_cap": args.max_pages, "deadline_seconds": getattr(args, "deadline", 300.0), "deadline_reached": time.monotonic() >= deadline, "unchecked_edges": sum(edge["check"]["state"] == "unverified" for edge in edges), "unvisited_urls": list(queue)},
        "robots": {"url": robots_url, "status": robots.status},
        "sitemaps": sitemap_results,
        "compare_origins": compare_results,
        "findings": [asdict(item) for item in findings],
        "counts": {severity: sum(1 for item in findings if item.severity == severity) for severity in severity_order},
        "limitations": [
            "Static HTTP/HTML evidence only; use a real browser for rendered DOM and interactive checks.",
            "Search Console, rankings, backlinks, field Core Web Vitals, and content quality are not measured.",
            "The crawl is a bounded sample, not a complete site inventory.",
        ],
    }


def markdown(report: dict[str, object]) -> str:
    counts = report["counts"]
    lines = [
        "# SEO audit",
        "",
        f"Root: `{report['root']}`",
        f"Pages sampled: {len(report['pages_sampled'])}",
        "",
        "## Outcome",
        "",
        ", ".join(f"{name}: {value}" for name, value in counts.items()),
        "",
        "## Findings",
        "",
    ]
    findings = report["findings"]
    if not findings:
        lines.append("No static findings in the sampled scope. Browser/manual controls still apply.")
    for item in findings:
        lines.extend([
            f"### {item['severity']} — {item['summary']}",
            "",
            f"- Code: `{item['code']}`",
            f"- URL: `{item['url']}`",
            f"- Evidence: `{item['evidence']}`",
            "",
        ])
    lines.extend(["## Limitations", ""])
    lines.extend(f"- {item}" for item in report["limitations"])
    return "\n".join(lines) + "\n"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Collect repeatable static SEO evidence")
    result.add_argument("url", help="canonical root or representative page URL")
    result.add_argument("--compare-origin", action="append", default=[], help="alternate origin to test for canonical-host redirects; repeatable")
    result.add_argument("--legacy-url", action="append", default=[], help="explicit legacy destination URL to verify; repeatable, does not authorize crawling its origin")
    result.add_argument("--deadline", type=float, default=300.0, help="total collection deadline seconds (default: 300)")
    result.add_argument("--max-pages", type=int, default=10, help="bounded same-origin page sample (default: 10)")
    result.add_argument("--timeout", type=float, default=15.0, help="per-request timeout seconds")
    result.add_argument("--format", choices=["markdown", "json"], default="markdown")
    result.add_argument("--output", help="write output to this path instead of stdout")
    return result


def main() -> int:
    args = parser().parse_args()
    if args.max_pages < 1 or args.max_pages > 500:
        print("--max-pages must be between 1 and 500", file=sys.stderr)
        return 2
    if args.deadline <= 0 or args.timeout <= 0:
        print("--deadline and --timeout must be positive", file=sys.stderr)
        return 2
    report = audit_site(args)
    output = json.dumps(report, indent=2, sort_keys=True) + "\n" if args.format == "json" else markdown(report)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(output)
    else:
        sys.stdout.write(output)
    return 1 if report["counts"]["Critical"] or report["counts"]["High"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
