"""Redact personal data from prompts before they leave the company.

Irish/EU-focused patterns. Regex PII detection is best-effort: it reduces risk,
it does not guarantee compliance - the README says so.
"""

from __future__ import annotations

import re

EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
IBAN = re.compile(r"\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,7}(?:\s?[A-Z0-9]{1,3})?\b")
# Irish PPS number: 7 digits + 1 or 2 letters (second letter W, A-I)
PPSN = re.compile(r"\b\d{7}[A-W][A-IW]?\b", re.IGNORECASE)
# Irish phone numbers: +353 / 00353 / 0 followed by 8-9 digits, spaces or dashes allowed
PHONE_IE = re.compile(r"(?<!\d)(?:\+353|00353|0)[\s-]?\(?\d{1,2}\)?(?:[\s-]?\d){6,8}(?!\d)")
CARD = re.compile(r"\b(?:\d[ -]?){13,19}\b")


def _luhn_ok(number: str) -> bool:
    digits = [int(d) for d in number if d.isdigit()]
    if not 13 <= len(digits) <= 19:
        return False
    checksum = 0
    for i, d in enumerate(reversed(digits)):
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        checksum += d
    return checksum % 10 == 0


def redact_text(text: str) -> tuple[str, dict[str, int]]:
    counts: dict[str, int] = {}

    def sub(pattern, label, s, check=None):
        def repl(m):
            if check and not check(m.group(0)):
                return m.group(0)
            counts[label] = counts.get(label, 0) + 1
            return f"[{label.upper()}]"

        return pattern.sub(repl, s)

    text = sub(EMAIL, "email", text)
    text = sub(IBAN, "iban", text)
    text = sub(CARD, "card", text, check=_luhn_ok)  # only real card numbers, not any long number
    text = sub(PHONE_IE, "phone", text)
    text = sub(PPSN, "ppsn", text)
    return text, counts


def redact_messages(body: dict) -> tuple[dict, dict[str, int]]:
    """Redact the system prompt and every text block in an Anthropic Messages request."""
    total: dict[str, int] = {}

    def add(c):
        for k, v in c.items():
            total[k] = total.get(k, 0) + v

    body = dict(body)
    if isinstance(body.get("system"), str):
        body["system"], c = redact_text(body["system"])
        add(c)
    new_messages = []
    for msg in body.get("messages", []):
        msg = dict(msg)
        if isinstance(msg.get("content"), str):
            msg["content"], c = redact_text(msg["content"])
            add(c)
        elif isinstance(msg.get("content"), list):
            blocks = []
            for b in msg["content"]:
                if isinstance(b, dict) and b.get("type") == "text":
                    b = dict(b)
                    b["text"], c = redact_text(b["text"])
                    add(c)
                blocks.append(b)
            msg["content"] = blocks
        new_messages.append(msg)
    body["messages"] = new_messages
    return body, total
