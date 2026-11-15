import { schemaDiff, schemaFromCode, schemaFromDatabase } from '@immich/sql-tools';
import { Kysely, sql } from 'kysely';
import { columns } from 'src/database.js';
import { AssetStatus, AssetType, AssetVisibility, ChecksumAlgorithm } from 'src/enum.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LibraryRepository } from 'src/repositories/library.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { immich_uuid_v7, invalidate_asset_content_fingerprint } from 'src/schema/functions.js';
import { DB } from 'src/schema/index.js';
import { BaseService } from 'src/services/base.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db.destroy();
});

it('registers the migrated fingerprint invalidation function without schema drift', async () => {
  const { rows } = await sql<{ name: string }>`SELECT current_database() AS name`.execute(db);
  const url = new URL(process.env.IMMICH_TEST_POSTGRES_URL!);
  url.pathname = `/${rows[0].name}`;
  const source = schemaFromCode({
    overrides: true,
    namingStrategy: 'default',
    uuidFunction: (version) => (version === 7 ? `${immich_uuid_v7.name}()` : 'uuid_generate_v4()'),
  });
  const target = await schemaFromDatabase({ connection: { connectionType: 'url', url: url.href } });
  const drift = schemaDiff(source, target, {
    tables: { ignoreExtra: true },
    constraints: { ignoreExtra: false },
    indexes: { ignoreExtra: true },
    triggers: { ignoreExtra: true },
    columns: { ignoreExtra: true },
    functions: { ignoreExtra: false },
    parameters: { ignoreExtra: true },
    extensions: { ignoreExtra: true },
    ignorePrefixes: ['futo_backups_'],
  });
  expect(drift.items).toEqual([]);
  const { rows: functions } = await sql<{ body: string; returnType: string }>`
    SELECT prosrc AS body, pg_get_function_result(oid) AS "returnType"
    FROM pg_proc WHERE oid = 'public.invalidate_asset_content_fingerprint()'::regprocedure
  `.execute(db);
  expect(functions).toHaveLength(1);
  expect(functions[0].returnType).toBe('trigger');
  expect(functions[0].body.trim()).toBe(
    invalidate_asset_content_fingerprint.expression.split('AS $$', 2)[1].split('$$;', 1)[0].trim(),
  );
});

it('matches secondary file bytes owner-scoped without changing external path identity, and invalidates stale/deleted sources', async () => {
  const { ctx } = newMediumService(BaseService, { database: db, real: [], mock: [LoggingRepository] });
  const repo = ctx.get(AssetRepository);
  const { user: alice } = await ctx.newUser();
  const { user: bob } = await ctx.newUser();
  const libraries = ctx.get(LibraryRepository);
  const archive = await libraries.create({
    ownerId: alice.id,
    name: 'Archive',
    importPaths: ['/archive'],
    exclusionPatterns: [],
  });
  const other = await libraries.create({
    ownerId: bob.id,
    name: 'Other',
    importPaths: ['/other'],
    exclusionPatterns: [],
  });
  const bytes = Buffer.from('actual-file-digest');
  const { asset: a } = await ctx.newAsset({
    ownerId: alice.id,
    libraryId: archive.id,
    checksumAlgorithm: ChecksumAlgorithm.sha1Path,
    checksum: Buffer.from('path:a'),
    originalPath: '/archive/a.jpg',
    isExternal: true,
  });
  const { asset: b } = await ctx.newAsset({
    ownerId: alice.id,
    libraryId: archive.id,
    checksumAlgorithm: ChecksumAlgorithm.sha1Path,
    checksum: Buffer.from('path:b'),
    originalPath: '/archive/b.jpg',
    isExternal: true,
  });
  const { asset: foreign } = await ctx.newAsset({
    ownerId: bob.id,
    libraryId: other.id,
    checksumAlgorithm: ChecksumAlgorithm.sha1Path,
    checksum: bytes,
    originalPath: '/other/a.jpg',
    isExternal: true,
  });
  expect(await repo.getContentFingerprintStatus(alice.id)).toEqual({ total: 2, prepared: 0, pending: 2 });
  for (const asset of [a, b, foreign]) {
    await repo.saveContentFingerprint({
      assetId: asset.id,
      originalPath: asset.originalPath,
      checksum: bytes,
      sourceFingerprint: 'file-state',
    });
  }
  expect(await repo.getByChecksums(bob.id, [bytes])).toEqual([]);
  const ownCopies = await repo.getByContentChecksums(alice.id, [bytes]);
  expect(ownCopies.map((row) => row.id)).toEqual([a.id, b.id].sort());
  expect(await repo.getContentFingerprintStatus(alice.id)).toEqual({ total: 2, prepared: 2, pending: 0 });
  const original = await db
    .selectFrom('asset')
    .select(['checksum', 'checksumAlgorithm'])
    .where('id', '=', a.id)
    .executeTakeFirstOrThrow();
  expect(original.checksum).toEqual(Buffer.from('path:a'));
  expect(original.checksumAlgorithm).toBe(ChecksumAlgorithm.sha1Path);
  const synced = await db
    .selectFrom('asset')
    .select(columns.syncAsset)
    .where('asset.id', '=', a.id)
    .executeTakeFirstOrThrow();
  expect(synced.checksumAlgorithm).toBe(ChecksumAlgorithm.sha1Path);
  expect(synced.contentChecksum).toEqual(bytes);

  await db.updateTable('asset').set({ originalPath: '/archive/moved.jpg' }).where('id', '=', a.id).execute();
  expect(await repo.getContentFingerprints([a.id])).toEqual([]);
  await repo.saveContentFingerprint({
    assetId: a.id,
    originalPath: '/archive/a.jpg',
    checksum: bytes,
    sourceFingerprint: 'stale-job',
  });
  expect(await repo.getContentFingerprints([a.id])).toEqual([]);
  await db.updateTable('asset').set({ isOffline: true }).where('id', '=', b.id).execute();
  expect(await repo.getContentFingerprints([b.id])).toEqual([]);
  expect(await repo.getByContentChecksums(alice.id, [bytes])).toEqual([]);
  await db
    .updateTable('asset')
    .set({ isOffline: false, status: AssetStatus.Active, visibility: AssetVisibility.Timeline })
    .where('id', '=', b.id)
    .execute();
  await repo.saveContentFingerprint({
    assetId: b.id,
    originalPath: b.originalPath,
    checksum: bytes,
    sourceFingerprint: 'new-file-state',
  });
  await db.deleteFrom('asset').where('id', '=', b.id).execute();
  expect(await repo.getContentFingerprints([b.id])).toEqual([]);
  const foreignCopies = await repo.getByContentChecksums(bob.id, [bytes]);
  expect(foreignCopies.map((row) => row.id)).toEqual([foreign.id]);
});

it('auto-pairs Live Photos only inside the same library and never with inactive source or target assets', async () => {
  const { ctx } = newMediumService(BaseService, { database: db, real: [], mock: [LoggingRepository] });
  const repo = ctx.get(AssetRepository);
  const { user } = await ctx.newUser();
  const archive = await ctx
    .get(LibraryRepository)
    .create({ ownerId: user.id, name: 'Archive', importPaths: ['/archive'], exclusionPatterns: [] });
  const { asset: originalStill } = await ctx.newAsset({
    ownerId: user.id,
    libraryId: archive.id,
    type: AssetType.Image,
  });
  const { asset: originalMotion } = await ctx.newAsset({
    ownerId: user.id,
    libraryId: archive.id,
    type: AssetType.Video,
  });
  const { asset: uploadedMotion } = await ctx.newAsset({ ownerId: user.id, libraryId: null, type: AssetType.Video });
  for (const asset of [originalStill, originalMotion, uploadedMotion]) {
    await ctx.newExif({ assetId: asset.id, livePhotoCID: 'shared-cloud-content-id' });
  }
  expect(
    await repo.findLivePhotoMatch({
      ownerId: user.id,
      libraryId: null,
      otherAssetId: uploadedMotion.id,
      livePhotoCID: 'shared-cloud-content-id',
      type: AssetType.Image,
    }),
  ).toBeUndefined();
  const options = {
    ownerId: user.id,
    libraryId: archive.id,
    otherAssetId: originalStill.id,
    livePhotoCID: 'shared-cloud-content-id',
    type: AssetType.Video,
  };
  const match = await repo.findLivePhotoMatch(options);
  expect(match?.id).toBe(originalMotion.id);
  for (const inactive of [
    { isOffline: true },
    { status: AssetStatus.Trashed, deletedAt: new Date() },
    { status: AssetStatus.Deleted },
  ]) {
    await db
      .updateTable('asset')
      .set({ ...inactive })
      .where('id', '=', originalMotion.id)
      .execute();
    expect(await repo.findLivePhotoMatch(options)).toBeUndefined();
    await db
      .updateTable('asset')
      .set({ isOffline: false, status: AssetStatus.Active, deletedAt: null })
      .where('id', '=', originalMotion.id)
      .execute();
  }
  await db
    .updateTable('asset')
    .set({ status: AssetStatus.Trashed, deletedAt: new Date() })
    .where('id', '=', originalStill.id)
    .execute();
  expect(await repo.findLivePhotoMatch(options)).toBeUndefined();
});
