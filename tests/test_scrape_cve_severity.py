# pyright: strict
"""scrape_cve_severity.parse_rows: the security-page CVE table parser."""

import pytest

import scrape_cve_severity as scs

# A stand-in for the security page's first table: header row, two valid CVE
# rows (one with the CVSS vector in the cell text, one with it only in the NVD
# calculator link's ?vector= href), one row with a score but no vector, and two
# rows that must be skipped (no CVE id; too few cells).
SECURITY_HTML = """
<html><body>
<table>
  <tr><th>CVE</th><th>Versions</th><th>Fixed in</th><th>Component &amp; CVSS</th></tr>
  <tr>
    <td>CVE-2022-1552</td><td>14, 13</td><td>14.3</td>
    <td><a href="https://nvd.nist.gov/vuln/calc?vector=AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H">
        core server 8.8 AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H</a></td>
  </tr>
  <tr>
    <td>CVE-2021-23222</td><td>13</td><td>13.4</td>
    <td><a href="https://nvd.nist.gov/vuln/calc?vector=AV:N/AC:H/PR:N/UI:N/S:U/C:L/I:N/A:N">
        client 3.7</a></td>
  </tr>
  <tr>
    <td>CVE-2019-10130</td><td>11</td><td>11.3</td>
    <td>core server</td>
  </tr>
  <tr><td>Not a CVE header</td><td>x</td><td>y</td><td>z</td></tr>
  <tr><td>CVE-2020-00001</td><td>too few cells</td></tr>
</table>
</body></html>
"""


def test_parses_only_the_two_and_one_valid_cve_rows() -> None:
    rows = scs.parse_rows(SECURITY_HTML)
    assert [row["cve_id"] for row in rows] == ["CVE-2022-1552", "CVE-2021-23222", "CVE-2019-10130"]


def test_vector_and_score_from_cell_text() -> None:
    row = scs.parse_rows(SECURITY_HTML)[0]
    assert row["component"] == "core server"
    assert row["cvss_base_score"] == "8.8"
    assert row["cvss_vector"] == "AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H"


def test_vector_falls_back_to_the_nvd_href() -> None:
    row = scs.parse_rows(SECURITY_HTML)[1]
    assert row["component"] == "client"
    assert row["cvss_base_score"] == "3.7"
    assert row["cvss_vector"] == "AV:N/AC:H/PR:N/UI:N/S:U/C:L/I:N/A:N"


def test_missing_score_and_vector_yield_empty_strings() -> None:
    row = scs.parse_rows(SECURITY_HTML)[2]
    assert row["component"] == "core server"
    assert row["cvss_base_score"] == ""
    assert row["cvss_vector"] == ""


def test_no_tables_raises_runtimeerror() -> None:
    with pytest.raises(RuntimeError, match="no tables"):
        scs.parse_rows("<html><body>the layout changed</body></html>")
