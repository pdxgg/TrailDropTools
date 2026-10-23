"""TrailDrop local disk adapter. JSON-lines CLI; no network or third-party packages."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import sys
import threading
import uuid

MEDIA = {'.mp4', '.mov', '.mkv', '.avi', '.insv', '.insp', '.jpg', '.jpeg', '.png', '.heic', '.dng', '.tif', '.tiff', '.webp'}
SIDECARS = {'.lrv', '.lrf', '.srt', '.thm', '.xmp', '.wav'}
CHUNK = 4 * 1024 * 1024


class Stopped(Exception):
    pass


class Engine:
    def __init__(self, state_dir, emit=lambda _: None, stop=None):
        state = Path(state_dir)
        state.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(state / 'index.sqlite3', timeout=30)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS copies (digest TEXT, size INTEGER, path TEXT PRIMARY KEY, verified TEXT);
        CREATE TABLE IF NOT EXISTS jobs (key TEXT PRIMARY KEY, source TEXT, target TEXT, digest TEXT, size INTEGER, mtime INTEGER);
        CREATE TABLE IF NOT EXISTS audit (time TEXT, action TEXT, source TEXT, detail TEXT);
        ''')
        self.emit = emit
        self.stop = stop or threading.Event()

    def check(self):
        if self.stop.is_set():
            raise Stopped('已暂停，临时文件与断点已保留。')

    def digest(self, path):
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            while True:
                self.check()
                block = f.read(CHUNK)
                if not block:
                    break
                h.update(block)
        return h.hexdigest()

    @staticmethod
    def safe(root, relative):
        root = Path(root).resolve(strict=True)
        rel = Path(relative)
        if rel.is_absolute() or '..' in rel.parts:
            raise ValueError('非法源路径')
        candidate = root / rel
        # Never follow source symlinks, including any parent component.
        current = root
        for part in rel.parts:
            current /= part
            if current.is_symlink():
                raise ValueError('不允许符号链接源文件')
        resolved = candidate.resolve(strict=True)
        if not resolved.is_relative_to(root) or not resolved.is_file():
            raise ValueError('源文件不在所选设备目录内')
        return resolved

    @staticmethod
    def stamp(path):
        match = re.search(r'(20\d{6})[_-]?(\d{6})', path.stem)
        if match:
            try:
                return dt.datetime.strptime(''.join(match.groups()), '%Y%m%d%H%M%S'), '文件名'
            except ValueError:
                pass
        return dt.datetime.fromtimestamp(path.stat().st_mtime), '修改时间（回退）'

    def known(self, path):
        # UI status is deliberately not authorization to delete. Deletion rehashes both sides.
        stat = path.stat()
        rows = self.db.execute('SELECT digest,path FROM copies WHERE size=?', (stat.st_size,)).fetchall()
        if not rows:
            return None
        digest = self.digest(path)
        for stored, target in rows:
            p = Path(target)
            if stored == digest and p.is_file() and p.stat().st_size == stat.st_size:
                if self.digest(p) == digest:
                    return str(p)
        return None

    @staticmethod
    def members(path):
        """Same-stem sidecars and documented paired Insta360 lens/proxy naming."""
        matched = [path]
        insta = re.fullmatch(r'(?:VID|LRV)_(\d{8}_\d{6})_\d{2}_(\d+)',path.stem,re.I)
        for sibling in sorted(path.parent.iterdir()):
            if sibling == path or sibling.is_symlink() or not sibling.is_file():
                continue
            same_stem = sibling.stem == path.stem and sibling.suffix.lower() in SIDECARS
            other = re.fullmatch(r'(?:VID|LRV)_(\d{8}_\d{6})_\d{2}_(\d+)',sibling.stem,re.I)
            paired = (insta and other and insta.groups() == other.groups()
                      and path.suffix.lower() in {'.insv','.lrv'}
                      and sibling.suffix.lower() in {'.insv','.lrv'})
            if same_stem or paired:
                matched.append(sibling)
        return matched

    def scan(self, source):
        root = Path(source).resolve(strict=True)
        if not root.is_dir():
            raise ValueError('请选择设备目录')
        found, warnings = [], []
        for folder, dirs, names in os.walk(root, followlinks=False):
            self.check()
            dirs[:] = [d for d in dirs if not d.startswith('.') and not (Path(folder)/d).is_symlink()]
            for name in sorted(names):
                p = Path(folder)/name
                if p.suffix.lower() not in MEDIA or p.is_symlink():
                    continue
                try:
                    st = p.stat()
                    date, origin = self.stamp(p)
                    relative = str(p.relative_to(root))
                    companions = [str(q.relative_to(root)) for q in self.members(p) if q != p]
                    copy = self.known(p)
                    if copy and any(not self.known(q) for q in self.members(p) if q != p):
                        copy = None
                    found.append(dict(id=relative, name=p.name, path=str(p), date=date.isoformat(timespec='seconds'),
                                      dateSource=origin, size=st.st_size, mtime=st.st_mtime_ns,
                                      isVideo=p.suffix.lower() in {'.mp4','.mov','.mkv','.avi','.insv'},
                                      companions=sorted(companions), macPath=copy))
                except (OSError, ValueError) as exc:
                    warnings.append(f'{p.name}: {exc}')
        found.sort(key=lambda f: f['date'], reverse=True)
        identity = root.stat()
        return dict(files=found, warnings=warnings, source=str(root),
                    sourceToken=f'{identity.st_dev}:{identity.st_ino}')

    def verified_copy(self, source, within=None):
        digest = self.digest(source)
        for (target,) in self.db.execute('SELECT path FROM copies WHERE digest=? AND size=?', (digest, source.stat().st_size)):
            p = Path(target)
            if within is not None and not p.is_relative_to(within):
                continue
            if p.is_file() and p.stat().st_size == source.stat().st_size and self.digest(p) == digest:
                return str(p)
        return None

    def transfer(self, source, destination, selected, expected=None):
        root = Path(source).resolve(strict=True)
        dest = Path(destination).resolve(strict=True)
        if not dest.is_dir() or dest == root or dest.is_relative_to(root) or root.is_relative_to(dest):
            raise ValueError('源目录与保存目录不能重合或相互包含')
        selected = list(dict.fromkeys(selected))
        if not selected:
            raise ValueError('未选择素材')
        all_files = []
        # Rescan companions rather than trusting UI-provided deletion/copy paths.
        for rel in selected:
            p = self.safe(root, rel)
            self.check_expected(p, rel, expected)
            if p.suffix.lower() not in MEDIA:
                raise ValueError('只能转存照片或视频素材')
            all_files.append(rel)
            all_files.extend(str(q.relative_to(root)) for q in self.members(p) if q != p)
        all_files = list(dict.fromkeys(all_files))
        import shutil
        batch = dt.datetime.now().strftime('%Y-%m-%d_%H-%M-%S') + '_' + uuid.uuid4().hex[:6]
        results = []
        for index, rel in enumerate(all_files):
            self.check()
            p = self.safe(root, rel)
            if rel in selected:
                self.check_expected(p, rel, expected)
            before = p.stat()
            digest = self.digest(p)
            key = hashlib.sha256((str(root)+'\0'+rel+'\0'+str(dest)+'\0'+digest).encode()).hexdigest()
            job = self.db.execute('SELECT target FROM jobs WHERE key=?', (key,)).fetchone()
            existing = self.verified_copy(p, within=dest)
            if existing:
                self.emit(dict(event='file', name=p.name, status='已跳过相同内容', index=index, total=len(all_files)))
                results.append(dict(source=rel, target=existing, status='skipped', sha256=digest))
                continue
            if job:
                target = Path(job[0])
                if not target.resolve().is_relative_to(dest):
                    raise ValueError('断点目标不属于当前保存目录')
            else:
                date, _ = self.stamp(p)
                target = dest / batch / date.strftime('%Y-%m-%d/%H-%M') / root.name / rel
                self.db.execute('INSERT OR REPLACE INTO jobs VALUES(?,?,?,?,?,?)', (key,str(p),str(target),digest,before.st_size,before.st_mtime_ns))
                self.db.commit()
            if not target.resolve().is_relative_to(dest):
                raise ValueError('目标目录包含越界符号链接')
            target.parent.mkdir(parents=True, exist_ok=True)
            part = target.with_name(target.name+'.traildrop-part')
            if part.is_symlink() or target.is_symlink():
                raise ValueError('目标不允许为符号链接')
            offset = part.stat().st_size if part.exists() else 0
            if offset > before.st_size:
                offset = 0
            # Validate the entire partial prefix before resuming, not only the last block.
            if offset:
                with p.open('rb') as a, part.open('rb') as b:
                    left = offset
                    while left:
                        self.check()
                        n = min(CHUNK,left)
                        if a.read(n) != b.read(n):
                            offset = 0
                            break
                        left -= n
            if shutil.disk_usage(dest).free < max(0,before.st_size-offset) + 1024*1024:
                raise ValueError('目标剩余空间不足，已完成文件与断点保留')
            self.emit(dict(event='file',name=p.name,status='复制中',offset=offset,index=index,total=len(all_files)))
            with p.open('rb') as src, part.open('r+b' if part.exists() else 'w+b') as out:
                src.seek(offset)
                out.truncate(offset)
                out.seek(offset)
                while True:
                    self.check()
                    block = src.read(CHUNK)
                    if not block:
                        break
                    out.write(block)
                    offset += len(block)
                    self.emit(dict(event='progress',name=p.name,bytes=offset,size=before.st_size,index=index,total=len(all_files)))
                out.flush()
                os.fsync(out.fileno())
            self.emit(dict(event='file',name=p.name,status='校验中',index=index,total=len(all_files)))
            after = p.stat()
            if (before.st_size,before.st_mtime_ns)!=(after.st_size,after.st_mtime_ns) or self.digest(p)!=digest or self.digest(part)!=digest:
                raise ValueError(f'{p.name} 发生变化或校验失败，保留源文件')
            # Atomically publish without overwriting an existing file.
            if target.exists():
                if self.digest(target)!=digest:
                    raise ValueError('目标同名文件内容不同，拒绝覆盖')
                part.unlink()
            else:
                self.publish(part, target)
            os.utime(target, ns=(before.st_atime_ns,before.st_mtime_ns))
            self.db.execute('INSERT OR REPLACE INTO copies VALUES(?,?,?,?)', (digest,before.st_size,str(target),dt.datetime.now().isoformat()))
            self.db.execute('DELETE FROM jobs WHERE key=?',(key,))
            self.db.commit()
            results.append(dict(source=rel,target=str(target),status='verified',sha256=digest))
        manifest = dest / batch / 'transfer-manifest.json'
        manifest.parent.mkdir(parents=True,exist_ok=True)
        manifest.write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
        return dict(files=results, manifest=str(manifest))

    @staticmethod
    def publish(part, target):
        if sys.platform == 'darwin':
            import ctypes
            libc = ctypes.CDLL(None, use_errno=True)
            rename = libc.renamex_np
            rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
            rename.restype = ctypes.c_int
            if rename(os.fsencode(part), os.fsencode(target), 4) != 0:  # RENAME_EXCL
                code = ctypes.get_errno()
                raise OSError(code, os.strerror(code), str(target))
        else:
            os.link(part, target)
            part.unlink()

    @staticmethod
    def check_expected(path, relative, expected):
        if expected is None:
            return
        snapshot = expected.get(relative)
        stat = path.stat()
        if not snapshot or snapshot.get('size') != stat.st_size or snapshot.get('mtime') != stat.st_mtime_ns:
            raise ValueError(f'{relative} 自扫描后已变化，请重新扫描后选择')

    @staticmethod
    def check_source(request):
        stat = Path(request['source']).resolve(strict=True).stat()
        if request.get('sourceToken') != f'{stat.st_dev}:{stat.st_ino}':
            raise ValueError('设备来源已变化或重新挂载，请重新扫描后再操作')

    def delete(self, source, selected, force=False, force_confirmation='', expected=None):
        if force and force_confirmation != '删除未备份素材':
            raise ValueError('强制清理需要输入“删除未备份素材”完成二次确认')
        root = Path(source).resolve(strict=True)
        selected = list(dict.fromkeys(selected))
        deleted, failed = [], []
        for rel in selected:
            if rel in deleted:
                continue
            try:
                self.check()
                p = self.safe(root,rel)
                self.check_expected(p, rel, expected)
                if p.suffix.lower() not in MEDIA:
                    raise ValueError('仅允许删除所选照片或视频')
                members = self.members(p)
                # Preflight the whole group and revalidate immediately before unlink.
                snapshots = [(q,q.stat(),self.digest(q)) for q in members]
                if not force:
                    for q,_,_ in snapshots:
                        if not self.verified_copy(q):
                            raise ValueError(f'{q.name} 没有完整有效的 Mac 副本；需单独强制清理')
                for q,st,digest in snapshots:
                    self.safe(root,str(q.relative_to(root)))
                    current = q.stat()
                    if (current.st_size,current.st_mtime_ns)!=(st.st_size,st.st_mtime_ns) or self.digest(q)!=digest:
                        raise ValueError('源文件已变化，取消删除')
                for q,_,_ in snapshots:
                    self.db.execute('INSERT INTO audit VALUES(?,?,?,?)',(dt.datetime.now().isoformat(),'force-delete' if force else 'delete',str(q),'intent'))
                    self.db.commit()
                    q.unlink()
                    self.db.execute('INSERT INTO audit VALUES(?,?,?,?)',(dt.datetime.now().isoformat(),'deleted',str(q),'success'))
                    self.db.commit()
                    if q.suffix.lower() in MEDIA:
                        deleted.append(str(q.relative_to(root)))
            except (OSError,ValueError) as exc:
                failed.append(dict(source=rel,error=str(exc)))
        return dict(deleted=deleted,failed=failed)


def main():
    def emit(event):
        print(json.dumps(event,ensure_ascii=False),flush=True)
    stopped=threading.Event()
    signal.signal(signal.SIGTERM,lambda *_:stopped.set())
    try:
        req=json.loads(sys.stdin.readline())
        import fcntl
        state=Path(req['stateDir'])
        state.mkdir(parents=True,exist_ok=True)
        lock=(state/'operation.lock').open('a')
        try:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('另一个窗口正在操作，请等待它完成或暂停')
        engine=Engine(req['stateDir'],emit,stopped)
        action=req['action']
        if action=='scan':
            result=engine.scan(req['source'])
        elif action=='transfer':
            Engine.check_source(req)
            result=engine.transfer(req['source'],req['destination'],req['selected'],req['expected'])
        elif action=='delete':
            Engine.check_source(req)
            result=engine.delete(req['source'],req['selected'],req.get('force',False),req.get('confirmation',''),req['expected'])
        else:
            raise ValueError('未知操作')
        emit(dict(event='result',result=result))
    except Stopped as exc:
        emit(dict(event='paused',message=str(exc)))
    except Exception as exc:
        emit(dict(event='error',message=str(exc)))
        sys.exit(1)

if __name__=='__main__':
    main()
