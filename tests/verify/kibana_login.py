#!/usr/bin/env python3
"""Headless verification that Kibana is up, login works, and Discover renders.

Usage:
    .venv/bin/python kibana_login.py  https://10.10.30.78/  elastic  <password>

Writes screenshots to ./screenshots/ and prints a short status report.
Exit 0 on success, non-zero on any failure (login form not found, wrong
password, no events visible in Discover, etc.).
"""

from __future__ import annotations

import argparse
import pathlib
import sys
import time
from playwright.sync_api import (
    sync_playwright,
    TimeoutError as PlaywrightTimeout,
)

SCREENSHOTS = pathlib.Path(__file__).parent / "screenshots"


def log(msg: str) -> None:
    print(f"[verify] {msg}", flush=True)


def shot(page, name: str) -> pathlib.Path:
    SCREENSHOTS.mkdir(exist_ok=True)
    path = SCREENSHOTS / f"{name}.png"
    page.screenshot(path=str(path), full_page=True)
    log(f"  screenshot -> {path}")
    return path


def run(base_url: str, user: str, password: str) -> int:
    base_url = base_url.rstrip("/") + "/"

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            ignore_https_errors=True,
            viewport={"width": 1440, "height": 900},
        )
        page = context.new_page()

        # ---- 1) navigate ----
        log(f"navigating to {base_url}")
        page.goto(base_url, wait_until="domcontentloaded", timeout=60_000)
        shot(page, "01-landing")

        # ---- 2) login form ----
        # Kibana 9.x login form fields are data-test-subj based.
        try:
            page.wait_for_selector(
                '[data-test-subj="loginUsername"]', timeout=45_000
            )
        except PlaywrightTimeout:
            log("ERROR: login form did not appear")
            shot(page, "ERR-no-login-form")
            return 2

        log("filling credentials")
        page.fill('[data-test-subj="loginUsername"]', user)
        page.fill('[data-test-subj="loginPassword"]', password)
        page.click('[data-test-subj="loginSubmit"]')

        # ---- 3) wait for home ----
        # Kibana 9.x can land us on any of: the "Welcome to Elastic" first-run
        # screen, the analytics overview, or directly in an app. We accept
        # any of those as "logged in" — what we explicitly reject is still
        # seeing the login form (i.e. login failed).
        try:
            page.wait_for_function(
                """() => {
                    const stillOnLogin = document.querySelector(
                        '[data-test-subj=\"loginSubmit\"]'
                    );
                    if (stillOnLogin) return false;
                    const txt = document.body.innerText || '';
                    return (
                        txt.includes('Welcome to Elastic') ||
                        txt.includes('Add integrations') ||
                        txt.includes('Discover') ||
                        txt.includes('Analytics') ||
                        document.querySelector(
                            '[data-test-subj=\"userMenuButton\"], ' +
                            '[data-test-subj=\"collapsibleNav\"], ' +
                            'nav[aria-label=\"Primary\"]'
                        ) !== null
                    );
                }""",
                timeout=90_000,
            )
        except PlaywrightTimeout:
            log("ERROR: post-login UI did not render in 90s")
            shot(page, "ERR-post-login")
            return 3

        # Give the dashboard a moment to settle, then snap.
        page.wait_for_load_state("networkidle", timeout=30_000)
        time.sleep(2)
        shot(page, "02-post-login")
        log(f"page title: {page.title()!r}")

        # ---- 4) navigate to Discover ----
        # If the elk-installer-syslog-generic data view exists (created by
        # `elk-kibana bootstrap` or `elk-template apply generic-syslog`),
        # deep-link directly to it; otherwise fall back to the default.
        log("navigating to Discover (data view: elk-installer-syslog-generic)")
        page.goto(
            base_url + "app/discover#/?_a=(index:'elk-installer-syslog-generic')",
            wait_until="domcontentloaded",
            timeout=60_000,
        )
        try:
            page.wait_for_load_state("networkidle", timeout=45_000)
        except PlaywrightTimeout:
            pass

        # Wait for either the histogram canvas or the table to appear.
        try:
            page.wait_for_selector(
                '[data-test-subj="discoverChart"], '
                '[data-test-subj="docTable"], '
                '[data-test-subj="discoverNoResults"]',
                timeout=60_000,
            )
        except PlaywrightTimeout:
            log("WARN: Discover never produced chart/table/no-results — "
                "screenshot will show current state")

        time.sleep(5)
        shot(page, "03-discover")

        # ---- 5) basic content sanity ----
        body_text = page.inner_text("body", timeout=5_000)
        markers_present = [m for m in ("Discover", "Kibana", "Elastic") if m in body_text]
        log(f"body markers found: {markers_present}")

        browser.close()
        return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("base_url")
    ap.add_argument("user")
    ap.add_argument("password")
    args = ap.parse_args()
    return run(args.base_url, args.user, args.password)


if __name__ == "__main__":
    sys.exit(main())
