% insp_state.m — verify manas2el current state + write-side duty cycle for Approach 1/2 decision
try
  DIR='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe'; M='manas2el';
  load_system([DIR '/' M '.slx']);

  % 1. confirm stream1 FFT taps / bus_create2 / complex_convert2,3 exist
  fprintf('=== STREAM1 TAP BLOCKS PRESENT? ===\n');
  for nm = {'bus_create','bus_create2','complex_convert2','complex_convert3','From14','From12','From_fft2','From_fft3','Goto6','Goto7'}
    h=find_system(M,'SearchDepth',1,'Name',nm{1});
    fprintf('  %s : %s\n', nm{1}, mat2str(~isempty(h)));
  end

  % all Goto tags (to find stream1 bin tags)
  fprintf('\n=== ALL GOTO TAGS (top level) ===\n');
  gts=find_system(M,'SearchDepth',1,'BlockType','Goto');
  for i=1:numel(gts), fprintf('  GOTO %s tag=%s\n', get_param(gts{i},'Name'), get_param(gts{i},'GotoTag')); end

  % FFT output port connectivity (which Delays tap stream1)
  fprintf('\n=== fft_wideband_real n_streams + output port dests ===\n');
  fb=[M '/fft_wideband_real'];
  mn=get_param(fb,'MaskNames'); mv=get_param(fb,'MaskValues');
  for k=1:numel(mn), if any(strcmp(mn{k},{'n_streams','n_inputs','FFTSize'})), fprintf('  %s=%s\n',mn{k},mv{k}); end; end
  pc=get_param(fb,'PortConnectivity');
  for k=1:numel(pc), p=pc(k); if strcmp(p.Type,'1')||~isnan(str2double(p.Type)), end
    d=''; for j=1:numel(p.DstBlock), if p.DstBlock(j)>0, d=[d get_param(p.DstBlock(j),'Name') ' ']; end; end
    s=''; for j=1:numel(p.SrcBlock), if p.SrcBlock(j)>0, s=[s get_param(p.SrcBlock(j),'Name') ' ']; end; end
    if ~isempty(d)||~isempty(p.Type), fprintf('  fft port[%s] src<%s> dst<%s>\n', p.Type, strtrim(s), strtrim(d)); end
  end

  % 2. write-path connectivity (Mux1, valid_delay2, data_delay3, valid_delay4, Counter3, DPRAM)
  fprintf('\n=== WRITE PATH ===\n');
  for nm={'bus_create','bus_create2','Mux1','valid_delay2','data_delay3','valid_delay4','Counter3','Dual Port RAM1'}
    h=find_system(M,'SearchDepth',1,'Name',nm{1}); if isempty(h), fprintf('[no %s]\n',nm{1}); continue; end
    b=[M '/' nm{1}]; pc=get_param(b,'PortConnectivity');
    fprintf('--- %s ---\n', nm{1});
    for k=1:numel(pc), p=pc(k);
      s=''; for j=1:numel(p.SrcBlock), if p.SrcBlock(j)>0, s=[s get_param(p.SrcBlock(j),'Name') ':' num2str(p.SrcPort(j)) ' ']; end; end
      d=''; for j=1:numel(p.DstBlock), if p.DstBlock(j)>0, d=[d get_param(p.DstBlock(j),'Name') ' ']; end; end
      fprintf('   p[%s] src<%s> dst<%s>\n', p.Type, strtrim(s), strtrim(d));
    end
  end

  % 3. COMPILE — confirm clean + get write-side & tx_data sample times / valid duty
  fprintf('\n=== COMPILING manas2el (baseline) ===\n');
  feval(M,[],[],[],'compile');
  fprintf('COMPILE_OK\n');
  for nm={'bus_create','bus_create2','valid_delay4','data_delay3','Dual Port RAM1','Delay4','gb_mux512','seqctr'}
    h=find_system(M,'SearchDepth',1,'Name',nm{1}); if isempty(h), continue; end
    b=[M '/' nm{1}];
    try dt=get_param(b,'CompiledPortDataTypes'); st=get_param(b,'CompiledSampleTime');
      fprintf('  %s IN=%s OUT=%s ST=%s\n', nm{1}, strjoin(string(dt.Inport),','), strjoin(string(dt.Outport),','), mat2str(st));
    catch e, fprintf('  %s ST-ERR %s\n', nm{1}, e.message); end
  end
  % onehundred_gbe tx_data ST
  ge=find_system(M,'SearchDepth',1,'Name','onehundred_gbe');
  if ~isempty(ge)
    st=get_param(ge{1},'CompiledSampleTime'); fprintf('  onehundred_gbe ST=%s\n', mat2str(st));
    dt=get_param(ge{1},'CompiledPortDataTypes'); fprintf('  onehundred_gbe IN=%s\n', strjoin(string(dt.Inport),','));
  end
  feval(M,[],[],[],'term');
  disp('=== INSP_DONE ===');
catch e
  disp('MATLAB_ERROR:'); disp(getReport(e));
  try, feval('manas2el',[],[],[],'term'); catch, end
end
bdclose('all'); disp('MY_DONE');
