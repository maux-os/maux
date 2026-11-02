# fixtures/partition -- byte streams for check-partition

vimj30.bin (1364 B) and vimdd.bin (1379 B) are the bytes host vim
(`vim -u NONE -n -i NONE`, TERM=vt102, an 80x24 pty) sent to the guest
through `tip` while check-tip-vim ran on the Mac, vim 9.1, 2026-10-21,
verilogapple 296d93a: every chunk `ExecBackend.to_guest()` returned,
concatenated. vimj30.bin is the open stream plus the 30 `j`; vimdd.bin is
the same plus the `dd` step's output (cumulative, because vim's later
output is only meaningful on the screen the earlier output made).

They are vim's output for a 40-line file of "line NN the quick brown fox
NN" -- not a copyrighted work. 7-bit, exactly as tip hands them to the
console (tip strips bit 7 and writes one SC_WRITE per read, <= 64 B).

Regenerate by running check-tip-vim with a recorder around
ExecBackend.to_guest (docs/PACE-1-NOTES.md sec 2); the streams are not
expected to change unless vim's startup or the oracle file does.

vim90j30.bin (1482 B) is the same flow's stream from the BOX, vim 9.0.1378
(Debian), 2026-10-21: every ssc_rx_write of the failing check-tip-vim run
(docs/PACE-1-NOTES.md sec 0b/0c). It differs from vimj30.bin from the first
`j`: it carries a reverse-video `l` per row. box-vim-inputs.json is that
run's complete input history (531 emulator calls) for pace1_probe.py replay.

vim90j30.ref.json is tmux 3.6a's rendering of vim90j30.bin (80x24 pane,
`stty -opost; cat`), made by `python3 scripts/tmux_ref.py
fixtures/partition/vim90j30.bin`, 2026-10-21: the 24 rows of text, a
24-row reverse-video mask, and the cursor cell. check-partition compares
the settled native-80 glass against it cell for cell. Committed rather
than computed because the box has no tmux. The stream is vim in
blockwise Visual mode (CTRL-Q from the guest's XON, docs/PACE-1-NOTES.md
sec 0d), so rows 0-21 carry a reverse `l` in column 0.
