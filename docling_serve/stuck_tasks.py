import asyncio
import datetime
import logging
import os
import threading
from collections.abc import Callable
from typing import Any

from docling_jobkit.datamodel.task import Task
from docling_jobkit.datamodel.task_meta import TaskStatus

_log = logging.getLogger(__name__)

STUCK_TASK_ERROR = (
    "Conversion exceeded its deadline and was abandoned by the stuck-task watchdog"
)


def task_document_timeout(task: Task) -> float | None:
    options = task.convert_options or task.options
    if options is None:
        return None
    return getattr(options, "document_timeout", None)


def task_deadline_seconds(
    task: Task, grace_seconds: float, default_timeout_seconds: float
) -> float | None:
    timeout = task_document_timeout(task)
    if timeout is None or timeout <= 0:
        if default_timeout_seconds <= 0:
            return None
        timeout = default_timeout_seconds
    return float(timeout) + float(grace_seconds)


def task_source_names(task: Task) -> list[str]:
    names: list[str] = []
    for source in task.sources:
        name = getattr(source, "filename", None) or getattr(source, "url", None)
        names.append(str(name) if name else type(source).__name__)
    return names


def find_stuck_tasks(
    tasks: list[Task],
    now: datetime.datetime,
    grace_seconds: float,
    default_timeout_seconds: float,
) -> list[tuple[Task, float, float]]:
    stuck: list[tuple[Task, float, float]] = []
    for task in tasks:
        if task.task_status != TaskStatus.STARTED or task.started_at is None:
            continue
        deadline = task_deadline_seconds(task, grace_seconds, default_timeout_seconds)
        if deadline is None:
            continue
        elapsed = (now - task.started_at).total_seconds()
        if elapsed > deadline:
            stuck.append((task, elapsed, deadline))
    return stuck


async def abandon_stuck_tasks(
    orchestrator: Any,
    grace_seconds: float,
    default_timeout_seconds: float,
    now: datetime.datetime | None = None,
) -> list[Task]:
    now = now or datetime.datetime.now(datetime.timezone.utc)
    abandoned: list[Task] = []
    for task, elapsed, deadline in find_stuck_tasks(
        list(orchestrator.tasks.values()), now, grace_seconds, default_timeout_seconds
    ):
        _log.error(
            "Stuck conversion: task %s has been running for %.0fs, past its %.0fs "
            "deadline; marking it failed and flagging the pod unhealthy. sources=%s",
            task.task_id,
            elapsed,
            deadline,
            task_source_names(task),
        )
        task.error_message = STUCK_TASK_ERROR
        task.set_status(TaskStatus.FAILURE)
        if orchestrator.notifier:
            await orchestrator.notifier.notify_task_subscribers(task.task_id)
        abandoned.append(task)
    return abandoned


async def stuck_task_watchdog(
    orchestrator: Any,
    stuck_event: asyncio.Event,
    grace_seconds: float,
    default_timeout_seconds: float,
    scan_interval_seconds: float,
) -> None:
    while True:
        await asyncio.sleep(scan_interval_seconds)
        try:
            abandoned = await abandon_stuck_tasks(
                orchestrator, grace_seconds, default_timeout_seconds
            )
        except Exception:
            _log.exception("Stuck-task watchdog scan failed")
            continue
        if abandoned:
            stuck_event.set()


def rq_guard_deadline_seconds(
    job_timeout: float | None,
    document_timeout: float | None,
    grace_seconds: float,
) -> float | None:
    candidates = [
        float(value)
        for value in (job_timeout, document_timeout)
        if isinstance(value, (int, float)) and value > 0
    ]
    if not candidates:
        return None
    return min(candidates) + float(grace_seconds)


def task_data_document_timeout(task_data: Any) -> float | None:
    if not isinstance(task_data, dict):
        return None
    options = task_data.get("convert_options") or task_data.get("options")
    if not isinstance(options, dict):
        return None
    value = options.get("document_timeout")
    return float(value) if isinstance(value, (int, float)) else None


def task_data_source_names(task_data: Any) -> list[str]:
    if not isinstance(task_data, dict):
        return []
    names: list[str] = []
    for source in task_data.get("sources", []) or []:
        if isinstance(source, dict):
            name = source.get("filename") or source.get("url")
            names.append(str(name) if name else str(source.get("kind", "source")))
    return names


class StuckJobGuard:
    def __init__(self, deadline_seconds: float, on_timeout: Callable[[], None]):
        self._timer = threading.Timer(deadline_seconds, on_timeout)
        self._timer.daemon = True

    def start(self) -> None:
        self._timer.start()

    def cancel(self) -> None:
        self._timer.cancel()


def exit_stuck_worker(
    job_id: str,
    task_id: str | None,
    sources: list[str],
    elapsed_seconds: float,
    heartbeat_key: str | None,
    redis_url: str | None,
) -> None:
    _log.error(
        "Stuck conversion in RQ worker: job %s task %s has been running for %.0fs, "
        "past its deadline; exiting so the pod restarts and the task is failed. "
        "sources=%s",
        job_id,
        task_id,
        elapsed_seconds,
        sources,
    )
    if heartbeat_key and redis_url:
        try:
            from redis import Redis

            with Redis.from_url(redis_url) as connection:
                connection.delete(heartbeat_key)
        except Exception:
            _log.exception(
                "Could not clear heartbeat key %s before exiting", heartbeat_key
            )
    logging.shutdown()
    os._exit(1)
