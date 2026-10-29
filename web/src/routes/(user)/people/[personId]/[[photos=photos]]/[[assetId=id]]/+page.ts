import {
  getPerson,
  getPersonStatistics,
  isHttpError,
  type PersonResponseDto,
  type PersonStatisticsResponseDto,
} from '@immich/sdk';
import { redirect } from '@sveltejs/kit';
import { Route } from '$lib/route';
import { authenticate } from '$lib/utils/auth';
import { getFormatter } from '$lib/utils/i18n';
import type { PageLoad } from './$types';

export const load = (async ({ params, url }) => {
  await authenticate(url);

  let person: PersonResponseDto;
  let statistics: PersonStatisticsResponseDto;
  try {
    [person, statistics] = await Promise.all([
      getPerson({ id: params.personId }),
      getPersonStatistics({ id: params.personId }),
    ]);
  } catch (error) {
    // A person merged into another or deleted no longer exists: show everyone rather than an error.
    if (isHttpError(error) && (error.status === 400 || error.status === 404)) {
      redirect(307, Route.people());
    }
    throw error;
  }
  const $t = await getFormatter();

  return {
    person,
    statistics,
    meta: {
      title: person.name || $t('person'),
    },
  };
}) satisfies PageLoad;
