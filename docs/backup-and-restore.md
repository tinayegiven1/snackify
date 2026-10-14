# Backups and restoring

Snackify's data lives in one PostgreSQL database (`snackify_dev` on this PC). These commands
back it up, prove every backup can be restored, and restore it in an emergency. Run them from
the `backend` folder.

| Command                                                      | What it does                                                        |
| ------------------------------------------------------------ | ------------------------------------------------------------------- |
| `npm run db:backup`                                          | Backs up, proves the backup restores, deletes the oldest backups    |
| `npm run db:restore-check`                                   | Proves the newest backup restores (add `-- --file <x.dump>` for another) |
| `npm run db:restore -- --file <x.dump> --confirm snackify_dev` | Replaces the database with a backup (emergencies only)            |

## What a backup is

`npm run db:backup` writes two files to the `backups` folder at the project root (Git ignores
it):

- `snackify_dev-20261013T220000.123Z.dump`: the whole database (tables, data, sequences,
  triggers, functions and privileges), compressed, in PostgreSQL's own format (`pg_dump -Fc`).
  The name is the database and the time in UTC, so the files sort in order.
- `snackify_dev-20261013T220000.123Z.dump.json`: the backup's **manifest**: a SHA-256 checksum
  of the file, plus a fingerprint of the database at that moment (the number of rows in each
  table and a hash of its contents, where each sequence such as invoice numbers was, and a hash
  of the schema and privileges).

The file and the fingerprint come from the same snapshot of the database, so they agree even if
staff are using the app while the backup runs. A backup is written under a temporary name and
only gets its manifest once it is complete, so an interrupted backup never looks like a good
one.

Backups hold everything: customers, invoices and the (hashed) passwords of staff. Treat the
`backups` folder like the database itself.

## How a restore is tested

Straight after each backup, and whenever you run `npm run db:restore-check`:

1. The file's checksum is compared with the manifest, which shows the file is the one that was
   made and has not been damaged since.
2. The backup is restored into a separate, empty database, `snackify_restore_check`, created
   for this by `database/setup/local-setup.sql`. The real database is never touched.
3. The restored copy is fingerprinted the same way and compared with the manifest: every table
   (row counts and contents), every sequence, and the columns, constraints, indexes, triggers,
   views, functions and privileges. Privileges matter: the app role must still be unable to
   change the stock ledger or delete invoices after a restore.
4. The restored copy is deleted again, so no extra copy of the business data is left behind.

Any difference is listed in words, for example
`table products: 120 rows in the backup, 119 restored`, and the command exits with an error.
`db:backup` deletes old backups only after the new one has passed this check, keeping the newest
`BACKUP_KEEP` (default 30).

The automated tests (`npm run test:db`, file `backup-restore.test.ts`) do the same against the
test database, and also check that a damaged file, a cut-off file and a restored copy that lost
rows, changed a value, reset a sequence, dropped a trigger or gained a privilege are all caught.

## Restoring for real

Only when the database is lost or badly damaged:

1. Stop the backend (`Ctrl+C` in its window), so nobody changes data during the restore.
2. Choose the backup (normally the newest file in `backups`), then from the `backend` folder:

   ```powershell
   npm run db:restore -- --file ..\backups\snackify_dev-20261013T220000.123Z.dump --confirm snackify_dev
   ```

   You must type the database name after `--confirm`. The command then:
   1. proves the backup restores, in `snackify_restore_check`, and stops if it does not;
   2. **backs up the current database first**, so the restore itself can be undone (the log
      names that file);
   3. empties the database, restores the backup and compares the result with the manifest.
3. Run `npm run db:migrate`, in case the backup was made by an older version of Snackify.
4. Start the backend again.

Everything entered after the backup was made is lost, so restore the newest good backup.

## Running backups automatically

On this PC, the Windows Task Scheduler task **Snackify daily backup** runs `npm run db:backup`
every evening at 22:00. It runs as you, only while you are signed in (so no password is stored),
catches up at the next opportunity if the PC was off at 22:00, and is stopped if it takes more
than an hour. Its output is added to `backups\backup.log`.

Check `backups\backup.log` now and then: each run ends with `Restore check passed`. In Task
Scheduler, a **Last Run Result** other than `0x0` means the last run failed.

To set the same task up on another Windows PC, in PowerShell (change the paths if the project
is elsewhere):

```powershell
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/c npm run db:backup >> "C:\dev\snackify\backups\backup.log" 2>&1' -WorkingDirectory 'C:\dev\snackify\backend'
$trigger = New-ScheduledTaskTrigger -Daily -At '22:00'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'Snackify daily backup' -Action $action -Trigger $trigger -Settings $settings
```

The `backups` folder must exist first (run `npm run db:backup` once by hand). To run the task
now: `Start-ScheduledTask 'Snackify daily backup'`. To remove it:
`Unregister-ScheduledTask 'Snackify daily backup'`.

## Keep a copy somewhere else

Backups on the same PC as the database do not survive a stolen PC, a dead disk or ransomware.
Copy the newest backup (both files) regularly to somewhere else: an encrypted USB drive kept off
site, or private cloud storage. Copy it, rather than moving the `backups` folder into a sync
folder. Check a copy now and then with
`npm run db:restore-check -- --file <path to the copied .dump>`.

## Settings (`backend/.env`, all optional)

| Variable                     | Default                         | Meaning                                         |
| ---------------------------- | ------------------------------- | ----------------------------------------------- |
| `BACKUP_DIR`                 | `backups` at the project root   | Where backups are written                       |
| `BACKUP_KEEP`                | `30`                            | How many backups to keep (1–1000)               |
| `PG_BIN_DIR`                 | `C:\Program Files\PostgreSQL\18\bin` on Windows, else the PATH | Folder with `pg_dump` and `pg_restore` |
| `RESTORE_CHECK_DATABASE_URL` | the `MIGRATION_DATABASE_URL` login, database `snackify_restore_check` | Scratch database for restore checks; its name must end in `_restore_check` |

The database backed up is the one in `MIGRATION_DATABASE_URL`, using the `snackify_owner` role,
which owns every table. Its password is passed to `pg_dump` and `pg_restore` in their
environment, never on the command line, and is never written to the log.

## Limits

- A daily backup can lose up to a day of work. Hosted PostgreSQL services offer continuous
  backups with point-in-time recovery; use that in production as well as these daily files.
- Backup files are not encrypted by Snackify. Protect the folder and any copies.
- `pg_dump` must be the same major version as the server (or newer).
