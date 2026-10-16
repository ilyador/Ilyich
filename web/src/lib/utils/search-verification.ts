import { Status, type SearchResponseDto } from '@immich/sdk';

type Verification = SearchResponseDto['verification'];

/** A later verified page cannot make earlier unverified results verified. */
export function mergeSearchVerification(previous: Verification, next: Verification): Verification {
  if (!previous) return next;
  const statuses = new Set([previous.status, next?.status]);
  const status =
    !next || statuses.has(Status.Unavailable)
      ? Status.Unavailable
      : statuses.has(Status.Partial)
        ? Status.Partial
        : next.status;
  return {
    status,
    checked: previous.checked + (next?.checked ?? 0),
    rejected: previous.rejected + (next?.rejected ?? 0),
  };
}
