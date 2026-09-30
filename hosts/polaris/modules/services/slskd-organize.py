# Files a manual slskd download into the music library by its tags, using
# the same layout as Lidarr: Artist/Album/NN. Title.ext. Lidarr's own grabs
# land under lidarr/ and are left for Lidarr to import.
#
# slskd reads stdout at debug level and logs any stderr as a warning, so
# stderr is reserved for files that were left behind.
import json
import os
import re
import sys
from pathlib import Path

import mutagen

DOWNLOADS = Path("/mnt/downloads/slskd")
LIDARR_DOWNLOADS = DOWNLOADS / "lidarr"
LIBRARY = Path("/mnt/music")
AUDIO = {
    ".aac", ".aif", ".aiff", ".alac", ".ape", ".flac", ".m4a", ".mp3",
    ".oga", ".ogg", ".opus", ".wav", ".wma", ".wv",
}
IMAGES = {".jpeg", ".jpg", ".png", ".webp"}
# Lidarr drops these characters because replaceIllegalCharacters is off.
ILLEGAL = re.compile(r'[\\/<>?*:|"]')


def clean(name):
    return " ".join(ILLEGAL.sub("", name).split()).strip(" .")


def first(tags, *keys):
    for key in keys:
        values = tags.get(key)
        if values and str(values[0]).strip():
            return str(values[0]).strip()
    return ""


def number(value):
    match = re.match(r"\s*(\d+)", value)
    return int(match.group(1)) if match else None


def existing(parent, name):
    """Reuse a folder that differs only by case, e.g. an artist's."""
    folded = name.casefold()
    if parent.is_dir():
        for entry in parent.iterdir():
            if entry.is_dir() and entry.name.casefold() == folded:
                return entry
    return parent / name


def move(source, target):
    # link+unlink never replaces a file already in the library.
    try:
        os.link(source, target)
    except OSError:
        return False
    os.unlink(source)
    return True


def read(path):
    try:
        audio = mutagen.File(path, easy=True)
    except mutagen.MutagenError:
        return None
    tags = audio.tags if audio is not None else None
    if tags is None:
        return None

    artist = clean(first(tags, "albumartist", "album artist", "artist"))
    album = clean(first(tags, "album"))
    if not artist or not album:
        return None

    disc_tag = first(tags, "discnumber")
    discs = number(first(tags, "disctotal", "totaldiscs"))
    if discs is None and "/" in disc_tag:
        discs = number(disc_tag.split("/", 1)[1])

    return {
        "path": path,
        "artist": artist,
        "album": album,
        "title": clean(first(tags, "title")) or clean(path.stem),
        "track": number(first(tags, "tracknumber")),
        "disc": number(disc_tag) or 1,
        "discs": discs or 1,
    }


def main():
    event = json.loads(os.environ.get("SLSKD_SCRIPT_DATA", "{}"))
    local = event.get("localDirectoryName") or "/"
    directory = Path(os.path.realpath(local))
    if (
        directory == DOWNLOADS
        or not directory.is_relative_to(DOWNLOADS)
        or directory.is_relative_to(LIDARR_DOWNLOADS)
        or not directory.is_dir()
    ):
        return

    tracks, untagged = [], []
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.suffix.lower() in AUDIO:
            track = read(path)
            if track:
                tracks.append(track)
            else:
                untagged.append(path.name)

    multi_disc = {
        (t["artist"], t["album"])
        for t in tracks
        if t["disc"] > 1 or t["discs"] > 1
    }

    album_dirs, unmoved = set(), []
    for t in tracks:
        artist_dir = existing(LIBRARY, t["artist"])
        album_dir = existing(artist_dir, t["album"])
        album_dir.mkdir(parents=True, exist_ok=True)

        stem = t["title"]
        if t["track"] is not None:
            prefix = f"{t['track']:02d}"
            if (t["artist"], t["album"]) in multi_disc:
                prefix = f"{t['disc']:02d}-{prefix}"
            stem = f"{prefix}. {stem}"
        target = album_dir / (stem + t["path"].suffix)

        if not move(t["path"], target):
            unmoved.append(t["path"].name)
            continue
        album_dirs.add(album_dir)

        lyrics = t["path"].with_suffix(".lrc")
        if lyrics.is_file():
            move(lyrics, target.with_suffix(".lrc"))

    if len(album_dirs) == 1 and not untagged and not unmoved:
        (album_dir,) = album_dirs
        for path in directory.iterdir():
            if path.is_file() and path.suffix.lower() in IMAGES:
                move(path, album_dir / path.name)

    try:
        directory.rmdir()
    except OSError:
        pass

    for album_dir in sorted(album_dirs):
        print(f"Filed into {album_dir}")
    if untagged:
        print(
            f"Left {len(untagged)} file(s) without artist/album tags"
            f" in {directory}",
            file=sys.stderr,
        )
    if unmoved:
        print(
            f"Left {len(unmoved)} file(s) already in the library or"
            f" unmovable in {directory}",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
