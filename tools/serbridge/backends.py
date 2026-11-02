#!/usr/bin/env python3
"""backends.py -- pluggable per-channel host endpoints for serbridge.

Each backend implements router.Backend: to_guest() -> bytes (what the
guest should read next) and from_guest(bytes) (what the guest just
wrote). Nothing here knows about the router or the transport.

Two are real (PtyBackend, ExecBackend); two are intentionally stubs
(TcpBackend, ListenBackend) -- the task only asks that they drop in
later without touching the router. A LoopbackBackend is included for
manual smoke-testing the router/transport wiring without a human typing
into a terminal.
"""
import errno
import os
import pty
import shlex
import subprocess
import sys

# House style (see scripts/check_iobuf.py and friends): flat scripts,
# no package machinery -- put this file's own directory on sys.path so
# sibling modules import by plain name whether this file is run
# directly, imported by serbridge.py, or imported via `python3 -m
# serbridge` from tools/.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from router import Backend  # noqa: E402

# Non-blocking drain: how long to let select() wait for data that may
# not be there yet. 0 = poll, don't block -- the router's pump loop
# already paces itself with its own sleep between rounds.
_POLL_TIMEOUT = 0
_READ_CHUNK = 4096



class SevenBit:
    """Fold host output for a 7-BIT terminal (the maux console is a VT102,
    which discards the eighth bit as parity -- a UTF-8 em-dash E2 80 94
    arrives as 'b', NUL, ^T; found live on HACKING.md 2026-09-12). Each
    UTF-8 lead byte becomes ONE '?', its continuation bytes are dropped,
    a stray continuation byte is '?'. Stateful across reads so a code
    point split over two reads still folds to one mark. `raw=True`
    passes bytes through (an 8-bit host program on purpose)."""

    def __init__(self, raw=False, mark=b'?'):
        self.raw = raw
        self.mark = mark
        self._pending = 0          # continuation bytes still expected

    def fold(self, data):
        if self.raw or not data:
            return data
        out = bytearray()
        for b in data:
            if b < 0x80:
                self._pending = 0
                out.append(b)
            elif 0x80 <= b <= 0xBF:                     # continuation
                if self._pending:
                    self._pending -= 1
                else:
                    out += self.mark
            else:                                       # lead byte
                self._pending = 1 if b < 0xE0 else 2 if b < 0xF0 else 3
                out += self.mark
        return bytes(out)


class PtyBackend(Backend):
    """"Tip in": allocate a pseudo-terminal and expose its slave path.
    A human (or a script) runs `screen /dev/ttysNNN` (or `tio`, `cu`,
    `picocom`) on that path and is, from their point of view, directly
    on the emulated IIe's serial line.

    Direction mapping:
      guest TX (from_guest)  -> written to the PTY MASTER -> appears as
                                 input on the slave, i.e. what the human
                                 typing `screen` sees the IIe send.
      guest RX (to_guest)    <- read from the PTY MASTER -- i.e. what
                                 the human typed into `screen`, to be
                                 delivered to the IIe.
    """

    def __init__(self, echo_path=True):
        self.master_fd, self.slave_fd = pty.openpty()
        # Put the master in non-blocking mode so to_guest() never stalls
        # the router's pump loop waiting for a human to type.
        os.set_blocking(self.master_fd, False)
        self.slave_path = os.ttyname(self.slave_fd)
        if echo_path:
            print(f"serbridge: pty backend -- connect with: screen {self.slave_path}")

    def to_guest(self):
        try:
            return os.read(self.master_fd, _READ_CHUNK)
        except BlockingIOError:
            return b""
        except OSError as e:
            if e.errno == errno.EAGAIN:
                return b""
            raise

    def from_guest(self, data):
        # The master fd is non-blocking; a short write is possible if a
        # human hasn't opened the slave yet or the kernel buffer is
        # momentarily full. The SSC's guest-facing data rate is low
        # (<=19200 baud in period hardware) relative to a host pty
        # buffer, so a short write here would mean something else is
        # wrong; we still loop rather than silently drop.
        view = memoryview(data)
        while view:
            try:
                n = os.write(self.master_fd, view)
            except BlockingIOError:
                continue
            view = view[n:]

    def close(self):
        for fd in (self.slave_fd, self.master_fd):
            try:
                os.close(fd)
            except OSError:
                pass


class ExecBackend(Backend):
    """"Tip out": spawn a host process and wire guest TX -> its input,
    its output -> guest RX. Default command is /bin/sh, so by default
    the emulated IIe gets an interactive shell on the other end of its
    serial line -- a period-plausible "dial into a host" scenario.

    Since 2026-09-11 the process runs on a PTY (pty.fork) by default;
    a shell on pipes has no job control, prompts nowhere useful, and
    screen programs refuse to start. TERM defaults to vt102 -- the
    maux console's target (docs/CONSOLE-VT102.md) -- and the pty's
    window size is set to the console geometry (cols x rows). The pty is
    what a real modem line into a login would give it. `use_pty=False`
    keeps the old pipe wiring (the router self-test's `cat` round trip
    uses it: a pty would echo and cook).
    """

    def __init__(self, command=None, use_pty=True, term="vt102", cols=80, rows=24,
                 eight_bit=False):
        self.command = command or ["/bin/sh"]
        if isinstance(self.command, str):
            # Allow a plain string for CLI convenience; split like a shell
            # would, quotes included (shlex) -- a bare .split() broke
            # `--exec "sh -c 'echo hi'"` on the first live tip session.
            self.command = shlex.split(self.command)
        self.use_pty = use_pty
        self.seven = SevenBit(raw=eight_bit)
        self.proc = None
        self.pid = None
        self.master_fd = None
        if use_pty:
            pid, fd = pty.fork()
            if pid == 0:                                  # child: the host program
                os.environ["TERM"] = term
                os.environ["LINES"] = str(rows)
                os.environ["COLUMNS"] = str(cols)
                try:
                    os.execvp(self.command[0], self.command)
                finally:
                    os._exit(127)
            self.pid, self.master_fd = pid, fd
            # The pty's window size is what curses/vim actually read
            # (TIOCGWINSZ); LINES/COLUMNS above are the fallback.
            try:
                import fcntl, struct, termios
                fcntl.ioctl(fd, termios.TIOCSWINSZ,
                            struct.pack("HHHH", rows, cols, 0, 0))
            except OSError:
                pass
            os.set_blocking(self.master_fd, False)
            self._read_fd, self._write_fd = fd, fd
        else:
            self.proc = subprocess.Popen(
                self.command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=None,
                bufsize=0,
            )
            os.set_blocking(self.proc.stdout.fileno(), False)
            self._read_fd, self._write_fd = self.proc.stdout.fileno(), self.proc.stdin.fileno()

    def to_guest(self):
        try:
            return self.seven.fold(os.read(self._read_fd, _READ_CHUNK))
        except BlockingIOError:
            return b""
        except OSError as e:
            if e.errno == errno.EAGAIN:
                return b""
            if e.errno == errno.EIO and self.use_pty:     # pty: the program exited
                return b""
            raise

    def from_guest(self, data):
        view = memoryview(data)
        while view:
            try:
                n = os.write(self._write_fd, view)
            except BlockingIOError:
                continue
            except (BrokenPipeError, OSError):
                # The child exited; nothing more to deliver to it.
                return
            view = view[n:]

    def close(self):
        if self.use_pty:
            try:
                os.close(self.master_fd)
            except OSError:
                pass
            try:
                os.kill(self.pid, 15)
                os.waitpid(self.pid, 0)
            except Exception:
                pass
            return
        for stream in (self.proc.stdin, self.proc.stdout):
            try:
                stream.close()
            except OSError:
                pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


class LoopbackBackend(Backend):
    """Echoes guest TX straight back as guest RX. No host resources, no
    subprocess -- useful as a trivial manual smoke-test backend ("is the
    wiring right at all") and as the simplest possible Backend
    implementation to read first."""

    def __init__(self):
        self._buf = bytearray()

    def to_guest(self):
        if not self._buf:
            return b""
        out, self._buf = bytes(self._buf), bytearray()
        return out

    def from_guest(self, data):
        self._buf.extend(data)


class TcpBackend(Backend):
    """TODO (slice 4+): connect out to host:port, wire guest TX -> the
    socket's send(), the socket's recv() -> guest RX. Drop-in once
    needed -- the router doesn't care that this isn't implemented yet,
    only that constructing one today raises clearly instead of silently
    doing nothing."""

    def __init__(self, host, port):
        raise NotImplementedError(
            "TcpBackend is a stub (slice 4+): connect to "
            f"{host}:{port} and wire its socket the same way "
            "ExecBackend wires a subprocess's stdio."
        )

    # Concrete (not abstract) so the class can be instantiated long
    # enough for __init__ to raise the friendlier, specific message
    # above -- an ABC with unimplemented abstract methods would instead
    # fail with a generic "can't instantiate abstract class" TypeError
    # before __init__ even runs. These are never reached.
    def to_guest(self):
        raise NotImplementedError

    def from_guest(self, data):
        raise NotImplementedError


class ListenBackend(Backend):
    """TODO (slice 4+): accept() one inbound connection on a host port
    and wire it up the same way TcpBackend would. Stubbed for the same
    reason."""

    def __init__(self, port):
        raise NotImplementedError(
            f"ListenBackend is a stub (slice 4+): accept on port {port} "
            "and wire the accepted socket the same way ExecBackend "
            "wires a subprocess's stdio."
        )

    def to_guest(self):
        raise NotImplementedError

    def from_guest(self, data):
        raise NotImplementedError
