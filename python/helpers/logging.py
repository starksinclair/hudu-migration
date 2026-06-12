from typing import Literal
from ..types.common import Stats

LogLevel = Literal["info", "success", "warn", "error", "debug"]


def write_log(message: str, level: LogLevel = "info") -> None:
    print(f"[{level}] {message}")


def write_log_section(title: str) -> None:
    write_log(f"==== {title} ====", "info")


def write_log_skipped(step: str, reason: str) -> None:
    write_log(f"SKIPPED: {step} — {reason}", "warn")


def write_stats_summary(stats: Stats, plan_label: str = "") -> None:
    if plan_label:
        write_log(f"Scope: {plan_label}", "info")
    write_log(f"Stats: {stats}", "info")
