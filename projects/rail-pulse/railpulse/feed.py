"""Parse the Irish Rail realtime feed (getCurrentTrainsXML) into Train records.

Feed: http://api.irishrail.ie/realtime/realtime.asmx/getCurrentTrainsXML
Each <objTrainPositions> has TrainStatus (N = not yet running, R = running),
TrainLatitude/Longitude, TrainCode, TrainDate, Direction and a PublicMessage like:

    E820\\n12:05 - Bray to Howth (1 mins late)\\nDeparted Pearse next stop Tara Street

Note the line separator is a LITERAL backslash-n, not a newline.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass

NS = {"ir": "http://api.irishrail.ie/realtime/"}

ROUTE_RE = re.compile(
    r"^(?P<time>\d{1,2}:\d{2})\s*-\s*(?P<origin>.+?)\s+to\s+(?P<dest>.+?)\s*(\((?P<late>-?\d+)\s+mins?\s+late\))?\s*$"
)
POSITION_RE = re.compile(r"^(?P<verb>Departed|Arrived)\s+(?P<at>.+?)(\s+next stop\s+(?P<next>.+))?$")


@dataclass
class Train:
    code: str
    status: str  # "running" | "not_started"
    lat: float
    lon: float
    direction: str
    category: str  # DART | Intercity | Commuter (heuristic, see category_for)
    origin: str | None = None
    destination: str | None = None
    scheduled: str | None = None
    delay_min: int | None = None  # negative = early, None = not reported yet
    last_event: str | None = None  # "Departed" | "Arrived"
    last_location: str | None = None
    next_stop: str | None = None

    def to_dict(self) -> dict:
        return asdict(self)


def category_for(code: str) -> str:
    """Rough service type from the train-code prefix (heuristic, not official)."""
    if code.startswith("E"):
        return "DART"
    if code.startswith("A"):
        return "Intercity"
    return "Commuter"


def parse_message(msg: str) -> dict:
    """Pull route, delay and position out of the PublicMessage text."""
    parts = [p.strip() for p in msg.replace("\\n", "\n").split("\n") if p.strip()]
    out: dict = {}
    for line in parts[1:]:  # parts[0] is the train code again
        if m := ROUTE_RE.match(line):
            out.update(origin=m["origin"], destination=m["dest"], scheduled=m["time"])
            if m["late"] is not None:
                out["delay_min"] = int(m["late"])
        elif m := POSITION_RE.match(line):
            out.update(last_event=m["verb"], last_location=m["at"], next_stop=m["next"])
    return out


def _text(el: ET.Element, tag: str) -> str:
    child = el.find(f"ir:{tag}", NS)
    return (child.text or "").strip() if child is not None else ""


def parse_trains(xml_text: str) -> list[Train]:
    root = ET.fromstring(xml_text)
    trains: list[Train] = []
    for el in root.findall("ir:objTrainPositions", NS):
        code = _text(el, "TrainCode")
        try:
            lat, lon = float(_text(el, "TrainLatitude")), float(_text(el, "TrainLongitude"))
        except ValueError:
            continue  # skip records without a usable position
        if not code or not (51 < lat < 56 and -11 < lon < -5):  # sanity: on the island of Ireland
            continue
        trains.append(
            Train(
                code=code,
                status="running" if _text(el, "TrainStatus") == "R" else "not_started",
                lat=lat,
                lon=lon,
                direction=_text(el, "Direction"),
                category=category_for(code),
                **parse_message(_text(el, "PublicMessage")),
            )
        )
    return trains
