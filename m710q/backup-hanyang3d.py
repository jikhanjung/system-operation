#!/usr/bin/env python3
"""m710q daily pull of verified Hanyang3D snapshots; local 30d / NAS 90d + month starts.
No live DB copy, no outgoing notifications, no cleanup after failed verification.
"""
from contextlib import closing
from datetime import datetime, timezone, timedelta
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import time

LOCAL = Path('/home/jikhanjung/backups/hanyang3d')
NAS = Path('/nas/JikhanJung/hanyang3d_backup')
EXPECTED = {'content.sqlite3', 'snapshot.json', 'configuration/.env', 'configuration/.env.django', 'configuration/docker-compose.yml', 'configuration/docker-compose.content.yml'}


def verify(path):
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro&immutable=1', uri=True)) as db:
        if db.execute('PRAGMA integrity_check').fetchall() != [('ok',)]: raise ValueError('Integrity check failed')
        if db.execute('PRAGMA foreign_key_check').fetchone(): raise ValueError('Foreign key check failed')
        if db.execute('SELECT COUNT(*) FROM django_session').fetchone()[0]: raise ValueError('Session data in snapshot')
        if db.execute('PRAGMA journal_mode').fetchone()[0] != 'delete': raise ValueError('Snapshot must be standalone DELETE mode')
        if db.execute('SELECT COUNT(*) FROM webapp_building').fetchone()[0] == 0: raise ValueError('No building data')


def copy_atomic(source, target):
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.incoming-', dir=target.parent)
    os.close(fd)
    try:
        shutil.copyfile(source, temporary)
        os.chmod(temporary, 0o600)
        if target.suffix == '.sqlite3': verify(Path(temporary))
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)


def adopt(root, staging, days):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    today = datetime.now(timezone.utc).date()
    for name in ('db_history', 'configuration_history', 'current'):
        (root / name).mkdir(exist_ok=True, mode=0o700)
    # DB and config validated as one bundle before either is adopted.
    db_target = root / 'db_history' / f'db_{today.isoformat()}.sqlite3'
    cfg_target = root / 'configuration_history' / f'configuration_{today.isoformat()}.tar.gz'
    if not db_target.exists(): copy_atomic(staging / 'content.sqlite3', db_target)
    if not cfg_target.exists(): copy_atomic(staging / 'bundle.tar.gz', cfg_target)
    copy_atomic(staging / 'content.sqlite3', root / 'current/content.sqlite3')
    copy_atomic(staging / 'bundle.tar.gz', root / 'current/configuration.tar.gz')
    copy_atomic(staging / 'snapshot.json', root / 'current/snapshot.json')
    cutoff = today - timedelta(days=days)
    for directory in ('db_history', 'configuration_history'):
        for path in (root / directory).iterdir():
            match = re.fullmatch(r'(?:db|configuration)_(\d{4}-\d{2}-\d{2})\.(?:sqlite3|tar.gz)', path.name)
            if not match: continue
            date = datetime.strptime(match[1], '%Y-%m-%d').date()
            if date < cutoff and date.day != 1:
                path.unlink()
    return {'days': days, 'buildings': 'verified', 'date': str(today)}


def main():
    os.umask(0o077)
    LOCAL.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (LOCAL / '.pull.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with tempfile.TemporaryDirectory(prefix='.pull-', dir=LOCAL) as directory:
                staging = Path(directory)
                with (staging / 'bundle.tar.gz').open('wb') as out:
                    subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2', 'dolfinid', 'sudo -n python3 /srv/hanyang3d/export_content_snapshot.py'], stdout=out, check=True, timeout=120)
                with tarfile.open(staging / 'bundle.tar.gz', 'r:gz') as archive:
                    members = archive.getmembers()
                    if len(members) != len(EXPECTED) or {m.name for m in members} != EXPECTED or not all(m.isfile() for m in members): raise ValueError('Unexpected backup bundle contents')
                    for name in ('content.sqlite3', 'snapshot.json'):
                        with archive.extractfile(name) as src, (staging / name).open('wb') as dst: shutil.copyfileobj(src, dst)
                metadata = json.loads((staging / 'snapshot.json').read_text())
                if not 0 <= time.time() - metadata['created_at'] <= 3*3600: raise ValueError('Stale snapshot')
                verify(staging / 'content.sqlite3')
                local_result = adopt(LOCAL, staging, 30)
                subprocess.run(['timeout', '10', 'mountpoint', '-q', '/nas'], check=True)
                subprocess.run(['timeout', '10', 'test', '-d', str(NAS.parent)], check=True)
                nas_result = adopt(NAS, staging, 90)
                result = {'status': 'ok', 'time': datetime.now(timezone.utc).isoformat(), 'local': local_result, 'nas': nas_result}
                (LOCAL / 'status.json').write_text(json.dumps(result) + '\n')
                print(json.dumps(result), flush=True)
        except Exception as exc:
            (LOCAL / 'status.json').write_text(json.dumps({'status': 'failed', 'time': datetime.now(timezone.utc).isoformat(), 'error': str(exc)}) + '\n')
            raise


if __name__ == '__main__': main()
