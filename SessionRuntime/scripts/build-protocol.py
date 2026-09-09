#!/usr/bin/env python3
"""Authoritative protocol definitions; emit reviewable schema/catalog artifacts."""
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ID = {'type':'string','pattern':r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'}
U64 = {'type':'integer','minimum':0,'maximum':18446744073709551615}
TEXT = {'type':'string','maxLength':4096}
SHORT = {'type':'string','minLength':1,'maxLength':128}
PATH = {'type':'string','minLength':1,'maxLength':4096,'pattern':r'^/[^\x00]*$'}
BOOL = {'type':'boolean'}

def ref(name): return {'$ref':'#/$defs/'+name}
def enum(*values): return {'enum':list(values)}
def array(item, maximum=1024, minimum=0): return {'type':'array','items':item,'maxItems':maximum,'minItems':minimum}
def obj(required=None, optional=None):
    required, optional = required or {}, optional or {}
    return {'type':'object','properties':required|optional,'required':list(required),'additionalProperties':False}
def integer(low=0, high=65535): return {'type':'integer','minimum':low,'maximum':high}

D = {
 'id':ID, 'u64':U64, 'path':PATH,
 'geometry':obj({'rows':integer(1),'columns':integer(1)}, {'pixelWidth':integer(),'pixelHeight':integer()}),
 'target':obj({'serverID':ID,'serverEpoch':ID,'sessionID':ID}),
 'lease':obj({'leaseID':ID,'leaseEpoch':U64}),
 'terminalSpec':obj({'cwd':PATH,'argv':array({'type':'string','maxLength':4096},128,1)},
                    {'environment':{'type':'object','maxProperties':128,'additionalProperties':{'type':'string','maxLength':8192}},'geometry':ref('geometry')}),
 'terminal':obj({'terminalID':ID,'cwd':PATH,'state':enum('running','terminating','exited','unavailable')},
                {'pid':integer(1,4294967295),'exitCode':integer(-2147483648,2147483647),'signal':integer(1,128),'title':TEXT,'geometry':ref('geometry')}),
 'session':obj({'sessionID':ID,'name':SHORT,'state':enum('running','stopped','attention')}, {'serverID':ID,'serverEpoch':ID}),
 'pane':obj({'paneID':ID,'terminalID':ID}, {'title':TEXT}),
 'tab':obj({'tabID':ID,'title':TEXT,'layout':ref('layout16')}),
 'workspace':obj({'workspaceID':ID,'title':TEXT,'cwd':PATH,'tabs':array(ref('tab'),128)}),
 'settings':obj({}, {'paneHistory':BOOL,'resumeAgentsOnRestore':BOOL,'historyBytes':integer(0,268435456)}),
 'agent':obj({'terminalID':ID,'provider':SHORT,'state':enum('idle','working','blocked','done','unknown')},
             {'name':SHORT,'nativeSession':TEXT,'source':SHORT,'unread':BOOL}),
 'upload':obj({'uploadID':ID,'maximumBytes':integer(1,20971520),'receivedBytes':integer(0,20971520)}),
 'attachment':obj({'attachmentID':ID,'terminalID':ID,'readOnly':BOOL}, {'lease':ref('lease')}),
 'error':obj({'code':{'type':'string','pattern':'^[a-z][a-z0-9_]{0,63}$'},'message':TEXT,
              'retry':enum('never','after_query','after_reconnect','backoff')}),
}
D['writeAttachment'] = obj({'attachmentID':ID,'terminalID':ID,'readOnly':enum(False),'lease':ref('lease')})
D['readAttachment'] = obj({'attachmentID':ID,'terminalID':ID,'readOnly':enum(True),'currentLeaseEpoch':U64})
D['layout0'] = obj({'kind':enum('leaf'),'pane':ref('pane')})
for depth in range(1,17):
    D['layout'+str(depth)] = {'oneOf':[ref('layout0'), obj({'kind':enum('split'),'axis':enum('horizontal','vertical'),
        'ratio':{'type':'number','exclusiveMinimum':0,'exclusiveMaximum':1},
        'first':ref('layout'+str(depth-1)),'second':ref('layout'+str(depth-1))})]}

DURABLE = set("session.create session.stop session.delete workspace.create workspace.update workspace.close tab.create tab.update tab.close pane.split pane.update pane.close terminal.create terminal.terminate".split())
OPS = []
def op(name, scope, capability, phase, mutation, params, result, errors=(), lease=False, sequence=False):
    OPS.append(dict(name=name,scope=scope,capability=capability,phase=phase,mutation=mutation,
                    params=params,result=result,errors=list(errors),lease=lease,controlSequence=sequence,durable=name in DURABLE))

op('health.check','session','health_check','P1','read',obj(),obj({'alive':enum(True)}))
op('session.list','registry',None,'P4','read',obj(),obj({'sessions':array(ref('session'))}))
op('session.create','registry',None,'P4','create',obj({'name':SHORT}),ref('session'),('session_exists',))
op('session.attach','registry',None,'P4','read',obj({'sessionID':ID}),ref('session'),('session_not_found',))
op('session.stop','registry',None,'P4','mutation',obj({'sessionID':ID}),ref('session'),('session_not_found',))
op('session.delete','registry',None,'P4','mutation',obj({'sessionID':ID}),obj({'deleted':BOOL}),('session_running',))
op('session.snapshot','session','session_snapshot','P1','read',obj(),obj({'workspaces':array(ref('workspace')),'terminals':array(ref('terminal'))}))
op('session.settings.get','session','session_settings','P6','read',obj(),ref('settings'))
op('session.settings.update','session','session_settings','P6','structure',ref('settings'),ref('settings'))
op('workspace.list','session','session_snapshot','P4','read',obj(),obj({'workspaces':array(ref('workspace'))}))
op('workspace.create','session','workspace_mutation','P4','structure',obj({'title':SHORT,'terminal':ref('terminalSpec')}),ref('workspace'))
op('workspace.update','session','workspace_mutation','P4','structure',obj({'workspaceID':ID},{'title':SHORT}),ref('workspace'),('workspace_not_found',))
op('workspace.close','session','workspace_mutation','P4','structure',obj({'workspaceID':ID}),obj({'closed':BOOL}),('workspace_not_found',))
op('tab.create','session','workspace_mutation','P4','structure',obj({'workspaceID':ID,'title':SHORT,'terminal':ref('terminalSpec')}),ref('tab'))
op('tab.update','session','workspace_mutation','P4','structure',obj({'tabID':ID},{'title':SHORT,'layout':ref('layout16')}),ref('tab'),('tab_not_found',))
op('tab.close','session','workspace_mutation','P4','structure',obj({'tabID':ID}),obj({'closed':BOOL}),('tab_not_found',))
op('pane.split','session','workspace_mutation','P4','structure',obj({'paneID':ID,'direction':enum('left','right','up','down'),'terminal':ref('terminalSpec')}),obj({'pane':ref('pane'),'terminal':ref('terminal')}))
op('pane.update','session','workspace_mutation','P4','structure',obj({'paneID':ID,'title':TEXT}),ref('pane'))
op('pane.close','session','workspace_mutation','P4','structure',obj({'paneID':ID}),obj({'closed':BOOL}))
op('terminal.create','session','terminal_control','P1','create',ref('terminalSpec'),ref('terminal'),('cwd_unavailable','executable_unavailable','outcome_unknown'))
op('terminal.list','session','terminal_control','P1','read',obj(),obj({'terminals':array(ref('terminal'))}))
op('terminal.attach','session','terminal_control','P1','mutation',dict(obj({'terminalID':ID},{'takeover':BOOL,'expectedLeaseEpoch':U64}), allOf=[{'if':{'properties':{'takeover':{'const':True}},'required':['takeover']},'then':{'required':['expectedLeaseEpoch']}}]),ref('writeAttachment'),('terminal_not_found','lease_busy','lease_lost'))
op('terminal.observe','session','terminal_observe','P1','read',obj({'terminalID':ID}),ref('readAttachment'),('terminal_not_found',))
control = {'oneOf':[
 obj({'terminalID':ID,'action':enum('input'),'data':{'type':'string','maxLength':87384,'contentEncoding':'base64'}}),
 obj({'terminalID':ID,'action':enum('resize'),'geometry':ref('geometry')}),
 obj({'terminalID':ID,'action':enum('scroll'),'rows':integer(-2147483648,2147483647)}),
]}
op('terminal.control','session','terminal_control','P1','input',control,obj({'accepted':BOOL}),('lease_lost','terminal_exited','delivery_unknown'),lease=True,sequence=True)
op('terminal.release','session','terminal_control','P1','mutation',obj({'attachmentID':ID}),obj({'released':BOOL}))
op('terminal.terminate','session','terminal_control','P1','mutation',obj({'terminalID':ID}),ref('terminal'),('terminal_not_found',))
op('surface.subscribe','session','surface_interest','P1','read',obj({'attachmentID':ID,'geometry':ref('geometry')}),obj({'streamID':ID,'terminalID':ID}))
op('surface.unsubscribe','session','surface_interest','P1','read',obj({'streamID':ID}),obj({'unsubscribed':BOOL}))
op('surface.snapshot','session','surface_interest','P1','read',obj({'streamID':ID}),obj({'scheduled':BOOL}))
op('agent.list','session','agent_state','P5','read',obj(),obj({'agents':array(ref('agent'))}))
op('agent.report','session','agent_state','P5','mutation',ref('agent'),obj({'accepted':BOOL}),('provider_mismatch','stale_agent_instance'))
op('agent.explain','session','agent_state','P5','read',obj({'terminalID':ID}),obj({'agent':ref('agent'),'reason':TEXT}))
op('agent.rename','session','agent_state','P5','mutation',obj({'terminalID':ID},{'name':SHORT}),ref('agent'))
op('agent.acknowledge','session','agent_state','P5','mutation',obj({'terminalID':ID}),obj({'acknowledged':BOOL}))
op('upload.begin','session','image_upload','P7','create',obj({'mimeType':enum('image/png','image/jpeg','image/webp'),'length':integer(1,20971520),'sha256':{'type':'string','pattern':'^[0-9a-f]{64}$'}}),ref('upload'))
op('upload.chunk','session','image_upload','P7','mutation',obj({'uploadID':ID,'offset':integer(0,20971520),'data':{'type':'string','maxLength':349528,'contentEncoding':'base64'}}),ref('upload'),('upload_offset_mismatch',))
op('upload.commit','session','image_upload','P7','mutation',obj({'uploadID':ID}),obj({'path':PATH,'expiresAt':SHORT}),('upload_incomplete','checksum_mismatch'))
op('upload.abort','session','image_upload','P7','mutation',obj({'uploadID':ID}),obj({'aborted':BOOL}))
op('upload.clear','session','image_upload','P7','mutation',obj(),obj({'removedCount':integer(0,100000)}))
op('config.get','session','server_config','P7','read',obj(),obj({'keybindings':array(obj({'key':SHORT,'action':SHORT})),'settings':ref('settings')}))
op('config.reload','session','server_config','P7','mutation',obj(),obj({'reloaded':BOOL}),('configuration_invalid',))
op('custom_command.list','session','custom_commands','P7','read',obj(),obj({'commands':array(obj({'commandID':ID,'label':SHORT}))}))
op('custom_command.run','session','custom_commands','P7','create',obj({'commandID':ID,'cwd':PATH}),ref('terminal'),('command_not_found',))
op('integration.list','session','agent_integration','P5','read',obj(),obj({'integrations':array(obj({'provider':SHORT,'installed':BOOL,'version':SHORT}))}))
op('integration.install','session','agent_integration','P5','mutation',obj({'provider':SHORT}),obj({'installed':BOOL}),('provider_unsupported',))
op('integration.remove','session','agent_integration','P5','mutation',obj({'provider':SHORT}),obj({'removed':BOOL}))
op('server.prepare','bootstrap',None,'P3','create',obj({'sessionName':SHORT,'allowStart':BOOL,'requiredCapabilities':array(SHORT,128)}),obj({'session':ref('session'),'protocolMajor':integer(),'protocolMinor':integer(),'capabilities':array(SHORT,128)}),('setup_required','incompatible_protocol'))
op('server.status','session','health_check','P1','read',obj(),obj({'version':SHORT,'protocolMajor':integer(),'protocolMinor':integer(),'capabilities':array(SHORT,128)}))
op('server.stop','session','server_lifecycle','P1','mutation',obj(),obj({'stopping':enum(True)}))
op('server.replace','session','server_replace','P8','mutation',obj({'installedVersion':SHORT,'expectedServerEpoch':ID,'stopRunningTerminals':BOOL}),obj({'operationID':ID,'state':enum('prepared','replacing','completed')}),('replacement_not_authorized','version_unavailable'))
op('server.handoff','session','live_handoff','P8','mutation',obj({'installedVersion':SHORT,'expectedServerEpoch':ID}),obj({'operationID':ID,'state':enum('prepared','transferring','committed','rolled_back')}),('handoff_unsupported','handoff_failed'))

op('request.status','session','terminal_control','P1','read',obj({'queriedRequestID':ID}),obj({'queriedRequestID':ID,'operation':SHORT,'state':enum('pending','committed','failed','unknown','expired'),'resourceIDs':array(ID,64)},{'resourcesInvalidated':BOOL}))
op('upload.status','session','image_upload','P7','read',obj({'uploadID':ID}),ref('upload'),('upload_not_found',))
op('server.operation_status','registry',None,'P8','read',obj({'operationID':ID}),obj({'operationID':ID,'sessionID':ID,'state':enum('prepared','transferring','committed','rolled_back','failed')},{'serverID':ID,'serverEpoch':ID,'error':ref('error')}),('operation_not_found',))

COMMON_ERRORS = ['invalid_request','wrong_scope','unsupported_operation','missing_capability','permission_denied',
 'stale_server_epoch','service_stopping','revision_conflict','resource_limit','request_expired','outcome_unknown','internal_error']

def request(operation):
    required = {'type':enum('request'),'requestID':ID,'clientID':ID,'scope':enum(operation['scope']),
                'operation':enum(operation['name']),'params':operation['params']}
    if operation['scope'] == 'session': required['target'] = ref('target')
    if operation['mutation'] == 'structure': required['expectedRevision'] = U64
    if operation['durable']: required['createdAtUnixMs'] = U64
    if operation['lease']: required['lease'] = ref('lease')
    if operation['controlSequence']: required['controlSequence'] = U64
    return obj(required, {'extensions':{'type':'object','maxProperties':32,'additionalProperties':TEXT}})

def response(operation):
    required = {'type':enum('response'),'requestID':ID,'operation':enum(operation['name']),
                'scope':enum(operation['scope']),'result':operation['result']}
    if operation['scope'] == 'session': required |= {'target':ref('target'),'revision':U64}
    return obj(required)

def artifacts():
    error = obj({'type':enum('error'),'requestID':ID,'operation':SHORT,'scope':enum('session','registry','bootstrap'),'error':ref('error')}, {'target':ref('target')})
    schema = {'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:aster:session:operations:1',
              'title':'Aster operation protocol v1','$defs':D,'oneOf':[request(x) for x in OPS]+[response(x) for x in OPS]+[error]}
    catalog = {'protocolMajor':1,'commonErrors':COMMON_ERRORS,'operations':OPS,
               'semanticLimits':{'maximumPanes':64,'maximumLayoutDepth':16,'maximumInputBytes':65536,
                                 'maximumImageBytes':20971520,'maximumImageChunkBytes':262144}}
    lines = ['# 操作目录 v1','','由 `scripts/build-protocol.py` 生成。schema 定义请求/结果结构；实际操作按所属阶段实现，目录存在不代表服务已支持。',
             '', '| 操作 | 范围 | 能力 | 阶段 | 类别 |', '| --- | --- | --- | --- | --- |']
    lines += [f"| `{o['name']}` | {o['scope']} | {o['capability'] or '进程入口校验'} | {o['phase']} | {o['mutation']} |" for o in OPS]
    return {'protocol/operations.schema.json':json.dumps(schema,ensure_ascii=False,indent=2)+'\n',
            'protocol/operations.json':json.dumps(catalog,ensure_ascii=False,indent=2)+'\n',
            'protocol/operations.md':'\n'.join(lines)+'\n', **generated_types(), **fixtures(), **event_artifacts(), **reply_fixtures()}

def sample(schema):
    if '$ref' in schema: return sample(D[schema['$ref'].split('/')[-1]])
    if 'oneOf' in schema: return sample(schema['oneOf'][0])
    if 'enum' in schema: return schema['enum'][0]
    kind=schema['type']
    if kind=='object': return {key:sample(schema['properties'][key]) for key in schema.get('required',[])}
    if kind=='array': return [sample(schema['items']) for _ in range(schema.get('minItems',0))]
    if kind=='boolean': return False
    if kind=='integer': return max(0,schema.get('minimum',0))
    if kind=='number': return 0.5
    if schema.get('contentEncoding')=='base64': return 'YQ=='
    pattern=schema.get('pattern','')
    if pattern==ID['pattern']: return '12345678-1234-1234-1234-123456789abc'
    if pattern==PATH['pattern']: return '/tmp/aster-protocol'
    if pattern=='^[0-9a-f]{64}$': return '0'*64
    return 'sample'

def fixtures():
    values=[]; envelopes=[]
    for o in OPS:
        value=sample(request(o))
        values.append({'name':o['name']+' request','valid':True,'value':value})
        envelopes.append({'name':o['name'],'result':'ok','value':value})
        values.append({'name':o['name']+' response','valid':True,'value':sample(response(o))})
        broken=json.loads(json.dumps(value)); del broken['requestID']
        values.append({'name':o['name']+' missing requestID','valid':False,'value':broken})
    def bad(name, op_name, mutate, result):
        value=sample(request(next(o for o in OPS if o['name']==op_name)))
        mutate(value)
        envelopes.append({'name':name,'result':result,'value':value})
        values.append({'name':name,'valid':False,'value':value})
    bad('invalid ID','terminal.list',lambda v:v.update(requestID='bad'),'invalidIdentity')
    bad('wrong scope','terminal.list',lambda v:v.update(scope='registry'),'wrongScope')
    bad('missing target','terminal.list',lambda v:v.pop('target'),'invalidTarget')
    bad('missing durable timestamp','terminal.create',lambda v:v.pop('createdAtUnixMs'),'invalidPreconditions')
    bad('timestamp on read','terminal.list',lambda v:v.update(createdAtUnixMs=1),'invalidPreconditions')
    bad('takeover missing epoch','terminal.attach',lambda v:v['params'].update(takeover=True),'invalidPreconditions')
    value=sample(request(next(o for o in OPS if o['name']=='terminal.attach')))
    value['params'].update(takeover=True,expectedLeaseEpoch=18446744073709551615)
    values.append({'name':'takeover maximum epoch','valid':True,'value':value})
    envelopes.append({'name':'takeover maximum epoch','result':'ok','value':value})
    value=sample(request(next(o for o in OPS if o['name']=='terminal.create')))
    value['createdAtUnixMs']=18446744073709551615
    values.append({'name':'maximum creation timestamp','valid':True,'value':value})
    envelopes.append({'name':'maximum creation timestamp','result':'ok','value':value})
    bad('missing revision','workspace.create',lambda v:v.pop('expectedRevision'),'invalidPreconditions')
    bad('missing lease','terminal.control',lambda v:v.pop('lease'),'invalidPreconditions')
    bad('missing control sequence','terminal.control',lambda v:v.pop('controlSequence'),'invalidPreconditions')
    bad('params not object','terminal.list',lambda v:v.update(params=[]),'invalidParameters')
    value=sample(request(next(o for o in OPS if o['name']=='terminal.control')))
    value['lease']['leaseEpoch']=18446744073709551615
    value['controlSequence']=18446744073709551615
    envelopes.append({'name':'maximum counters','result':'ok','value':value})
    values.append({'name':'maximum counters','valid':True,'value':value})
    error={'type':'error','requestID':sample(ID),'operation':'terminal.create','scope':'session',
           'error':{'code':'cwd_unavailable','message':'Remote directory is unavailable','retry':'never'}}
    values.append({'name':'error response','valid':True,'value':error})
    wrong=json.loads(json.dumps(error));wrong['error']['retry']='automatically_execute'
    values.append({'name':'invalid error retry','valid':False,'value':wrong})
    attachment=sample(response(next(o for o in OPS if o['name']=='terminal.attach')))
    del attachment['result']['lease']
    values.append({'name':'write attachment missing lease','valid':False,'value':attachment})
    observation=sample(response(next(o for o in OPS if o['name']=='terminal.observe')))
    for epoch in (0, 18446744073709551615):
        item=json.loads(json.dumps(observation));item['result']['currentLeaseEpoch']=epoch
        values.append({'name':f'observer current lease epoch {epoch}','valid':True,'value':item})
    for label,epoch in [('negative',-1),('overflow',18446744073709551616)]:
        item=json.loads(json.dumps(observation));item['result']['currentLeaseEpoch']=epoch
        values.append({'name':'observer current lease epoch '+label,'valid':False,'value':item})
    item=json.loads(json.dumps(observation));del item['result']['currentLeaseEpoch']
    values.append({'name':'observer missing current lease epoch','valid':False,'value':item})
    observation['result']['lease']=sample(D['lease'])
    values.append({'name':'observer unexpectedly has lease','valid':False,'value':observation})
    return {'protocol/operation-fixtures.json':json.dumps(values,ensure_ascii=False,indent=2)+'\n',
            'protocol/envelope-fixtures.json':json.dumps(envelopes,ensure_ascii=False,indent=2)+'\n'}

def event_artifacts():
    events={
      'session.changed':ref('session'), 'workspace.changed':ref('workspace'), 'tab.changed':ref('tab'),
      'pane.changed':ref('pane'), 'terminal.created':ref('terminal'), 'terminal.updated':ref('terminal'),
      'terminal.exited':ref('terminal'), 'agent.changed':ref('agent'),
      'lease.revoked':obj({'terminalID':ID,'leaseID':ID,'leaseEpoch':U64,'reason':SHORT}),
      'server.replacing':obj({'operationID':ID,'state':enum('prepared','transferring','committed','rolled_back')}),
      'server.closed':obj({'reason':SHORT}),
    }
    variants=[]; examples=[]
    for name,body in events.items():
        value=obj({'type':enum('event'),'event':enum(name),'eventID':ID,'target':ref('target'),'sequence':U64,'revision':U64,'body':body})
        variants.append(value)
        examples.append({'name':name,'valid':True,'value':sample(value)})
        invalid=sample(value);invalid.pop('target')
        examples.append({'name':name+' missing target','valid':False,'value':invalid})
    event_schema={'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:aster:session:events:1','$defs':D,'oneOf':variants}
    sha={'type':'string','pattern':'^[0-9a-f]{64}$'}
    stream_variants=[
      obj({'type':enum('snapshot_begin'),'length':integer(1,33554432),'sha256':sha,'sequence':U64},{'baseSequence':{'type':'null'}}),
      obj({'type':enum('delta_begin'),'length':integer(1,65536),'sha256':sha,'sequence':U64,'baseSequence':U64}),
      obj({'type':enum('snapshot_end')}),obj({'type':enum('delta_end')}),
    ]
    stream_examples=[]
    for variant in stream_variants:
        value=sample(variant)
        if value['type']=='delta_begin': value['sequence']=1
        stream_examples.append({'name':value['type'],'valid':True,'value':value})
    invalid=sample(stream_variants[0]);invalid['length']=33554433
    stream_examples.append({'name':'oversized snapshot','valid':False,'value':invalid})
    invalid=sample(stream_variants[1]);invalid.pop('baseSequence')
    stream_examples.append({'name':'delta missing base','valid':False,'value':invalid})
    stream_schema={'$schema':'https://json-schema.org/draft/2020-12/schema','$id':'urn:aster:session:stream:1','oneOf':stream_variants}
    return {name:json.dumps(value,ensure_ascii=False,indent=2)+'\n' for name,value in {
        'protocol/events.schema.json':event_schema,'protocol/event-fixtures.json':examples,
        'protocol/stream.schema.json':stream_schema,'protocol/stream-fixtures.json':stream_examples}.items()}

def reply_fixtures():
    operation=next(o for o in OPS if o['name']=='terminal.attach')
    req=sample(request(operation)); reply=sample(response(operation))
    reply['revision']=18446744073709551615
    reply['result']['lease']['leaseEpoch']=18446744073709551615
    cases=[]
    def add(name,kind,value,result,after=None):
        cases.append({'name':name,'kind':kind,'requestJSON':json.dumps(req),'valueJSON':json.dumps(value),
                      'afterSequence':after,'result':result})
    add('maximum reply counters','response',reply,'ok')
    wrong=json.loads(json.dumps(reply));wrong['requestID']='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    add('wrong request','response',wrong,'requestMismatch')
    wrong=json.loads(json.dumps(reply));wrong['target']['serverEpoch']='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    add('wrong epoch','response',wrong,'targetMismatch')
    wrong=json.loads(json.dumps(reply));wrong.pop('revision')
    add('missing revision','response',wrong,'targetMismatch')
    failure={'type':'error','requestID':req['requestID'],'operation':req['operation'],'scope':req['scope'],
             'error':{'code':'lease_busy','message':'Terminal is controlled by another client','retry':'never'}}
    add('error without unauthorized target','error',failure,'ok')
    wrong=json.loads(json.dumps(failure));wrong['error']['code']='7invalid'
    add('invalid error code','error',wrong,'invalidError')
    event={'type':'event','event':'lease.revoked','eventID':sample(ID),'target':req['target'],'sequence':18446744073709551615,
           'revision':18446744073709551615,'body':{'terminalID':sample(ID),'leaseID':sample(ID),
           'leaseEpoch':18446744073709551615,'reason':'takeover'}}
    add('maximum event counters','event',event,'ok',18446744073709551614)
    wrong=json.loads(json.dumps(event));wrong['event']='terminal.updated'
    add('wrong event kind','event',wrong,'eventMismatch',18446744073709551614)
    wrong=json.loads(json.dumps(event));wrong['sequence']=2
    add('stale event','event',wrong,'staleEvent',2)
    wrong=json.loads(json.dumps(event));wrong['sequence']=4
    add('event gap','event',wrong,'sequenceGap',2)
    wrong=json.loads(json.dumps(event));wrong['target']['serverID']='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    add('event wrong instance','event',wrong,'targetMismatch',18446744073709551614)
    wrong=json.loads(json.dumps(event));wrong['eventID']='invalid'
    add('invalid event identity','event',wrong,'invalidEventID',18446744073709551614)
    wrong=json.loads(json.dumps(event));wrong['sequence']=3;wrong['revision']=1
    add('stale revision','event',wrong,'staleRevision',2)
    cases[-1]['minimumRevision']=2
    observe=next(o for o in OPS if o['name']=='terminal.observe')
    observation=sample(response(observe))
    observations=[]
    for epoch in (0, 18446744073709551615):
        observation['result']['currentLeaseEpoch']=epoch
        observations.append({'requestJSON':json.dumps(sample(request(observe))),
                             'valueJSON':json.dumps(observation),'epoch':epoch})
    return {'protocol/reply-fixtures.json':json.dumps(cases,ensure_ascii=False,indent=2)+'\n',
            'protocol/observe-fixtures.json':json.dumps(observations,ensure_ascii=False,indent=2)+'\n'}

def generated_types():
    def swift_name(name):
        parts=re.split(r'[._]',name)
        return parts[0]+''.join(p[:1].upper()+p[1:] for p in parts[1:])
    swift=['// Generated by SessionRuntime/scripts/build-protocol.py. Do not edit.', 'import Foundation', '',
           'public enum SessionOperationScope: String, Codable, Sendable { case session, registry, bootstrap }',
           'public struct SessionOperationMetadata: Sendable {',
           '  public let scope: SessionOperationScope', '  public let capability: String?',
           '  public let requiresRevision: Bool', '  public let requiresLease: Bool',
           '  public let requiresControlSequence: Bool', '  public let requiresCreatedAt: Bool', '}', '',
           'public enum SessionOperationKind: String, Codable, CaseIterable, Sendable {']
    swift += [f'  case {swift_name(o["name"])} = "{o["name"]}"' for o in OPS]
    swift += ['  public var metadata: SessionOperationMetadata {', '    switch self {']
    for o in OPS:
        cap='"'+o['capability']+'"' if o['capability'] else 'nil'
        swift += [f'    case .{swift_name(o["name"])}: .init(scope: .{o["scope"]}, capability: {cap}, requiresRevision: {str(o["mutation"]=="structure").lower()}, requiresLease: {str(o["lease"]).lower()}, requiresControlSequence: {str(o["controlSequence"]).lower()}, requiresCreatedAt: {str(o["durable"]).lower()})']
    swift += ['    }', '  }', '}']
    zig=['// Generated by scripts/build-protocol.py. Do not edit.',
         'pub const Scope = enum { session, registry, bootstrap };',
         'pub const Metadata = struct { scope: Scope, capability: ?[]const u8, requires_revision: bool, requires_lease: bool, requires_control_sequence: bool, requires_created_at: bool };',
         'pub const Operation = enum {']
    zig += ['    @"'+o['name']+'",' for o in OPS]
    zig += ['    pub fn metadata(self: Operation) Metadata {', '        return switch (self) {']
    for o in OPS:
        cap='"'+o['capability']+'"' if o['capability'] else 'null'
        zig += [f'            .@"{o["name"]}" => .{{ .scope = .{o["scope"]}, .capability = {cap}, .requires_revision = {str(o["mutation"]=="structure").lower()}, .requires_lease = {str(o["lease"]).lower()}, .requires_control_sequence = {str(o["controlSequence"]).lower()}, .requires_created_at = {str(o["durable"]).lower()} }},']
    zig += ['        };', '    }', '};']
    return {'../Sources/AsterCore/SessionOperationKind.swift':'\n'.join(swift)+'\n',
            'src/operation_kind.zig':subprocess.run(['zig','fmt','--stdin'],input='\n'.join(zig)+'\n',text=True,check=True,capture_output=True).stdout}

if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    for name,text in artifacts().items():
        path=ROOT/name
        if args.check:
            if not path.exists() or path.read_text()!=text: raise SystemExit(f'Outdated generated protocol file: {path}')
        else:path.write_text(text)
    print(f'{len(OPS)} operation contracts '+('verified' if args.check else 'generated'))
