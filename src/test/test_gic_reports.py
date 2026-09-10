"""Offline tests for GIC report discovery (gic_reports)."""

import inspect
import pathlib

from shared import gic_reports as gr

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
INDEX_HTML = (FIXTURES / "gic_index.html").read_text()


def test_catalogue_finds_every_document():
    reports = gr.parse_catalogue(gr.SEGMENT, INDEX_HTML)
    periods = {r.period for r in reports}
    # July/June/April 2026, Oct 2025, Jan/Feb 2026, FY 2024-25 = 7 documents.
    assert periods == {"2026-07", "2026-06", "2026-04", "2025-10",
                       "2026-01", "2026-02", "2024-25"}
    # The non-document /about-us link is ignored.
    assert all(r.fmt in ("xlsx", "pdf") for r in reports)


def test_period_parses_from_month_forms():
    assert gr.parse_period("Download July 2026") == ("2026-07", "July 2026")
    assert gr.parse_period("flash-report-Jan-2026.pdf") == ("2026-01", "January 2026")
    assert gr.parse_period("flash-report-feb-2026.pdf") == ("2026-02", "February 2026")
    assert gr.parse_period("flash-report-march-2026.pdf") == ("2026-03", "March 2026")
    assert gr.parse_period("flash-report-april-2026.pdf") == ("2026-04", "April 2026")


def test_period_parses_from_underscore_filenames():
    # \b does not fire between 'april' and '_2026' without normalisation.
    assert gr.parse_period("segment_april_2026.xlsx") == ("2026-04", "April 2026")
    assert gr.parse_period("GIC_Yearbook_2024-25.pdf") == ("2024-25", "FY 2024-25")


def test_both_path_schemes_resolve():
    reports = gr.parse_catalogue(gr.SEGMENT, INDEX_HTML)
    by_period = {r.period: r for r in reports}
    # current /Industry Statistics/... scheme
    assert "Industry%20Statistics" in by_period["2026-07"].url
    # older /media/<id>/... scheme
    assert "/media/8123/" in by_period["2025-10"].url
    assert all(r.url.startswith("https://www.gicouncil.in/") for r in reports)


def test_latest_selected_when_no_period(monkeypatch):
    reports = gr.parse_catalogue(gr.SEGMENT, INDEX_HTML)
    monkeypatch.setattr(gr, "build_catalogue", lambda family=gr.SEGMENT, refresh=False: reports)
    res = gr.resolve_report(gr.SEGMENT, None)
    assert res.report.period == "2026-07"
    assert res.fell_back is False and res.requested is None


def test_unknown_period_falls_back_to_latest(monkeypatch):
    reports = gr.parse_catalogue(gr.SEGMENT, INDEX_HTML)
    monkeypatch.setattr(gr, "build_catalogue", lambda family=gr.SEGMENT, refresh=False: reports)
    res = gr.resolve_report(gr.SEGMENT, "March 2019")
    assert res.report.period == "2026-07"
    assert res.fell_back is True
    assert res.requested == "March 2019"


def test_known_period_resolves_exactly(monkeypatch):
    reports = gr.parse_catalogue(gr.SEGMENT, INDEX_HTML)
    monkeypatch.setattr(gr, "build_catalogue", lambda family=gr.SEGMENT, refresh=False: reports)
    res = gr.resolve_report(gr.SEGMENT, "June 2026")
    assert res.report.period == "2026-06"
    assert res.fell_back is False


def test_unknown_family_raises():
    import pytest
    with pytest.raises(ValueError):
        gr.parse_catalogue("bogus", INDEX_HTML)


def test_no_public_entry_point_exposes_a_url_parameter():
    for name in ("parse_period", "parse_catalogue", "build_catalogue",
                 "available_periods", "resolve_report"):
        params = inspect.signature(getattr(gr, name)).parameters
        assert "url" not in params, f"{name} must not accept a url parameter"
