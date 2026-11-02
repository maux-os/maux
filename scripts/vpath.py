"""vpath.py -- the virtual root (docs/VROOT.md), HOST side.

The guest spells a path one way: /bin/ls, /usr/man/LS, /mnt/MAUX/F1.
a2til's module-level API (prodos.write / mkdir / read / scandir /
stat / remove / rmdir ...) names the volume as the FIRST component:
/MAUX/BIN/LS. Every gate and image builder in this tree used to
write the second form for both, and the two meant the same thing.
Now they do not, and a path constant is often BOTH (a fixture
staged by the host and then read by the guest), so the corpus has
ONE spelling -- the guest's -- and this module teaches a2til to read
it. `import vpath` after `from a2til import prodos` is all a
script needs; nothing else in it changes.

The map is the kernel's (src/kernel/vroot.s VR_TAB), the boot
volume being PRODOS_CARRIER_VOL (MAUX):

    /bin /usr /etc /tmp  ->  /MAUX/BIN etc. (a directory map)
    /mnt/NAME/...        ->  /NAME/...
    anything else        ->  unchanged (already a2til's own form;
                             lenient on purpose, so a host-only
                             f'/{VOL}/X' keeps working)

Only the paths a2til RESOLVES are touched (`prodos._resolve`, the one
function every module-level call goes through). Image file names,
volume names and Volume-relative paths are not paths in this sense.
"""
import os

BOOT = os.environ.get('PRODOS_CARRIER_VOL', 'MAUX')
ROWS = ('bin', 'usr', 'etc', 'tmp')


def phys(path):
    """Guest (virtual) path -> a2til path. Idempotent on a2til paths."""
    if not isinstance(path, str) or not path.startswith('/'):
        return path
    parts = path.split('/')
    head = parts[1].lower()
    if head in ROWS:
        return '/' + '/'.join([BOOT, head.upper()] + parts[2:])
    if head == 'mnt' and len(parts) > 2 and parts[2]:
        return '/' + '/'.join(parts[2:])
    return path


def virt(path):
    """a2til path -> guest path (the reverse; boot volume only)."""
    parts = path.split('/')
    if len(parts) > 2 and parts[1].upper() == BOOT.upper():
        if parts[2].lower() in ROWS:
            return '/' + '/'.join([parts[2].lower()] + parts[3:])
        return '/mnt' + path
    return '/mnt' + path


def install():
    from a2til import prodos
    if getattr(prodos, '_vroot_patched', False):
        return
    inner = prodos._resolve

    def resolve(path):
        return inner(phys(path))

    prodos._resolve = resolve
    # Volume methods take '/VOL/SUB/FILE' and '/SUB/FILE' alike and drop
    # the volume name in _components, "once, and only here": so this is
    # the one place the virtual spelling has to be understood as well.
    inner_c = prodos.Volume._components

    def components(self, path):
        parts = [p for p in str(path).split('/') if p]
        if parts:
            head = parts[0].lower()
            if head == 'mnt' and len(parts) > 1:
                parts = parts[1:]
            elif (head in ROWS
                  and self.name.upper() == BOOT.upper()):
                parts = [BOOT, parts[0].upper()] + parts[1:]
        return inner_c(self, '/' + '/'.join(parts))

    prodos.Volume._components = components
    prodos._vroot_patched = True


install()
