import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`CREATE TABLE "asset_content_fingerprint" (
    "assetId" uuid PRIMARY KEY REFERENCES "asset"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    "checksum" bytea NOT NULL,
    "originalPath" character varying NOT NULL,
    "sourceFingerprint" character varying NOT NULL,
    "checkedAt" timestamp with time zone NOT NULL DEFAULT now()
  );`.execute(db);
  await sql`CREATE INDEX "asset_content_fingerprint_checksum_idx" ON "asset_content_fingerprint" ("checksum");`.execute(db);
  await sql`CREATE FUNCTION invalidate_asset_content_fingerprint() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW."originalPath" IS DISTINCT FROM OLD."originalPath"
        OR NEW."checksumAlgorithm" IS DISTINCT FROM OLD."checksumAlgorithm"
        OR NEW."isOffline" OR NEW."deletedAt" IS NOT NULL OR NEW."status" <> 'active' THEN
        DELETE FROM "asset_content_fingerprint" WHERE "assetId" = NEW."id";
      END IF;
      RETURN NEW;
    END;
  $$;`.execute(db);
  await sql`CREATE TRIGGER "asset_content_fingerprint_invalidate"
    AFTER UPDATE OF "originalPath", "checksumAlgorithm", "isOffline", "deletedAt", "status" ON "asset"
    FOR EACH ROW EXECUTE FUNCTION invalidate_asset_content_fingerprint();`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP TRIGGER "asset_content_fingerprint_invalidate" ON "asset";`.execute(db);
  await sql`DROP FUNCTION invalidate_asset_content_fingerprint();`.execute(db);
  await sql`DROP TABLE "asset_content_fingerprint";`.execute(db);
}
