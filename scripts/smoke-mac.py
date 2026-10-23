"""Exercise the shipped executable, including Darwin's exclusive rename API."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
engine=root/'build/TrailDrop.app/Contents/Resources/traildrop-engine'
with tempfile.TemporaryDirectory() as temp:
    base=Path(temp)
    source=base/'camera'; source.mkdir()
    target=base/'archive'; target.mkdir()
    media=source/'DJI_20261023_091800_001.MP4'
    media.write_bytes(os.urandom(8*1024*1024))
    def call(action,**extra):
        request=dict(action=action,source=str(source),stateDir=str(base/'state'),**extra)
        result=subprocess.run([str(engine)],input=json.dumps(request)+'\n',capture_output=True,text=True,check=True)
        events=[json.loads(line) for line in result.stdout.splitlines()]
        assert events[-1]['event']=='result',events
        return events[-1]['result']
    scan=call('scan')
    file=scan['files'][0]
    common=dict(selected=[file['id']],sourceToken=scan['sourceToken'],expected={file['id']:dict(size=file['size'],mtime=file['mtime'])})
    copied=call('transfer',destination=str(target),**common)
    installed=Path(copied['files'][0]['target'])
    assert installed.read_bytes()==media.read_bytes()
    again=call('transfer',destination=str(target),**common)
    assert again['files'][0]['status']=='skipped'
    deleted=call('delete',force=False,**common)
    assert deleted['deleted']==[file['id']] and not media.exists() and installed.exists()
print('PASS: standalone engine scan, transfer, Darwin rename, checksum, deduplication, safe cleanup')
