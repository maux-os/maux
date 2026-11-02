"""kernel_mains.py -- the kernel-bearing manifests whose REL segment forms
join the oracle sweep (check_librel.py, build_nas_librel_image.py, and the
Makefile's KERNEL_LISTINGS).

Pure data, NO imports, on purpose. It used to live in check_librel.py,
whose import chain reaches a2til and the emulator driver; the Makefile
imported it at parse time, and on a host with no a2til (the build tier's
first `make`) the import died, the list came out empty, and nothing said
so (docs/DEPS-TIER-NOTES.md, P3). A data file cannot fail that way.
"""

# -- S9-PLAN 6b stage A: kernel-bearing manifests whose REL segment
# -- forms join the oracle sweep. Value = the monolithic merlin32
# -- listing the GENERATED-LITERAL rewrites read (built beside the
# -- .bin by the Makefile's -V listing rule). forktest is the pilot
# -- (K_BLTN_COUNT=0, so hazard 1's LEN differences are absent).
KERNEL_MAINS = {
    'src/test/forktest.s': {
        'listing': 'build/forktest.bin_Output.txt',
        'ref': 'build/forktest.bin', 'base': 0x0800,
        'out': 'FORKTEST', 'type': 0x06},
    'src/test/playtest.s': {
        'listing': 'build/MAUXPLAY.SYSTEM_Output.txt',
        'ref': 'build/MAUXPLAY.SYSTEM', 'base': 0x2000,
        'out': 'MAUXPLAY.SYSTEM', 'type': 0xFF},
    # -- the item-2 rollout (S9-PLAN 6b), 2026-09-01: every
    # kernel-bearing manifest except ffpage.size.s (a 256-byte size
    # probe, not a kernel image) and the FIVE that override
    # K_DISP_COUNT (bankcopytest, syscalltest, sched.coop/
    # preempt/wake): kdisp.s's own header rules their dispatch
    # tables DIFFERENT by design, but entry.s bakes the equ's VALUE
    # into the shared KENTRY module ('cmp #K_DISP_COUNT'), so their
    # links differ by exactly that immediate (got $0C, want their
    # own). THE TRIGGER: they join the day K_DISP_COUNT becomes a
    # LINKED CELL (the K_BLTN_COUNT precedent) -- which turns the
    # immediate into an absolute read, +1 byte in entry.s, shifting
    # every kernel image; that blast radius is the operator's to
    # rule, not this table's. Out-names over ProDOS's 15-char cap
    # are the harness stem instead of the host ref.
    'src/test/argvtest.s': {
        'listing': 'build/argvtest.bin_Output.txt',
        'ref': 'build/argvtest.bin', 'base': 0x0800,
        'out': 'argvtest.bin', 'type': 0x06},
    'src/test/fdatest.s': {
        'listing': 'build/fdatest.bin_Output.txt',
        'ref': 'build/fdatest.bin', 'base': 0x0800,
        'out': 'fdatest.bin', 'type': 0x06},
    'src/test/fdatestp.s': {
        'listing': 'build/fdatestp.bin_Output.txt',
        'ref': 'build/fdatestp.bin', 'base': 0x0800,
        'out': 'fdatestp.bin', 'type': 0x06},
    'src/test/astest.s': {
        'listing': 'build/MAUXAS.SYSTEM_Output.txt',
        'ref': 'build/MAUXAS.SYSTEM', 'base': 0x2000,
        'out': 'MAUXAS.SYSTEM', 'type': 0xFF},
    'src/test/bufiotest.s': {
        'listing': 'build/MAUXBUFIO.SYSTEM_Output.txt',
        'ref': 'build/MAUXBUFIO.SYSTEM', 'base': 0x2000,
        'out': 'BUFIOTEST', 'type': 0xFF},
    'src/test/catreadtest.s': {
        'listing': 'build/MAUXCATREAD.SYSTEM_Output.txt',
        'ref': 'build/MAUXCATREAD.SYSTEM', 'base': 0x2000,
        'out': 'CATREADTEST', 'type': 0xFF},
    'src/test/chmodtest.s': {
        'listing': 'build/MAUXCHMOD.SYSTEM_Output.txt',
        'ref': 'build/MAUXCHMOD.SYSTEM', 'base': 0x2000,
        'out': 'CHMODTEST', 'type': 0xFF},
    'src/test/commtest.s': {
        'listing': 'build/MAUXCOMM.SYSTEM_Output.txt',
        'ref': 'build/MAUXCOMM.SYSTEM', 'base': 0x2000,
        'out': 'MAUXCOMM.SYSTEM', 'type': 0xFF},
    'src/test/difftest.s': {
        'listing': 'build/MAUXDIFFTEST.SYSTEM_Output.txt',
        'ref': 'build/MAUXDIFFTEST.SYSTEM', 'base': 0x2000,
        'out': 'DIFFTEST', 'type': 0xFF},
    'src/test/dutest.s': {
        'listing': 'build/MAUXDUTEST.SYSTEM_Output.txt',
        'ref': 'build/MAUXDUTEST.SYSTEM', 'base': 0x2000,
        'out': 'DUTEST', 'type': 0xFF},
    'src/test/e2etest.s': {
        'listing': 'build/MAUXE2E.SYSTEM_Output.txt',
        'ref': 'build/MAUXE2E.SYSTEM', 'base': 0x2000,
        'out': 'MAUXE2E.SYSTEM', 'type': 0xFF},
    'src/test/edtest.s': {
        'listing': 'build/MAUXEDTEST.SYSTEM_Output.txt',
        'ref': 'build/MAUXEDTEST.SYSTEM', 'base': 0x2000,
        'out': 'EDTEST', 'type': 0xFF},
    'src/test/envtest.s': {
        'listing': 'build/MAUXENV.SYSTEM_Output.txt',
        'ref': 'build/MAUXENV.SYSTEM', 'base': 0x2000,
        'out': 'MAUXENV.SYSTEM', 'type': 0xFF},
    'src/test/exprtest.s': {
        'listing': 'build/MAUXEXPR.SYSTEM_Output.txt',
        'ref': 'build/MAUXEXPR.SYSTEM', 'base': 0x2000,
        'out': 'MAUXEXPR.SYSTEM', 'type': 0xFF},
    'src/test/fileproctest.s': {
        'listing': 'build/MAUXFILEPROC.SYSTEM_Output.txt',
        'ref': 'build/MAUXFILEPROC.SYSTEM', 'base': 0x2000,
        'out': 'FILEPROCESSTEST', 'type': 0xFF},
    'src/test/findtest.s': {
        'listing': 'build/MAUXFINDTEST.SYSTEM_Output.txt',
        'ref': 'build/MAUXFINDTEST.SYSTEM', 'base': 0x2000,
        'out': 'FINDTEST', 'type': 0xFF},
    'src/test/fleettest.s': {
        'listing': 'build/MAUXFLEET.SYSTEM_Output.txt',
        'ref': 'build/MAUXFLEET.SYSTEM', 'base': 0x2000,
        'out': 'FLEETTEST', 'type': 0xFF},
    'src/test/ldtest.s': {
        'listing': 'build/LDTEST.SYSTEM_Output.txt',
        'ref': 'build/LDTEST.SYSTEM', 'base': 0x2000,
        'out': 'LDTEST.SYSTEM', 'type': 0xFF},
    'src/test/lstest.s': {
        'listing': 'build/MAUXLSTEST.SYSTEM_Output.txt',
        'ref': 'build/MAUXLSTEST.SYSTEM', 'base': 0x2000,
        'out': 'LSTEST', 'type': 0xFF},
    'src/test/nmtest.s': {
        'listing': 'build/MAUXNM.SYSTEM_Output.txt',
        'ref': 'build/MAUXNM.SYSTEM', 'base': 0x2000,
        'out': 'MAUXNM.SYSTEM', 'type': 0xFF},
    'src/test/pipewraptest.s': {
        'listing': 'build/MAUXPIPEWRAP.SYSTEM_Output.txt',
        'ref': 'build/MAUXPIPEWRAP.SYSTEM', 'base': 0x2000,
        'out': 'PIPEWRAPTEST', 'type': 0xFF},
    'src/test/probetest.s': {
        'listing': 'build/probetest.bin_Output.txt',
        'ref': 'build/probetest.bin', 'base': 0x0800,
        'out': 'probetest.bin', 'type': 0x06},
    'src/test/processtest.s': {
        'listing': 'build/processtest.bin_Output.txt',
        'ref': 'build/processtest.bin', 'base': 0x0800,
        'out': 'processtest.bin', 'type': 0x06},
    'src/test/prodos.spike.s': {
        'listing': 'build/MAUXSPIKE.SYSTEM_Output.txt',
        'ref': 'build/MAUXSPIKE.SYSTEM', 'base': 0x2000,
        'out': 'PRODOSSPIKE', 'type': 0xFF},
    'src/test/sedtest.s': {
        'listing': 'build/MAUXSEDTEST.SYSTEM_Output.txt',
        'ref': 'build/MAUXSEDTEST.SYSTEM', 'base': 0x2000,
        'out': 'SEDTEST', 'type': 0xFF},
    'src/test/seektest.s': {
        'listing': 'build/MAUXSEEK.SYSTEM_Output.txt',
        'ref': 'build/MAUXSEEK.SYSTEM', 'base': 0x2000,
        'out': 'MAUXSEEK.SYSTEM', 'type': 0xFF},
    'src/test/shlangtest.s': {
        'listing': 'build/MAUXSHLANG.SYSTEM_Output.txt',
        'ref': 'build/MAUXSHLANG.SYSTEM', 'base': 0x2000,
        'out': 'SHLANGTEST', 'type': 0xFF},
    'src/test/shtest.s': {
        'listing': 'build/MAUXSH.SYSTEM_Output.txt',
        'ref': 'build/MAUXSH.SYSTEM', 'base': 0x2000,
        'out': 'MAUXSH.SYSTEM', 'type': 0xFF},
    'src/test/stickytest.s': {
        'listing': 'build/MAUXSTICKY.SYSTEM_Output.txt',
        'ref': 'build/MAUXSTICKY.SYSTEM', 'base': 0x2000,
        'out': 'STICKYTEST', 'type': 0xFF},
    'src/test/sumdatetest.s': {
        'listing': 'build/MAUXSUMDT.SYSTEM_Output.txt',
        'ref': 'build/MAUXSUMDT.SYSTEM', 'base': 0x2000,
        'out': 'SUMDATETEST', 'type': 0xFF},
    'src/test/tailtest.s': {
        'listing': 'build/MAUXTAIL.SYSTEM_Output.txt',
        'ref': 'build/MAUXTAIL.SYSTEM', 'base': 0x2000,
        'out': 'MAUXTAIL.SYSTEM', 'type': 0xFF},
    'src/test/testevtest.s': {
        'listing': 'build/MAUXTESTEV.SYSTEM_Output.txt',
        'ref': 'build/MAUXTESTEV.SYSTEM', 'base': 0x2000,
        'out': 'TESTEVTEST', 'type': 0xFF},
    'src/test/uttest.s': {
        'listing': 'build/MAUXUT.SYSTEM_Output.txt',
        'ref': 'build/MAUXUT.SYSTEM', 'base': 0x2000,
        'out': 'MAUXUT.SYSTEM', 'type': 0xFF},
}
