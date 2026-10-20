import { SearchVocabulary, planNaturalSearch } from 'src/utils/natural-search.js';

const vocabulary: SearchVocabulary = {
  people: [
    { name: 'Me', personGroupId: 'self' },
    { name: 'Maya', personGroupId: 'maya' },
    { name: 'Hye Joo', personGroupId: 'hye' },
    { name: 'Anna Smith', personGroupId: 'anna1' },
    { name: 'Anna Jones', personGroupId: 'anna2' },
  ],
  cities: ['Amsterdam', 'Lisbon', 'São Paulo', 'Reading'],
  countries: ['Netherlands', 'Portugal'],
  userName: 'Ilya',
};
const plan = (query: string) => planNaturalSearch(query, vocabulary, new Date('2026-10-15T12:00:00Z'));

describe(planNaturalSearch.name, () => {
  it('matches a whole region when a place is also one, so its suburbs count', () => {
    const regional = { ...vocabulary, cities: [...vocabulary.cities, 'Mem Martins'], states: ['Lisbon', 'Setúbal'] };
    expect(planNaturalSearch('me and Maya in Lisbon', regional)).toEqual({
      query: '',
      filter: { personIds: { all: ['self', 'maya'] }, state: { in: ['Lisbon'] } },
    });
    expect(planNaturalSearch('me in Mem Martins', regional)).toEqual({
      query: '',
      filter: { personIds: { all: ['self'] }, city: { in: ['Mem Martins'] } },
    });
  });

  it.each([
    ['Priya Raman', 'Søren Lind', 'Utrecht'],
    ['Lúcia Pereira', 'Aarav Shah', 'Oslo'],
    ['Zoë Martin', 'Min Seo', 'Kyoto'],
  ])('resolves supplied vocabulary rather than specific people: %s and %s', (first, second, city) => {
    const result = planNaturalSearch(`${first} hugging ${second} in ${city}`, {
      people: [
        { name: first, personGroupId: 'arbitrary-first' },
        { name: second, personGroupId: 'arbitrary-second' },
      ],
      cities: [city],
      countries: [],
      userName: 'An unrelated account name',
    });
    expect(result).toEqual({
      query: 'hugging',
      filter: { personIds: { all: ['arbitrary-first', 'arbitrary-second'] }, city: { in: [city] } },
      verification: {
        query: 'Person 1 hugging Person 2',
        subjects: [
          { personGroupId: 'arbitrary-first', marker: 1 },
          { personGroupId: 'arbitrary-second', marker: 2 },
        ],
        groups: [[1, 2]],
      },
    });
  });
  it.each(['me and maya in amsterdam', 'me an maya in amsterdam', 'Me & Maya in Amsterdam'])(
    'requires both faces: %s',
    (query) => {
      expect(plan(query)).toEqual({
        query: '',
        filter: { personIds: { all: ['self', 'maya'] }, city: { in: ['Amsterdam'] } },
      });
    },
  );
  it('resolves the account name through its explicitly named Me person', () => {
    expect(plan('Ilya and Maya in Amsterdam').filter?.personIds).toEqual({ all: ['self', 'maya'] });
  });
  it('keeps an action for visual search after resolving metadata', () => {
    expect(plan('Maya holding a phone in Amsterdam')).toEqual({
      query: 'holding a phone',
      filter: { personIds: { all: ['maya'] }, city: { in: ['Amsterdam'] } },
      verification: {
        query: 'Person 1 holding a phone',
        subjects: [{ personGroupId: 'maya', marker: 1 }],
        groups: [[1]],
      },
    });
  });
  it.each([
    ['me holding a phone', 'Person 1 holding a phone', ['self'], [[1]]],
    ['Maya holding a phone', 'Person 1 holding a phone', ['maya'], [[1]]],
    ['me holding a phone with Maya', 'Person 1 holding a phone with Person 2', ['self', 'maya'], [[1, 2]]],
    ['Maya holding a phone with me', 'Person 1 holding a phone with Person 2', ['maya', 'self'], [[1, 2]]],
    ['me and Maya wearing red hats', 'Person 1 and Person 2 wearing red hats', ['self', 'maya'], [[1, 2]]],
    ['me or Maya wearing a red hat', 'Person 1 or Person 2 wearing a red hat', ['self', 'maya'], [[1], [2]]],
    ['a phone held by Hye Joo in Lisbon', 'phone held by Person 1', ['hye'], [[1]]],
    ['Maya in Amsterdam holding an H&M bag', 'Person 1 holding an H&M bag', ['maya'], [[1]]],
    ['Maya watching Disney+', 'Person 1 watching Disney+', ['maya'], [[1]]],
    ['show me photos of Maya holding a phone', 'Person 1 holding a phone', ['maya'], [[1]]],
  ])('preserves anonymous actor relationships: %s', (query, expected, ids, groups) => {
    expect(plan(query).verification).toEqual({
      query: expected,
      groups,
      subjects: ids.map((personGroupId, index) => ({ personGroupId, marker: index + 1 })),
    });
  });
  it('splits a mixed face, clothing and location query', () => {
    expect(plan('me wearing a red hat in Amsterdam')).toEqual({
      query: 'wearing a red hat',
      filter: { personIds: { all: ['self'] }, city: { in: ['Amsterdam'] } },
      verification: {
        query: 'Person 1 wearing a red hat',
        subjects: [{ personGroupId: 'self', marker: 1 }],
        groups: [[1]],
      },
    });
    expect(plan('me wearing an Amsterdam shirt')).toEqual({
      query: 'wearing an Amsterdam shirt',
      filter: { personIds: { all: ['self'] } },
      verification: {
        query: 'Person 1 wearing an Amsterdam shirt',
        subjects: [{ personGroupId: 'self', marker: 1 }],
        groups: [[1]],
      },
    });
  });
  it('does not confuse an indirect object with a face constraint', () => {
    expect(plan('show me photos of Maya in Amsterdam').filter?.personIds).toEqual({ all: ['maya'] });
    expect(plan('show me in Amsterdam').filter?.personIds).toEqual({ all: ['self'] });
    expect(plan('show me all photos of Maya in Amsterdam')).toEqual({
      query: '',
      filter: { personIds: { all: ['maya'] }, city: { in: ['Amsterdam'] } },
    });
  });
  it('preserves conjunction groups inside a disjunction', () => {
    expect(plan('me and Maya or Hye Joo in Amsterdam').filter?.or).toEqual([
      { personIds: { all: ['self', 'maya'] } },
      { personIds: { all: ['hye'] } },
    ]);
  });
  it('respects a negated location', () => {
    expect(plan('Maya not in Amsterdam')).toEqual({
      query: '',
      filter: { personIds: { all: ['maya'] }, city: { notIn: ['Amsterdam'] } },
    });
  });
  it('supports people exclusions', () => {
    expect(plan('Maya without me in Amsterdam').filter?.personIds).toEqual({ all: ['maya'], none: ['self'] });
    expect(plan('Maya not with me').filter?.personIds).toEqual({ all: ['maya'], none: ['self'] });
  });
  it('supports either person', () => {
    expect(plan('Maya or me in Amsterdam').filter?.personIds).toEqual({ any: ['maya', 'self'] });
  });
  it('does not treat a choice of clothing colors as a choice of faces', () => {
    expect(plan('me wearing a red or blue hat with Maya in Amsterdam')).toEqual({
      query: 'wearing a red or blue hat',
      filter: { personIds: { all: ['self', 'maya'] }, city: { in: ['Amsterdam'] } },
      verification: {
        query: 'Person 1 wearing a red or blue hat with Person 2',
        subjects: [
          { personGroupId: 'self', marker: 1 },
          { personGroupId: 'maya', marker: 2 },
        ],
        groups: [[1, 2]],
      },
    });
  });
  it('uses explicit place context when a location collides with a person name', () => {
    const withJordan = {
      ...vocabulary,
      people: [...vocabulary.people, { name: 'Jordan Smith', personGroupId: 'jordan' }],
      countries: [...vocabulary.countries, 'Jordan'],
    };
    expect(planNaturalSearch('me in Jordan', withJordan)).toEqual({
      query: '',
      filter: { personIds: { all: ['self'] }, country: { in: ['Jordan'] } },
    });
    expect(planNaturalSearch('Jordan Smith in Amsterdam', withJordan).filter?.personIds).toEqual({ all: ['jordan'] });
  });
  it.each([
    ['Maya wearing an H&M shirt in Amsterdam', 'wearing an H&M shirt'],
    ['Maya holding a C++ book in Amsterdam', 'holding a C++ book'],
    ['Maya wearing a red/blue hat in Amsterdam', 'wearing a red/blue hat'],
    ['Maya watching Disney+', 'watching Disney+'],
  ])('preserves visual brand and attribute punctuation: %s', (query, description) => {
    expect(plan(query).query).toBe(description);
  });
  it('does not consume a partial name or guess an ambiguous first name', () => {
    expect(plan('some Mayan temples')).toEqual({ query: 'some Mayan temples' });
    expect(plan('Anna swimming')).toEqual({ query: 'Anna swimming' });
    expect(plan('Anna Smith swimming').filter?.personIds).toEqual({ all: ['anna1'] });
  });
  it('does not choose arbitrarily between people with the same full name', () => {
    expect(
      planNaturalSearch('Maya swimming', {
        ...vocabulary,
        people: [...vocabulary.people, { name: 'Maya', personGroupId: 'another-maya' }],
      }),
    ).toEqual({ query: 'Maya swimming' });
  });
  it('handles hyphenated names using the same word boundaries as the query', () => {
    expect(
      planNaturalSearch('Maya-Jane swimming', {
        ...vocabulary,
        people: [{ name: 'Maya-Jane', personGroupId: 'maya-jane' }],
      }),
    ).toEqual({
      query: 'swimming',
      filter: { personIds: { all: ['maya-jane'] } },
      verification: {
        query: 'Person 1 swimming',
        subjects: [{ personGroupId: 'maya-jane', marker: 1 }],
        groups: [[1]],
      },
    });
  });
  it('handles multiword names and accented places', () => {
    expect(plan('Hye Joo in Sao Paulo')).toEqual({
      query: '',
      filter: { personIds: { all: ['hye'] }, city: { in: ['São Paulo'] } },
    });
  });
  it('keeps ordinary words when they are not used as locations', () => {
    expect(plan('Maya reading a book')).toEqual({
      query: 'reading a book',
      filter: { personIds: { all: ['maya'] } },
      verification: {
        query: 'Person 1 reading a book',
        subjects: [{ personGroupId: 'maya', marker: 1 }],
        groups: [[1]],
      },
    });
  });
  it('handles a year without treating arbitrary numbers as dates', () => {
    expect(plan('Maya in Amsterdam in 2025').filter?.takenAt).toEqual({
      gte: new Date('2025-01-01Z'),
      lt: new Date('2026-01-01Z'),
    });
    expect(plan('Maya last year').filter?.takenAt).toEqual({
      gte: new Date('2025-01-01Z'),
      lt: new Date('2026-01-01Z'),
    });
    expect(plan('Maya holding a 2025 calendar').query).toBe('holding a 2025 calendar');
  });
  it('uses exclusive year boundaries correctly', () => {
    expect(plan('Maya before 2025').filter?.takenAt).toEqual({ lt: new Date('2025-01-01Z') });
    expect(plan('Maya after 2025').filter?.takenAt).toEqual({ gte: new Date('2026-01-01Z') });
  });
  it.each(['Maya after 2020 before 2025', 'Maya before 2025 after 2020'])(
    'keeps both year range boundaries: %s',
    (query) => {
      expect(plan(query).filter?.takenAt).toEqual({
        gte: new Date('2021-01-01Z'),
        lt: new Date('2025-01-01Z'),
      });
    },
  );
  it('retains unsupported negated years instead of creating a positive date filter', () => {
    expect(plan('me not in 2025')).toEqual({
      query: 'not in 2025',
      filter: { personIds: { all: ['self'] } },
      verification: { query: 'Person 1 not in 2025', subjects: [{ personGroupId: 'self', marker: 1 }], groups: [[1]] },
    });
  });
  it('does not mutate the vocabulary or input', () => {
    const before = structuredClone(vocabulary);
    plan('Maya in Amsterdam');
    expect(vocabulary).toEqual(before);
  });
});
