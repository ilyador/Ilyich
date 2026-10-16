import type { SearchFilter } from 'src/dtos/search.dto.js';
import { SearchSubject, searchSubjectLabel } from 'src/utils/search-subjects.js';

export interface SearchVocabulary {
  people: { personGroupId: string; name: string }[];
  cities: string[];
  countries: string[];
  userName: string;
}

export interface NaturalSearchPlan {
  query: string;
  filter?: SearchFilter;
  verification?: {
    query: string;
    subjects: SearchSubject[];
    // Any group may satisfy the query; every marker in that group is required.
    groups: number[][];
  };
}

const normalize = (value: string) => value.normalize('NFKD').replaceAll(/\p{M}/gu, '').toLowerCase();
const wordPattern = /[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/gu;
const words = (value: string) => normalize(value).match(wordPattern) ?? [];
const filler = new Set([
  'a',
  'an',
  'all',
  'some',
  'and',
  'or',
  'in',
  'at',
  'near',
  'around',
  'from',
  'of',
  'with',
  'the',
  'on',
  'during',
  'photos',
  'pictures',
  'images',
  'show',
  'find',
  'give',
  'please',
  'taken',
  'year',
]);

/** Resolve only entities present in this user's library; never invent a face or location. */
export function planNaturalSearch(query: string, vocabulary: SearchVocabulary, now = new Date()): NaturalSearchPlan {
  const tokens = query
    .matchAll(wordPattern)
    .map((match, position) => ({
      text: match[0],
      normalized: normalize(match[0]),
      start: match.index,
      end: match.index + match[0].length,
      position,
    }))
    .toArray();
  const used = new Set<number>();
  const filter: SearchFilter = {};
  const positive: { id: string; start: number; end: number }[] = [];
  const negative: string[] = [];
  const aliases = new Map<string, Set<string>>();
  const addAlias = (name: string, id: string) => {
    const key = words(name).join(' ');
    if (!key) return;
    const ids = aliases.get(key) ?? new Set<string>();
    ids.add(id);
    aliases.set(key, ids);
  };
  for (const person of vocabulary.people) {
    addAlias(person.name, person.personGroupId);
    const firstName = words(person.name)[0];
    if (firstName) addAlias(firstName, person.personGroupId);
  }
  const self = vocabulary.people.filter((person) => normalize(person.name) === 'me');
  if (self.length === 1) {
    for (const name of ['myself', 'I', vocabulary.userName]) addAlias(name, self[0].personGroupId);
  }
  const matches = (start: number, parts: string[]) =>
    parts.every((part, offset) => tokens[start + offset]?.normalized === part && !used.has(start + offset));
  const consume = (start: number, length: number) => {
    for (let offset = 0; offset < length; offset++) used.add(start + offset);
  };
  const places = [...vocabulary.cities, ...vocabulary.countries].map((value) => words(value));
  for (const [alias, ids] of [...aliases].sort(([a], [b]) => b.length - a.length)) {
    if (ids.size !== 1) continue; // Ambiguous first names must not silently pick a person.
    const parts = alias.split(' ');
    for (let index = 0; index < tokens.length; index++) {
      if (!matches(index, parts)) continue;
      const previous = tokens[index - 1]?.normalized;
      const next = tokens[index + 1]?.normalized;
      if (
        ['in', 'at', 'from', 'near', 'around', 'outside'].includes(previous) &&
        places.some((place) => matches(index, place))
      )
        continue;
      if (
        alias === 'me' &&
        ['show', 'find', 'give'].includes(previous) &&
        (['photos', 'pictures', 'images', 'a', 'an', 'the', 'some', 'all'].includes(next) || aliases.has(next))
      ) {
        consume(index, 1); // "show me <person>" does not require the viewer to be present.
        continue;
      }
      const excluded =
        ['without', 'except', 'excluding', 'not'].includes(previous) ||
        (previous === 'with' && tokens[index - 2]?.normalized === 'not');
      const id = [...ids][0];
      if (excluded) {
        negative.push(id);
        consume(index - (previous === 'with' ? 2 : 1), previous === 'with' ? 2 : 1);
      } else positive.push({ id, start: index, end: index + parts.length });
      consume(index, parts.length);
    }
  }
  positive.sort((a, b) => a.start - b.start);
  const subjectGroups: string[][] = [];
  for (const [index, person] of positive.entries()) {
    const startsAlternative =
      index === 0 || (person.start === positive[index - 1].end + 1 && tokens[person.start - 1].normalized === 'or');
    if (startsAlternative) subjectGroups.push([]);
    if (!subjectGroups.at(-1)!.includes(person.id)) subjectGroups.at(-1)!.push(person.id);
  }
  if (positive.length > 0 || negative.length > 0) {
    const disjunction = subjectGroups.length > 1;
    filter.personIds = {
      ...(positive.length > 0 && { [disjunction ? 'any' : 'all']: [...new Set(positive.map((person) => person.id))] }),
      ...(negative.length > 0 && { none: [...new Set(negative)] }),
    };
    if (disjunction && subjectGroups.some((group) => group.length > 1)) {
      delete filter.personIds.any;
      if (Object.keys(filter.personIds).length === 0) delete filter.personIds;
      filter.or = subjectGroups.map((all) => ({ personIds: { all } }));
    }
  }
  for (const [field, values] of [
    ['city', vocabulary.cities],
    ['country', vocabulary.countries],
  ] as const) {
    const found = new Set<string>();
    const excluded = new Set<string>();
    for (const value of [...values].sort((a, b) => b.length - a.length)) {
      const parts = words(value);
      if (parts.length === 0) continue;
      for (let index = 0; index < tokens.length; index++) {
        if (!matches(index, parts)) continue;
        const previous = tokens[index - 1]?.normalized;
        // Location names can also be ordinary words (Reading, Bath, Orange).
        if (
          !['in', 'at', 'from', 'near', 'around', 'outside', 'or'].includes(previous) &&
          tokens.some(
            (token, i) => !used.has(i) && (i < index || i >= index + parts.length) && !filler.has(token.normalized),
          )
        )
          continue;
        if (previous === 'outside' || tokens[index - 2]?.normalized === 'not') {
          excluded.add(value);
          consume(index - (previous === 'outside' ? 1 : 2), 1);
        } else found.add(value);
        consume(index, parts.length);
        if (['in', 'at', 'from', 'near', 'around', 'or'].includes(previous)) consume(index - 1, 1);
      }
    }
    if (found.size > 0 || excluded.size > 0)
      filter[field] = {
        ...(found.size > 0 && { in: [...found] }),
        ...(excluded.size > 0 && { notIn: [...excluded] }),
      };
  }
  for (let index = 0; index < tokens.length; index++) {
    if (used.has(index)) continue;
    const token = tokens[index].normalized;
    const previous = tokens[index - 1]?.normalized;
    if (previous === 'not' || tokens[index - 2]?.normalized === 'not') continue;
    let year: number | undefined;
    if (['this', 'last'].includes(token) && tokens[index + 1]?.normalized === 'year') {
      year = now.getUTCFullYear() - (token === 'last' ? 1 : 0);
      consume(index, 2);
    } else if (/^(19|20)\d{2}$/.test(token) && ['in', 'from', 'during', 'year', 'before', 'after'].includes(previous)) {
      year = Number(token);
      consume(index, 1);
    }
    if (year === undefined) continue;
    const start = new Date(Date.UTC(year, 0, 1));
    const end = new Date(Date.UTC(year + 1, 0, 1));
    const lower = previous === 'before' ? undefined : previous === 'after' ? end : start;
    const upper = previous === 'after' ? undefined : previous === 'before' ? start : end;
    filter.takenAt = {
      ...filter.takenAt,
      ...(lower && { gte: filter.takenAt?.gte && filter.takenAt.gte > lower ? filter.takenAt.gte : lower }),
      ...(upper && { lt: filter.takenAt?.lt && filter.takenAt.lt < upper ? filter.takenAt.lt : upper }),
    };
    if (['in', 'from', 'during', 'year', 'before', 'after'].includes(previous)) consume(index - 1, 1);
  }
  if (Object.keys(filter).length === 0) return { query };
  const remaining = tokens.filter((_, index) => !used.has(index));
  while (remaining.length > 0 && filler.has(remaining[0].normalized)) remaining.shift();
  while (remaining.length > 0 && filler.has(remaining.at(-1)!.normalized)) remaining.pop();
  if (remaining.length === 0) return { query: '', filter };
  const render = (selected: ((typeof tokens)[number] & { endPosition?: number })[]) => {
    const first = selected[0];
    const last = selected.at(-1)!;
    const prefix = query.slice(tokens[first.position - 1]?.end ?? 0, first.start).match(/\S+$/u)?.[0] ?? '';
    const suffix =
      query
        .slice(last.end, tokens[(last.endPosition ?? last.position) + 1]?.start ?? query.length)
        .match(/^\S*/u)?.[0] ?? '';
    return (
      selected
        .map((token, index) => {
          const previous = selected[index - 1];
          return previous && (previous.endPosition ?? previous.position) === token.position - 1
            ? query.slice(previous.end, token.start) + token.text
            : `${index === 0 ? prefix : ' '}${token.text}`;
        })
        .join('') + suffix
    );
  };
  const description = render(remaining);
  // Keep the original relationships for verification, replacing identities with
  // anonymous labels. The embedding still uses only the visual description.
  const subjects = [...new Set(positive.map(({ id }) => id))].map((personGroupId, index) => ({
    personGroupId,
    marker: index + 1,
  }));
  const verificationTokens = tokens.flatMap((token, index) => {
    const person = positive.find(({ start }) => start === index);
    if (person)
      return [
        {
          ...token,
          text: searchSubjectLabel(subjects.find(({ personGroupId }) => personGroupId === person.id)!.marker),
          normalized: 'person',
          end: tokens[person.end - 1].end,
          endPosition: person.end - 1,
        },
      ];
    return used.has(index) ? [] : [token];
  });
  while (verificationTokens.length > 0 && filler.has(verificationTokens[0].normalized)) verificationTokens.shift();
  while (verificationTokens.length > 0 && filler.has(verificationTokens.at(-1)!.normalized)) verificationTokens.pop();
  return {
    query: description,
    filter,
    ...(subjects.length > 0 && {
      verification: {
        query: render(verificationTokens),
        subjects,
        groups: subjectGroups.map((group) =>
          group.map((id) => subjects.find(({ personGroupId }) => personGroupId === id)!.marker),
        ),
      },
    }),
  };
}
