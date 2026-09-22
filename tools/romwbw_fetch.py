#!/usr/bin/env python3
"""Fetch a stock RomWBW ROM image through the romwbw_disks catalog.

The images are not in this repository -- they are large, they are not ours,
and they move independently.  ROMWBW_ROM points at one you already have; this
fetches one you do not:

    python tools/romwbw_fetch.py -o sim/SBC_simh_std.rom
    make romwbw ROMWBW_ROM=sim/SBC_simh_std.rom

or the same thing in one step, which is what the Makefile does with it:

    make romwbw ROMWBW_VERSION=3.6.0

Without --romwbw you get whatever the catalog calls its default, which is the
current release -- 3.6.0 today, and what you almost always want.  Naming one
is for pinning a build to a release, or for reaching a development snapshot,
which is hidden from a bare run because naming it is the opt-in.

It walks the v0 catalog at avwohl/romwbw_disks -- one stable index URL, then
one catalog per RomWBW release -- and reads that catalog's top-level
`upstream` object: the release tag, the URL of wwarthen's own Package.zip, and
the SHA-256 the download is checked against before it is opened.  The bytes
are upstream's; the catalog only says which zip and what it must hash to.

It never reads the catalog's `roms[]`.  Those are emulator ROMs whose bank 0
is an HBIOS proxy expecting a host that traps its ports, and they are silent
on this board -- docs/romwbw.md says why.

ROMWBW_INDEX_URL, or --index-url, points the whole walk at a fork's index,
which is how a forked catalog is tried without changing a line here.  It is
the same override, spelled the same way, as in romwbw_emu, cpmdroid, ioscpm
and z80cpmw.
"""

import argparse
import hashlib
import http.client
import json
import os
import posixpath
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

INDEX_URL = "https://github.com/avwohl/romwbw_disks/releases/latest/download/index-v0.json"
INTERFACE = "v0"
INDEX_SCHEMA = "romwbw-disks-index"
CATALOG_SCHEMA = "romwbw-disks-catalog"

# Where a stock Package.zip keeps the ROM, and how big that one is.  --member
# and --expect-size override both, because upstream reshuffling Binary/ is a
# thing that happens, and a development snapshot is where it happens first.
MEMBER = "Binary/SBC_simh_std.rom"
ROM_SIZE = 524288

# Bounds, so that a mistyped URL cannot stream a disk image into memory.
INDEX_MAX = 1 << 20
CATALOG_MAX = 4 << 20

UA = "romwbw_fetch/1 (+https://github.com/avwohl/z80fpga)"

# A flag, then the environment, then the one compiled in -- the same order the
# other four clients resolve these in, minus their stored setting, which wants
# a config file this repository does not have.  run_sst.py reads Z80_TESTS
# exactly this way, and argparse does the ordering.
DEFAULT_INDEX_URL = os.environ.get("ROMWBW_INDEX_URL", INDEX_URL)
DEFAULT_VERSION = os.environ.get("ROMWBW_VERSION", "")
DEFAULT_CACHE = os.environ.get(
    "ROMWBW_CACHE", os.path.join(os.path.expanduser("~"), ".cache", "romwbw_fetch"))
DEFAULT_PRERELEASE = os.environ.get("ROMWBW_PRERELEASE", "") not in ("", "0")

# A document may name a file for us to write.  This is the whole of what it is
# allowed to name: no separator of either kind, nothing starting with a dot.
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")

# Anything a socket can go wrong with.  IncompleteRead is an HTTPException, not
# an OSError, so it has to be named or it escapes both retry loops.
NET_ERRORS = (urllib.error.URLError, http.client.HTTPException, OSError)


class Bad(Exception):
    """Something is demonstrably wrong, as opposed to merely unreachable."""


def say(msg):
    print("romwbw_fetch: " + msg, file=sys.stderr)


def fnv1a32(text):
    """FNV-1a 64 folded to 32 bits, as the other four clients spell it.

    Copied from romwbw_emu/tools/romwbw-get so that a fork's downloads land in
    the same namespace here as they do there.
    """
    h = 0xcbf29ce484222325
    for b in text.encode("utf-8"):
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return "%08x" % (((h >> 32) ^ h) & 0xFFFFFFFF)


def index_scope(url):
    """The cache namespace a download from `url` lives under.

    Empty for the compiled-in index, so its paths never move; anything else
    gets a hash of the URL, which is what stops a fork's package sharing a
    filename with the real one and quietly being served in its place.
    """
    return "" if url == INDEX_URL else "@" + fnv1a32(url)


def package_name(url):
    """The cache filename for `url`, which the catalog does not get to choose.

    The last path segment, and only if it is a plain name.  os.path.join on
    Windows treats a backslash as a separator, so an unfiltered segment lets a
    document we fetched decide where on the disk we write -- which is the one
    thing the namespacing above exists to prevent.
    """
    name = posixpath.basename(urllib.parse.urlsplit(url).path)
    if not SAFE_NAME.match(name or ""):
        raise Bad("package_url does not end in a plain file name: %r" % url)
    return name


def http_get(url, max_bytes, timeout, retries):
    """Fetch a bounded document into memory."""
    last = None
    for attempt in range(retries + 1):
        if attempt:
            time.sleep(attempt)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                declared = r.length
                data = r.read(max_bytes + 1)
        except urllib.error.HTTPError as e:
            last = "HTTP %s" % e.code
            continue
        except NET_ERRORS as e:
            last = str(getattr(e, "reason", e))
            continue
        if len(data) > max_bytes:
            raise Bad("%s is bigger than the %d bytes a document here may be "
                      "-- is that URL really a catalog?" % (url, max_bytes))
        # A body that stops early is a transport failure, not a bad document:
        # read() returns b"" on a premature close rather than raising.
        if declared is not None and len(data) != declared:
            last = "short read, %d of %d bytes" % (len(data), declared)
            continue
        return data
    raise Bad("could not fetch %s: %s" % (url, last))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, dest, want_sha, timeout, retries):
    """Stream a large file to `dest`, and only call it that once it hashes.

    The bytes land in a .partial first, so an interrupted run cannot leave
    behind something that looks finished.  An existing file that already
    hashes right is reused; one that does not is replaced rather than trusted.
    """
    if os.path.exists(dest):
        if not want_sha:
            say("%s is cached but there is no hash to check it against"
                % os.path.basename(dest))
        elif sha256_file(dest) == want_sha:
            say("cached %s" % dest)
            return dest
        else:
            say("the cached %s does not match the catalog, fetching it again"
                % os.path.basename(dest))

    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    part = dest + ".partial"
    last = None
    for attempt in range(retries + 1):
        if attempt:
            time.sleep(attempt)
        h = hashlib.sha256()
        n = 0
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                declared = r.length
                with open(part, "wb") as f:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        h.update(chunk)
                        n += len(chunk)
                        f.write(chunk)
        except NET_ERRORS as e:
            last = str(getattr(e, "reason", e))
            continue
        # Same trap as above, and it matters more here: without this a dropped
        # connection is reported as the catalog publishing a wrong SHA-256,
        # and the retry that would have worked never happens.
        if declared is not None and n != declared:
            last = "short read, %d of %d bytes" % (n, declared)
            continue
        if want_sha and h.hexdigest() != want_sha:
            os.remove(part)
            raise Bad("%s hashed %s, but the catalog promised %s"
                      % (url, h.hexdigest(), want_sha))
        replace(part, dest)
        say("fetched %s (%d bytes)" % (dest, n))
        return dest
    raise Bad("could not fetch %s: %s" % (url, last))


def replace(part, dest):
    """Rename into place, saying which file was in the way when it fails."""
    try:
        os.replace(part, dest)
    except OSError as e:
        try:
            os.remove(part)
        except OSError:
            pass
        raise Bad("could not write %s: %s" % (dest, e))


def parsed(data, what):
    """A JSON object, or a message naming what was not one."""
    try:
        doc = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise Bad("%s is not JSON: %s" % (what, e))
    if not isinstance(doc, dict):
        raise Bad("%s is a %s, not an object" % (what, type(doc).__name__))
    return doc


def checked(data, size, sha, what):
    """Size first, then hash, and only then may anything parse it."""
    if size is not None and len(data) != size:
        raise Bad("%s is %d bytes, but the index says %d" % (what, len(data), size))
    if sha:
        got = hashlib.sha256(data).hexdigest()
        if got != sha:
            raise Bad("%s hashed %s, but the index says %s" % (what, got, sha))
    else:
        say("%s carries no sha256 in the index, so it is taken on trust" % what)
    return parsed(data, what)


def pick(entries, want, prerelease):
    """Which release to take.

    Naming one reaches it even when it is a snapshot -- naming it is itself
    the opt-in.  A bare run lands only on a real release, because a snapshot's
    version bytes are identical to those of the release it precedes, and
    nothing computed from the ROM can tell the two apart.
    """
    if want:
        for e in entries:
            if e.get("romwbw_version") == want:
                return e
        raise Bad("the index has no RomWBW %s; it offers %s"
                  % (want, ", ".join(e.get("romwbw_version", "?") for e in entries)))
    pool = [e for e in entries if prerelease or not e.get("prerelease")]
    if not pool:
        raise Bad("the index offers no released version, only snapshots; "
                  "name one, or pass --prerelease")
    for e in pool:
        if e.get("default"):
            return e
    return pool[0]


def member_of(zf, want):
    """The archive entry holding `want`, wherever the zip chose to put it.

    Upstream keeps them at the root today, but a zip that grows a top-level
    directory is a thing that happens, and the publisher's own
    tools/fetch_romwbw.sh already allows for it.
    """
    names = zf.namelist()
    if want in names:
        return want
    hits = [n for n in names if n.endswith("/" + want)]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        raise Bad("%s matches %d entries in the package: %s"
                  % (want, len(hits), ", ".join(sorted(hits))))
    # Only the neighbours, and not many of them: a RomWBW package carries some
    # six hundred .rom files, most of them MSX cartridges under Source/Images.
    where = want.rsplit("/", 1)[0] + "/" if "/" in want else ""
    near = sorted(n for n in names
                  if n.lower().endswith(".rom") and n.startswith(where))
    shown = ", ".join(near[:8]) + (", and %d more" % (len(near) - 8)
                                   if len(near) > 8 else "")
    raise Bad("%s is not in the package.  %s holds %s.  Name another with "
              "--member." % (want, where or "it", shown or "no .rom at all"))


def same_member(recorded, want):
    """Whether a recorded member is the one `want` would resolve to.

    member_of may have had to look past a top-level directory, so what was
    written down is the resolved name and what is asked for is the bare one.
    """
    return bool(recorded) and (recorded == want or recorded.endswith("/" + want))


def out_note(path):
    """What a previous run recorded about the image at `path`, if anything."""
    try:
        with open(path + ".provenance.json", encoding="utf-8") as f:
            note = json.load(f)
    except (OSError, ValueError):
        return None
    return note if os.path.exists(path) and isinstance(note, dict) else None


def already(note, index_url, version, args):
    """True when the image on disk is the one this run would have fetched.

    Worth being sure about: saying yes here skips a 200 MB download, and
    leaving the file's mtime alone is what stops make rebuilding behind it.
    """
    if not note:
        return False
    if (note.get("index_url") != index_url
            or note.get("romwbw_version") != version
            or not same_member(note.get("member"), args.member)):
        return False
    if args.expect_size and note.get("size") != args.expect_size:
        return False
    try:
        return note.get("sha256") == sha256_file(args.out)
    except OSError:
        return False


def hcb(data):
    """RomWBW's configuration block: the version and update bytes, or None."""
    if len(data) < 0x107 or data[0x103:0x105] != b"\x57\xa8":
        return None
    return data[0x105], data[0x106]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", help="write the ROM image here")
    ap.add_argument("--romwbw", default=DEFAULT_VERSION,
                    help="RomWBW release to take, e.g. 3.6.0 (default: the index's)")
    ap.add_argument("--index-url", default=DEFAULT_INDEX_URL,
                    help="override the compiled-in index URL")
    ap.add_argument("--prerelease", action="store_true", default=DEFAULT_PRERELEASE,
                    help="let a bare run land on a development snapshot")
    ap.add_argument("--member", default=MEMBER,
                    help="path inside the package to extract")
    ap.add_argument("--expect-size", type=int, default=ROM_SIZE,
                    help="fail unless the image is this many bytes, 0 to skip")
    ap.add_argument("--allow-unverified", action="store_true",
                    help="proceed when the catalog publishes no package hash")
    ap.add_argument("--cache", default=DEFAULT_CACHE,
                    help="where fetched packages are kept between runs")
    ap.add_argument("--list", action="store_true",
                    help="list what the index offers, and stop")
    ap.add_argument("--timeout", type=float, default=30.0, help="seconds per request")
    ap.add_argument("--retries", type=int, default=2, help="retries per request")
    args = ap.parse_args()

    if not args.list and not args.out:
        ap.error("say where the ROM goes with -o, or pass --list")

    # An exact release, already sitting there, is the whole answer: do not ask
    # anybody anything.  This is what lets a rebuild work with no network.
    if args.out and args.romwbw and already(out_note(args.out), args.index_url,
                                            args.romwbw, args):
        say("%s is already RomWBW %s, untouched" % (args.out, args.romwbw))
        print(args.out)
        return 0

    if args.index_url != INDEX_URL:
        say("using a non-default index: %s" % args.index_url)
        say("its downloads are kept apart, under %s"
            % os.path.join(args.cache, INTERFACE + index_scope(args.index_url)))

    index = parsed(http_get(args.index_url, INDEX_MAX, args.timeout, args.retries),
                   "the index")
    if index.get("schema") != INDEX_SCHEMA:
        raise Bad("%s is not a %s document" % (args.index_url, INDEX_SCHEMA))
    if index.get("interface") != INTERFACE:
        raise Bad("%s speaks interface %r, not %r"
                  % (args.index_url, index.get("interface"), INTERFACE))
    entries = [e for e in index.get("romwbw_versions") or []
               if isinstance(e, dict) and isinstance(e.get("romwbw_version"), str)]
    if not entries:
        raise Bad("%s lists no usable RomWBW version" % args.index_url)

    if args.list:
        for e in entries:
            marks = [m for m in ("default" if e.get("default") else "",
                                 "snapshot" if e.get("prerelease") else "") if m]
            print("%-14s %s%s" % (e["romwbw_version"], e.get("label", ""),
                                  "  [" + ", ".join(marks) + "]" if marks else ""))
        return 0

    entry = pick(entries, args.romwbw, args.prerelease)
    version = entry["romwbw_version"]
    if entry.get("prerelease"):
        say("%s is a development snapshot, not a release"
            % entry.get("label", version))
    if not args.romwbw:
        say("no release named, taking the catalog's default, %s" % version)

    # The bare run could not check this before it knew what the default was.
    if already(out_note(args.out), args.index_url, version, args):
        say("%s is already RomWBW %s, untouched" % (args.out, version))
        print(args.out)
        return 0

    cat_url = entry.get("catalog_url")
    if not cat_url:
        raise Bad("the index entry for %s names no catalog_url" % version)
    catalog = checked(http_get(cat_url, CATALOG_MAX, args.timeout, args.retries),
                      entry.get("catalog_size"), entry.get("catalog_sha256"),
                      "the catalog for %s" % version)
    if catalog.get("schema") != CATALOG_SCHEMA:
        raise Bad("%s is not a %s document" % (cat_url, CATALOG_SCHEMA))
    if catalog.get("interface") != INTERFACE:
        raise Bad("%s speaks interface %r, not %r"
                  % (cat_url, catalog.get("interface"), INTERFACE))
    if catalog.get("romwbw_version") != version:
        raise Bad("the index calls that release %s and its own catalog calls "
                  "it %s" % (version, catalog.get("romwbw_version")))

    up = catalog.get("upstream") or {}
    pkg_url = up.get("package_url")
    pkg_sha = up.get("package_sha256")
    if not pkg_url:
        raise Bad("the catalog for %s names no upstream package" % version)
    if not pkg_sha and not args.allow_unverified:
        # A null hash is legal -- the schema says the field is nullable -- so
        # this is not a malformed catalog.  It is a catalog that pins nothing,
        # and pinning the package is what keeps a dev build out of a release,
        # so the choice to take it anyway should be made out loud.
        raise Bad("the catalog for %s pins no package_sha256, which the schema "
                  "allows but leaves HTTPS as the whole of the check.  Pass "
                  "--allow-unverified to take it anyway." % version)

    pkg = os.path.join(args.cache, INTERFACE + index_scope(args.index_url),
                       package_name(pkg_url))
    download(pkg_url, pkg, pkg_sha, args.timeout, args.retries)

    try:
        with zipfile.ZipFile(pkg) as zf:
            name = member_of(zf, args.member)
            data = zf.read(name)
    except (zipfile.BadZipFile, OSError) as e:
        raise Bad("%s is not a readable zip: %s" % (pkg, e))

    if args.expect_size and len(data) != args.expect_size:
        raise Bad("%s is %d bytes, not the %d expected -- pass --expect-size 0 "
                  "if that is right" % (name, len(data), args.expect_size))

    promised = entry.get("hbios") or {}
    seen = hcb(data)
    if seen is None:
        say("%s carries no RomWBW configuration block at 0x103" % name)
    else:
        for i, (label, key) in enumerate((("version", "ver_byte"),
                                          ("update", "upd_byte"))):
            said = promised.get(key)
            try:
                mismatch = said is not None and int(str(said), 16) != seen[i]
            except ValueError:
                mismatch = False
            if mismatch:
                say("%s reports its %s byte as 0x%02x, but the index says %s"
                    % (name, label, seen[i], said))

    out = args.out
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    part = out + ".partial"
    with open(part, "wb") as f:
        f.write(data)
    replace(part, out)

    rom_sha = hashlib.sha256(data).hexdigest()
    with open(out + ".provenance.json", "w", newline="\n") as f:
        json.dump({"index_url": args.index_url,
                   "member": name,
                   "package_sha256": pkg_sha,
                   "package_url": pkg_url,
                   "prerelease": bool(entry.get("prerelease")),
                   "romwbw_version": version,
                   "sha256": rom_sha,
                   "size": len(data),
                   "upstream_tag": up.get("tag")}, f, indent=2, sort_keys=True)
        f.write("\n")

    say("RomWBW %s, %s, %s" % (version, up.get("tag", "?"), name))
    say("%s: %d bytes, sha256 %s" % (out, len(data), rom_sha))
    print(out)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Bad as e:
        say(str(e))
        raise SystemExit(1)
