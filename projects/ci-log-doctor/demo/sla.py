"""Tiny demo module. Break it on purpose in a PR to watch ci-log-doctor work."""


def availability(total_minutes: int, downtime_minutes: int) -> float:
    """Uptime percentage, rounded to 3 decimals. 43200 min = 30 days."""
    if total_minutes <= 0:
        raise ValueError("total_minutes must be positive")
    return round(100 * (total_minutes - downtime_minutes) / total_minutes, 3)


def error_budget_minutes(slo_percent: float, total_minutes: int = 43_200) -> float:
    """How many minutes of downtime the SLO allows in the window."""
    return round(total_minutes * (1 - slo_percent / 100), 1)
