#!/usr/bin/env python3
"""itsm_ticket.py 가 **읽기만 하고, 내부 메모를 고객 발언으로 읽지 않고, 못 읽으면 멈추는지** 본다.

틀리면 비싼 쪽 셋: 쓰기 요청이 나가는 것, 내부 메모가 공개로 찍히는 것, 반쪽 출력이 완성본처럼 보이는 것.
그래서 부른 URL 을 전부 가짜 fetch 로 기록해 허용 목록과 맞춰 보고, 내부 종류를 하나씩 못 박는다.

**어떤 테스트도 ITSM 에 닿지 않는다.** 네트워크는 `fetch` 한 곳뿐이고 전부 가짜를 넣는다.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/itsm_ticket.py"

spec = importlib.util.spec_from_file_location("itsm_ticket", SOURCE)
itsm_ticket = importlib.util.module_from_spec(spec)
spec.loader.exec_module(itsm_ticket)

BASE = "https://itsm.example.com"
TOKEN = "cops_token-value-for-tests"
NUMBER = "4242"
UNKNOWN_LABEL = "[구분 모름 — 고객 발언으로 읽지 않는다]"
INTERNAL_TYPES = ["work_note", "internal_note", "reply_cc", "escalation"]


def item(kind="incident", id="inc-1", number=4242, **extra) -> dict:
    return {"type": kind, "view": "x", "id": id, "ticket_number": number, "label": f"#{number}",
            "title": "검색에만 나오는 제목", "status": "open", "customer_id": "cust-1",
            "customer_name": "합성고객", **extra}


def detail(**extra) -> dict:
    return {"id": "inc-1", "ticket_number": 4242, "status": "open", "title": "합성 제목",
            "description": "<p>최초 <b>요청</b></p>", "content_format": "html",
            "created_at": "2026-10-01T01:00:00.000Z", "updated_at": "2026-10-02T01:00:00.000Z",
            "priority": "high", "customer_id": "cust-1", "customer_name": "합성고객",
            "ticket_authority": "itsm", "zendesk_ticket_id": None, "inbound_attachments": [], **extra}


def act(id, type, content, created_at, **extra) -> dict:
    return {"id": id, "type": type, "content": content, "content_format": "text", "created_at": created_at,
            "author_display_name": "합성엔지니어", "author_role": "engineer", "username": "eng-user",
            "attachments": [], **extra}


# 최신순 — API 가 이 순서로 준다.
THREAD = [
    act(3, "customer_reply", "고객 두 번째", "2026-10-03T00:00:00.000Z",
        author_display_name="합성고객담당", author_role="customer-user",
        attachments=[{"original_name": "log.txt", "size": 2048}]),
    act(2, "work_note", "내부 두 번째 메모", "2026-10-02T00:00:00.000Z"),
    act(1, "customer_note", "<p>엔지니어 첫 답변</p>", "2026-10-01T02:00:00.000Z", content_format="html"),
]

PATHS = {
    "incident": ("/api/incidents/{}", "/api/incidents/{}/activity"),
    "service_request": ("/api/service-requests/{}", "/api/service-requests/{}/activity"),
    "change_request": ("/api/change-requests/{}", "/api/change-requests/{}/activity"),
    "problem": ("/api/problems/{}", None),
}
ALLOWED_URLS = re.compile(
    re.escape(BASE) + r"(/api/search/tickets\?q=\d+&limit=\d+"
    r"|/api/(incidents|service-requests|change-requests|problems)/[A-Za-z0-9_.%-]+(/activity)?)"
)


def routes_for(kind="incident", id="inc-1", number=4242, thread=THREAD, detail_extra=None) -> dict:
    detail_path, activity_path = PATHS[kind]
    routes = {
        f"/api/search/tickets?q={number}&limit=25": (200, {"items": [item(kind, id, number)]}),
        detail_path.format(id): (200, detail(id=id, ticket_number=number, **(detail_extra or {}))),
    }
    if activity_path:
        routes[activity_path.format(id)] = (200, {"activities": thread, "sla": {}})
    return routes


class FakeServer:
    """`fetch(url, token, timeout)` 자리에 들어간다. 부른 URL 을 남긴다."""

    def __init__(self, routes: dict) -> None:
        self.routes = routes
        self.calls: list[tuple[str, str]] = []

    def __call__(self, url: str, token: str, timeout: int):
        self.calls.append((url, token))
        answer = self.routes.get(url.removeprefix(BASE).removeprefix("https://dev.itsm.example.com"),
                                 (404, {"error": "no route"}))
        if isinstance(answer, Exception):
            raise answer
        return answer


class Harness(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="tiket-itsm-")
        self.conf = Path(self.tempdir.name) / "itsm"
        self.conf.write_text(f"ITSM_API_TOKEN={TOKEN}\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_main(self, server: FakeServer, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = itsm_ticket.main(list(argv) or [NUMBER], fetch=server, conf=self.conf)
        return code, out.getvalue(), err.getvalue()

    def read(self, routes: dict | None = None, *argv: str) -> tuple[FakeServer, str, str]:
        server = FakeServer(routes or routes_for())
        code, out, err = self.run_main(server, *argv)
        self.assertEqual(code, 0, err)
        return server, out, err


class ReadTests(Harness):
    def test_prints_meta_then_thread_oldest_first_with_authors_and_attachments(self) -> None:
        _, out, _ = self.read()

        for line in ("TICKET #4242  [open]", "제목   : 합성 제목", "우선순위: high   유형: incident",
                     "고객   : 합성고객 (customer_id cust-1)", "권한   : itsm",
                     "생성   : 2026-10-01T01:00:00.000Z   업데이트: 2026-10-02T01:00:00.000Z"):
            self.assertIn(line, out)
        self.assertIn("최초 요청", out)
        order = [out.index(text) for text in ("엔지니어 첫 답변", "내부 두 번째 메모", "고객 두 번째")]
        self.assertEqual(order, sorted(order))
        self.assertIn("합성고객담당 (customer-user)", out)
        self.assertIn("합성엔지니어 (engineer)", out)
        self.assertIn("첨부: log.txt (2KB)", out)

    def test_html_bodies_become_plain_text_without_tags_or_scripts(self) -> None:
        thread = [act(1, "customer_reply", "<p>첫 줄</p><ul><li>하나</li></ul><script>alert(1)</script>"
                      '<a href="https://example.test/x">링크</a>', "2026-10-01T00:00:00.000Z", content_format="html")]
        _, out, _ = self.read(routes_for(thread=thread))

        self.assertIn("첫 줄", out)
        self.assertIn("- 하나", out)
        self.assertIn("링크 (https://example.test/x)", out)
        self.assertNotIn("alert(1)", out)
        self.assertNotRegex(out.split("요청 본문")[1], r"<\w+")

    def test_every_internal_only_type_is_labelled_internal_never_public(self) -> None:
        for kind in INTERNAL_TYPES:
            with self.subTest(kind=kind):
                _, out, _ = self.read(routes_for(thread=[act(1, kind, "내부 내용", "2026-10-01T00:00:00.000Z")]))
                self.assertIn(f"· 내부 메모 · {kind}", out)
                self.assertNotIn(f"· 공개 · {kind}", out)
                self.assertNotIn(UNKNOWN_LABEL, out)

    def test_system_note_from_internal_sources_is_internal_and_plain_system_note_is_public(self) -> None:
        for username in ("connect-attacher", "slack-notifier"):
            with self.subTest(username=username):
                thread = [act(1, "system_note", "통화 요약", "2026-10-01T00:00:00.000Z", username=username)]
                _, out, _ = self.read(routes_for(thread=thread))
                self.assertIn("· 내부 메모 · system_note", out)
        thread = [act(1, "system_note", "일반", "2026-10-01T00:00:00.000Z", username=None)]
        _, out, _ = self.read(routes_for(thread=thread))
        self.assertIn("· 공개 · system_note", out)

    def test_ai_drafted_public_reply_stays_internal(self) -> None:
        thread = [act(1, "customer_note", "AI 초안", "2026-10-01T00:00:00.000Z",
                      idempotency_key="ai-support-case-public-reply:abc")]
        _, out, _ = self.read(routes_for(thread=thread))
        self.assertIn("· 내부 메모 · customer_note", out)

    def test_unrecognised_type_is_unknown_not_public(self) -> None:
        thread = [act(1, "brand_new_type", "새 종류", "2026-10-01T00:00:00.000Z")]
        _, out, _ = self.read(routes_for(thread=thread))

        self.assertIn(f"· {UNKNOWN_LABEL} · brand_new_type", out)
        self.assertNotIn("· 공개 · brand_new_type", out)

    def test_recognised_customer_visible_types_are_public(self) -> None:
        for kind in ("customer_reply", "customer_note", "inbound_email", "status_change"):
            with self.subTest(kind=kind):
                _, out, _ = self.read(routes_for(thread=[act(1, kind, "보이는 내용", "2026-10-01T00:00:00.000Z")]))
                self.assertIn(f"· 공개 · {kind}", out)

    def test_zendesk_authority_warns_on_stderr_and_itsm_does_not(self) -> None:
        _, _, err = self.read(routes_for(detail_extra={"ticket_authority": "zendesk"}))
        self.assertIn("Zendesk", err)
        self.assertIn("정본", err)
        _, _, err = self.read()
        self.assertEqual(err, "")

    def test_json_mode_prints_ticket_and_activities_only(self) -> None:
        _, out, _ = self.read(None, NUMBER, "--json")

        data = json.loads(out)
        self.assertEqual(data["ticket"]["id"], "inc-1")
        self.assertEqual([a["id"] for a in data["activities"]], [3, 2, 1])

    def test_each_ticket_type_reads_its_own_detail_and_activity_paths(self) -> None:
        for kind in ("service_request", "change_request"):
            with self.subTest(kind=kind):
                server, out, _ = self.read(routes_for(kind, id="x-1"))
                detail_path, activity_path = PATHS[kind]
                self.assertEqual([url.removeprefix(BASE) for url, _ in server.calls][1:],
                                 [detail_path.format("x-1"), activity_path.format("x-1")])
                self.assertIn("고객 두 번째", out)

    def test_problem_has_no_activity_path_and_says_the_thread_was_not_read(self) -> None:
        server, out, err = self.read(routes_for("problem", id="p-1"))

        self.assertEqual(len(server.calls), 2)
        self.assertIn("스레드를 읽지 못했다", out)
        self.assertIn("스레드를 읽지 못했다", err)

    def test_dev_flag_uses_the_dev_server_and_the_dev_token(self) -> None:
        self.conf.write_text(f'ITSM_API_TOKEN={TOKEN}\nexport DEV_ITSM_API_TOKEN="dev-token"\n', encoding="utf-8")
        server, _, _ = self.read(None, NUMBER, "--dev")

        self.assertTrue(all(url.startswith("https://dev.itsm.example.com/") for url, _ in server.calls))
        self.assertEqual({token for _, token in server.calls}, {"dev-token"})


class ResolveTests(Harness):
    def test_only_the_exact_ticket_number_is_taken_from_search_results(self) -> None:
        routes = routes_for()
        routes[f"/api/search/tickets?q={NUMBER}&limit=25"] = (200, {"items": [
            item(id="inc-9", number=94242), item("service_request", "sr-9", 42420), item(id="inc-1")]})
        routes["/api/incidents/inc-9"] = (200, detail(id="inc-9", ticket_number=94242))
        routes["/api/service-requests/sr-9"] = (200, detail(id="sr-9", ticket_number=42420))

        _, out, _ = self.read(routes)

        self.assertIn("TICKET #4242", out)

    def test_an_exact_ticket_number_match_opens_no_other_ticket(self) -> None:
        # 검색에 섞인 다른 티켓(다른 고객일 수 있다)의 단건을 Zendesk 번호 대조용으로 열지 않는다.
        routes = routes_for()
        routes[f"/api/search/tickets?q={NUMBER}&limit=25"] = (200, {"items": [
            item(id="inc-9", number=94242), item(id="inc-1")]})
        routes["/api/incidents/inc-9"] = (200, detail(id="inc-9", ticket_number=94242))

        server, _, _ = self.read(routes)

        self.assertNotIn(f"{BASE}/api/incidents/inc-9", [url for url, _ in server.calls])

    def test_zendesk_id_on_a_search_hit_resolves_when_no_ticket_number_matches(self) -> None:
        routes = routes_for(number=777)
        routes[f"/api/search/tickets?q={NUMBER}&limit=25"] = (200, {"items": [item(number=777)]})
        routes["/api/incidents/inc-1"] = (200, detail(ticket_number=777, zendesk_ticket_id=NUMBER))

        _, out, _ = self.read(routes)

        self.assertIn("TICKET #777", out)

    def test_zendesk_id_that_only_contains_the_number_is_not_a_match(self) -> None:
        routes = routes_for(number=777)
        routes[f"/api/search/tickets?q={NUMBER}&limit=25"] = (200, {"items": [item(number=777)]})
        routes["/api/incidents/inc-1"] = (200, detail(ticket_number=777, zendesk_ticket_id="14242"))

        code, out, err = self.run_main(FakeServer(routes))

        self.assertEqual((code, out), (2, ""))
        self.assertIn("찾지 못했다", err)

    def test_no_exact_match_stops_with_not_found(self) -> None:
        routes = {f"/api/search/tickets?q={NUMBER}&limit=25": (200, {"items": []})}

        code, out, err = self.run_main(FakeServer(routes))

        self.assertEqual((code, out), (2, ""))
        self.assertIn("찾지 못했다", err)

    def test_more_than_one_exact_match_lists_type_id_number_only(self) -> None:
        routes = routes_for()
        routes[f"/api/search/tickets?q={NUMBER}&limit=25"] = (200, {"items": [
            item(id="inc-1"), item("service_request", "sr-1")]})

        code, out, err = self.run_main(FakeServer(routes))

        self.assertEqual((code, out), (2, ""))
        self.assertIn("incident inc-1 #4242", err)
        self.assertIn("service_request sr-1 #4242", err)
        self.assertNotIn("합성고객", err)
        self.assertNotIn("검색에만 나오는 제목", err)

    def test_search_uses_the_number_and_a_wide_limit(self) -> None:
        server, _, _ = self.read()
        self.assertEqual(server.calls[0][0], f"{BASE}/api/search/tickets?q={NUMBER}&limit=25")


class SafetyTests(Harness):
    def test_every_request_is_an_allowed_single_ticket_read(self) -> None:
        for kind in PATHS:
            with self.subTest(kind=kind):
                server, _, _ = self.read(routes_for(kind, id="x-1"))
                for url, _ in server.calls:
                    self.assertRegex(url, ALLOWED_URLS)
                    self.assertNotRegex(url, r"/all\b|/comments|/query")

    def test_the_real_fetch_sends_a_get_without_a_body(self) -> None:
        seen = []

        def fake_urlopen(request, timeout):
            seen.append(request)
            raise urllib.error.HTTPError(request.full_url, 403, "no", {}, io.BytesIO(b""))

        with mock.patch.object(itsm_ticket.https_fetch, "urlopen", fake_urlopen):
            status, _ = itsm_ticket.fetch(f"{BASE}/api/x", TOKEN, 5)

        self.assertEqual(status, 403)
        self.assertEqual((seen[0].get_method(), seen[0].data), ("GET", None))

    def test_source_has_no_write_verb_and_no_list_everything_path(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        for needle in ("method=", "data=", "POST", "PUT", "PATCH", "DELETE", "/all", "/comments", "/query"):
            self.assertNotIn(needle, source, needle)

    def test_token_is_never_printed(self) -> None:
        for routes in (routes_for(), {f"/api/search/tickets?q={NUMBER}&limit=25": (401, None)}):
            _, out, err = self.run_main(FakeServer(routes))
            self.assertNotIn(TOKEN, out + err)

    def test_never_writes_files(self) -> None:
        before = set(Path(self.tempdir.name).rglob("*"))
        self.read()
        self.assertEqual(set(Path(self.tempdir.name).rglob("*")), before)


class StopTests(Harness):
    """못 읽은 것은 전부 종료 코드 2, stdout 은 비고, stderr 에 한국어 한 줄 이유."""

    SEARCH = f"/api/search/tickets?q={NUMBER}&limit=25"

    def assert_stops(self, server: FakeServer, *argv: str, calls: int | None = None) -> str:
        code, out, err = self.run_main(server, *argv)
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertRegex(err, r"[가-힣]")
        self.assertEqual(len(err.strip().splitlines()), 1)
        if calls is not None:
            self.assertEqual(len(server.calls), calls)
        return err

    def with_route(self, path: str, answer) -> FakeServer:
        routes = routes_for()
        routes[path] = answer
        return FakeServer(routes)

    def test_missing_token_stops_before_any_call(self) -> None:
        self.conf.unlink()
        self.assertIn("토큰", self.assert_stops(FakeServer(routes_for()), calls=0))

    def test_number_that_is_not_digits_stops_before_any_call(self) -> None:
        self.assert_stops(FakeServer(routes_for()), "42a2", calls=0)

    def test_rejected_token_stops(self) -> None:
        for status in (401, 403):
            with self.subTest(status=status):
                err = self.assert_stops(self.with_route(self.SEARCH, (status, None)), calls=1)
                self.assertIn(str(status), err)

    def test_server_error_stops(self) -> None:
        self.assert_stops(self.with_route(self.SEARCH, (503, None)), calls=1)

    def test_network_failure_stops(self) -> None:
        self.assert_stops(self.with_route(self.SEARCH, OSError("timed out")))

    def test_malformed_json_stops(self) -> None:
        self.assert_stops(self.with_route(self.SEARCH, ValueError("Expecting value")))

    def test_search_answer_without_items_stops(self) -> None:
        self.assert_stops(self.with_route(self.SEARCH, (200, {"nope": []})))

    def test_thread_failure_after_detail_does_not_print_a_partial_ticket(self) -> None:
        self.assert_stops(self.with_route("/api/incidents/inc-1/activity", (500, None)), calls=3)

    def test_thread_without_activities_stops(self) -> None:
        self.assert_stops(self.with_route("/api/incidents/inc-1/activity", (200, {"sla": {}})))

    def test_detail_of_another_ticket_stops(self) -> None:
        self.assert_stops(self.with_route("/api/incidents/inc-1", (200, detail(id="inc-other"))))

    def test_unknown_ticket_type_stops(self) -> None:
        routes = {self.SEARCH: (200, {"items": [item("surprise", "z-1")]})}
        self.assert_stops(FakeServer(routes), calls=1)


if __name__ == "__main__":
    unittest.main()
