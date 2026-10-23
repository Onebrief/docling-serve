import datetime
import importlib
import threading
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from docling_jobkit.datamodel.task import Task
from docling_jobkit.datamodel.task_meta import TaskStatus

from docling_serve.settings import docling_serve_settings
from docling_serve.stuck_tasks import (
    STUCK_TASK_ERROR,
    StuckJobGuard,
    abandon_stuck_tasks,
    find_stuck_tasks,
    rq_guard_deadline_seconds,
    task_data_document_timeout,
    task_data_source_names,
)

NOW = datetime.datetime(2026, 10, 23, 12, 0, 0, tzinfo=datetime.timezone.utc)


def make_task(
    status: TaskStatus,
    started_seconds_ago: float | None,
    document_timeout: float | None,
    task_id: str = "task-1",
) -> Task:
    task = Task(task_id=task_id)
    task.task_status = status
    if started_seconds_ago is not None:
        task.started_at = NOW - datetime.timedelta(seconds=started_seconds_ago)
    task.convert_options = SimpleNamespace(document_timeout=document_timeout)
    return task


class TestFindStuckTasks:
    def test_flags_a_started_task_past_its_document_timeout_plus_grace(self):
        task = make_task(
            TaskStatus.STARTED, started_seconds_ago=400, document_timeout=60
        )

        stuck = find_stuck_tasks(
            [task], NOW, grace_seconds=300, default_timeout_seconds=0
        )

        assert [
            (t.task_id, round(elapsed), deadline) for t, elapsed, deadline in stuck
        ] == [("task-1", 400, 360.0)]

    def test_leaves_a_started_task_inside_its_deadline_alone(self):
        task = make_task(
            TaskStatus.STARTED, started_seconds_ago=100, document_timeout=60
        )

        assert find_stuck_tasks([task], NOW, 300, 0) == []

    def test_ignores_pending_and_finished_tasks(self):
        pending = make_task(TaskStatus.PENDING, None, 60, task_id="pending")
        done = make_task(TaskStatus.SUCCESS, 5000, 60, task_id="done")

        assert find_stuck_tasks([pending, done], NOW, 0, 0) == []

    def test_never_flags_a_task_without_a_timeout_when_no_default_is_set(self):
        task = make_task(
            TaskStatus.STARTED, started_seconds_ago=99_999, document_timeout=None
        )

        assert find_stuck_tasks([task], NOW, 300, default_timeout_seconds=0) == []

    def test_uses_the_default_timeout_when_the_task_has_none(self):
        task = make_task(
            TaskStatus.STARTED, started_seconds_ago=400, document_timeout=None
        )

        stuck = find_stuck_tasks([task], NOW, 100, default_timeout_seconds=200)

        assert [deadline for _, _, deadline in stuck] == [300.0]


class TestAbandonStuckTasks:
    async def test_fails_the_task_notifies_subscribers_and_returns_it(self):
        stuck = make_task(TaskStatus.STARTED, 400, 60, task_id="stuck")
        healthy = make_task(TaskStatus.STARTED, 10, 60, task_id="healthy")
        orchestrator = SimpleNamespace(
            tasks={"stuck": stuck, "healthy": healthy},
            notifier=SimpleNamespace(notify_task_subscribers=AsyncMock()),
        )

        abandoned = await abandon_stuck_tasks(orchestrator, 300, 0, now=NOW)

        assert [t.task_id for t in abandoned] == ["stuck"]
        assert stuck.task_status == TaskStatus.FAILURE
        assert stuck.error_message == STUCK_TASK_ERROR
        assert stuck.finished_at is not None
        assert healthy.task_status == TaskStatus.STARTED
        orchestrator.notifier.notify_task_subscribers.assert_awaited_once_with("stuck")

    async def test_returns_nothing_when_no_task_is_stuck(self):
        orchestrator = SimpleNamespace(
            tasks={"a": make_task(TaskStatus.STARTED, 10, 60)}, notifier=None
        )

        assert await abandon_stuck_tasks(orchestrator, 300, 0, now=NOW) == []


class TestStuckJobGuard:
    def test_fires_once_the_deadline_passes(self):
        fired = threading.Event()
        guard = StuckJobGuard(0.05, fired.set)

        guard.start()

        assert fired.wait(timeout=2)

    def test_does_not_fire_after_cancel(self):
        fired = threading.Event()
        guard = StuckJobGuard(0.05, fired.set)

        guard.start()
        guard.cancel()

        assert not fired.wait(timeout=0.2)


class TestRqGuardDeadline:
    @pytest.mark.parametrize(
        ("job_timeout", "document_timeout", "expected"),
        [
            (None, None, None),
            (-1, None, None),
            (-1, 30, 90.0),
            (100, 30, 90.0),
            (100, None, 160.0),
            (20, 30, 80.0),
        ],
    )
    def test_uses_the_tighter_timeout_plus_grace(
        self, job_timeout, document_timeout, expected
    ):
        assert rq_guard_deadline_seconds(job_timeout, document_timeout, 60) == expected


class TestTaskDataHelpers:
    def test_reads_document_timeout_from_convert_options(self):
        assert (
            task_data_document_timeout({"convert_options": {"document_timeout": 15}})
            == 15.0
        )

    def test_falls_back_to_deprecated_options(self):
        assert task_data_document_timeout({"options": {"document_timeout": 7.5}}) == 7.5

    def test_returns_none_without_a_timeout(self):
        assert task_data_document_timeout({"convert_options": {}}) is None
        assert task_data_document_timeout(None) is None

    def test_names_sources_by_filename_or_url(self):
        task_data = {
            "sources": [
                {"kind": "file", "filename": "a.pdf"},
                {"kind": "http", "url": "http://x/b.pdf"},
                {"kind": "s3"},
            ]
        }

        assert task_data_source_names(task_data) == ["a.pdf", "http://x/b.pdf", "s3"]


@pytest.fixture
def app_module():
    return importlib.import_module("docling_serve.app")


@pytest.fixture
def client(app_module, monkeypatch):
    monkeypatch.setattr(app_module, "get_async_orchestrator", lambda: MagicMock())
    monkeypatch.setattr(docling_serve_settings, "static_path", None)
    with patch.object(app_module, "setup_otel_instrumentation"):
        yield TestClient(app_module.create_app())
    app_module._stuck_task_detected.clear()


class TestHealthProbes:
    def test_health_and_livez_fail_once_a_stuck_task_was_detected(
        self, app_module, client
    ):
        assert client.get("/health").status_code == 200
        assert client.get("/livez").status_code == 200

        app_module._stuck_task_detected.set()

        assert client.get("/health").status_code == 503
        assert client.get("/livez").status_code == 503
