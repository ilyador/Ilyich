import { Column, CreateDateColumn, ForeignKeyColumn, Index, Table, Timestamp, type Generated } from '@immich/sql-tools';
import { AssetTable } from 'src/schema/tables/asset.table.js';

/** Secondary file-content identity. External asset.checksum remains its stable path identity. */
@Table('asset_content_fingerprint')
@Index({ columns: ['checksum'] })
export class AssetContentFingerprintTable {
  @ForeignKeyColumn(() => AssetTable, { onDelete: 'CASCADE', onUpdate: 'CASCADE', primary: true })
  assetId!: string;

  @Column({ type: 'bytea' })
  checksum!: Buffer;

  @Column()
  originalPath!: string;

  @Column()
  sourceFingerprint!: string;

  @CreateDateColumn()
  checkedAt!: Generated<Timestamp>;
}
