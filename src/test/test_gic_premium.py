"""Offline tests for GIC workbook parsing, fetch guards, matching, and the tool."""

import inspect
import json

import pytest

from shared import gic_premium as gp
from shared import gic_reports as gr
from test.fixtures.gic_workbook import build_workbook_bytes

WORKBOOK_BYTES = build_workbook_bytes()


def _wb():
    return gp.load_workbook(WORKBOOK_BYTES)


# ── parsing ───────────────────────────────────────────────────────────

def test_all_four_sheets_parse_with_enough_insurers():
    wb = _wb()
    for key in ("segment", "health", "liability", "miscellaneous"):
        sheet = gp.parse_sheet(wb, key)
        assert len(sheet.insurers) >= 5, f"{key} parsed too few insurers"


def test_header_row_correct_per_sheet():
    wb = _wb()
    seg = gp.parse_sheet(wb, "segment")
    health = gp.parse_sheet(wb, "health")
    assert "Motor Total" in seg.columns
    assert "Health-Retail" in health.columns
    # Segment sheet must NOT expose health columns (proves the right header row).
    assert "Health-Retail" not in seg.columns


def test_double_spaced_marine_headers_are_normalised():
    seg = gp.parse_sheet(_wb(), "segment")
    assert "Marine Cargo" in seg.columns
    assert "Marine Hull" in seg.columns
    assert "Marine  Cargo" not in seg.columns  # double space collapsed


def test_icici_lombard_ground_truth():
    seg = gp.parse_sheet(_wb(), "segment")
    icici = next(r for r in seg.insurers if r.name.startswith("ICICI Lombard"))
    assert icici.values["Fire"] == 1247.97
    assert icici.values["Motor Total"] == 3755.91
    assert icici.values["Grand Total"] == 10723.58
    # Previous-year row pairs with the right insurer.
    assert icici.previous_year["Motor Total"] == 3270.75


def test_aggregates_excluded_from_insurers_and_present_in_aggregates():
    seg = gp.parse_sheet(_wb(), "segment")
    names = [r.name for r in seg.insurers]
    assert not any("Sub Total" in n or "Industry Total" in n or "% Growth" in n
                   for n in names)
    assert "Industry Total" in seg.aggregates
    assert "General Insurers Sub Total" in seg.aggregates


def test_missing_sheet_raises():
    wb = _wb()
    with pytest.raises(gp.GicWorkbookError):
        gp.parse_sheet(wb, "nonexistent_key")


def test_header_less_rows_raise():
    with pytest.raises(gp.GicWorkbookError):
        gp.find_header_row([[None], ["only one label"], [1, 2, 3]])


# ── fetch guards ──────────────────────────────────────────────────────

class _Resp:
    def __init__(self, content, ctype):
        self.content = content
        self.headers = {"Content-Type": ctype}

    def raise_for_status(self):
        pass


def test_html_content_type_rejected(monkeypatch):
    monkeypatch.setattr(gp.requests, "get",
                        lambda url, timeout=60.0: _Resp(b"PK\x03\x04", "text/html"))
    with pytest.raises(gp.GicWorkbookError):
        gp.fetch_workbook("http://x")


def test_non_pk_payload_rejected_even_with_spreadsheet_ctype(monkeypatch):
    ctype = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    monkeypatch.setattr(gp.requests, "get",
                        lambda url, timeout=60.0: _Resp(b"<html> app shell", ctype))
    with pytest.raises(gp.GicWorkbookError):
        gp.fetch_workbook("http://x")


def test_valid_pk_payload_accepted(monkeypatch):
    ctype = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    monkeypatch.setattr(gp.requests, "get",
                        lambda url, timeout=60.0: _Resp(WORKBOOK_BYTES, ctype))
    data = gp.fetch_workbook("http://x")
    assert data[:2] == b"PK"


# ── insurer matching ──────────────────────────────────────────────────

def _insurers():
    return gp.parse_sheet(_wb(), "segment").insurers


def test_common_name_resolves_to_registered_name():
    matches, _ = gp.resolve_insurer("ICICI Lombard", _insurers())
    assert [m.name for m in matches] == ["ICICI Lombard General Insurance Co Ltd"]


def test_rebrand_resolves_through_alias_map():
    matches, _ = gp.resolve_insurer("Bajaj Allianz", _insurers())
    assert [m.name for m in matches] == ["Bajaj General Insurance Limited"]
    matches, _ = gp.resolve_insurer("Edelweiss", _insurers())
    assert [m.name for m in matches] == ["Zuno General Insurance Co Ltd"]


def test_hdfc_life_does_not_return_hdfc_ergo():
    with pytest.raises(gp.LifeInsurerRequested):
        gp.resolve_insurer("HDFC Life", _insurers())


@pytest.mark.parametrize("name", ["HDFC Life", "SBI Life", "ICICI Prudential Life",
                                  "Max Life", "LIC"])
def test_life_insurers_raise(name):
    with pytest.raises(gp.LifeInsurerRequested):
        gp.resolve_insurer(name, _insurers())


def test_non_life_lookalikes_still_resolve():
    # These contain "assurance"/"india" but are genuine non-life insurers.
    matches, _ = gp.resolve_insurer("New India Assurance", _insurers())
    assert matches and "New India Assurance" in matches[0].name


def test_unknown_name_returns_candidates():
    matches, candidates = gp.resolve_insurer("Totally Unknown Insurer", _insurers())
    assert matches == []
    assert len(candidates) >= 5


def test_every_alias_target_exists_in_the_sheet():
    names = {r.name for r in _insurers()}
    for target in gp._ALIASES.values():
        assert target in names, f"alias target not in sheet: {target}"


# ── tool entry point ──────────────────────────────────────────────────

def _patch_network(monkeypatch, period_label="July 2026", period="2026-07",
                   fell_back=False, requested=None):
    report = gr.Report(family="segment", period=period, period_label=period_label,
                       url="https://www.gicouncil.in/x/segment_july_2026.xlsx", fmt="xlsx")
    monkeypatch.setattr(gr, "resolve_report",
                        lambda family=gr.SEGMENT, period=None:
                        gr.Resolution(report=report, requested=requested, fell_back=fell_back))
    monkeypatch.setattr(gp, "fetch_workbook", lambda url, timeout=60.0: WORKBOOK_BYTES)
    gp._workbook_cache.clear()
    gp._workbook_last_good.clear()


def test_tool_payload_has_provenance_and_values(monkeypatch):
    _patch_network(monkeypatch)
    out = json.loads(gp.query_industry_premium(
        insurers=["ICICI Lombard"], segments=["Motor Total"], include_previous_year=True))
    assert out["measure"] == "Gross Direct Premium Income"
    assert out["units"] == "INR crore"
    assert out["period"] == "July 2026"
    assert out["provisional"] is True
    assert out["source_url"].endswith(".xlsx")
    assert out["rows"][0]["values"]["Motor Total"] == 3755.91
    assert out["rows"][0]["previous_year"]["Motor Total"] == 3270.75


def test_tool_top_n_ranking(monkeypatch):
    _patch_network(monkeypatch)
    out = json.loads(gp.query_industry_premium(segments=["Grand Total"], top_n=3))
    grand = [r["values"]["Grand Total"] for r in out["rows"]]
    assert grand == sorted(grand, reverse=True)
    assert len(out["rows"]) == 3


def test_tool_flags_life_insurers(monkeypatch):
    _patch_network(monkeypatch)
    out = json.loads(gp.query_industry_premium(insurers=["SBI Life"]))
    assert out["life_insurers_requested"] == ["SBI Life"]
    assert "life_note" in out


def test_tool_reports_period_fallback(monkeypatch):
    _patch_network(monkeypatch, fell_back=True, requested="March 2019")
    out = json.loads(gp.query_industry_premium(insurers=["ICICI Lombard"], period="March 2019"))
    assert out["fell_back"] is True
    assert out["period_requested"] == "March 2019"


def test_tool_reports_unmatched(monkeypatch):
    _patch_network(monkeypatch)
    out = json.loads(gp.query_industry_premium(insurers=["Nope Insurer"]))
    assert out["unmatched_insurers"][0]["requested"] == "Nope Insurer"
    assert out["unmatched_insurers"][0]["candidates"]


def test_tool_fails_closed(monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("kaboom")
    monkeypatch.setattr(gr, "resolve_report", boom)
    out = json.loads(gp.query_industry_premium(insurers=["ICICI Lombard"]))
    assert "error" in out
    assert "rows" not in out


def test_schema_has_no_url_parameter():
    assert "url" not in gp.GIC_PREMIUM_SCHEMA["properties"]
    # tool function signature also has no url parameter
    assert "url" not in inspect.signature(gp.query_industry_premium).parameters
