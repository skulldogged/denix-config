"""A small Newznab/SABnzbd compatibility bridge for Lidarr and gamdl.

Lidarr already knows how to search a Newznab indexer and how to supervise a
SABnzbd download client.  This process implements only those two narrow
protocol surfaces.  Catalog searches use gamdl's authenticated Apple Music
API, while a configurable pool of background workers invokes ``python -m
gamdl`` for grabs.

The module deliberately has no import-time dependency on gamdl.  That keeps
the protocol and persistence code independently testable and, more
importantly, lets us configure structlog before gamdl initializes its APIs.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import dataclasses
import datetime as dt
import email.parser
import email.policy
import hashlib
import hmac
import json
import logging
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from collections.abc import Callable, Iterable, Mapping, Sequence
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import parse_qs, quote, urlsplit, urlunsplit

LOG = logging.getLogger("lidarr-gamdl-bridge")
NEWZNAB_NS = "http://www.newznab.com/DTD/2010/feeds/attributes/"
NZB_NS = "http://www.newzbin.com/DTD/2003/nzb"
SAB_VERSION = "3.0.0"
MAX_UPLOAD_BYTES = 1024 * 1024
MAX_TOKEN_BYTES = 16 * 1024
AUDIO_EXTENSIONS = frozenset(
    {".aac", ".alac", ".ape", ".flac", ".m4a", ".mp4", ".wav", ".wv"}
)
NZO_PREFIX = "gamdl_nzo_"

ET.register_namespace("newznab", NEWZNAB_NS)


class BridgeError(Exception):
    """An expected request or bridge-state error."""


class InvalidToken(BridgeError):
    """The opaque grab token is invalid or was not issued by this bridge."""


@dataclasses.dataclass(frozen=True)
class Album:
    apple_id: str
    artist: str
    title: str
    url: str
    release_date: str
    track_count: int
    audio_traits: tuple[str, ...]
    explicit: bool = False


class Catalog(Protocol):
    def search(self, term: str, limit: int) -> Sequence[Album]: ...


@dataclasses.dataclass(frozen=True)
class ProcessResult:
    returncode: int
    cancelled: bool = False


class DownloadRunner(Protocol):
    def download(
        self,
        job: Mapping[str, Any],
        output_dir: Path,
        temp_dir: Path,
        cancel_event: threading.Event,
    ) -> ProcessResult: ...


@dataclasses.dataclass(frozen=True)
class AudioProperties:
    codec_name: str
    bits_per_raw_sample: int | None


class AudioProbe(Protocol):
    def inspect(self, path: Path) -> AudioProperties | None: ...


def validate_apple_album_url(value: str) -> str:
    """Return a normalized Apple Music album URL or raise ``BridgeError``.

    Only HTTPS catalog album URLs on the exact music.apple.com host are
    accepted.  This check is repeated after an NZB upload so signed metadata
    can never become a general-purpose subprocess URL input.
    """

    if not isinstance(value, str) or len(value) > 2048:
        raise BridgeError("invalid Apple Music album URL")
    parsed = urlsplit(value)
    if (
        parsed.scheme.lower() != "https"
        or parsed.hostname is None
        or parsed.hostname.lower() != "music.apple.com"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port not in (None, 443)
    ):
        raise BridgeError("invalid Apple Music album URL")

    segments = [segment for segment in parsed.path.split("/") if segment]
    try:
        album_index = segments.index("album")
    except ValueError as exc:
        raise BridgeError("invalid Apple Music album URL") from exc
    if album_index + 2 >= len(segments) or not segments[-1].isdigit():
        raise BridgeError("invalid Apple Music album URL")
    if album_index != len(segments) - 3:
        raise BridgeError("invalid Apple Music album URL")

    return urlunsplit(("https", "music.apple.com", parsed.path, parsed.query, ""))


def count_audio_files(root: Path) -> int:
    if not root.is_dir():
        return 0
    return sum(
        1
        for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS
    )


def directory_size(root: Path) -> int:
    if not root.is_dir():
        return 0
    total = 0
    for path in root.rglob("*"):
        try:
            if path.is_file():
                total += path.stat().st_size
        except OSError:
            # Lidarr may move files while history is being polled.
            continue
    return total


def _scoped_path(path: Path, root: Path) -> Path:
    resolved_root = root.resolve(strict=False)
    resolved_path = path.resolve(strict=False)
    if resolved_path == resolved_root or resolved_root not in resolved_path.parents:
        raise BridgeError("refusing to operate outside the managed directory")
    return resolved_path


def safe_remove_tree(path: Path, root: Path) -> None:
    """Remove one job directory, never the configured root or an outside path."""

    _scoped_path(path, root)
    if path.is_symlink():
        path.unlink(missing_ok=True)
    elif path.exists():
        shutil.rmtree(path)


def _token_bytes(payload: Mapping[str, Any]) -> bytes:
    return json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def encode_token(payload: Mapping[str, Any], api_key: str) -> str:
    data = _token_bytes(payload)
    if len(data) > MAX_TOKEN_BYTES:
        raise BridgeError("grab metadata is too large")
    encoded = base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")
    signature = hmac.new(api_key.encode(), encoded.encode(), hashlib.sha256).hexdigest()
    return f"{encoded}.{signature}"


def _bounded_string(payload: Mapping[str, Any], key: str, maximum: int) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise InvalidToken(f"invalid {key}")
    return value


def decode_token(token: str, api_key: str) -> dict[str, Any]:
    if not isinstance(token, str) or len(token) > MAX_TOKEN_BYTES * 2:
        raise InvalidToken("invalid grab token")
    try:
        encoded, supplied_signature = token.rsplit(".", 1)
    except ValueError as exc:
        raise InvalidToken("invalid grab token") from exc
    expected_signature = hmac.new(
        api_key.encode(), encoded.encode(), hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(supplied_signature, expected_signature):
        raise InvalidToken("invalid grab token")
    try:
        padding = "=" * (-len(encoded) % 4)
        raw = base64.b64decode(encoded + padding, altchars=b"-_", validate=True)
        payload = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeError, json.JSONDecodeError) as exc:
        raise InvalidToken("invalid grab token") from exc
    if not isinstance(payload, dict) or payload.get("v") != 1:
        raise InvalidToken("unsupported grab token")

    codec = _bounded_string(payload, "codec", 8).lower()
    if codec not in {"alac", "aac"}:
        raise InvalidToken("invalid codec")
    expected_tracks = payload.get("expected_tracks")
    if (
        isinstance(expected_tracks, bool)
        or not isinstance(expected_tracks, int)
        or not 1 <= expected_tracks <= 1000
    ):
        raise InvalidToken("invalid expected track count")
    apple_id = _bounded_string(payload, "apple_id", 32)
    if not apple_id.isdigit():
        raise InvalidToken("invalid Apple Music ID")

    high_resolution = payload.get("high_resolution", False)
    if not isinstance(high_resolution, bool) or (high_resolution and codec != "alac"):
        raise InvalidToken("invalid high-resolution marker")
    try:
        validated = {
            "v": 1,
            "apple_id": apple_id,
            "artist": _bounded_string(payload, "artist", 512),
            "title": _bounded_string(payload, "title", 512),
            "release_name": _bounded_string(payload, "release_name", 1200),
            "url": validate_apple_album_url(_bounded_string(payload, "url", 2048)),
            "codec": codec,
            "expected_tracks": expected_tracks,
            "high_resolution": high_resolution,
        }
    except BridgeError as exc:
        raise InvalidToken("invalid grab token") from exc
    return validated


def make_nzb(token: str, release_name: str) -> bytes:
    root = ET.Element(f"{{{NZB_NS}}}nzb")
    head = ET.SubElement(root, f"{{{NZB_NS}}}head")
    ET.SubElement(head, f"{{{NZB_NS}}}meta", {"type": "title"}).text = release_name
    ET.SubElement(head, f"{{{NZB_NS}}}meta", {"type": "gamdl-token"}).text = token
    file_node = ET.SubElement(
        root,
        f"{{{NZB_NS}}}file",
        {"date": str(int(time.time())), "subject": release_name},
    )
    groups = ET.SubElement(file_node, f"{{{NZB_NS}}}groups")
    ET.SubElement(groups, f"{{{NZB_NS}}}group").text = "alt.binaries.sounds.lossless"
    segments = ET.SubElement(file_node, f"{{{NZB_NS}}}segments")
    ET.SubElement(
        segments,
        f"{{{NZB_NS}}}segment",
        {"bytes": "1", "number": "1"},
    ).text = "lidarr-gamdl-bridge"
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def token_from_nzb(content: bytes) -> str:
    if not content or len(content) > MAX_UPLOAD_BYTES:
        raise BridgeError("invalid NZB upload")
    try:
        root = ET.fromstring(content)
    except ET.ParseError as exc:
        raise BridgeError("invalid NZB upload") from exc
    for element in root.iter():
        if (
            element.tag.rsplit("}", 1)[-1] == "meta"
            and element.get("type") == "gamdl-token"
            and element.text
        ):
            return element.text.strip()
    raise BridgeError("gamdl metadata is missing from NZB")


def parse_multipart_nzb(content_type: str, content: bytes) -> bytes:
    if len(content) > MAX_UPLOAD_BYTES or len(content_type) > 500:
        raise BridgeError("NZB upload is too large")
    if not content_type.lower().startswith("multipart/form-data"):
        raise BridgeError("multipart/form-data is required")
    try:
        synthetic_message = (
            f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode("ascii")
            + content
        )
    except UnicodeEncodeError as exc:
        raise BridgeError("invalid multipart content type") from exc
    message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
        synthetic_message
    )
    if not message.is_multipart():
        raise BridgeError("invalid multipart upload")
    for part in message.iter_parts():
        field_name = part.get_param("name", header="content-disposition")
        if field_name == "name":
            data = part.get_payload(decode=True)
            if data:
                return data
    raise BridgeError("NZB file field is missing")


class GamdlCatalog:
    """Authenticated Apple Music catalog search using gamdl's wrapper API."""

    def __init__(
        self,
        wrapper_url: str,
        decrypt_host: str,
        decrypt_port: int,
    ) -> None:
        self.wrapper_url = wrapper_url
        self.decrypt_host = decrypt_host
        self.decrypt_port = decrypt_port
        self._lock = threading.Lock()

    @staticmethod
    def _configure_quiet_structlog() -> None:
        # WrapperApi.get_me logs the complete response at DEBUG, including auth
        # material.  Configure the filtering wrapper before importing/creating
        # either gamdl API and discard third-party structured events entirely.
        import structlog

        structlog.configure(
            processors=[structlog.processors.add_log_level],
            logger_factory=structlog.ReturnLoggerFactory(),
            wrapper_class=structlog.make_filtering_bound_logger(logging.WARNING),
            cache_logger_on_first_use=True,
        )

    async def _search(self, term: str, limit: int) -> Sequence[Album]:
        self._configure_quiet_structlog()
        # Import only after structlog is made safe.  There are intentionally no
        # gamdl imports at module scope.
        from gamdl.api import AppleMusicApi
        from gamdl.api.wrapper import WrapperApi

        wrapper_api = None
        apple_api = None
        try:
            wrapper_api = await WrapperApi.create(
                base_url=self.wrapper_url,
                decrypt_host=self.decrypt_host,
                decrypt_port=self.decrypt_port,
            )
            apple_api = await AppleMusicApi.create_from_wrapper(wrapper_api=wrapper_api)
            result = await apple_api.get_search_results(
                term=term,
                types="albums",
                limit=limit,
            )
            raw_albums = (
                result.get("results", {}).get("albums", {}).get("data", [])
                if isinstance(result, dict)
                else []
            )
            albums: list[Album] = []
            for raw_album in raw_albums:
                if not isinstance(raw_album, dict):
                    continue
                attributes = raw_album.get("attributes", {})
                if not isinstance(attributes, dict):
                    continue
                try:
                    apple_id = str(raw_album["id"])
                    artist = str(attributes["artistName"]).strip()
                    title = str(attributes["name"]).strip()
                    url = validate_apple_album_url(str(attributes["url"]))
                    track_count = max(1, int(attributes.get("trackCount", 1)))
                except (KeyError, TypeError, ValueError, BridgeError):
                    continue
                raw_traits = attributes.get("audioTraits", [])
                traits = tuple(
                    str(trait).lower() for trait in raw_traits if isinstance(trait, str)
                )
                if not apple_id.isdigit() or not artist or not title:
                    continue
                albums.append(
                    Album(
                        apple_id=apple_id,
                        artist=artist,
                        title=title,
                        url=url,
                        release_date=str(attributes.get("releaseDate", "")),
                        track_count=track_count,
                        audio_traits=traits,
                        explicit=attributes.get("contentRating") == "explicit",
                    )
                )
            return albums
        finally:
            clients = []
            if apple_api is not None:
                clients.append(getattr(apple_api, "client", None))
            if wrapper_api is not None:
                clients.append(getattr(wrapper_api, "client", None))
            for client in clients:
                if client is not None:
                    try:
                        await client.aclose()
                    except Exception:  # noqa: BLE001,S110 - never log auth-bearing clients
                        pass

    def search(self, term: str, limit: int) -> Sequence[Album]:
        # Serialize searches because each one initializes and closes its own
        # authenticated client pair.  No API object or token is retained.
        with self._lock:
            return asyncio.run(self._search(term, limit))


class GamdlRunner:
    def __init__(
        self,
        wrapper_url: str,
        decrypt_host: str,
        decrypt_port: int,
        ffmpeg_path: str,
        *,
        popen_factory: Callable[..., subprocess.Popen[Any]] = subprocess.Popen,
        poll_interval: float = 0.25,
    ) -> None:
        self.wrapper_url = wrapper_url
        self.decrypt_host = decrypt_host
        self.decrypt_port = decrypt_port
        self.ffmpeg_path = ffmpeg_path
        self.popen_factory = popen_factory
        self.poll_interval = poll_interval

    def command(
        self, job: Mapping[str, Any], output_dir: Path, temp_dir: Path
    ) -> list[str]:
        # ALAC and AAC are intentionally separate grabs.  In particular, an
        # ALAC result must never silently fall back to AAC after Lidarr accepted
        # it as a lossless release.
        return [
            sys.executable,
            "-m",
            "gamdl",
            "--no-config-file",
            "--no-exceptions",
            "--log-level",
            "INFO",
            "--wrapper-url",
            self.wrapper_url,
            "--wrapper-decrypt-host",
            self.decrypt_host,
            "--wrapper-decrypt-port",
            str(self.decrypt_port),
            "--ffmpeg-path",
            self.ffmpeg_path,
            "--use-wrapper",
            "--song-codec-priority",
            str(job["codec"]),
            "--synced-lyrics-format",
            "lrc",
            "--output-path",
            str(output_dir),
            "--temp-path",
            str(temp_dir),
            str(job["url"]),
        ]

    @staticmethod
    def _terminate_process_group(process: subprocess.Popen[Any]) -> None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                process.kill()
            process.wait()

    def download(
        self,
        job: Mapping[str, Any],
        output_dir: Path,
        temp_dir: Path,
        cancel_event: threading.Event,
    ) -> ProcessResult:
        output_dir.mkdir(parents=True, exist_ok=True)
        temp_dir.mkdir(parents=True, exist_ok=True)
        process = self.popen_factory(
            self.command(job, output_dir, temp_dir),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        while True:
            returncode = process.poll()
            if returncode is not None:
                return ProcessResult(returncode=returncode)
            if cancel_event.wait(self.poll_interval):
                self._terminate_process_group(process)
                return ProcessResult(
                    returncode=process.returncode or -signal.SIGTERM, cancelled=True
                )


class FfprobeAudioProbe:
    """Inspect the codec and bit depth actually staged for Lidarr."""

    def __init__(self, ffprobe_path: str) -> None:
        self.ffprobe_path = ffprobe_path

    def inspect(self, path: Path) -> AudioProperties | None:
        try:
            if not path.is_file() or path.stat().st_size <= 0:
                return None
            completed = subprocess.run(
                [
                    self.ffprobe_path,
                    "-v",
                    "error",
                    "-select_streams",
                    "a:0",
                    "-show_entries",
                    "stream=codec_name,bits_per_raw_sample,bits_per_sample",
                    "-of",
                    "json",
                    str(path),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                text=True,
                timeout=30,
            )
            response = json.loads(completed.stdout) if completed.returncode == 0 else {}
            stream = response.get("streams", [])[0]
            codec_name = stream.get("codec_name")
            raw_bits = stream.get("bits_per_raw_sample") or stream.get(
                "bits_per_sample"
            )
            bit_depth = int(raw_bits) if raw_bits not in (None, "", "0", 0) else None
        except (
            OSError,
            ValueError,
            KeyError,
            IndexError,
            TypeError,
            json.JSONDecodeError,
            subprocess.TimeoutExpired,
        ):
            return None
        if not isinstance(codec_name, str) or not codec_name:
            return None
        return AudioProperties(codec_name.lower(), bit_depth)


class JobStore:
    def __init__(self, database_path: Path) -> None:
        self.database_path = database_path
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=15)
        connection.row_factory = sqlite3.Row
        return connection

    @contextmanager
    def connection(self):
        connection = self._connect()
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def _initialize(self) -> None:
        with self.connection() as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    status TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    started_at REAL,
                    finished_at REAL,
                    apple_id TEXT NOT NULL,
                    artist TEXT NOT NULL,
                    title TEXT NOT NULL,
                    release_name TEXT NOT NULL,
                    url TEXT NOT NULL,
                    codec TEXT NOT NULL,
                    expected_tracks INTEGER NOT NULL,
                    high_resolution INTEGER NOT NULL DEFAULT 0,
                    output_path TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    error TEXT NOT NULL DEFAULT '',
                    returncode INTEGER,
                    audio_count INTEGER NOT NULL DEFAULT 0,
                    size_bytes INTEGER NOT NULL DEFAULT 0
                )
                """
            )
            columns = {
                row[1]
                for row in connection.execute("PRAGMA table_info(jobs)").fetchall()
            }
            if "high_resolution" not in columns:
                connection.execute(
                    "ALTER TABLE jobs ADD COLUMN high_resolution INTEGER NOT NULL DEFAULT 0"
                )
            # A process killed during a download leaves a retryable queued job.
            connection.execute(
                "UPDATE jobs SET status = 'queued', started_at = NULL "
                "WHERE status = 'downloading'"
            )

    @staticmethod
    def _row(row: sqlite3.Row | None) -> dict[str, Any] | None:
        return dict(row) if row is not None else None

    def add(self, payload: Mapping[str, Any], output_path: Path) -> dict[str, Any]:
        job_id = uuid.uuid4().hex
        now = time.time()
        with self.connection() as connection:
            connection.execute(
                """
                INSERT INTO jobs (
                    id, status, created_at, updated_at, apple_id, artist, title,
                    release_name, url, codec, expected_tracks, high_resolution, output_path,
                    payload_json
                ) VALUES (?, 'queued', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job_id,
                    now,
                    now,
                    payload["apple_id"],
                    payload["artist"],
                    payload["title"],
                    payload["release_name"],
                    payload["url"],
                    payload["codec"],
                    payload["expected_tracks"],
                    int(bool(payload["high_resolution"])),
                    str(output_path),
                    json.dumps(payload, ensure_ascii=False, sort_keys=True),
                ),
            )
        job = self.get(job_id)
        assert job is not None
        return job

    def get(self, job_id: str) -> dict[str, Any] | None:
        with self.connection() as connection:
            row = connection.execute(
                "SELECT * FROM jobs WHERE id = ?", (job_id,)
            ).fetchone()
        return self._row(row)

    def claim(self) -> dict[str, Any] | None:
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM jobs WHERE status = 'queued' ORDER BY created_at LIMIT 1"
            ).fetchone()
            if row is None:
                connection.commit()
                return None
            now = time.time()
            connection.execute(
                "UPDATE jobs SET status = 'downloading', started_at = ?, "
                "updated_at = ? WHERE id = ? AND status = 'queued'",
                (now, now, row["id"]),
            )
            connection.commit()
            return self.get(str(row["id"]))
        finally:
            connection.close()

    def finish(
        self,
        job_id: str,
        *,
        status: str,
        error: str,
        returncode: int,
        audio_count: int,
        size_bytes: int,
    ) -> None:
        now = time.time()
        with self.connection() as connection:
            connection.execute(
                """
                UPDATE jobs SET status = ?, error = ?, returncode = ?,
                    audio_count = ?, size_bytes = ?, finished_at = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    status,
                    error,
                    returncode,
                    audio_count,
                    size_bytes,
                    now,
                    now,
                    job_id,
                ),
            )

    def list_statuses(self, statuses: Iterable[str]) -> list[dict[str, Any]]:
        statuses = tuple(statuses)
        if not statuses:
            return []
        placeholders = ",".join("?" for _ in statuses)
        with self.connection() as connection:
            rows = connection.execute(
                f"SELECT * FROM jobs WHERE status IN ({placeholders}) "
                "ORDER BY created_at DESC",
                statuses,
            ).fetchall()
        return [dict(row) for row in rows]

    def delete(self, job_id: str) -> bool:
        with self.connection() as connection:
            cursor = connection.execute("DELETE FROM jobs WHERE id = ?", (job_id,))
        return cursor.rowcount > 0

    def retry(self, job_id: str) -> bool:
        now = time.time()
        with self.connection() as connection:
            cursor = connection.execute(
                """
                UPDATE jobs SET status = 'queued', updated_at = ?, started_at = NULL,
                    finished_at = NULL, error = '', returncode = NULL,
                    audio_count = 0, size_bytes = 0
                WHERE id = ? AND status = 'failed'
                """,
                (now, job_id),
            )
        return cursor.rowcount > 0

    def set_output_path(self, job_id: str, output_path: Path) -> None:
        with self.connection() as connection:
            connection.execute(
                "UPDATE jobs SET output_path = ? WHERE id = ?",
                (str(output_path), job_id),
            )


class JobManager:
    def __init__(
        self,
        database_path: Path,
        download_root: Path,
        temp_root: Path,
        runner: DownloadRunner,
        probe: AudioProbe,
        *,
        start_worker: bool = True,
        worker_count: int = 1,
    ) -> None:
        if worker_count < 1:
            raise ValueError("worker_count must be at least 1")
        self.download_root = download_root.resolve(strict=False)
        self.temp_root = temp_root.resolve(strict=False)
        self.download_root.mkdir(parents=True, exist_ok=True)
        self.temp_root.mkdir(parents=True, exist_ok=True)
        self.runner = runner
        self.probe = probe
        self.store = JobStore(database_path)
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._active_lock = threading.Lock()
        self._active: dict[str, tuple[threading.Event, threading.Event]] = {}
        self._cancelled_ids: set[str] = set()
        self._worker_count = worker_count
        self._workers: list[threading.Thread] = []
        if start_worker:
            self.start()

    def start(self) -> None:
        if self._workers:
            return
        for worker_number in range(1, self._worker_count + 1):
            worker = threading.Thread(
                target=self._worker_loop,
                name=f"gamdl-download-worker-{worker_number}",
                daemon=True,
            )
            self._workers.append(worker)
            worker.start()

    def close(self) -> None:
        self._stop.set()
        self._wake.set()
        with self._active_lock:
            active = list(self._active.values())
        for cancel_event, _ in active:
            cancel_event.set()
        for worker in self._workers:
            worker.join(timeout=15)

    def enqueue(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        job_id = uuid.uuid4().hex
        # JobStore owns the final identifier, so build the final path only after
        # insertion and replace it in a second, tightly scoped update.
        temporary_path = self.download_root / f"pending-{job_id}"
        job = self.store.add(payload, temporary_path)
        output_path = self.download_root / job["id"]
        _scoped_path(output_path, self.download_root)
        self.store.set_output_path(job["id"], output_path)
        self._wake.set()
        result = self.store.get(job["id"])
        assert result is not None
        return result

    def _temp_path(self, job_id: str) -> Path:
        path = self.temp_root / job_id
        _scoped_path(path, self.temp_root)
        return path

    def _run_job(self, job: Mapping[str, Any]) -> bool:
        job_id = str(job["id"])
        cancel_event = threading.Event()
        done_event = threading.Event()
        with self._active_lock:
            if job_id in self._cancelled_ids:
                return True
            self._active[job_id] = (cancel_event, done_event)

        output_path = Path(str(job["output_path"]))
        temp_path = self._temp_path(job_id)
        try:
            _scoped_path(output_path, self.download_root)
            result = self.runner.download(job, output_path, temp_path, cancel_event)
            if result.cancelled or cancel_event.is_set():
                return True

            audio_files = (
                [
                    path
                    for path in output_path.rglob("*")
                    if path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS
                ]
                if output_path.is_dir()
                else []
            )
            actual_count = len(audio_files)
            expected_count = int(job["expected_tracks"])
            size_bytes = directory_size(output_path)
            properties = [self.probe.inspect(path) for path in audio_files]
            wrong_codec_count = sum(
                prop is None or prop.codec_name != str(job["codec"]).lower()
                for prop in properties
            )
            insufficient_depth_count = (
                sum(
                    prop is None
                    or prop.bits_per_raw_sample is None
                    or prop.bits_per_raw_sample < 24
                    for prop in properties
                )
                if bool(job.get("high_resolution"))
                else 0
            )
            if result.returncode != 0:
                status = "failed"
                error = f"gamdl exited with code {result.returncode}"
            elif actual_count != expected_count:
                status = "failed"
                error = (
                    f"album mismatch: found {actual_count} audio files; "
                    f"expected exactly {expected_count}"
                )
            elif wrong_codec_count:
                status = "failed"
                error = (
                    f"codec validation failed for {wrong_codec_count} of "
                    f"{actual_count} audio files"
                )
            elif insufficient_depth_count:
                status = "failed"
                error = (
                    f"24-bit validation failed for {insufficient_depth_count} of "
                    f"{actual_count} audio files"
                )
            else:
                status = "completed"
                error = ""
            self.store.finish(
                job_id,
                status=status,
                error=error,
                returncode=result.returncode,
                audio_count=actual_count,
                size_bytes=size_bytes,
            )
            return True
        except Exception as exc:  # noqa: BLE001 - worker boundary must persist failures
            # Persist only the exception type.  Third-party HTTP exceptions may
            # carry response bodies, and wrapper response bodies can contain
            # authentication material.
            self.store.finish(
                job_id,
                status="failed",
                error=f"download failed ({type(exc).__name__})",
                returncode=-1,
                audio_count=count_audio_files(output_path),
                size_bytes=directory_size(output_path),
            )
            LOG.warning("gamdl job %s failed (%s)", job_id, type(exc).__name__)
            return True
        finally:
            try:
                safe_remove_tree(temp_path, self.temp_root)
            except BridgeError:
                LOG.warning("refused to clean a temp path for job %s", job_id)
            with self._active_lock:
                self._active.pop(job_id, None)
                done_event.set()

    def run_once(self) -> bool:
        job = self.store.claim()
        if job is None:
            return False
        return self._run_job(job)

    def _worker_loop(self) -> None:
        while not self._stop.is_set():
            if self.run_once():
                continue
            self._wake.wait(1)
            self._wake.clear()

    @staticmethod
    def _job_id(nzo_id: str) -> str:
        if not isinstance(nzo_id, str) or not nzo_id.startswith(NZO_PREFIX):
            raise BridgeError("invalid download ID")
        job_id = nzo_id[len(NZO_PREFIX) :]
        if not re.fullmatch(r"[0-9a-f]{32}", job_id):
            raise BridgeError("invalid download ID")
        return job_id

    def delete(self, nzo_id: str, delete_files: bool) -> bool:
        job_id = self._job_id(nzo_id)
        job = self.store.get(job_id)
        if job is None:
            return False
        output_path = Path(str(job["output_path"]))
        temp_path = self._temp_path(job_id)
        _scoped_path(output_path, self.download_root)
        _scoped_path(temp_path, self.temp_root)

        with self._active_lock:
            self._cancelled_ids.add(job_id)
            active = self._active.get(job_id)
            if active is not None:
                active[0].set()
        if active is not None:
            active[1].wait(timeout=15)

        removed = self.store.delete(job_id)
        if delete_files:
            safe_remove_tree(output_path, self.download_root)
        safe_remove_tree(temp_path, self.temp_root)
        with self._active_lock:
            self._cancelled_ids.discard(job_id)
        return removed

    def retry(self, nzo_id: str) -> bool:
        job_id = self._job_id(nzo_id)
        job = self.store.get(job_id)
        if job is None or job["status"] != "failed":
            return False
        output_path = Path(str(job["output_path"]))
        safe_remove_tree(output_path, self.download_root)
        safe_remove_tree(self._temp_path(job_id), self.temp_root)
        retried = self.store.retry(job_id)
        if retried:
            self._wake.set()
        return retried

    def queue(self) -> list[dict[str, Any]]:
        return self.store.list_statuses(("queued", "downloading"))

    def history(self) -> list[dict[str, Any]]:
        return self.store.list_statuses(("completed", "failed"))


@dataclasses.dataclass(frozen=True)
class Candidate:
    album: Album
    codec: str
    quality_name: str
    category_id: str
    category_name: str
    estimated_size: int
    release_name: str
    high_resolution: bool = False


class BridgeApp:
    def __init__(
        self,
        api_key: str,
        catalog: Catalog,
        jobs: JobManager,
        *,
        include_aac: bool = True,
        catalog_limit: int = 25,
    ) -> None:
        if not api_key:
            raise ValueError("api_key must not be empty")
        self.api_key = api_key
        self.catalog = catalog
        self.jobs = jobs
        self.include_aac = include_aac
        self.catalog_limit = max(1, min(catalog_limit, 50))

    def authenticated(self, query: Mapping[str, Sequence[str]], headers: Any) -> bool:
        supplied = ""
        for name in ("apikey", "api_key"):
            values = query.get(name)
            if values:
                supplied = values[0]
                break
        if not supplied:
            supplied = headers.get("X-Api-Key", "")
        return bool(supplied) and hmac.compare_digest(str(supplied), self.api_key)

    @staticmethod
    def _search_term(query: Mapping[str, Sequence[str]]) -> str:
        parts: list[str] = []
        for name in ("artist", "album", "q"):
            values = query.get(name)
            if values:
                value = values[0].strip()
                if value and value not in parts:
                    parts.append(value)
        return " ".join(parts)

    def candidates(self, album: Album) -> list[Candidate]:
        try:
            normalized_url = validate_apple_album_url(album.url)
        except BridgeError:
            return []
        album = dataclasses.replace(album, url=normalized_url)
        traits = {trait.lower() for trait in album.audio_traits}
        year = album.release_date[:4] if re.match(r"^\d{4}", album.release_date) else ""
        explicit = " [EXPLICIT]" if album.explicit else ""
        tracks = max(1, album.track_count)
        results: list[Candidate] = []
        if "lossless" in traits or "hi-res-lossless" in traits:
            high_resolution = "hi-res-lossless" in traits
            quality = "ALAC 24bit" if high_resolution else "ALAC"
            release_name = (
                f"{album.artist} - {album.title}"
                f"{f' ({year})' if year else ''}{explicit} {quality} "
                f"[WEB]-gamdl ({tracks} tracks)"
            )
            results.append(
                Candidate(
                    album=album,
                    codec="alac",
                    quality_name=quality,
                    category_id="3040",
                    category_name="Audio > Lossless",
                    estimated_size=tracks
                    * (80 if high_resolution else 40)
                    * 1024
                    * 1024,
                    release_name=release_name,
                    high_resolution=high_resolution,
                )
            )
        if self.include_aac and "lossy-stereo" in traits:
            quality = "AAC-256"
            release_name = (
                f"{album.artist} - {album.title}"
                f"{f' ({year})' if year else ''}{explicit} {quality} "
                f"[WEB]-gamdl ({tracks} tracks)"
            )
            results.append(
                Candidate(
                    album=album,
                    codec="aac",
                    quality_name=quality,
                    category_id="3010",
                    category_name="Audio > MP3",
                    estimated_size=tracks * 10 * 1024 * 1024,
                    release_name=release_name,
                )
            )
        return results

    def payload(self, candidate: Candidate) -> dict[str, Any]:
        return {
            "v": 1,
            "apple_id": candidate.album.apple_id,
            "artist": candidate.album.artist,
            "title": candidate.album.title,
            "release_name": candidate.release_name,
            "url": candidate.album.url,
            "codec": candidate.codec,
            "expected_tracks": max(1, candidate.album.track_count),
            "high_resolution": candidate.high_resolution,
        }

    @staticmethod
    def caps_xml() -> bytes:
        root = ET.Element("caps")
        ET.SubElement(
            root,
            "server",
            {
                "version": "1.0",
                "title": "Lidarr gamdl bridge",
                "strapline": "Authenticated Apple Music catalog via gamdl",
                "email": "none@localhost",
                "url": "http://127.0.0.1/",
            },
        )
        ET.SubElement(root, "limits", {"max": "100", "default": "25"})
        searching = ET.SubElement(root, "searching")
        ET.SubElement(searching, "search", {"available": "yes", "supportedParams": "q"})
        ET.SubElement(
            searching,
            "audio-search",
            {"available": "yes", "supportedParams": "q,artist,album"},
        )
        categories = ET.SubElement(root, "categories")
        audio = ET.SubElement(categories, "category", {"id": "3000", "name": "Audio"})
        ET.SubElement(audio, "subcat", {"id": "3010", "name": "MP3"})
        ET.SubElement(audio, "subcat", {"id": "3040", "name": "Lossless"})
        return ET.tostring(root, encoding="utf-8", xml_declaration=True)

    def search_xml(self, query: Mapping[str, Sequence[str]], origin: str) -> bytes:
        # Lidarr validates Newznab indexers with an empty search and rejects a
        # successful response containing no category-matching items.  A small
        # real catalog probe both satisfies that contract and proves the
        # wrapper session is authenticated before bootstrap reports success.
        # A one-word generic term is rejected by Apple's authenticated search
        # endpoint on some storefronts; this canonical album query is stable
        # enough for the validation probe and returns ordinary catalog data.
        term = self._search_term(query) or "Abbey Road"
        albums = self.catalog.search(term, self.catalog_limit)
        all_candidates = [
            candidate for album in albums for candidate in self.candidates(album)
        ]
        try:
            offset = max(0, int(query.get("offset", ["0"])[0]))
            limit = max(1, min(100, int(query.get("limit", ["100"])[0])))
        except (ValueError, TypeError):
            offset, limit = 0, 100
        candidates = all_candidates[offset : offset + limit]

        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Lidarr gamdl bridge"
        ET.SubElement(
            channel, "description"
        ).text = "Apple Music releases available through gamdl"
        ET.SubElement(channel, "link").text = origin
        ET.SubElement(
            channel,
            f"{{{NEWZNAB_NS}}}response",
            {"offset": str(offset), "total": str(len(all_candidates))},
        )
        for candidate in candidates:
            payload = self.payload(candidate)
            token = encode_token(payload, self.api_key)
            download_url = (
                f"{origin}/api/lidarr/download/{token}"
                f"?apikey={quote(self.api_key, safe='')}"
            )
            album = candidate.album
            item = ET.SubElement(channel, "item")
            ET.SubElement(item, "title").text = candidate.release_name
            ET.SubElement(
                item, "guid", {"isPermaLink": "false"}
            ).text = f"gamdl:{album.apple_id}:{candidate.codec}"
            ET.SubElement(item, "link").text = album.url
            release_date = album.release_date[:10]
            try:
                parsed_date = dt.datetime.strptime(release_date, "%Y-%m-%d").replace(
                    tzinfo=dt.timezone.utc
                )
            except ValueError:
                parsed_date = dt.datetime.now(dt.timezone.utc)
            ET.SubElement(item, "pubDate").text = parsed_date.strftime(
                "%a, %d %b %Y %H:%M:%S GMT"
            )
            ET.SubElement(item, "category").text = candidate.category_name
            ET.SubElement(
                item, "description"
            ).text = f"{candidate.release_name} from Apple Music"
            ET.SubElement(
                item,
                "enclosure",
                {
                    "url": download_url,
                    "length": str(candidate.estimated_size),
                    "type": "application/x-nzb",
                },
            )
            attributes = {
                "artist": album.artist,
                "album": album.title,
                "size": str(candidate.estimated_size),
                "category": candidate.category_id,
                "tracks": str(max(1, album.track_count)),
            }
            if re.match(r"^\d{4}", album.release_date):
                attributes["year"] = album.release_date[:4]
            for name, value in attributes.items():
                ET.SubElement(
                    item,
                    f"{{{NEWZNAB_NS}}}attr",
                    {"name": name, "value": value},
                )
        return ET.tostring(root, encoding="utf-8", xml_declaration=True)

    def queue_json(self, query: Mapping[str, Sequence[str]]) -> dict[str, Any]:
        rows = self.jobs.queue()
        slots = []
        for index, row in enumerate(rows):
            downloading = row["status"] == "downloading"
            size_mb = max(
                0, int(row["expected_tracks"]) * (80 if row["codec"] == "alac" else 10)
            )
            slots.append(
                {
                    "status": "Downloading" if downloading else "Queued",
                    "index": index,
                    "timeleft": "0:00:00",
                    "mb": str(size_mb),
                    "filename": row["release_name"],
                    "priority": "Normal",
                    "cat": "music",
                    "mbleft": str(size_mb),
                    "percentage": 50 if downloading else 0,
                    "nzo_id": NZO_PREFIX + row["id"],
                }
            )
        slots = self._page(slots, query)
        return {
            "queue": {
                "status": "Downloading" if slots else "Idle",
                "paused": False,
                "pause_int": "0",
                "noofslots": len(rows),
                "start": self._integer_param(query, "start", 0),
                "limit": self._integer_param(query, "limit", 0),
                "slots": slots,
            }
        }

    def history_json(self, query: Mapping[str, Sequence[str]]) -> dict[str, Any]:
        rows = self.jobs.history()
        slots = []
        for row in rows:
            completed = row["status"] == "completed"
            start = row["started_at"] or row["created_at"]
            finish = row["finished_at"] or row["updated_at"]
            slots.append(
                {
                    "fail_message": "" if completed else row["error"],
                    "bytes": int(row["size_bytes"]),
                    "category": "music",
                    "nzb_name": row["release_name"],
                    "download_time": max(0, int(finish - start)),
                    "storage": row["output_path"],
                    "status": "Completed" if completed else "Failed",
                    "nzo_id": NZO_PREFIX + row["id"],
                    "name": row["release_name"],
                }
            )
        slots = self._page(slots, query)
        return {
            "history": {
                "paused": False,
                "noofslots": len(rows),
                "slots": slots,
            }
        }

    @staticmethod
    def _integer_param(
        query: Mapping[str, Sequence[str]], name: str, default: int
    ) -> int:
        try:
            return int(query.get(name, [str(default)])[0])
        except (ValueError, TypeError):
            return default

    @classmethod
    def _page(
        cls, values: Sequence[dict[str, Any]], query: Mapping[str, Sequence[str]]
    ) -> list[dict[str, Any]]:
        start = max(0, cls._integer_param(query, "start", 0))
        limit = cls._integer_param(query, "limit", 0)
        if limit > 0:
            return list(values[start : start + limit])
        return list(values[start:])

    def sab_action(
        self,
        mode: str,
        query: Mapping[str, Sequence[str]],
        *,
        nzb_content: bytes | None = None,
    ) -> dict[str, Any]:
        if mode == "version":
            return {"version": SAB_VERSION}
        if mode == "get_config":
            complete_dir = str(self.jobs.download_root.parent)
            category_dir = self.jobs.download_root.name
            return {
                "config": {
                    "version": SAB_VERSION,
                    "servers": [],
                    "categories": [
                        {
                            "name": "music",
                            "priority": 0,
                            "pp": "3",
                            "script": "None",
                            "dir": category_dir,
                        },
                        {
                            "name": "*",
                            "priority": 0,
                            "pp": "3",
                            "script": "None",
                            "dir": category_dir,
                        },
                    ],
                    "misc": {
                        "complete_dir": complete_dir,
                        "download_dir": complete_dir,
                        "api_key": "",
                        "enable_tv_sorting": False,
                        "enable_movie_sorting": False,
                        "enable_date_sorting": False,
                        "tv_categories": [],
                        "movie_categories": [],
                        "date_categories": [],
                    },
                }
            }
        if mode == "fullstatus":
            return {"status": {"completedir": str(self.jobs.download_root.parent)}}
        if mode == "addfile":
            if nzb_content is None:
                raise BridgeError("NZB file is missing")
            token = token_from_nzb(nzb_content)
            payload = decode_token(token, self.api_key)
            job = self.jobs.enqueue(payload)
            return {"status": True, "nzo_ids": [NZO_PREFIX + job["id"]]}
        if mode in {"queue", "history"}:
            action = query.get("name", [""])[0]
            if action == "delete":
                nzo_id = query.get("value", [""])[0]
                delete_files = query.get("del_files", ["0"])[0] in {"1", "true", "True"}
                removed = self.jobs.delete(nzo_id, delete_files)
                return {
                    "status": removed,
                    "nzo_ids": [nzo_id] if removed else [],
                    "error": "" if removed else "download not found",
                }
            return (
                self.queue_json(query) if mode == "queue" else self.history_json(query)
            )
        if mode == "retry":
            nzo_id = query.get("value", [""])[0]
            retried = self.jobs.retry(nzo_id)
            return {
                "status": retried,
                "nzo_id": nzo_id if retried else "",
                "error": "" if retried else "download cannot be retried",
            }
        raise BridgeError("unsupported SABnzbd mode")


class BridgeRequestHandler(BaseHTTPRequestHandler):
    server_version = "lidarr-gamdl-bridge/1"

    @property
    def app(self) -> BridgeApp:
        return self.server.app  # type: ignore[attr-defined,no-any-return]

    def log_message(self, format: str, *args: Any) -> None:
        # BaseHTTPRequestHandler logs the full request target, which contains
        # the API key in Lidarr's query string.  Do not emit access logs.
        return

    def _send(self, status: int, content_type: str, content: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(content)

    def _json(self, status: int, value: Mapping[str, Any]) -> None:
        self._send(
            status,
            "application/json; charset=utf-8",
            json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode(
                "utf-8"
            ),
        )

    def _origin(self) -> str:
        host = self.headers.get("Host", "")
        if not re.fullmatch(r"[A-Za-z0-9.:[\]-]+", host):
            address = self.server.server_address  # type: ignore[attr-defined]
            host = f"{address[0]}:{address[1]}"
        return f"http://{host}".rstrip("/")

    def _route(self) -> tuple[str, dict[str, list[str]]]:
        parsed = urlsplit(self.path)
        return parsed.path.rstrip("/") or "/", parse_qs(
            parsed.query, keep_blank_values=True
        )

    def _authorize(self, query: Mapping[str, Sequence[str]]) -> bool:
        if self.app.authenticated(query, self.headers):
            return True
        self._json(403, {"status": False, "error": "authentication required"})
        return False

    def do_GET(self) -> None:
        path, query = self._route()
        if path == "/health":
            self._json(200, {"status": "ok"})
            return
        if not self._authorize(query):
            return
        try:
            if path == "/api/lidarr":
                mode = query.get("t", ["search"])[0]
                if mode == "caps":
                    self._send(
                        200, "application/xml; charset=utf-8", self.app.caps_xml()
                    )
                elif mode in {"search", "music", "album"}:
                    xml = self.app.search_xml(query, self._origin())
                    self._send(200, "application/rss+xml; charset=utf-8", xml)
                else:
                    raise BridgeError("unsupported Newznab search type")
                return
            prefix = "/api/lidarr/download/"
            if path.startswith(prefix):
                token = path[len(prefix) :]
                payload = decode_token(token, self.app.api_key)
                self._send(
                    200,
                    "application/x-nzb",
                    make_nzb(token, payload["release_name"]),
                )
                return
            if path == "/api/sabnzbd/api":
                mode = query.get("mode", [""])[0]
                self._json(200, self.app.sab_action(mode, query))
                return
            self._json(404, {"status": False, "error": "not found"})
        except InvalidToken:
            self._json(400, {"status": False, "error": "invalid grab token"})
        except BridgeError as exc:
            self._json(400, {"status": False, "error": str(exc)})
        except Exception as exc:  # noqa: BLE001 - HTTP boundary sanitizes failures
            # Never include a third-party exception string in the HTTP response.
            LOG.warning("request failed (%s)", type(exc).__name__)
            self._json(502, {"status": False, "error": "upstream request failed"})

    def do_POST(self) -> None:
        path, query = self._route()
        if not self._authorize(query):
            return
        try:
            if path != "/api/sabnzbd/api" or query.get("mode", [""])[0] != "addfile":
                raise BridgeError("unsupported request")
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError as exc:
                raise BridgeError("Content-Length is required") from exc
            if not 0 < length <= MAX_UPLOAD_BYTES:
                raise BridgeError("invalid upload size")
            body = self.rfile.read(length)
            nzb = parse_multipart_nzb(self.headers.get("Content-Type", ""), body)
            self._json(200, self.app.sab_action("addfile", query, nzb_content=nzb))
        except InvalidToken:
            self._json(400, {"status": False, "error": "invalid grab token"})
        except BridgeError as exc:
            self._json(400, {"status": False, "error": str(exc)})
        except Exception as exc:  # noqa: BLE001 - HTTP boundary sanitizes failures
            LOG.warning("upload failed (%s)", type(exc).__name__)
            self._json(500, {"status": False, "error": "upload failed"})


class BridgeHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], app: BridgeApp) -> None:
        self.app = app
        super().__init__(address, BridgeRequestHandler)


def create_server(host: str, port: int, app: BridgeApp) -> BridgeHTTPServer:
    return BridgeHTTPServer((host, port), app)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--host", default=os.environ.get("LIDARR_GAMDL_HOST", "127.0.0.1")
    )
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("LIDARR_GAMDL_PORT", "8787"))
    )
    parser.add_argument("--api-key", default=os.environ.get("LIDARR_GAMDL_API_KEY"))
    parser.add_argument(
        "--api-key-file",
        type=Path,
        default=(
            Path(os.environ["LIDARR_GAMDL_API_KEY_FILE"])
            if os.environ.get("LIDARR_GAMDL_API_KEY_FILE")
            else None
        ),
    )
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=Path(
            os.environ.get("LIDARR_GAMDL_STATE_DIR", "/var/lib/lidarr-gamdl-bridge")
        ),
    )
    parser.add_argument(
        "--download-dir",
        type=Path,
        default=Path(
            os.environ.get("LIDARR_GAMDL_DOWNLOAD_DIR", "/mnt/downloads/gamdl")
        ),
    )
    parser.add_argument(
        "--wrapper-url",
        default=os.environ.get("LIDARR_GAMDL_WRAPPER_URL", "http://127.0.0.1:8080"),
    )
    parser.add_argument(
        "--decrypt-host",
        default=os.environ.get("LIDARR_GAMDL_DECRYPT_HOST", "127.0.0.1"),
    )
    parser.add_argument(
        "--decrypt-port",
        type=int,
        default=int(os.environ.get("LIDARR_GAMDL_DECRYPT_PORT", "10020")),
    )
    parser.add_argument(
        "--ffmpeg-path",
        default=os.environ.get(
            "LIDARR_GAMDL_FFMPEG_PATH", shutil.which("ffmpeg") or "ffmpeg"
        ),
    )
    parser.add_argument(
        "--ffprobe-path",
        default=os.environ.get(
            "LIDARR_GAMDL_FFPROBE_PATH", shutil.which("ffprobe") or "ffprobe"
        ),
    )
    parser.add_argument("--catalog-limit", type=int, default=25)
    parser.add_argument(
        "--workers",
        type=int,
        default=int(os.environ.get("LIDARR_GAMDL_WORKERS", "1")),
        help="Number of album downloads to run concurrently (default: 1)",
    )
    parser.add_argument(
        "--disable-aac",
        action="store_true",
        help="Do not advertise the lower-priority AAC fallback",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.api_key and args.api_key_file:
        parser.error("--api-key and --api-key-file are mutually exclusive")
    api_key = args.api_key
    if args.api_key_file:
        try:
            api_key = args.api_key_file.read_text(encoding="utf-8").strip()
        except OSError:
            parser.error("the API key file could not be read")
    if not api_key:
        parser.error(
            "--api-key, --api-key-file, or the corresponding environment variable is required"
        )
    if not 1 <= args.port <= 65535 or not 1 <= args.decrypt_port <= 65535:
        parser.error("ports must be between 1 and 65535")
    if not 1 <= args.workers <= 16:
        parser.error("workers must be between 1 and 16")

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    # httpx logs full request URLs at INFO.  Search terms are not credentials,
    # but they do not belong in routine service logs either.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    state_dir = args.state_dir.resolve(strict=False)
    download_dir = args.download_dir.resolve(strict=False)
    state_dir.mkdir(parents=True, exist_ok=True)
    download_dir.mkdir(parents=True, exist_ok=True)
    runner = GamdlRunner(
        args.wrapper_url,
        args.decrypt_host,
        args.decrypt_port,
        args.ffmpeg_path,
    )
    probe = FfprobeAudioProbe(args.ffprobe_path)
    jobs = JobManager(
        state_dir / "jobs.sqlite3",
        download_dir,
        state_dir / "tmp",
        runner,
        probe,
        worker_count=args.workers,
    )
    catalog = GamdlCatalog(args.wrapper_url, args.decrypt_host, args.decrypt_port)
    app = BridgeApp(
        api_key,
        catalog,
        jobs,
        include_aac=not args.disable_aac,
        catalog_limit=args.catalog_limit,
    )
    server = create_server(args.host, args.port, app)

    def stop_server(_signum: int, _frame: Any) -> None:
        # shutdown() must be called from a different thread than serve_forever.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop_server)
    signal.signal(signal.SIGINT, stop_server)
    LOG.info(
        "listening on %s:%s with %s download workers",
        args.host,
        args.port,
        args.workers,
    )
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        jobs.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
