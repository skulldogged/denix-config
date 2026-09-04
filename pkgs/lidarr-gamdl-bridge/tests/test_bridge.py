from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

import bridge

API_KEY = "offline-test-key"


class FakeCatalog:
    def __init__(self, albums):
        self.albums = albums
        self.terms = []

    def search(self, term, limit):
        self.terms.append((term, limit))
        return self.albums[:limit]


class FileRunner:
    def __init__(self, files_to_write=None, returncode=0):
        self.files_to_write = files_to_write
        self.returncode = returncode
        self.calls = []

    def download(self, job, output_dir, temp_dir, cancel_event):
        self.calls.append((dict(job), output_dir, temp_dir))
        output_dir.mkdir(parents=True, exist_ok=True)
        temp_dir.mkdir(parents=True, exist_ok=True)
        count = (
            int(job["expected_tracks"])
            if self.files_to_write is None
            else self.files_to_write
        )
        album_dir = output_dir / job["artist"] / job["title"]
        album_dir.mkdir(parents=True, exist_ok=True)
        for index in range(count):
            (album_dir / f"{index + 1:02d}.m4a").write_bytes(b"audio")
        return bridge.ProcessResult(self.returncode)


class ConcurrentFileRunner(FileRunner):
    def __init__(self):
        super().__init__()
        self._lock = threading.Lock()
        self.active = 0
        self.max_active = 0
        self.two_started = threading.Event()
        self.release = threading.Event()

    def download(self, job, output_dir, temp_dir, cancel_event):
        with self._lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
            if self.active >= 2:
                self.two_started.set()
        try:
            if not self.release.wait(timeout=5):
                return bridge.ProcessResult(124)
            return super().download(job, output_dir, temp_dir, cancel_event)
        finally:
            with self._lock:
                self.active -= 1


class FakeProbe:
    def __init__(self, codec="alac", bit_depth=24):
        self.codec = codec
        self.bit_depth = bit_depth
        self.paths = []

    def inspect(self, path):
        self.paths.append(path)
        if not path.stat().st_size:
            return None
        return bridge.AudioProperties(self.codec, self.bit_depth)


class Harness:
    def __init__(self, albums, runner=None, probe=None):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.catalog = FakeCatalog(albums)
        self.runner = runner or FileRunner()
        self.probe = probe or FakeProbe()
        self.jobs = bridge.JobManager(
            self.root / "state" / "jobs.sqlite3",
            self.root / "downloads",
            self.root / "state" / "tmp",
            self.runner,
            self.probe,
            start_worker=False,
        )
        self.app = bridge.BridgeApp(API_KEY, self.catalog, self.jobs)
        self.server = bridge.create_server("127.0.0.1", 0, self.app)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        host, port = self.server.server_address
        self.origin = f"http://{host}:{port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.jobs.close()
        self.temp.cleanup()

    def get(self, path):
        with urllib.request.urlopen(self.origin + path, timeout=5) as response:
            return response.status, response.headers, response.read()

    def post_nzb(self, nzb):
        boundary = "offline-test-boundary"
        body = (
            (
                f"--{boundary}\r\n"
                'Content-Disposition: form-data; name="name"; filename="release.nzb"\r\n'
                "Content-Type: application/x-nzb\r\n\r\n"
            ).encode()
            + nzb
            + f"\r\n--{boundary}--\r\n".encode()
        )
        request = urllib.request.Request(
            self.origin + f"/api/sabnzbd/api?mode=addfile&apikey={API_KEY}",
            data=body,
            method="POST",
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read())


def album(**overrides):
    values = {
        "apple_id": "1889369103",
        "artist": "Westwood",
        "title": "Glamour",
        "url": "https://music.apple.com/us/album/glamour/1889369103",
        "release_date": "2025-12-19",
        "track_count": 3,
        "audio_traits": ("lossless", "hi-res-lossless", "lossy-stereo"),
        "explicit": False,
    }
    values.update(overrides)
    return bridge.Album(**values)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.harnesses = []

    def tearDown(self):
        for harness in self.harnesses:
            harness.close()

    def harness(self, albums, runner=None, probe=None):
        value = Harness(albums, runner, probe)
        self.harnesses.append(value)
        return value

    def test_caps_and_api_key(self):
        harness = self.harness([album()])
        with self.assertRaises(urllib.error.HTTPError) as caught:
            harness.get("/api/lidarr?t=caps")
        self.assertEqual(caught.exception.code, 403)
        caught.exception.close()

        status, headers, content = harness.get(f"/api/lidarr?t=caps&apikey={API_KEY}")
        self.assertEqual(status, 200)
        self.assertIn("application/xml", headers["Content-Type"])
        root = ET.fromstring(content)
        self.assertEqual(root.tag, "caps")
        subcategories = {node.get("id") for node in root.findall(".//subcat")}
        self.assertEqual(subcategories, {"3010", "3040"})

    def test_search_advertises_separate_alac_and_aac_candidates(self):
        harness = self.harness([album()])
        query = urllib.parse.urlencode(
            {"t": "music", "artist": "Westwood", "album": "Glamour", "apikey": API_KEY}
        )
        _, _, content = harness.get("/api/lidarr?" + query)
        root = ET.fromstring(content)
        items = root.findall(".//item")
        self.assertEqual(len(items), 2)
        titles = [item.findtext("title") for item in items]
        self.assertIn("ALAC 24bit", titles[0])
        self.assertIn("AAC-256", titles[1])
        self.assertEqual(harness.catalog.terms, [("Westwood Glamour", 25)])

        namespace = {"n": bridge.NEWZNAB_NS}
        categories = {
            attr.get("value")
            for item in items
            for attr in item.findall("n:attr", namespace)
            if attr.get("name") == "category"
        }
        self.assertEqual(categories, {"3010", "3040"})

    def test_empty_lidarr_validation_search_probes_the_real_catalog(self):
        harness = self.harness([album()])
        _, _, content = harness.get(
            f"/api/lidarr?t=search&cat=3010%2C3040&apikey={API_KEY}"
        )
        self.assertEqual(len(ET.fromstring(content).findall(".//item")), 2)
        self.assertEqual(harness.catalog.terms, [("Abbey Road", 25)])

    def test_search_download_queue_and_completed_history_flow(self):
        harness = self.harness([album()])
        query = urllib.parse.urlencode(
            {"t": "search", "q": "Westwood Glamour", "apikey": API_KEY}
        )
        _, _, search_xml = harness.get("/api/lidarr?" + query)
        item = ET.fromstring(search_xml).find(".//item")
        enclosure = item.find("enclosure")
        with urllib.request.urlopen(enclosure.get("url"), timeout=5) as response:
            nzb = response.read()

        status, added = harness.post_nzb(nzb)
        self.assertEqual(status, 200)
        self.assertTrue(added["status"])
        nzo_id = added["nzo_ids"][0]

        _, _, queue_body = harness.get(f"/api/sabnzbd/api?mode=queue&apikey={API_KEY}")
        queue = json.loads(queue_body)["queue"]
        self.assertEqual(queue["slots"][0]["nzo_id"], nzo_id)
        self.assertEqual(queue["slots"][0]["status"], "Queued")

        self.assertTrue(harness.jobs.run_once())
        _, _, history_body = harness.get(
            f"/api/sabnzbd/api?mode=history&apikey={API_KEY}"
        )
        history = json.loads(history_body)["history"]
        self.assertEqual(history["slots"][0]["status"], "Completed")
        storage = Path(history["slots"][0]["storage"])
        self.assertEqual(bridge.count_audio_files(storage), 3)
        self.assertTrue(storage.is_relative_to(harness.root / "downloads"))

    def test_multiple_workers_download_jobs_concurrently(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            runner = ConcurrentFileRunner()
            jobs = bridge.JobManager(
                root / "state" / "jobs.sqlite3",
                root / "downloads",
                root / "state" / "tmp",
                runner,
                FakeProbe(),
                start_worker=False,
                worker_count=2,
            )
            app = bridge.BridgeApp(API_KEY, FakeCatalog([album()]), jobs)
            payload = app.payload(app.candidates(album())[0])
            try:
                jobs.enqueue(payload)
                jobs.enqueue(payload)
                jobs.start()
                self.assertTrue(runner.two_started.wait(timeout=5))
                self.assertEqual(runner.max_active, 2)
                runner.release.set()

                deadline = time.monotonic() + 5
                while len(jobs.history()) < 2 and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertEqual(
                    [job["status"] for job in jobs.history()],
                    ["completed", "completed"],
                )
            finally:
                runner.release.set()
                jobs.close()

    def test_zero_exit_with_incomplete_album_is_failed_and_retryable(self):
        harness = self.harness([album()], FileRunner(files_to_write=2, returncode=0))
        candidate = harness.app.candidates(album())[0]
        token = bridge.encode_token(harness.app.payload(candidate), API_KEY)
        _, added = harness.post_nzb(bridge.make_nzb(token, candidate.release_name))
        nzo_id = added["nzo_ids"][0]
        harness.jobs.run_once()

        row = harness.jobs.history()[0]
        self.assertEqual(row["status"], "failed")
        self.assertEqual(row["audio_count"], 2)
        self.assertIn("found 2", row["error"])
        self.assertIn("exactly 3", row["error"])

        retry = harness.app.sab_action("retry", {"value": [nzo_id]})
        self.assertTrue(retry["status"])
        self.assertEqual(harness.jobs.queue()[0]["status"], "queued")
        self.assertFalse(Path(row["output_path"]).exists())

    def test_codec_probe_prevents_aac_from_completing_an_alac_job(self):
        harness = self.harness([album()], FileRunner(), FakeProbe("aac", 24))
        candidate = harness.app.candidates(album())[0]
        token = bridge.encode_token(harness.app.payload(candidate), API_KEY)
        _, added = harness.post_nzb(bridge.make_nzb(token, candidate.release_name))
        harness.jobs.run_once()
        row = harness.jobs.store.get(
            added["nzo_ids"][0].removeprefix(bridge.NZO_PREFIX)
        )
        self.assertEqual(row["status"], "failed")
        self.assertIn("codec validation failed", row["error"])
        self.assertEqual(len(harness.probe.paths), 3)

    def test_hires_candidate_requires_24_bit_files(self):
        harness = self.harness([album()], FileRunner(), FakeProbe("alac", 16))
        candidate = harness.app.candidates(album())[0]
        self.assertTrue(candidate.high_resolution)
        token = bridge.encode_token(harness.app.payload(candidate), API_KEY)
        _, added = harness.post_nzb(bridge.make_nzb(token, candidate.release_name))
        harness.jobs.run_once()
        row = harness.jobs.store.get(
            added["nzo_ids"][0].removeprefix(bridge.NZO_PREFIX)
        )
        self.assertEqual(row["status"], "failed")
        self.assertIn("24-bit validation failed", row["error"])

    def test_invalid_apple_url_is_never_advertised_or_accepted(self):
        harness = self.harness(
            [album(url="https://example.com/album/glamour/1889369103")]
        )
        _, _, content = harness.get(f"/api/lidarr?t=search&q=glamour&apikey={API_KEY}")
        self.assertEqual(ET.fromstring(content).findall(".//item"), [])

        payload = harness.app.payload(harness.app.candidates(album())[0])
        payload["url"] = "https://music.apple.com.evil.invalid/us/album/x/123"
        token = bridge.encode_token(payload, API_KEY)
        with self.assertRaises(bridge.InvalidToken):
            bridge.decode_token(token, API_KEY)

    def test_delete_removes_only_the_selected_scoped_job_directory(self):
        harness = self.harness([album()])
        candidate = harness.app.candidates(album())[0]
        token = bridge.encode_token(harness.app.payload(candidate), API_KEY)
        _, first = harness.post_nzb(bridge.make_nzb(token, candidate.release_name))
        _, second = harness.post_nzb(bridge.make_nzb(token, candidate.release_name))
        first_id = first["nzo_ids"][0]
        second_id = second["nzo_ids"][0]
        first_job = harness.jobs.store.get(first_id.removeprefix(bridge.NZO_PREFIX))
        second_job = harness.jobs.store.get(second_id.removeprefix(bridge.NZO_PREFIX))
        first_path = Path(first_job["output_path"])
        second_path = Path(second_job["output_path"])
        first_path.mkdir()
        second_path.mkdir()
        (first_path / "one.m4a").write_bytes(b"one")
        (second_path / "two.m4a").write_bytes(b"two")

        result = harness.app.sab_action(
            "queue",
            {"name": ["delete"], "value": [first_id], "del_files": ["1"]},
        )
        self.assertTrue(result["status"])
        self.assertFalse(first_path.exists())
        self.assertTrue(second_path.exists())
        self.assertTrue((second_path / "two.m4a").exists())

    def test_sab_validation_contract(self):
        harness = self.harness([album()])
        version = harness.app.sab_action("version", {})
        config = harness.app.sab_action("get_config", {})
        fullstatus = harness.app.sab_action("fullstatus", {})
        self.assertEqual(version["version"], "3.0.0")
        self.assertEqual(config["config"]["categories"][0]["name"], "music")
        self.assertEqual(
            fullstatus["status"]["completedir"],
            str(harness.root),
        )
        config_root = Path(config["config"]["misc"]["complete_dir"])
        category_dir = config["config"]["categories"][0]["dir"]
        self.assertEqual(config_root / category_dir, harness.root / "downloads")


if __name__ == "__main__":
    unittest.main()
