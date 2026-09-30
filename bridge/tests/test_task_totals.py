"""E12: real totals when given, labels from Hermes' toolset metadata with the fixed map first."""

import pytest

from hermescall_bridge.tasks import Turn, _total, label_for, parse_progress


def test_toolset_labels_unknown_tools_but_the_fixed_map_wins() -> None:
    assert label_for("web_search", "anything") == "Searching the web"
    assert label_for("mcp_fetch_page", "web") == "Searching the web"
    assert label_for("new_tool", "terminal") == "Running a command"
    assert label_for("new_tool", "unknown_set") == "Using new_tool"
    assert label_for("new_tool") == "Using new_tool"


def test_total_and_toolset_are_parsed_and_validated() -> None:
    event = parse_progress({"tool": "x", "index": 0, "state": "started", "total": 3, "toolset": "web"})
    assert (event.total, event.toolset) == (3, "web")
    for bad in ({"total": 0}, {"total": True}, {"total": 1000}, {"toolset": "Web Search"}, {"toolset": ""}):
        with pytest.raises(ValueError):
            parse_progress({"tool": "x", "index": 0, "state": "started", **bad})


def test_total_never_below_the_step() -> None:
    turn = Turn("t", 1, 0, step=4, total=3)
    assert _total(turn) == 4
    assert _total(Turn("t", 1, 0, step=1)) is None
    assert _total(Turn("t", 1, 0, step=1, total=5)) == 5
