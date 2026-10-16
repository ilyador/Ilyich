import { Status } from '@immich/sdk';
import { mergeSearchVerification } from './search-verification';

describe('mergeSearchVerification', () => {
  it.each([Status.Complete, Status.Partial, Status.Unavailable])('keeps earlier %s status and counts', (status) => {
    expect(
      mergeSearchVerification(
        { status, checked: 3, rejected: 1 },
        { status: Status.Complete, checked: 4, rejected: 2 },
      ),
    ).toEqual({ status, checked: 7, rejected: 3 });
  });
  it('marks results unavailable if a later page has no verification information', () => {
    expect(mergeSearchVerification({ status: Status.Complete, checked: 2, rejected: 1 }, undefined)).toEqual({
      status: Status.Unavailable,
      checked: 2,
      rejected: 1,
    });
  });
  it('preserves a first page and ordinary searches', () => {
    expect(mergeSearchVerification(undefined, undefined)).toBeUndefined();
    expect(mergeSearchVerification(undefined, { status: Status.Partial, checked: 2, rejected: 1 })).toEqual({
      status: Status.Partial,
      checked: 2,
      rejected: 1,
    });
  });
});
