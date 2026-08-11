from __future__ import annotations

import http.client
import json
import plistlib
import re
import sqlite3
import threading
import unittest
from functools import partial
from http.server import ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory

import server as landing


class PreviewMDLandingContentTests(unittest.TestCase):
    analytics_id = "G-8YXDM1JJH2"
    release_archive = "PreviewMD-1.7-11-macOS.dmg"
    site_dir = Path(__file__).resolve().parent

    def test_editing_is_presented_as_a_core_capability(self) -> None:
        html = (self.site_dir / "index.html").read_text(encoding="utf-8")
        normalized = html.lower()

        self.assertIn("reader and editor", normalized)
        self.assertIn("direct editing", normalized)
        self.assertIn("the rendered document is an editor", normalized)
        self.assertNotIn("reader, not editor", normalized)
        self.assertNotIn("new in previewmd", normalized)

    def test_portable_copy_and_semantic_docx_are_presented(self) -> None:
        html = (self.site_dir / "index.html").read_text(encoding="utf-8")
        normalized = html.lower()

        self.assertIn("take the document with you", normalized)
        self.assertIn("advanced copy", normalized)
        self.assertIn("pages or word", normalized)
        self.assertIn("export a semantic docx", normalized)
        self.assertIn("headings as heading styles", normalized)
        self.assertIn("tables as real editable tables", normalized)
        self.assertIn("copy a supported visual object on its own as svg", normalized)

    def test_custom_visual_presets_are_presented_with_reading_styles(self) -> None:
        html = (self.site_dir / "index.html").read_text(encoding="utf-8")
        stylesheet = (self.site_dir / "styles.css").read_text(encoding="utf-8")
        normalized = html.lower()

        self.assertIn("set the page your way", normalized)
        self.assertIn("save your own named visual presets", normalized)
        self.assertIn("named visual presets", normalized)
        self.assertIn("body and heading fonts", normalized)
        self.assertIn("styles.css?v=db-7", html)
        self.assertIn(".spec-custom", stylesheet)
        self.assertIn(".preset-swatches", stylesheet)

    def test_release_archive_is_consistent_in_html_and_javascript(self) -> None:
        html = (self.site_dir / "index.html").read_text(encoding="utf-8")
        javascript = (self.site_dir / "main.js").read_text(encoding="utf-8")
        app_info = plistlib.loads(
            (self.site_dir.parent / "scripts" / "Info.plist").read_bytes()
        )
        release_links = set(
            re.findall(r'href="(PreviewMD-[^"]+-macOS\.dmg)"', html)
        )

        self.assertTrue((self.site_dir / self.release_archive).is_file())
        self.assertEqual(release_links, {self.release_archive})
        self.assertIn(
            f'const DOWNLOAD_FILE = "{self.release_archive}";',
            javascript,
        )
        self.assertEqual(app_info["CFBundleShortVersionString"], "1.7")
        self.assertEqual(app_info["CFBundleVersion"], "11")
        self.assertIn("v1.7 (build 11)", html)
        self.assertIn('main.js?v=db-11', html)
        self.assertNotIn("PreviewMD-1.6-10-macOS.dmg", html)
        self.assertNotIn("PreviewMD-1.6-10-macOS.dmg", javascript)
        self.assertNotIn("PreviewMD-1.5-7-macOS.zip", html)
        self.assertNotIn("PreviewMD-1.5-7-macOS.zip", javascript)

    def test_shared_analytics_respects_the_strict_csp(self) -> None:
        html = (self.site_dir / "index.html").read_text(encoding="utf-8")
        analytics = (self.site_dir / "analytics.js").read_text(encoding="utf-8")
        nginx = (
            self.site_dir.parent / "deploy" / "nginx-previewmd.conf"
        ).read_text(encoding="utf-8")
        inline_script_bodies = re.findall(
            r"<script(?:\s[^>]*)?>(.*?)</script>",
            html,
            flags=re.DOTALL,
        )

        self.assertIn(
            f'https://www.googletagmanager.com/gtag/js?id={self.analytics_id}',
            html,
        )
        self.assertIn('src="analytics.js?v=1"', html)
        self.assertIn(
            f'const GOOGLE_ANALYTICS_ID = "{self.analytics_id}";',
            analytics,
        )
        self.assertIn("No in-app telemetry", html)
        self.assertTrue(all(not body.strip() for body in inline_script_bodies))
        self.assertIn(
            "script-src 'self' https://www.googletagmanager.com",
            nginx,
        )
        self.assertIn("https://*.google-analytics.com", nginx)
        self.assertIn("https://*.analytics.google.com", nginx)


class QuietRequestHandler(landing.PreviewMDRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass


class PreviewMDServerTests(unittest.TestCase):
    archive_name = "PreviewMD-1.7-11-macOS.dmg"

    def setUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.site_dir = self.root / "site"
        self.site_dir.mkdir()
        (self.site_dir / self.archive_name).write_bytes(b"test archive")

        self.original_db_path = landing.DB_PATH
        self.original_site_dir = landing.SITE_DIR
        landing.DB_PATH = self.root / "data" / "subscribers.sqlite3"
        landing.SITE_DIR = self.site_dir
        landing.initialize_database()

        handler = partial(QuietRequestHandler, directory=str(self.site_dir))
        self.http_server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.server_thread = threading.Thread(
            target=self.http_server.serve_forever,
            daemon=True,
        )
        self.server_thread.start()

    def tearDown(self) -> None:
        self.http_server.shutdown()
        self.http_server.server_close()
        self.server_thread.join(timeout=5)
        landing.DB_PATH = self.original_db_path
        landing.SITE_DIR = self.original_site_dir
        self.temporary_directory.cleanup()

    def post_json(
        self,
        path: str,
        payload: object,
    ) -> tuple[int, dict[str, object]]:
        body = json.dumps(payload).encode("utf-8")
        connection = http.client.HTTPConnection(
            "127.0.0.1",
            self.http_server.server_port,
            timeout=5,
        )
        try:
            connection.request(
                "POST",
                path,
                body=body,
                headers={"Content-Type": "application/json"},
            )
            response = connection.getresponse()
            response_body = json.loads(response.read())
            return response.status, response_body
        finally:
            connection.close()

    def test_download_endpoint_increments_aggregate_count(self) -> None:
        for expected_count in (1, 2):
            status, payload = self.post_json(
                "/api/download",
                {"file": self.archive_name},
            )

            self.assertEqual(status, 200)
            self.assertEqual(payload, {"ok": True, "status": "recorded"})
            with sqlite3.connect(landing.DB_PATH) as connection:
                row = connection.execute(
                    """
                    SELECT file_name, click_count, updated_at
                    FROM downloads
                    """
                ).fetchone()
            self.assertIsNotNone(row)
            self.assertEqual(row[0], self.archive_name)
            self.assertEqual(row[1], expected_count)
            self.assertRegex(row[2], r"^\d{4}-\d{2}-\d{2}T")

    def test_download_endpoint_rejects_unknown_or_unsafe_files(self) -> None:
        for file_name in (
            "PreviewMD-missing-macOS.dmg",
            "PreviewMD-missing-macOS.zip",
            "../PreviewMD-1.7-11-macOS.dmg",
            "../PreviewMD-1.7-11-macOS.zip",
            "PreviewMD-1.7-11-macOS.pkg",
            "not-previewmd.zip",
        ):
            status, payload = self.post_json(
                "/api/download",
                {"file": file_name},
            )
            self.assertEqual(status, 422)
            self.assertEqual(payload["error"], "invalid_download")

        with sqlite3.connect(landing.DB_PATH) as connection:
            count = connection.execute("SELECT COUNT(*) FROM downloads").fetchone()[0]
        self.assertEqual(count, 0)

    def test_subscribe_endpoint_still_normalizes_and_deduplicates_email(self) -> None:
        status, _ = self.post_json(
            "/api/subscribe",
            {"email": "  Reader@Example.com "},
        )
        duplicate_status, _ = self.post_json(
            "/api/subscribe",
            {"email": "reader@example.com"},
        )

        self.assertEqual(status, 201)
        self.assertEqual(duplicate_status, 200)
        with sqlite3.connect(landing.DB_PATH) as connection:
            rows = connection.execute("SELECT email FROM subscribers").fetchall()
        self.assertEqual(rows, [("reader@example.com",)])

    def test_database_initialization_is_an_idempotent_migration(self) -> None:
        legacy_database = self.root / "legacy.sqlite3"
        with sqlite3.connect(legacy_database) as connection:
            connection.execute(
                """
                CREATE TABLE subscribers (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    email TEXT NOT NULL COLLATE NOCASE UNIQUE,
                    created_at TEXT NOT NULL
                )
                """
            )
            connection.execute(
                """
                INSERT INTO subscribers (email, created_at)
                VALUES ('existing@example.com', '2026-01-01T00:00:00+00:00')
                """
            )
            connection.commit()

        landing.DB_PATH = legacy_database
        landing.initialize_database()
        landing.initialize_database()

        with sqlite3.connect(landing.DB_PATH) as connection:
            table_names = {
                row[0]
                for row in connection.execute(
                    """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table'
                    """
                )
            }
            subscribers = connection.execute(
                "SELECT email FROM subscribers"
            ).fetchall()
        self.assertIn("subscribers", table_names)
        self.assertIn("downloads", table_names)
        self.assertEqual(subscribers, [("existing@example.com",)])


if __name__ == "__main__":
    unittest.main()
