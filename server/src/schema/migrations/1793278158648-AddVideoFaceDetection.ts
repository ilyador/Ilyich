import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`ALTER TABLE "asset_face" ADD "frameTimestamp" integer;`.execute(db);
  await sql`ALTER TABLE "asset_job_status" ADD "videoFacesDetectedAt" timestamp with time zone;`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`ALTER TABLE "asset_face" DROP COLUMN "frameTimestamp";`.execute(db);
  await sql`ALTER TABLE "asset_job_status" DROP COLUMN "videoFacesDetectedAt";`.execute(db);
}
