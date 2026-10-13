import argparse,json,os,pathlib,subprocess,time,urllib.request
p=argparse.ArgumentParser();p.add_argument('--layers',type=int,default=16);p.add_argument('--force',type=int,choices=[0,1],default=0);p.add_argument('--reserve',action='store_true');p.add_argument('--reps',default='60,300');p.add_argument('--ub',default='256');p.add_argument('--no-graphs',action='store_true');p.add_argument('--reserve-count',type=int,default=4);p.add_argument('--runtime',type=pathlib.Path,default=pathlib.Path.home()/'.local/share/qwen-local-coder/research/llama.cpp/build/bin');p.add_argument('--model',type=pathlib.Path,default=pathlib.Path.home()/'models/Qwen3.8-27B-UD-IQ1_M.gguf');p.add_argument('--out',type=pathlib.Path,default=pathlib.Path('split-kv-results'));a=p.parse_args()
D=a.runtime.resolve()
label=f'host{a.layers}-gpu{a.force}-reserve{int(a.reserve)}-ub{a.ub}-ng{int(a.no_graphs)}-envfixed-ff{a.reserve_count}';root=a.out;root.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,LD_LIBRARY_PATH=str(D),QLC_HOST_KV_LAYERS=str(a.layers),QLC_KV_ATTN_GPU=str(a.force))
if a.reserve:env.pop('GGML_CUDA_ENABLE_UNIFIED_MEMORY',None)
else:env['GGML_CUDA_ENABLE_UNIFIED_MEMORY']='1'
if a.no_graphs:env['GGML_CUDA_DISABLE_GRAPHS']='1'
cmd=[str(D/'llama-server'),'-m',str(a.model.resolve()),'--host','127.0.0.1','--port','8094','-ngl','99','-c','32768','-np','1','-fa','on','-ctk','q8_0','-ctv','q8_0','-ub',a.ub,'-t','6','--jinja','--ctx-checkpoints','0','--cache-ram','0','-lv','4']
if a.reserve:cmd+=['-ot',r'output.weight|blk\.('+ '|'.join(map(str,range(a.reserve_count))) +r')\.ffn_(up|down|gate)\.weight=CPU']
log=open(root/(label+'.log'),'w');proc=subprocess.Popen(cmd,env=env,stdout=log,stderr=log)
try:
 for _ in range(90):
  if proc.poll() is not None:raise RuntimeError('server exited')
  try:urllib.request.urlopen('http://127.0.0.1:8094/health',timeout=1);break
  except Exception:time.sleep(1)
 else:raise RuntimeError('startup timeout')
 filler="def handler(event, ctx):\n    data = json.loads(event['body'])\n    return {'status': 200, 'id': data.get('id')}\n\n"
 for rep in map(int,a.reps.split(',')):
  body={'messages':[{'role':'user','content':filler*rep+'Explain what handler returns in two sentences.'}],'max_tokens':32,'temperature':0,'cache_prompt':False,'chat_template_kwargs':{'enable_thinking':False}}
  req=urllib.request.Request('http://127.0.0.1:8094/v1/chat/completions',json.dumps(body).encode(),{'Content-Type':'application/json'})
  t=time.monotonic();res=json.load(urllib.request.urlopen(req,timeout=180));print(json.dumps({'label':label,'rep':rep,'wall_s':time.monotonic()-t,'timings':res.get('timings'),'message':res['choices'][0]['message']}),flush=True)
except Exception as e:print(json.dumps({'label':label,'error':str(e)}),flush=True)
finally:
 proc.terminate()
 try:proc.wait(timeout=15)
 except subprocess.TimeoutExpired:proc.kill();proc.wait()
 log.close()
