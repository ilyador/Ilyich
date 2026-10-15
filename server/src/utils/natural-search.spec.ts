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
    });
  });
  it('splits a mixed face, clothing and location query', () => {
    expect(plan('me wearing a red hat in Amsterdam')).toEqual({
      query: 'wearing a red hat',
      filter: { personIds: { all: ['self'] }, city: { in: ['Amsterdam'] } },
    });
    expect(plan('me wearing an Amsterdam shirt')).toEqual({
      query: 'wearing an Amsterdam shirt',
      filter: { personIds: { all: ['self'] } },
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
    ).toEqual({ query: 'swimming', filter: { personIds: { all: ['maya-jane'] } } });
  });
  it('handles multiword names and accented places', () => {
    expect(plan('Hye Joo in Sao Paulo')).toEqual({
      query: '',
      filter: { personIds: { all: ['hye'] }, city: { in: ['São Paulo'] } },
    });
  });
  it('keeps ordinary words when they are not used as locations', () => {
    expect(plan('Maya reading a book')).toEqual({ query: 'reading a book', filter: { personIds: { all: ['maya'] } } });
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
    expect(plan('me not in 2025')).toEqual({ query: 'not in 2025', filter: { personIds: { all: ['self'] } } });
  });
  it('does not mutate the vocabulary or input', () => {
    const before = structuredClone(vocabulary);
    plan('Maya in Amsterdam');
    expect(vocabulary).toEqual(before);
  });
});
