// Formatting helpers shared by the UI and by tests.
//
// These live apart from ui.js because that module builds the application as
// soon as it loads and so only runs in a browser, while the judgements here --
// whether a drive counts as busy, how far through an image a guest has read --
// are worth testing on their own.

// A bytes tier matters because this also formats transfer rates: a drive
// trickling a few hundred bytes a second is doing something, and rounding that
// to "0 KiB/s" would read as idle.
export const human = (n) => n >= 2 ** 30 ? `${(n / 2 ** 30).toFixed(1)} GiB`
                          : n >= 2 ** 20 ? `${(n / 2 ** 20).toFixed(1)} MiB`
                          : n >= 1024 ? `${(n / 1024).toFixed(1)} KiB`
                          : `${Math.round(n)} B`;

/**
 * Decide how one drive's activity should read.
 *
 * A guest still pulling data off an install image and one that has gone quiet
 * look identical in the instruction counter, so this is what tells them apart.
 * The position matters as much as the total: a boot working steadily walks it
 * forwards, while a wedged one leaves it parked.
 */
export function formatDiskRow(d, deltaBytes, waiting, dt) {
  const rate = dt > 0 ? deltaBytes / dt : 0;
  // Amber means the guest asked for data that is not resident yet and will
  // retry, which is activity of a different kind from a completed read.
  const lamp = deltaBytes > 0 ? 'lamp on' : waiting ? 'lamp wait' : 'lamp';
  const pos = d.lastLba < 0
    ? 'idle'
    : `lba ${d.lastLba.toLocaleString()}` +
      (d.size ? ` (${((d.lastLba * d.sectorSize / d.size) * 100).toFixed(0)}%)` : '');
  const value = `${deltaBytes > 0 ? human(rate) + '/s  ' : ''}` +
                `${human(d.bytesRead)}  ${d.reads} rd  ${pos}`;
  return { lamp, label: d.kind, value };
}
