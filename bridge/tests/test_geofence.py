"""M9 §3: place reminders (`geofence` phone capability). The phone watches the place; its location never leaves it."""

import asyncio

import pytest

from hermescall_bridge.phone import check_data, parse_params
from hermescall_common.errors import ProtocolError

from .test_bridge_flows import h  # noqa: F401 - fixture
from .test_chat import online_device, stop_devices  # noqa: F401 - fixtures
from .test_phone import answering, ask


def test_add_with_coordinates_or_query_gets_defaults() -> None:
    params = parse_params("geofence", {"action": "add", "title": " Buy milk ", "place": {"lat": 48.1, "lon": 11.5}})
    assert params == {
        "action": "add",
        "title": "Buy milk",
        "place": {"lat": 48.1, "lon": 11.5, "radius_m": 200},
        "trigger": "enter",
        "repeat": False,
    }
    params = parse_params(
        "geofence",
        {
            "action": "add",
            "id": "milk",
            "title": "Buy milk",
            "note": "2 litres",
            "place": {"query": " Rewe Schwabing "},
            "trigger": "exit",
            "repeat": True,
        },
    )
    assert params["place"] == {"query": "Rewe Schwabing"} and params["trigger"] == "exit" and params["repeat"] is True
    assert params["note"] == "2 litres" and params["id"] == "milk"
    assert parse_params("geofence", {"action": "remove", "id": "milk"}) == {"action": "remove", "id": "milk"}
    assert parse_params("geofence", {"action": "list"}) == {"action": "list"}


@pytest.mark.parametrize(
    "params",
    [
        {},
        {"action": "move"},
        {"action": "add", "place": {"query": "x"}},
        {"action": "add", "title": "", "place": {"query": "x"}},
        {"action": "add", "title": "t" * 121, "place": {"query": "x"}},
        {"action": "add", "title": "t"},
        {"action": "add", "title": "t", "place": {"query": ""}},
        {"action": "add", "title": "t", "place": {"query": "q" * 121}},
        {"action": "add", "title": "t", "place": {"lat": 91, "lon": 0}},
        {"action": "add", "title": "t", "place": {"lat": 0, "lon": 181}},
        {"action": "add", "title": "t", "place": {"lat": True, "lon": 0}},
        {"action": "add", "title": "t", "place": {"lat": 0, "lon": 0, "radius_m": 99}},
        {"action": "add", "title": "t", "place": {"lat": 0, "lon": 0, "radius_m": 2001}},
        {"action": "add", "title": "t", "place": {"lat": 0, "lon": 0, "query": "both"}},
        {"action": "add", "title": "t", "place": {"lat": 0}},
        {"action": "add", "title": "t", "place": "Rewe"},
        {"action": "add", "title": "t", "place": {"query": "x"}, "note": "n" * 501},
        {"action": "add", "title": "t", "place": {"query": "x"}, "trigger": "dwell"},
        {"action": "add", "title": "t", "place": {"query": "x"}, "repeat": "yes"},
        {"action": "add", "title": "t", "place": {"query": "x"}, "id": "i" * 65},
        {"action": "add", "title": "t", "place": {"query": "x"}, "extra": 1},
        {"action": "remove"},
        {"action": "remove", "id": ""},
        {"action": "remove", "id": "x", "title": "t"},
        {"action": "list", "id": "x"},
    ],
)
def test_bad_params_are_rejected(params) -> None:
    with pytest.raises(ValueError):
        parse_params("geofence", params)


def test_answer_data_is_checked_per_action() -> None:
    add = parse_params("geofence", {"action": "add", "title": "t", "place": {"query": "Rewe"}})
    assert check_data("geofence", add, {"id": "g1", "resolved_name": "REWE, Hauptstr. 1"})[0]["id"] == "g1"
    remove = parse_params("geofence", {"action": "remove", "id": "g1"})
    assert check_data("geofence", remove, {"removed": True})[0] == {"removed": True}
    listing = parse_params("geofence", {"action": "list"})
    reminder = {"id": "g1", "title": "Buy milk", "place_name": "REWE", "trigger": "enter", "repeat": False}
    assert check_data("geofence", listing, {"reminders": [reminder]})[0]["reminders"] == [reminder]
    for params, data in (
        (add, {"id": "g1", "resolved_name": "REWE", "lat": 48.1, "lon": 11.5}),  # the phone's location never leaves it
        (add, {"id": 5, "resolved_name": "REWE"}),
        (add, {"removed": True}),
        (remove, {"removed": "yes"}),
        (remove, {"id": "g1", "resolved_name": "x"}),
        (listing, {"reminders": [reminder] * 21}),
        (listing, {"reminders": [{**reminder, "lat": 1.0}]}),
        (listing, {"reminders": [{**reminder, "trigger": "dwell"}]}),
        (listing, {"reminders": "all"}),
    ):
        with pytest.raises(ProtocolError):
            check_data("geofence", params, data)


async def test_geofence_query_roundtrip(h) -> None:  # noqa: F811
    device = await online_device(h)
    seen: list[dict] = []
    device.answer_queries = answering("ok", {"id": "g1", "resolved_name": "REWE Schwabing"}, seen)
    params = {"action": "add", "title": "Buy milk", "place": {"query": "Rewe Schwabing"}}
    status, result = await asyncio.wait_for(ask(h, "geofence", "You asked for a reminder", params), 10)
    assert status == 200 and result == {"status": "ok", "data": {"id": "g1", "resolved_name": "REWE Schwabing"}}
    assert seen[0]["capability"] == "geofence" and seen[0]["params"]["trigger"] == "enter"


async def test_geofence_bad_params_are_400(h) -> None:  # noqa: F811
    await online_device(h)
    status, result = await asyncio.wait_for(ask(h, "geofence", "r", {"action": "add", "title": "t"}), 10)
    assert status == 400 and "place" in result["error"]


async def test_geofence_answer_with_location_is_unavailable(h) -> None:  # noqa: F811
    device = await online_device(h)
    device.answer_queries = answering("ok", {"id": "g1", "resolved_name": "x", "lat": 48.0, "lon": 11.0})
    params = {"action": "add", "title": "t", "place": {"lat": 48.0, "lon": 11.0, "radius_m": 150}}
    status, result = await asyncio.wait_for(ask(h, "geofence", "r", params), 10)
    assert result == {"status": "unavailable"}
