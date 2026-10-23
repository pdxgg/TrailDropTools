import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

SPEC = importlib.util.spec_from_file_location('engine',Path(__file__).parents[1]/'Core/engine.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.base=Path(self.temp.name)
        self.source=self.base/'camera'; self.source.mkdir()
        self.dest=self.base/'mac'; self.dest.mkdir()
        self.state=self.base/'state'
        self.events=[]
        self.engine=MODULE.Engine(self.state,self.events.append)

    def tearDown(self):
        self.engine.db.close()
        self.temp.cleanup()

    def media(self,name='DCIM/DJI_20261023_091800_001.MP4',content=b'original-video'):
        path=self.source/name
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(content)
        return name

    def transfer(self,selected):
        return self.engine.transfer(self.source,self.dest,selected)

    def test_scan_all_days_media_and_companions(self):
        rel=self.media()
        self.media('another/place/DJI_20261021_081500_002.JPG',b'photo')
        self.media('DCIM/DJI_20261023_091800_001.SRT',b'caption')
        self.media('notes.txt',b'ignore')
        result=self.engine.scan(self.source)
        self.assertEqual(len(result['files']),2)
        self.assertEqual(result['files'][0]['id'],rel)
        self.assertEqual(result['files'][0]['dateSource'],'文件名')
        self.assertEqual(len(result['files'][0]['companions']),1)

    def test_transfer_repeat_sidecar_manifest_and_time(self):
        rel=self.media(); side=self.media('DCIM/DJI_20261023_091800_001.SRT',b'caption')
        first=self.transfer([rel]); second=self.transfer([rel])
        self.assertEqual(len(first['files']),2)
        self.assertTrue(all(row['status']=='skipped' for row in second['files']))
        target=Path(first['files'][0]['target'])
        self.assertEqual(target.read_bytes(),(self.source/rel).read_bytes())
        self.assertIn('2026-10-23/09-18',str(target))
        self.assertEqual(target.stat().st_mtime_ns,(self.source/rel).stat().st_mtime_ns)
        self.assertEqual(len(json.loads(Path(first['manifest']).read_text())),2)
        self.assertTrue((self.source/side).exists())

    def test_different_content_same_name_and_missing_target(self):
        rel=self.media(); one=self.transfer([rel])['files'][0]
        (self.source/rel).write_bytes(b'changed-source')
        two=self.transfer([rel])['files'][0]
        self.assertNotEqual(one['target'],two['target'])
        Path(two['target']).unlink()
        self.assertIsNone(self.engine.scan(self.source)['files'][0]['macPath'])
        self.assertEqual(self.transfer([rel])['files'][0]['status'],'verified')

    def test_different_name_same_content(self):
        a=self.media(); self.transfer([a]); b=self.media('DCIM/renamed.MOV')
        result=self.transfer([b])
        self.assertEqual(result['files'][0]['status'],'skipped')

    def test_resume_after_pause_validates_prefix(self):
        rel=self.media(content=os.urandom(MODULE.CHUNK*2+5))
        stopped=threading.Event()
        def emit(e):
            self.events.append(e)
            if e['event']=='progress': stopped.set()
        self.engine.stop=stopped; self.engine.emit=emit
        with self.assertRaises(MODULE.Stopped): self.transfer([rel])
        part=next(self.dest.rglob('*.traildrop-part'))
        self.assertEqual(part.stat().st_size,MODULE.CHUNK)
        self.engine.stop=threading.Event(); self.engine.emit=self.events.append
        result=self.transfer([rel])
        self.assertEqual(next(e for e in reversed(self.events) if e['event']=='file' and e['status']=='复制中')['offset'],MODULE.CHUNK)
        self.assertEqual(Path(result['files'][0]['target']).read_bytes(),(self.source/rel).read_bytes())

    def test_corrupt_partial_restarts_from_zero(self):
        rel=self.media(content=os.urandom(MODULE.CHUNK+10))
        def pause(e):
            if e['event']=='progress': self.engine.stop.set()
        self.engine.emit=pause
        with self.assertRaises(MODULE.Stopped): self.transfer([rel])
        part=next(self.dest.rglob('*.traildrop-part')); part.write_bytes(b'bad-prefix')
        self.engine.stop.clear(); self.engine.emit=self.events.append
        self.transfer([rel])
        self.assertEqual(next(e for e in self.events if e['event']=='file' and e['status']=='复制中')['offset'],0)

    def test_corrupt_destination_is_not_safe_to_delete(self):
        rel=self.media(); target=Path(self.transfer([rel])['files'][0]['target']); target.write_bytes(b'corrupt-copy!!')
        result=self.engine.delete(self.source,[rel])
        self.assertFalse(result['deleted']); self.assertTrue(result['failed']); self.assertTrue((self.source/rel).exists())

    def test_safe_delete_requires_all_companions(self):
        rel=self.media(); self.transfer([rel]); self.media('DCIM/DJI_20261023_091800_001.SRT',b'new-caption')
        result=self.engine.delete(self.source,[rel]); self.assertFalse(result['deleted'])
        self.transfer([rel]); result=self.engine.delete(self.source,[rel]); self.assertEqual(result['deleted'],[rel])
        self.assertFalse((self.source/rel).exists())

    def test_force_delete_requires_exact_second_confirmation(self):
        rel=self.media()
        with self.assertRaises(ValueError): self.engine.delete(self.source,[rel],True,'yes')
        self.assertTrue((self.source/rel).exists())
        self.assertEqual(self.engine.delete(self.source,[rel],True,'删除未备份素材')['deleted'],[rel])
        self.assertGreater(self.engine.db.execute('SELECT COUNT(*) FROM audit').fetchone()[0],0)

    def test_path_escape_symlink_and_overlapping_destination(self):
        outside=self.base/'outside.MP4'; outside.write_bytes(b'private')
        (self.source/'link.MP4').symlink_to(outside)
        for rel in ['../outside.MP4','link.MP4',str(outside)]:
            with self.assertRaises(ValueError): self.transfer([rel])
        rel=self.media()
        with self.assertRaises(ValueError): self.engine.transfer(self.source,self.source,[rel])

    def test_changed_after_scan_is_not_deleted_even_forced(self):
        rel=self.media(); f=self.engine.scan(self.source)['files'][0]
        expected={rel:{'size':f['size'],'mtime':f['mtime']}}
        (self.source/rel).write_bytes(b'new recording')
        result=self.engine.delete(self.source,[rel],True,'删除未备份素材',expected)
        self.assertFalse(result['deleted']); self.assertTrue((self.source/rel).exists())
        with self.assertRaises(ValueError): self.engine.transfer(self.source,self.dest,[rel],expected)

    def test_source_changes_during_copy_retained(self):
        rel=self.media(content=b'video'*100)
        def mutate(e):
            if e['event']=='progress': (self.source/rel).write_bytes(b'changed-during-copy')
        self.engine.emit=mutate
        with self.assertRaises(ValueError): self.transfer([rel])
        self.assertTrue((self.source/rel).exists())
        self.assertFalse(list(self.dest.rglob('*.MP4')))

    def test_cli_scan_json_protocol(self):
        self.media()
        result=subprocess.run([sys.executable,str(Path(__file__).parents[1]/'Core/engine.py')],input=json.dumps(dict(action='scan',source=str(self.source),stateDir=str(self.state)))+'\n',text=True,capture_output=True,check=True)
        event=json.loads(result.stdout.strip()); self.assertEqual(event['event'],'result'); self.assertEqual(len(event['result']['files']),1)

    def test_fresh_target_index_is_scoped_by_destination_for_copy(self):
        rel=self.media(); self.transfer([rel]); other=self.base/'other'; other.mkdir()
        result=self.engine.transfer(self.source,other,[rel])
        self.assertEqual(result['files'][0]['status'],'verified')
        self.assertTrue(Path(result['files'][0]['target']).resolve().is_relative_to(other.resolve()))

    def test_insta_lens_pair_and_proxy_remain_a_group(self):
        a=self.media('DCIM/VID_20261023_091800_00_001.insv',b'lens-a')
        b=self.media('DCIM/VID_20261023_091800_10_001.insv',b'lens-b')
        c=self.media('DCIM/LRV_20261023_091800_11_001.lrv',b'proxy')
        self.assertEqual(len(self.engine.scan(self.source)['files'][0]['companions']),2)
        result=self.transfer([a]); self.assertEqual(len(result['files']),3)
        deleted=self.engine.delete(self.source,[a,b])
        self.assertEqual(set(deleted['deleted']),{a,b}); self.assertFalse(deleted['failed'])
        self.assertFalse((self.source/c).exists())

    def test_completed_duplicates_skip_even_when_disk_full(self):
        from unittest.mock import patch
        from collections import namedtuple
        rel=self.media(); self.transfer([rel])
        usage=namedtuple('usage','total used free')(100,100,0)
        with patch('shutil.disk_usage',return_value=usage):
            self.assertEqual(self.transfer([rel])['files'][0]['status'],'skipped')

    def test_not_enough_space_preserves_original(self):
        from unittest.mock import patch
        from collections import namedtuple
        rel=self.media()
        usage=namedtuple('usage','total used free')(100,100,0)
        with patch('shutil.disk_usage',return_value=usage):
            with self.assertRaisesRegex(ValueError,'空间不足'): self.transfer([rel])
        self.assertTrue((self.source/rel).exists())

    def test_resume_survives_engine_restart(self):
        rel=self.media(content=os.urandom(MODULE.CHUNK+100))
        def pause(e):
            if e['event']=='progress': self.engine.stop.set()
        self.engine.emit=pause
        with self.assertRaises(MODULE.Stopped): self.transfer([rel])
        self.engine.db.close()
        self.engine=MODULE.Engine(self.state,self.events.append)
        self.transfer([rel])
        resumed=next(e for e in self.events if e['event']=='file' and e['status']=='复制中')
        self.assertEqual(resumed['offset'],MODULE.CHUNK)

    def test_source_token_detects_directory_replacement(self):
        self.media()
        token=self.engine.scan(self.source)['sourceToken']
        MODULE.Engine.check_source(dict(source=self.source,sourceToken=token))
        self.source.rename(self.base/'old-camera'); self.source.mkdir()
        with self.assertRaisesRegex(ValueError,'来源已变化'):
            MODULE.Engine.check_source(dict(source=self.source,sourceToken=token))

    def test_cli_transfer_then_safe_cleanup(self):
        rel=self.media()
        scan=self.engine.scan(self.source)
        f=scan['files'][0]
        request=dict(source=str(self.source),stateDir=str(self.state),sourceToken=scan['sourceToken'],
                     selected=[rel],expected={rel:dict(size=f['size'],mtime=f['mtime'])})
        def cli(action,**extra):
            payload=dict(request,action=action,**extra)
            proc=subprocess.run([sys.executable,str(Path(__file__).parents[1]/'Core/engine.py')],input=json.dumps(payload)+'\n',text=True,capture_output=True,check=True)
            return [json.loads(line) for line in proc.stdout.splitlines()][-1]['result']
        transferred=cli('transfer',destination=str(self.dest))
        self.assertEqual(transferred['files'][0]['status'],'verified')
        removed=cli('delete',force=False)
        self.assertEqual(removed['deleted'],[rel])
        self.assertTrue(Path(transferred['files'][0]['target']).exists())


if __name__=='__main__': unittest.main(verbosity=2)
