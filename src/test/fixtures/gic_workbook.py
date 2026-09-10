"""Builds a faithful GIC workbook fixture in-memory for offline tests.

Encodes the documented quirks: title row, header at row 2 (Segmentwise,
Miscellaneous) vs row 3 (Health, Liability), double-spaced Marine headers,
per-insurer "Previous Year" rows, section headings with no numbers, and
aggregate rows. The Segmentwise sheet carries the ICICI Lombard ground truth
from the spec (Fire 1247.97, Motor Total 3755.91 / PY 3270.75, Grand Total
10723.58).
"""

from __future__ import annotations

from io import BytesIO

import openpyxl

_TITLE = ("GROSS DIRECT PREMIUM INCOME UNDERWRITTEN BY NON-LIFE INSURERS WITHIN "
          "INDIA (SEGMENT WISE) : FOR THE PERIOD UPTO July 2026 (PROVISIONAL & "
          "UNAUDITED) IN FY 2026-27 (Rs. In Crs.)")

# name, Fire, MarineTotal, MarineCargo, MarineHull, MotorTotal, GrandTotal,
# optional explicit previous-year tuple (same shape minus name).
_SEG_GENERAL = [
    ("Acko General Insurance Ltd",            0.79,  1.0, 0.5, 0.5,   10.0,    20.0),
    ("Bajaj General Insurance Limited",       700.0, 30.0,15.0,15.0,  1500.0,  6000.0),
    ("Generali Central Insurance Company Limited", 60.0, 5.0, 2.5, 2.5, 250.0, 900.0),
    ("Go Digit General Insurance Ltd",        120.0, 12.0, 6.0, 6.0,  900.0,   3000.0),
    ("HDFC ERGO General Insurance Co Ltd",    900.0, 45.0,25.0,20.0,  2000.0,  8000.0),
    # ICICI Lombard carries the spec ground truth incl. exact previous-year Motor Total.
    ("ICICI Lombard General Insurance Co Ltd",1247.97,50.0,30.0,20.0, 3755.91, 10723.58,
     (1050.0, 42.0, 26.0, 16.0, 3270.75, 9100.0)),
    ("Reliance General Insurance Co Ltd",     300.0, 20.0,10.0,10.0,  1200.0,  4000.0),
    ("The New India Assurance Co Ltd",        2000.0,90.0,50.0,40.0,  5000.0,  20000.0),
    ("Zurich Kotak Mahindra General Insurance Co Ltd", 80.0, 6.0, 3.0, 3.0, 300.0, 1100.0),
    ("Zuno General Insurance Co Ltd",         40.0,  3.0, 1.5, 1.5,   150.0,   500.0),
]
_SEG_STANDALONE_HEALTH = [
    ("Star Health & Allied Insurance Co Ltd", 0.0, 0.0, 0.0, 0.0, 0.0, 5000.0),
    ("Niva Bupa Health Insurance Co Ltd",     0.0, 0.0, 0.0, 0.0, 0.0, 3000.0),
]


def _prev(vals):
    """Return a slightly smaller 'previous year' tuple for numeric fields."""
    return tuple(round(v * 0.85, 2) if isinstance(v, (int, float)) else v for v in vals)


def _add_segment(wb):
    ws = wb.active
    ws.title = "Segmentwise Report"
    ws.append([_TITLE])
    # Header at row 2 — note the DOUBLE spaces in Marine Cargo/Hull (verbatim).
    ws.append([None, "Fire", "Marine Total", "Marine  Cargo", "Marine  Hull",
               "Motor Total", "Grand Total"])
    ws.append(["General Insurers"])  # section heading, no numbers
    for row in _SEG_GENERAL:
        current = row[:7]
        py = row[7] if len(row) > 7 else _prev(current[1:])
        ws.append(list(current))
        ws.append(["Previous Year", *py])
    ws.append(["General Insurers Sub Total", 5307.76, 251.0, 138.0, 113.0, 14515.91, 52243.58])
    ws.append(["Stand-alone Health Insurers"])  # section heading
    for row in _SEG_STANDALONE_HEALTH:
        ws.append(list(row))
        ws.append(["Previous Year", *_prev(row[1:])])
    ws.append(["Industry Total", 5307.76, 251.0, 138.0, 113.0, 14515.91, 60243.58])
    ws.append(["% Growth", 12.0, 8.0, 7.0, 9.0, 11.0, 10.0])


def _add_portfolio(wb, sheet_name, header_row_index, columns, insurers):
    """Add a sheet with the header at a given 1-based row index."""
    ws = wb.create_sheet(sheet_name)
    ws.append([_TITLE])
    # Pad so the header lands on the requested row (Health/Liability = row 3).
    for _ in range(header_row_index - 2):
        ws.append([None])
    ws.append([None, *columns])
    ws.append(["General Insurers"])
    for row in insurers:
        ws.append(list(row))
        ws.append(["Previous Year", *_prev(row[1:])])
    ws.append(["Industry Total", *[round(sum(r[i] for r in insurers), 2)
                                    for i in range(1, len(columns) + 1)]])


def build_workbook_bytes() -> bytes:
    """Return a faithful GIC workbook as .xlsx bytes."""
    wb = openpyxl.Workbook()
    _add_segment(wb)

    # Health Portfolio — header at row 3.
    _add_portfolio(
        wb, "Health Portfolio", 3,
        ["Health-Retail", "Health-Group", "Health-Government schemes",
         "Overseas Medical", "Grand Total"],
        [
            ("ICICI Lombard General Insurance Co Ltd", 1200.0, 2000.0, 500.0, 50.0, 3750.0),
            ("HDFC ERGO General Insurance Co Ltd",      800.0, 1500.0, 300.0, 40.0, 2640.0),
            ("Star Health & Allied Insurance Co Ltd",   3000.0, 1800.0, 200.0, 10.0, 5010.0),
            ("The New India Assurance Co Ltd",          900.0, 2500.0, 600.0, 30.0, 4030.0),
            ("Bajaj General Insurance Limited",         400.0, 700.0, 100.0, 20.0, 1220.0),
            ("Reliance General Insurance Co Ltd",       350.0, 650.0, 90.0, 15.0, 1105.0),
        ],
    )

    # Liability Portfolio — header at row 3.
    _add_portfolio(
        wb, "Liability Portfolio", 3,
        ["Workmen's compensation/Employers' liability", "Public Liability (Act)",
         "Product Liability", "Other liability covers", "Grand Total"],
        [
            ("ICICI Lombard General Insurance Co Ltd", 50.0, 30.0, 40.0, 80.0, 200.0),
            ("HDFC ERGO General Insurance Co Ltd",      40.0, 25.0, 35.0, 70.0, 170.0),
            ("Bajaj General Insurance Limited",         30.0, 20.0, 25.0, 55.0, 130.0),
            ("The New India Assurance Co Ltd",          60.0, 45.0, 50.0, 95.0, 250.0),
            ("Go Digit General Insurance Ltd",          15.0, 10.0, 12.0, 25.0, 62.0),
            ("Reliance General Insurance Co Ltd",       20.0, 15.0, 18.0, 40.0, 93.0),
        ],
    )

    # Miscellaneous portfolio — header at row 2.
    _add_portfolio(
        wb, "Miscellaneous portfolio", 2,
        ["Crop Insurance", "Credit Guarantee", "All Other miscellaneous", "Grand Total"],
        [
            ("ICICI Lombard General Insurance Co Ltd", 500.0, 20.0, 300.0, 820.0),
            ("HDFC ERGO General Insurance Co Ltd",      400.0, 15.0, 250.0, 665.0),
            ("Agriculture Insurance Co Of India Ltd",   3000.0, 0.0, 50.0, 3050.0),
            ("Bajaj General Insurance Limited",         350.0, 10.0, 200.0, 560.0),
            ("The New India Assurance Co Ltd",          600.0, 25.0, 400.0, 1025.0),
            ("Reliance General Insurance Co Ltd",       300.0, 8.0, 180.0, 488.0),
        ],
    )

    buf = BytesIO()
    wb.save(buf)
    return buf.getvalue()
