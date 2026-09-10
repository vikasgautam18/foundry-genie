"""GIC report discovery.

Reads the General Insurance Council index pages and turns the document anchors
into :class:`Report` records. The period is parsed *from the page*, never
constructed from a URL template — filenames are inconsistent, path schemes
change over time, and a missing file returns HTTP 200 with the SPA shell rather
than a 404 (see the module notes in the implementation spec).

Pure helpers (``parse_period``, ``parse_catalogue``) take text/HTML so they can
be unit-tested with no network. ``build_catalogue`` / ``resolve_report`` add a
short-lived in-process cache around the network fetch.
"""

from __future__ import annotations

import html
import logging
import re
import time
from dataclasses import dataclass
from html.parser import HTMLParser

import requests

logger = logging.getLogger(__name__)

BASE_URL = "https://www.gicouncil.in"

SEGMENT = "segment"
FLASH = "flash"
YEARBOOK = "yearbook"

FAMILY_INDEX = {
    SEGMENT: "/segmentwise-report",
    FLASH: "/flash-figures",
    YEARBOOK: "/years-archives",
}

_CATALOGUE_TTL = 3600.0  # 1 hour

_MONTHS = {
    "jan": 1, "january": 1,
    "feb": 2, "february": 2,
    "mar": 3, "march": 3,
    "apr": 4, "april": 4,
    "may": 5,
    "jun": 6, "june": 6,
    "jul": 7, "july": 7,
    "aug": 8, "august": 8,
    "sep": 9, "sept": 9, "september": 9,
    "oct": 10, "october": 10,
    "nov": 11, "november": 11,
    "dec": 12, "december": 12,
}
_MONTH_NAMES = [
    "", "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]
_MONTH_ALT = "|".join(sorted(_MONTHS, key=len, reverse=True))

# FY 2024-25 / FY 2024-2025 / 2024-25 (yearbook)
_FY_RE = re.compile(r"\b(?:FY\s*)?(20\d{2})\s*[-/]\s*(\d{2,4})\b", re.IGNORECASE)
_MONTH_RE = re.compile(rf"\b({_MONTH_ALT})\b[\s,.\-/]*?(20\d{{2}})\b", re.IGNORECASE)


@dataclass(frozen=True)
class Report:
    family: str
    period: str          # "2026-07" monthly, "2024-25" yearbook
    period_label: str    # "July 2026", "FY 2024-25"
    url: str
    fmt: str             # "xlsx" | "pdf"


@dataclass(frozen=True)
class Resolution:
    report: Report
    requested: str | None = None
    fell_back: bool = False


def _normalise(text: str) -> str:
    """Unescape entities and turn separators (``_``, ``%20``) into spaces.

    Critical: ``\\b`` does not fire between ``april`` and ``_2026`` because ``_``
    is a word character, so ``segment_april_2026.xlsx`` would not match without
    this normalisation.
    """
    if not text:
        return ""
    text = html.unescape(text)
    text = text.replace("%20", " ")
    text = re.sub(r"[_]+", " ", text)
    return text


def parse_period(text: str) -> tuple[str, str] | None:
    """Return ``(period, period_label)`` parsed from *text*, or ``None``.

    Monthly → ``("2026-07", "July 2026")``. Yearbook → ``("2024-25", "FY 2024-25")``.
    Pure and side-effect free.
    """
    cleaned = _normalise(text)

    m = _MONTH_RE.search(cleaned)
    if m:
        month = _MONTHS[m.group(1).lower()]
        year = int(m.group(2))
        return f"{year:04d}-{month:02d}", f"{_MONTH_NAMES[month]} {year}"

    fy = _FY_RE.search(cleaned)
    if fy:
        start = fy.group(1)
        end = fy.group(2)
        end2 = end[-2:]  # normalise 2025 -> 25
        return f"{start}-{end2}", f"FY {start}-{end2}"

    return None


class _AnchorParser(HTMLParser):
    """Collect ``(href, text)`` pairs for document anchors."""

    def __init__(self) -> None:
        super().__init__()
        self._href: str | None = None
        self._text: list[str] = []
        self.anchors: list[tuple[str, str]] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href")
            self._href = href
            self._text = []

    def handle_data(self, data):
        if self._href is not None:
            self._text.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._href is not None:
            self.anchors.append((self._href, "".join(self._text).strip()))
            self._href = None
            self._text = []


def _fmt_from_href(href: str) -> str | None:
    low = href.lower().split("?", 1)[0]
    if low.endswith(".xlsx") or low.endswith(".xls"):
        return "xlsx"
    if low.endswith(".pdf"):
        return "pdf"
    return None


def _absolute(href: str) -> str:
    if href.startswith("http://") or href.startswith("https://"):
        return href
    if not href.startswith("/"):
        href = "/" + href
    return BASE_URL + href


def parse_catalogue(family: str, index_html: str) -> list[Report]:
    """Parse document anchors from *index_html* into ``Report`` records.

    Period is taken from the anchor **text** first, falling back to the href
    (the filename), so both label styles resolve. Supports both the current
    ``/Industry Statistics/.../Year_YYYY/`` and the older ``/media/<id>/...``
    path schemes. Pure — no network.
    """
    if family not in FAMILY_INDEX:
        raise ValueError(f"Unknown report family: {family!r}")

    parser = _AnchorParser()
    parser.feed(index_html)

    seen: set[str] = set()
    reports: list[Report] = []
    for href, text in parser.anchors:
        fmt = _fmt_from_href(href)
        if fmt is None:
            continue  # not a document link
        parsed = parse_period(text) or parse_period(href)
        if parsed is None:
            continue
        period, label = parsed
        url = _absolute(href)
        key = f"{period}:{url}"
        if key in seen:
            continue
        seen.add(key)
        reports.append(Report(family=family, period=period, period_label=label, url=url, fmt=fmt))

    # Newest first (period strings sort correctly for both monthly and FY forms).
    reports.sort(key=lambda r: r.period, reverse=True)
    return reports


# ── network + cache ──────────────────────────────────────────────────

_cache: dict[str, tuple[float, list[Report]]] = {}
_last_good: dict[str, list[Report]] = {}


def _fetch_index(family: str, *, timeout: float = 30.0) -> str:
    resp = requests.get(BASE_URL + FAMILY_INDEX[family], timeout=timeout)
    resp.raise_for_status()
    return resp.text


def build_catalogue(family: str = SEGMENT, *, refresh: bool = False) -> list[Report]:
    """Return the catalogue for *family*, cached for ~1h with a last-good fallback."""
    if family not in FAMILY_INDEX:
        raise ValueError(f"Unknown report family: {family!r}")

    now = time.time()
    if not refresh:
        hit = _cache.get(family)
        if hit and (now - hit[0]) < _CATALOGUE_TTL:
            return hit[1]

    try:
        reports = parse_catalogue(family, _fetch_index(family))
        if reports:
            _cache[family] = (now, reports)
            _last_good[family] = reports
        return reports
    except Exception:
        logger.exception("Failed to build catalogue for %s; using last-good", family)
        if family in _last_good:
            return _last_good[family]
        raise


def available_periods(family: str = SEGMENT) -> list[str]:
    """Return published period strings (newest first)."""
    return [r.period for r in build_catalogue(family)]


def resolve_report(family: str = SEGMENT, period: str | None = None) -> Resolution:
    """Resolve a report for *family*/*period*.

    ``period=None`` returns the newest (the normal path). A named period that is
    not published returns the newest with ``fell_back=True`` and ``requested``
    set, so the caller can say so rather than silently substituting.
    """
    catalogue = build_catalogue(family)
    if not catalogue:
        raise RuntimeError(f"No reports found for family {family!r}")

    if period is None:
        return Resolution(report=catalogue[0])

    want = parse_period(period)
    want_key = want[0] if want else period
    for r in catalogue:
        if r.period == want_key:
            return Resolution(report=r, requested=period)

    return Resolution(report=catalogue[0], requested=period, fell_back=True)
