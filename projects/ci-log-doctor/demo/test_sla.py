import pytest

from demo.sla import availability, error_budget_minutes


def test_availability():
    assert availability(43_200, 43) == 99.9


def test_three_nines_budget_is_43_minutes():
    assert error_budget_minutes(99.9) == 43.2


def test_rejects_zero_window():
    with pytest.raises(ValueError):
        availability(0, 0)
