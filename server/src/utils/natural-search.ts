import type { SearchFilter } from 'src/dtos/search.dto.js';

export interface SearchVocabulary {
  people: { personGroupId: string; name: string }[];
  cities: string[];
  countries: string[];
  userName: string;
}

export interface NaturalSearchPlan {
  query: string;
  filter?: SearchFilter;
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
    .map((match) => ({
      text: match[0],
      normalized: normalize(match[0]),
    }))
    .toArray();
  const used = new Set<number>();
  const filter: SearchFilter = {};
  const positive: { id: string; start: number }[] = [];
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
  for (const [alias, ids] of [...aliases].sort(([a], [b]) => b.length - a.length)) {
    if (ids.size !== 1) continue; // Ambiguous first names must not silently pick a person.
    const parts = alias.split(' ');
    for (let index = 0; index < tokens.length; index++) {
      if (!matches(index, parts)) continue;
      const previous = tokens[index - 1]?.normalized;
      const next = tokens[index + 1]?.normalized;
      if (
        alias === 'me' &&
        ['show', 'find', 'give'].includes(previous) &&
        (['photos', 'pictures', 'images', 'a', 'an', 'the', 'some', 'all'].includes(next) || aliases.has(next))
      ) {
        consume(index, 1); // "show me Maya" does not mean both people.
        continue;
      }
      const excluded =
        ['without', 'except', 'excluding', 'not'].includes(previous) ||
        (previous === 'with' && tokens[index - 2]?.normalized === 'not');
      const id = [...ids][0];
      if (excluded) {
        negative.push(id);
        consume(index - (previous === 'with' ? 2 : 1), previous === 'with' ? 2 : 1);
      } else positive.push({ id, start: index });
      consume(index, parts.length);
    }
  }
  if (positive.length > 0 || negative.length > 0) {
    positive.sort((a, b) => a.start - b.start);
    const starts = positive.map((person) => person.start);
    const disjunction = tokens.some(
      (token, index) => token.normalized === 'or' && index > Math.min(...starts) && index < Math.max(...starts),
    );
    filter.personIds = {
      ...(positive.length > 0 && { [disjunction ? 'any' : 'all']: [...new Set(positive.map((person) => person.id))] }),
      ...(negative.length > 0 && { none: [...new Set(negative)] }),
    };
    if (disjunction && positive.length > 2) {
      const groups: string[][] = [[]];
      for (const [index, person] of positive.entries()) {
        if (
          index > 0 &&
          tokens.slice(positive[index - 1].start, person.start).some((token) => token.normalized === 'or')
        )
          groups.push([]);
        groups.at(-1)!.push(person.id);
      }
      if (groups.some((group) => group.length > 1)) {
        delete filter.personIds.any;
        if (Object.keys(filter.personIds).length === 0) delete filter.personIds;
        filter.or = groups.map((all) => ({ personIds: { all } }));
      }
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
    filter.takenAt =
      previous === 'before' ? { lt: start } : previous === 'after' ? { gte: end } : { gte: start, lt: end };
    if (['before', 'after'].includes(previous)) consume(index - 1, 1);
  }
  if (Object.keys(filter).length === 0) return { query };
  const remaining = tokens.filter((_, index) => !used.has(index));
  while (remaining.length > 0 && filler.has(remaining[0].normalized)) remaining.shift();
  while (remaining.length > 0 && filler.has(remaining.at(-1)!.normalized)) remaining.pop();
  return { query: remaining.map((token) => token.text).join(' '), filter };
}
