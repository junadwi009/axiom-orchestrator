# Legacy Documentation Archive

Folder ini berisi dokumen pre-resolution yang sudah disuperseded oleh dokumentasi di root, tapi dipertahankan untuk:

1. Historical context (audit trail evolution arsitektur)
2. Lore value untuk AutoGen Council debate (mythos tone preservation)
3. Recovery reference kalau perlu cek konsep yang dropped

## File yang di-archive

| File | Reason | Superseded by |
|---|---|---|
| `deploy.sh` | PM2-based deployment, deprecated per Konflik 7 (Docker Compose only) | `docker-compose.yaml`, `MIGRATION_GUIDE.md` |
| `Deployment Strategy.md` | Pre-Konflik 1 architecture (axiom_executioner, Dockerfile.bot stub) | `MIGRATION_GUIDE.md` |
| `File Structure.txt` | Snapshot folder pre-resolution, references file/folder yang sudah tidak ada | Repo current state |
| `The Absolute Masterplan.md` | 5-fase deployment plan dengan VPS spec mismatch + axiom_executioner reference | `MIGRATION_GUIDE.md` + `DEVELOPMENT_ROADMAP.md` |

## Important

File ini **tidak referenced dari runtime code apapun**. Mereka di sini untuk dibaca oleh manusia atau AI yang butuh historical context, BUKAN untuk di-execute atau di-import.
