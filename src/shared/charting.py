"""
Chart-type inference and construction for Genie query results.

Databricks Genie's Conversation API never returns a chart specification —
only tabular data (``columns`` + stringified ``rows``). This module infers a
reasonable chart type from the shape/content of that data and builds a
Plotly figure, or returns ``None`` when a plain table is a better fit.

All cell values arrive as strings (per the Databricks SQL Statement
Execution API), so numeric/date coercion here is intentionally strict to
avoid misclassifying things like ``"Q1"`` or a bare ``"2020"`` id.
"""

from __future__ import annotations

import re
from datetime import datetime
from typing import Any

import plotly.graph_objects as go

# Matches only well-formed integers/floats (optional sign, digits, optional
# decimal part, optional exponent) — rejects strings like "Q1" or "Cat0".
_NUMERIC_RE = re.compile(r"^[+-]?\d+(\.\d+)?([eE][+-]?\d+)?$")

# Date/datetime formats that require an explicit separator, so a bare
# "2020" (e.g. a numeric id) is never misread as a year.
_DATE_FORMATS = (
    "%Y-%m-%d", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S",
    "%Y/%m/%d", "%m/%d/%Y", "%d-%m-%Y",
    "%Y-%m", "%b %Y", "%B %Y", "%Y-%m-%dT%H:%M:%S.%f",
)

# Column-name hints that a bare year-like value should be treated as temporal.
_TIME_NAME_HINT_RE = re.compile(
    r"(date|time|month|quarter|year|period|day|week)", re.IGNORECASE
)

# Column-name hints for non-additive measures that shouldn't be summed in a pie
# (rates, ratios, averages, percentages, scores, etc.).
_NON_ADDITIVE_NAME_RE = re.compile(
    r"(rate|ratio|avg|average|mean|pct|percent|roi|score|index|margin|per_)",
    re.IGNORECASE,
)

_MAX_PIE_SLICES = 8
_MAX_BAR_CATEGORIES = 30
_LONG_LABEL_THRESHOLD = 12


def _is_numeric(value: Any) -> bool:
    if value is None:
        return False
    s = str(value).strip()
    return bool(_NUMERIC_RE.fullmatch(s))


def _is_temporal(value: Any, col_name: str) -> bool:
    if value is None:
        return False
    s = str(value).strip()
    if not s:
        return False
    # Require a separator (or a name hint) so a bare number isn't parsed as a year.
    has_separator = any(ch in s for ch in ("-", "/", ":", " "))
    if not has_separator and not _TIME_NAME_HINT_RE.search(col_name):
        return False
    for fmt in _DATE_FORMATS:
        try:
            datetime.strptime(s, fmt)
            return True
        except ValueError:
            continue
    return False


def _to_float(value: Any) -> float | None:
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


def _parse_date(value: Any) -> datetime | None:
    """Parse a value using the same formats _is_temporal() checks against,
    for use as a chronological sort key (rather than lexical string sort,
    which sorts "January 2024" before "March 2024" incorrectly)."""
    if value is None:
        return None
    s = str(value).strip()
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    return None


def _date_sort_key(value: Any):
    """Sort key that sorts chronologically when the value parses as a date,
    falling back to the original string for stable, deterministic ordering."""
    parsed = _parse_date(value)
    # Tuple keeps all parsed dates before all unparsed strings, and keeps
    # comparisons well-typed (datetime vs datetime, str vs str).
    return (0, parsed) if parsed is not None else (1, str(value))


def _classify_columns(columns: list[str], rows: list[list[Any]]) -> dict:
    """Return per-column classification: numeric / temporal / categorical."""
    n_cols = len(columns)
    numeric_flags = [True] * n_cols
    temporal_flags = [True] * n_cols

    for row in rows:
        for i in range(n_cols):
            val = row[i] if i < len(row) else None
            if numeric_flags[i] and not _is_numeric(val):
                numeric_flags[i] = False
            if temporal_flags[i] and not _is_temporal(val, columns[i]):
                temporal_flags[i] = False

    kinds = []
    for i in range(n_cols):
        if numeric_flags[i]:
            kinds.append("numeric")
        elif temporal_flags[i]:
            kinds.append("temporal")
        else:
            kinds.append("categorical")
    return {
        "kinds": kinds,
        "numeric": [i for i, k in enumerate(kinds) if k == "numeric"],
        "temporal": [i for i, k in enumerate(kinds) if k == "temporal"],
        "categorical": [i for i, k in enumerate(kinds) if k == "categorical"],
    }


def build_chart(
    columns: list[str],
    rows: list[list[Any]],
    chart_type: str | None = None,
) -> "go.Figure | None":
    """Infer a chart type from ``columns``/``rows`` and build a Plotly figure.

    Returns ``None`` when the data doesn't clearly suit a chart (caller should
    fall back to a plain table/text). ``chart_type`` can be set to one of
    "line", "bar", "pie" to honor an explicit user request when the data
    shape supports it; otherwise it is ignored.
    """
    # R0 guards
    if not columns or not rows or len(rows) < 2:
        return None

    info = _classify_columns(columns, rows)
    numeric_idx = info["numeric"]
    temporal_idx = info["temporal"]
    categorical_idx = info["categorical"]

    if not numeric_idx:
        return None

    # R1 / R1b — temporal x + numeric y (line chart)
    if temporal_idx:
        x_idx = temporal_idx[0]
        sorted_rows = sorted(rows, key=lambda r: _date_sort_key(r[x_idx]))
        x_vals = [str(r[x_idx]) for r in sorted_rows]

        if categorical_idx and len(numeric_idx) == 1:
            # R1b: long-form (date, category, value) -> multi-line pivoted by category
            cat_idx = categorical_idx[0]
            y_idx = numeric_idx[0]
            series: dict[str, dict[str, float]] = {}
            for r in sorted_rows:
                cat = str(r[cat_idx])
                x = str(r[x_idx])
                y = _to_float(r[y_idx])
                if y is None:
                    continue
                series.setdefault(cat, {})[x] = y
            if len(series) > 12:
                return None  # too many series to be readable
            fig = go.Figure()
            for cat, points in series.items():
                fig.add_trace(go.Scatter(
                    x=list(points.keys()), y=list(points.values()),
                    mode="lines+markers", name=cat,
                ))
            fig.update_layout(title=columns[y_idx], xaxis_title=columns[x_idx])
            return fig

        # R1: one or more numeric series against the temporal axis
        fig = go.Figure()
        for y_idx in numeric_idx:
            y_vals = [_to_float(r[y_idx]) for r in sorted_rows]
            fig.add_trace(go.Scatter(
                x=x_vals, y=y_vals, mode="lines+markers", name=columns[y_idx],
            ))
        fig.update_layout(xaxis_title=columns[x_idx])
        return fig

    # R2 / R3 — one categorical + one numeric column
    if len(categorical_idx) == 1 and len(numeric_idx) == 1:
        cat_idx, y_idx = categorical_idx[0], numeric_idx[0]
        if len(rows) > _MAX_BAR_CATEGORIES:
            return None

        labels = [str(r[cat_idx]) for r in rows]
        values = [_to_float(r[y_idx]) for r in rows]
        if any(v is None for v in values):
            return None

        is_additive_measure = not _NON_ADDITIVE_NAME_RE.search(columns[y_idx])
        all_non_negative = all(v >= 0 for v in values)
        unique_short_labels = len(set(labels)) == len(labels) and all(
            len(l) <= _LONG_LABEL_THRESHOLD for l in labels
        )

        if (
            chart_type != "bar"
            and len(rows) <= _MAX_PIE_SLICES
            and is_additive_measure
            and all_non_negative
            and unique_short_labels
            and (chart_type == "pie" or chart_type is None)
        ):
            fig = go.Figure(data=[go.Pie(labels=labels, values=values)])
            fig.update_layout(title=columns[y_idx])
            return fig

        # R3: bar (horizontal if many/long labels)
        horizontal = len(labels) > 8 or any(len(l) > _LONG_LABEL_THRESHOLD for l in labels)
        if horizontal:
            fig = go.Figure(data=[go.Bar(x=values, y=labels, orientation="h")])
            fig.update_layout(xaxis_title=columns[y_idx])
        else:
            fig = go.Figure(data=[go.Bar(x=labels, y=values)])
            fig.update_layout(yaxis_title=columns[y_idx])
        return fig

    # R4 — one categorical + multiple numeric columns (grouped bar)
    if len(categorical_idx) == 1 and len(numeric_idx) >= 2:
        if len(rows) > _MAX_BAR_CATEGORIES:
            return None
        cat_idx = categorical_idx[0]
        labels = [str(r[cat_idx]) for r in rows]
        fig = go.Figure()
        for y_idx in numeric_idx:
            fig.add_trace(go.Bar(
                x=labels, y=[_to_float(r[y_idx]) for r in rows], name=columns[y_idx],
            ))
        fig.update_layout(barmode="group")
        return fig

    # R5 — all-numeric / ambiguous shapes: no confident chart, fall back to table
    return None


def chart_to_native_points(fig: "go.Figure") -> dict | None:
    """Detect whether ``fig`` is "simple" enough for a native Teams Adaptive
    Card ``Chart.*`` element (single-series bar/line/pie), and if so return
    its data in a UI-agnostic shape: ``{"kind": "bar"|"line"|"pie",
    "title": str, "points": [(label, value), ...]}``.

    Returns ``None`` for anything else (multi-series lines, grouped bars,
    etc.) — the caller should render a PNG instead for those.
    """
    if fig is None or len(fig.data) != 1:
        return None

    trace = fig.data[0]
    title = (fig.layout.title.text if fig.layout.title else None) or ""

    if isinstance(trace, go.Pie):
        labels = list(trace.labels)
        values = list(trace.values)
        return {"kind": "pie", "title": title, "points": list(zip(labels, values))}

    if isinstance(trace, go.Bar):
        # Bar orientation "h" means (x=values, y=labels); default is (x=labels, y=values).
        if getattr(trace, "orientation", None) == "h":
            labels, values = list(trace.y), list(trace.x)
        else:
            labels, values = list(trace.x), list(trace.y)
        return {"kind": "bar", "title": title, "points": list(zip(labels, values))}

    if isinstance(trace, go.Scatter):
        labels, values = list(trace.x), list(trace.y)
        return {"kind": "line", "title": title, "points": list(zip(labels, values))}

    return None
