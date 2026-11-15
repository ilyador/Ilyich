import type { Stats } from 'node:fs';

/** Include inode/ctime so replacing bytes while restoring mtime cannot reuse old proof. */
export const contentSourceFingerprint = (stat: Stats): string =>
  JSON.stringify([stat.dev, stat.ino, stat.size, stat.mtimeMs, stat.ctimeMs]);

export const contentFingerprintIsCurrent = (
  cached: { originalPath: string; sourceFingerprint: string },
  originalPath: string,
  stat: Stats,
): boolean =>
  stat.isFile() && cached.originalPath === originalPath && cached.sourceFingerprint === contentSourceFingerprint(stat);
