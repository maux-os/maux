#!/usr/bin/env python3
"""Assemble the GitHub Pages tree (docs/SITE-PAGES.md).

  site_pages.py release --version X.Y.Z   build/pages/ from dist/maux-X.Y.Z/
  site_pages.py preview [--port N]        build/pages-preview/ from build/full.po

Nothing here pushes. `release` prints the publish commands and runs none.
Refusals (exit 1, a REFUSE line): a missing bundle, an image that does not
match its SHA256SUMS line or is not the release shape, a demo in site/demos
with no film, a lesson session of another disk, and any check-site finding
over the finished tree.
"""
import argparse
import hashlib
import re
import shutil
import sys
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import check_site  # noqa: E402
import demo_phos  # noqa: E402
import demo_stamp  # noqa: E402

VOL_BLOCKS = 65535
FILE_BLOCKS = 65536
# docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits
PAGES_MAX = 1 << 30           # "Published GitHub Pages sites may be no larger than 1 GB"
# docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github
GIT_WARN = 50 << 20           # warning above 50 MiB per file
GIT_BLOCK = 100 << 20         # blocked above 100 MiB per file
PAGES = 'https://maux-os.github.io/maux/'
REPO = 'maux-os/maux'


def refuse(msg):
    print('REFUSE site-pages: ' + msg)
    sys.exit(1)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for c in iter(lambda: f.read(1 << 20), b''):
            h.update(c)
    return h.hexdigest()


def check_release_shape(img):
    """The shipped shape (build_release.validate_release_file): 65,536
    blocks, header still 65,535, trailing block zero."""
    data = Path(img).read_bytes()
    if len(data) != FILE_BLOCKS * 512:
        refuse('%s is %d bytes, not %d (a release image is %d blocks)'
               % (Path(img).name, len(data), FILE_BLOCKS * 512, FILE_BLOCKS))
    if int.from_bytes(data[2 * 512 + 0x29:2 * 512 + 0x2b], 'little') != VOL_BLOCKS:
        refuse('%s: the ProDOS header does not say %d blocks' % (Path(img).name, VOL_BLOCKS))
    if any(data[VOL_BLOCKS * 512:]):
        refuse('%s: the trailing block is not all zero' % Path(img).name)
    return data


def check_demos():
    """Every demo must have the //e's film on every monitor. One
    phosphor present and another missing is the shape a partial
    `make demos --phosphor X` leaves behind, and it would ship a page
    whose monitor button 404s, so all of them are required by name
    (docs/DEMO-PHOSPHOR.md)."""
    names = sorted(p.stem for p in (ROOT / 'site/demos').glob('*.py'))
    missing = []
    for n in names:
        for ph in demo_phos.NAMES:
            fn = demo_stamp.out_name('mp4', n, '', ph)
            if not (ROOT / 'build/demos' / n / fn).is_file():
                missing.append('%s/%s' % (n, fn))
    if missing:
        refuse('demo film(s) missing from build/demos: %s (run make demos); '
               'a release page ships every film on every monitor'
               % ', '.join(missing))
    return names


def assemble(out, image_url, apple2ts, repo_url, revision, full_image, local,
             ut=False, image_sha=None):
    """Render the site into `out` through check_site.run, so the tree is
    checked by the same code as `make check-site` (without its self-test)."""
    if out.exists():
        shutil.rmtree(out)
    extra = ['--cache', str(ROOT / 'build/site-cache'),
             '--image-url', image_url, '--apple2ts-url', apple2ts,
             '--repo-url', repo_url, '--full-image', str(full_image)]
    if image_sha:
        extra += ['--image-sha256', image_sha]
    if revision:
        extra += ['--revision', revision]
    if ut:                          # the UltraTerm films: off by default
        extra.append('--ut')
    errs, b = check_site.run(ROOT, ROOT / 'site', out, extra, full=True, local_ok=local)
    if errs:
        for e in errs:
            print('FAIL site:', e)
        hint = ''
        if any('stale session' in e for e in errs):
            hint = (' (stale lesson session: run make check-examples on the '
                    'full.po the release was cut from)')
        shutil.rmtree(out, ignore_errors=True)   # no rendered tree with stale films
        refuse('check-site found %d problem(s)%s' % (len(errs), hint))
    return b


def size_report(out):
    files = sorted(((p.stat().st_size, p) for p in out.rglob('*') if p.is_file()),
                   reverse=True)
    total = sum(s for s, _ in files)
    print('size report: %d files, %d bytes (%.1f MiB)' % (len(files), total, total / 1048576))
    for s, p in files[:6]:
        print('  %12d  %s' % (s, p.relative_to(out)))
    print('  limits: published site <= 1 GB (%d bytes): %.1f%% used'
          % (PAGES_MAX, 100.0 * total / PAGES_MAX))
    print('          per file: git warns > 50 MiB, blocks > 100 MiB; largest is %.1f MiB'
          % (files[0][0] / 1048576))
    print('          deploy timeout 10 min; soft 100 GB/month bandwidth = about %d image '
          'fetches a month' % (100 * 10 ** 9 // max(1, files[0][0])))
    print('  (docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits;'
          ' .../repositories/working-with-files/managing-large-files/about-large-files-on-github)')
    if total > PAGES_MAX:
        refuse('the tree is %d bytes, over the 1 GB Pages limit' % total)
    if files[0][0] > GIT_BLOCK:
        refuse('%s is over the 100 MiB per-file push limit' % files[0][1].name)


def check_image_link(out, image_url, name):
    """The embedded emulator on /try/ names the image URL, and /get/
    sends the reader to that page; the file must be in the tree.
    (The configured URL moved off /get/ the day the emulator moved INTO
    the site -- /get/ now carries a link to /try/, not a query string.)"""
    page = (out / 'try/index.html').read_text()
    if 'hd1=' + quote(image_url, safe='') not in page:
        refuse('/try/ does not carry the emulator for %s' % image_url)
    get = (out / 'get/index.html').read_text()
    if 'try/index.html' not in get:
        refuse('/get/ does not send the reader to /try/')
    if not (out / name).is_file():
        refuse('/try/ boots %s but the tree has no such file' % name)


def release(a):
    v = a.version
    bundle = Path(a.dist_root) / ('maux-' + v)
    if not bundle.is_dir():
        refuse('no bundle %s (make release VERSION=%s writes it from a tagged commit)'
               % (bundle, v))
    name = 'maux-%s.po' % v
    img, sums = bundle / name, bundle / 'SHA256SUMS'
    for p in (img, sums):
        if not p.is_file():
            refuse('bundle has no %s' % p.name)
    want = None
    for ln in sums.read_text().splitlines():
        m = re.match(r'([0-9a-f]{64})  (.+)$', ln)
        if m and m.group(2) == name:
            want = m.group(1)
    if want is None:
        refuse('SHA256SUMS has no line for %s' % name)
    got = sha256(img)
    if got != want:
        refuse('%s sha256 %s does not match SHA256SUMS %s' % (name, got[:12], want[:12]))
    data = check_release_shape(img)
    names = check_demos()
    work = ROOT / 'build/pages-work'
    work.mkdir(parents=True, exist_ok=True)
    trunc = work / 'release-full.po'
    trunc.write_bytes(data[:VOL_BLOCKS * 512])      # what the lesson sessions ran on
    out = ROOT / 'build/pages'
    tag = 'v' + v
    assemble(out, PAGES + name, 'https://apple2ts.com/',
             'https://github.com/%s/blob/%s/' % (REPO, tag), tag, trunc, False,
             a.ut, want)
    shutil.copyfile(img, out / name)
    shutil.copyfile(sums, out / 'SHA256SUMS')
    (out / '.nojekyll').write_text('')
    if sha256(out / name) != want:
        refuse('copied image differs from the bundle')
    check_image_link(out, PAGES + name, name)
    print('PASS site-pages: %s: %d pages, %d films (%s), image %s sha256 %s'
          % (out, sum(1 for _ in out.rglob('index.html')), len(names),
             ', '.join(names), name, got[:12]))
    size_report(out)
    print('\nNOT RUN. To publish (needs push rights; one commit, so the 32 MB image\n'
          'does not accumulate in gh-pages history):\n')
    print('  cd %s' % out)
    print('  git init -q -b gh-pages && git add -A . && git add -f .nojekyll')
    print('  git commit -q -m "maux %s site"' % v)
    print('  git push --force git@github.com:%s.git gh-pages' % REPO)
    print('  # once: repo Settings > Pages > Source: branch gh-pages, folder / (root)')
    print('  # then: curl -sI %s%s   (200, Content-Length %d, Access-Control-Allow-Origin: *)'
          % (PAGES, name, len(data)))
    return 0


def preview(a):
    full = ROOT / 'build/full.po'
    if not full.is_file():
        refuse('no build/full.po (make full-image)')
    built = full.read_bytes()
    if len(built) != VOL_BLOCKS * 512:
        refuse('build/full.po is %d bytes, not %d' % (len(built), VOL_BLOCKS * 512))
    check_demos()
    out = ROOT / 'build/pages-preview'
    url = 'http://127.0.0.1:%d/maux-preview.po' % a.port
    shipped = built + bytes(512)
    assemble(out, url, a.apple2ts_url, 'https://github.com/%s/blob/main/' % REPO,
             None, full, True, a.ut, hashlib.sha256(shipped).hexdigest())
    (out / 'maux-preview.po').write_bytes(shipped)
    (out / '.nojekyll').write_text('')
    check_image_link(out, url, 'maux-preview.po')
    print('PASS site-preview: %s (image %s, apple2ts %s)' % (out, url, a.apple2ts_url))
    size_report(out)
    print('serve with: make site-preview-serve PREVIEW_PORT=%d' % a.port)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('release')
    r.add_argument('--version', required=True)
    r.add_argument('--dist-root', default=str(ROOT / 'dist'))
    r.add_argument('--ut', action='store_true',
                   help='publish the UltraTerm films (Makefile: UT ?= 1)')
    p = sub.add_parser('preview')
    p.add_argument('--port', type=int, default=8010)
    p.add_argument('--apple2ts-url', default='https://apple2ts.com/')
    p.add_argument('--ut', action='store_true',
                   help='publish the UltraTerm films (Makefile: UT ?= 1)')
    a = ap.parse_args()
    return release(a) if a.cmd == 'release' else preview(a)


if __name__ == '__main__':
    sys.exit(main())
