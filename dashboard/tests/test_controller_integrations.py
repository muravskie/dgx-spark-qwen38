"""The upgraded cockpit preserves controller ownership and remote OpenCode."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import pagejs

DASH = Path(__file__).parents[1]
sys.path.insert(0, str(DASH))


class ControllerPage(unittest.TestCase):
    def test_managed_qwen_has_no_legacy_load_or_checkpoint_controls(self):
        result = pagejs.run(self, """
const wrap = o => Object.fromEntries(Object.entries(o).map(([k,v]) => [k,{data:v,ts:Date.now()/1000}]));
apply(wrap({config:{version:'1.22.6',repo_dir:'/repo',periods:{}},
 units:{units:{[U27]:{active:'active',enabled:'enabled',manager:'spark-model-controller'}}},
 lifecycle:{engines:{[U27]:{state:'ready',target:'stock'}},events:[],blocked:{}}}));
const c=LCARDS.get(U27);
report({load:c.load.hidden,select:c.tsel.hidden,stop:c.stop.hidden,update:$('st-update').textContent});
""")
        self.assertTrue(result['load'])
        self.assertTrue(result['select'])
        self.assertFalse(result['stop'])
        self.assertEqual(result['update'], 'cd /repo && ./dashboard/install-dashboard.sh')

    def test_remote_agent_does_not_offer_local_restart_fit_or_journal(self):
        result = pagejs.run(self, """
const d={enabled:true,remote:true,unit_installed:true,relay:{listening:true,port:30091,bind:'localhost'},server:{healthy:true,version:'2.0'}};
apply({agent:{data:d,ts:Date.now()/1000}});
report({restart:$('ag-restart').hidden,fit:$('oc-fitbtn').hidden,logs:$('log-opt-agent').hidden,line:$('ag-line').textContent});
""")
        self.assertTrue(result['restart'])
        self.assertTrue(result['fit'])
        self.assertTrue(result['logs'])
        self.assertIn('Uba', result['line'])

    def test_image_worker_and_throughput_survive_frontend_rebuild(self):
        result = pagejs.run(self, """
apply({image_lab:{data:{controller:{runtime:'running',ownership:'managed',healthy:true,roles:['image-generation','image-edit']},queue:{running:1,pending:2,running_model:'Qwen Image Edit'},history:{successful:3,failed:0,sample_size:3}},ts:Date.now()/1000},
throughput:{data:{current:{generation:42,prefill_compute:100},recent_median:{generation:40},sample_count:3},ts:Date.now()/1000}});
report({worker:$('image-lane-chip').textContent,model:$('image-model').textContent,pending:$('image-pending').textContent,rate:$('genrate').textContent});
""")
        self.assertEqual(result, {'worker':'API ready','model':'Qwen Image Edit','pending':'2','rate':'42.0 tok/s'})


class ControllerBackend(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        with patch.dict(os.environ, {'COCKPIT_CONFIG_DIR':self.tmp.name, 'COCKPIT_DRY_RUN':'1','COCKPIT_AGENT_REMOTE':'1'}):
            spec = importlib.util.spec_from_file_location('controller_integration_test', DASH/'cockpit.py')
            self.cp = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.cp)

    def tearDown(self):
        self.tmp.cleanup()

    def test_handoff_marker_blocks_legacy_actions_even_when_controller_is_down(self):
        Path(self.tmp.name,'controller-managed').touch()
        self.cp.controller_27b = lambda: None
        self.assertTrue(self.cp.controller_manages_27b())
        for name, params in [('switch',{'target':'stock'}), ('unit',{'unit':'qwen38-image.service','verb':'start'}),('unit',{'unit':'qwen38-video.service','verb':'start'})]:
            with self.subTest(action=name,params=params):
                code, _ = self.cp.start_action(name,params)
                self.assertEqual(code,409)

    def test_remote_limits_are_not_modified_and_remote_unit_is_not_controllable(self):
        self.assertEqual(self.cp.start_action('fit_opencode',{})[0],409)
        self.assertEqual(self.cp.start_action('unit',{'unit':self.cp.AGENT_UNIT,'verb':'restart'})[0],400)

    def test_qwen_restart_uses_controller_and_never_systemctl(self):
        self.cp.controller_27b = lambda: {'ownership':'managed'}
        calls=[]
        self.cp.controller_request = lambda method,path,**kw: (calls.append((method,path)) or (200,{'status':'active'}))
        with patch.object(self.cp.subprocess,'run',side_effect=AssertionError('legacy lifecycle call')):
            job=type('Job',(),{'params':{'unit':'qwen38-sglang.service','verb':'restart'}})()
            ok,_,_=self.cp.job_unit(job)
        self.assertTrue(ok)
        self.assertEqual(calls,[('POST','/v1/models/qwen3.8-27b/deactivate'),('POST','/v1/models/qwen3.8-27b/activate')])

    def test_stopped_engine_telemetry_is_unavailable_without_old_rates(self):
        self.cp.HEALTH["ok"] = False
        self.cp.THROUGHPUT["recent"].append({"generation": 42.0})
        with patch.object(self.cp, "http_text", side_effect=OSError("stopped")), patch.object(self.cp, "engine_server_info", side_effect=OSError("stopped")):
            rates = self.cp.collect_throughput()
            info = self.cp.collect_engine_info()
        self.assertFalse(rates["available"])
        self.assertEqual(rates["recent_median"], {})
        self.assertEqual(list(self.cp.THROUGHPUT["recent"]), [])
        self.assertEqual(info["info"], {})
        self.assertNotIn("error", rates)
        self.assertNotIn("error", info)

    def test_legacy_cli_guard_is_persistent_and_preserves_standalone_mode(self):
        guard=DASH.parent/'controller-ownership.py'
        env=dict(os.environ,CONFIG_DIR=self.tmp.name)
        self.assertEqual(subprocess.run([sys.executable,str(guard)],env=env,capture_output=True).returncode,0)
        Path(self.tmp.name,'controller-managed').touch()
        result=subprocess.run([sys.executable,str(guard)],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,1)
        self.assertIn('spark-model-controller',result.stderr)
