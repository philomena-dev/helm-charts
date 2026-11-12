#!/usr/bin/env python3
"""Finish the Helm repository site in a directory of chart packages.

Expects the directory to hold the packages and the index.yaml that
`helm repo index` made from them, and does two things:

1. Sets each index entry's `created` to the publication time of its GitHub
   release (`helm repo index` stamps every entry with the current time, on
   every run), when --releases is given.
2. Renders index.html from site/index.html.tmpl, with one card per chart,
   and puts the PhilomenaCSS stylesheet it uses next to it (installed by
   `npm ci --prefix site`).

Usage:
  build-site.py --site _site --repo-url https://charts.example.com \\
    --source-url https://github.com/owner/repo [--releases releases.json]

releases.json is the output of
`gh release list --json tagName,publishedAt`. Needs PyYAML.
"""
import argparse
import datetime
import html
import json
import pathlib
import shutil

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
MARKER = "<!-- CHART_CARDS -->"

# Subchart name -> (badge text, badge color of the framework)
DEPENDENCY_BADGES = {
    "cluster": ("CloudNativePG", "primary"),
    "opensearch": ("OpenSearch", "success"),
    "valkey": ("Valkey", "warning"),
    "infisical-secret": ("Infisical (optional)", "special"),
}


def plain(node):
    """PyYAML turns timestamps into datetimes; make them RFC 3339 strings
    again, which is what Helm reads."""
    if isinstance(node, dict):
        return {key: plain(value) for key, value in node.items()}
    if isinstance(node, list):
        return [plain(value) for value in node]
    if isinstance(node, datetime.datetime):
        if node.tzinfo is None:
            node = node.replace(tzinfo=datetime.timezone.utc)
        return node.isoformat().replace("+00:00", "Z")
    return node


def badge(text, color="", prefix=""):
    css = f"badge badge-{color}" if color else "badge"
    prefix = f'<span class="badge-prefix">{html.escape(prefix)}</span>' if prefix else ""
    return f'<span class="{css}">{prefix}<span class="badge-content">{html.escape(text)}</span></span>'


def button(text, href, color=""):
    css = f"button button-{color}" if color else "button"
    return (
        f'<a class="{css}" href="{html.escape(href, quote=True)}">'
        f'<span class="button-content"><span class="button-text">{html.escape(text)}</span></span></a>'
    )


def dependency_badges(chart):
    found = [
        DEPENDENCY_BADGES[dep["name"]]
        for dep in chart.get("dependencies", [])
        if dep["name"] in DEPENDENCY_BADGES
    ]
    if not found and "infisical" in chart.get("keywords", []):
        found = [("Infisical operator", "special")]
    if not found:
        found = [("No operators required", "")]
    return "\n".join(f"              {badge(text, color)}" for text, color in found)


def card(name, versions, source_url):
    latest = versions[0]
    tag = f"{name}-{latest['version']}"
    tree = f"{source_url}/tree/{tag}/charts/{name}"
    blob = f"{source_url}/blob/{tag}/charts/{name}"

    version_badges = [badge(latest["version"], "primary", "chart")]
    if latest.get("appVersion"):
        version_badges.append(badge(str(latest["appVersion"]), "", "app"))

    rows = "\n".join(
        "                      <tr>"
        f'<td><a href="{html.escape(entry["urls"][0], quote=True)}">{html.escape(entry["version"])}</a></td>'
        f'<td>{html.escape(str(entry.get("appVersion", "")))}</td>'
        f'<td>{html.escape(str(entry.get("created", ""))[:10])}</td>'
        "</tr>"
        for entry in versions
    )

    name = html.escape(name)
    return f"""          <article class="card">
            <header class="card-header flex flex-wrap items-center justify-between gap-md">
              <h3>{name}</h3>
              <span class="badge-group">{"".join(version_badges)}</span>
            </header>
            <p class="chart-description">{html.escape(latest.get("description", ""))}</p>
            <div class="badge-group">
{dependency_badges(latest)}
            </div>
            <pre class="code-block user-select-all">helm install {name} philomena/{name}</pre>
            <div class="button-group separated">
              {button("Documentation", f"{tree}#readme", "primary")}
              {button("Default values", f"{blob}/values.yaml")}
              {button("Download", latest["urls"][0])}
            </div>
            <div class="accordion">
              <details class="accordion-item">
                <summary class="accordion-item-header">All versions ({len(versions)})</summary>
                <div class="accordion-item-body">
                  <div class="table-wrap responsive">
                    <table class="table striped">
                      <thead>
                        <tr><th>Chart</th><th>Philomena</th><th>Released</th></tr>
                      </thead>
                      <tbody>
{rows}
                      </tbody>
                    </table>
                  </div>
                </div>
              </details>
            </div>
          </article>"""


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--site", required=True, type=pathlib.Path)
    parser.add_argument("--repo-url", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--releases", type=pathlib.Path)
    parser.add_argument(
        "--stylesheet",
        type=pathlib.Path,
        default=ROOT / "site/node_modules/@philomena/philomena-css/dist/philomena.min.css",
        help="PhilomenaCSS build to publish next to the page",
    )
    args = parser.parse_args()

    if not args.stylesheet.is_file():
        raise SystemExit(f"{args.stylesheet} is missing; run `npm ci --prefix site` first")
    shutil.copyfile(args.stylesheet, args.site / "philomena.min.css")

    index_path = args.site / "index.yaml"
    index = plain(yaml.safe_load(index_path.read_text()))
    entries = index.get("entries") or {}

    if args.releases:
        published = {
            release["tagName"]: release["publishedAt"]
            for release in json.loads(args.releases.read_text())
        }
        for name, versions in entries.items():
            for entry in versions:
                created = published.get(f"{name}-{entry['version']}")
                if created:
                    entry["created"] = created
        index_path.write_text(yaml.safe_dump(index, sort_keys=False))

    source_url = args.source_url.rstrip("/")
    cards = "\n".join(
        card(name, versions, source_url)
        # The main chart first, the rest by name
        for name, versions in sorted(entries.items(), key=lambda item: (item[0] != "philomena", item[0]))
        if versions
    )
    if not cards:
        cards = '          <div class="alert col-span-full">No chart has been released yet.</div>'

    page = (ROOT / "site" / "index.html.tmpl").read_text()
    if MARKER not in page:
        raise SystemExit(f"{MARKER} is missing from site/index.html.tmpl")
    page = (
        page.replace(MARKER, cards)
        .replace("@@REPO_URL@@", html.escape(args.repo_url.rstrip("/")))
        .replace("@@SOURCE_URL@@", html.escape(source_url, quote=True))
        .replace("@@UPDATED@@", datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
    )
    (args.site / "index.html").write_text(page)
    print(f"Wrote {args.site / 'index.html'} with {len(entries)} chart(s)")


if __name__ == "__main__":
    main()
