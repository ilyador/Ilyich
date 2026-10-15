import { Kysely, sql } from 'kysely';
import { AssetFileType } from 'src/enum.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { SearchRepository } from 'src/repositories/search.repository.js';
import { DB } from 'src/schema/index.js';
import { BaseService } from 'src/services/base.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

let database: Kysely<DB>;
const embedding = (index: number) => JSON.stringify(Array.from({ length: 512 }, (_, i) => (i === index ? 1 : 0)));

beforeAll(async () => {
  database = await getKyselyDB();
});

afterAll(async () => {
  await database?.destroy();
});

const setup = async () => {
  const { ctx } = newMediumService(BaseService, { database, real: [], mock: [LoggingRepository] });
  const { user } = await ctx.newUser();
  const { asset } = await ctx.newAsset({ ownerId: user.id });
  await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.Preview, path: '/cache/initial.jpg' });
  const assets = ctx.get(AssetRepository);
  const search = ctx.get(SearchRepository);
  const revision = async () => (await ctx.get(AssetJobRepository).getForClipEncoding(asset.id))!.mediaRevision;
  const publish = (path: string, isEdited = false) =>
    assets.publishImageGeneration({
      assetId: asset.id,
      originalPath: asset.originalPath,
      sidecarPath: null,
      fingerprint: null,
      edits: [],
      files: [{ assetId: asset.id, type: AssetFileType.Preview, path, isEdited }],
      thumbhash: Buffer.from('same-thumbhash'),
      dimensions: { width: 1200, height: 800 },
      visibility: { faces: { visible: [], hidden: [] }, ocr: { visible: [], hidden: [] } },
    });
  return { asset, assets, search, revision, publish };
};

describe('search embedding publication', () => {
  it('cannot overwrite a newer embedding when old inference finishes last', async () => {
    const { asset, search, revision, publish } = await setup();
    const oldRevision = await revision();

    await publish('/cache/developed.jpg');
    const latestRevision = await revision();
    expect(latestRevision).not.toBe(oldRevision);
    expect(await search.upsert(asset.id, embedding(1), latestRevision)).toBe(true);
    expect(await search.upsert(asset.id, embedding(0), oldRevision)).toBe(false);
    const latest = await search.getEmbedding(asset.id);
    expect(latest?.embedding).toBe(embedding(1));
  });

  it('guards edited-preview preference and removal while allowing metadata-only changes', async () => {
    const { asset, assets, search, revision, publish } = await setup();
    const baseRevision = await revision();
    await assets.update({ id: asset.id, isFavorite: true });
    expect(await search.upsert(asset.id, embedding(0), baseRevision)).toBe(true);

    await publish('/cache/edited.jpg', true);
    const editedRevision = await revision();
    expect(await search.upsert(asset.id, embedding(0), baseRevision)).toBe(false);
    expect(await search.upsert(asset.id, embedding(1), editedRevision)).toBe(true);

    await publish('/cache/reverted.jpg');
    expect(await search.upsert(asset.id, embedding(1), editedRevision)).toBe(false);
    expect(await search.upsert(asset.id, embedding(2), await revision())).toBe(true);
    const latest = await search.getEmbedding(asset.id);
    expect(latest?.embedding).toBe(embedding(2));
  });

  it('reads the revision after acquiring the asset publication lock', async () => {
    const { asset, search, revision } = await setup();
    const oldRevision = await revision();
    const locked = Promise.withResolvers<void>();
    const release = Promise.withResolvers<void>();
    const publication = database.transaction().execute(async (tx) => {
      // Hold the same row lock as AssetRepository.publishImageGeneration.
      await tx.selectFrom('asset').select('id').where('id', '=', asset.id).forUpdate().executeTakeFirstOrThrow();
      await tx
        .updateTable('asset_file')
        .set({ path: '/cache/concurrently-published.jpg' })
        .where('assetId', '=', asset.id)
        .where('type', '=', AssetFileType.Preview)
        .execute();
      locked.resolve();
      await release.promise;
    });
    let stale: Promise<boolean> | undefined;
    try {
      await locked.promise;
      stale = search.upsert(asset.id, embedding(0), oldRevision);
      await vi.waitFor(async () => {
        const { rows } = await sql<{ waiting: boolean }>`select exists (
          select 1 from pg_stat_activity where datname = current_database() and wait_event_type = 'Lock'
        ) as waiting`.execute(database);
        expect(rows[0].waiting).toBe(true);
      });
    } finally {
      release.resolve();
      await publication;
    }
    expect(await stale).toBe(false);
    expect(await search.getEmbedding(asset.id)).toBeUndefined();
    expect(await search.upsert(asset.id, embedding(1), await revision())).toBe(true);
  });

  it('does not recreate an embedding after the asset is deleted', async () => {
    const { asset, search, revision } = await setup();
    const oldRevision = await revision();
    await database.deleteFrom('asset').where('id', '=', asset.id).execute();
    expect(await search.upsert(asset.id, embedding(0), oldRevision)).toBe(false);
    expect(await search.getEmbedding(asset.id)).toBeUndefined();
  });
});
