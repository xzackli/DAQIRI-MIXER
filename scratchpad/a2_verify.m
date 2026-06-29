% a2_verify.m — final verification of saved manas2el: full anchor chain + structural confirmation
try
  DIR='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe'; M='manas2el';
  load_system([DIR '/' M '.slx']);

  fprintf('=== STRUCTURAL CONFIRM ===\n');
  fb=[M '/fft_wideband_real']; mn=get_param(fb,'MaskNames'); mv=get_param(fb,'MaskValues');
  for k=1:numel(mn), if any(strcmp(mn{k},{'n_streams','n_inputs','FFTSize'})), fprintf('  fft.%s=%s\n',mn{k},mv{k}); end; end
  pfbs = find_system(M,'SearchDepth',1,'MaskType','pfb_fir_real'); fprintf('  #pfb_fir_real=%d\n', numel(pfbs));
  dprams = find_system(M,'SearchDepth',1,'RefBlock','xbsIndex_r4/Dual Port RAM');
  if isempty(dprams), dprams=find_system(M,'SearchDepth',1,'Name','Dual Port RAM1'); dp2=find_system(M,'SearchDepth',1,'Name','Dual Port RAM2'); fprintf('  DPRAM1:%d DPRAM2:%d\n', ~isempty(dprams), ~isempty(dp2)); end
  % MTS flags
  rf=[M '/rfdc']; mn=get_param(rf,'MaskNames'); mv=get_param(rf,'MaskValues');
  for k=1:numel(mn), if ~isempty(regexp(mn{k},'enable_mts','once')), fprintf('  rfdc.%s=%s\n',mn{k},mv{k}); end; end
  % new blocks present?
  for nm={'bus_create2','Dual Port RAM2','rd_sel_mux','elemctr','seqhdr96','elem8','Relational_e2','edge_detect_e2'}
    fprintf('  %s present:%d\n', nm{1}, ~isempty(find_system(M,'SearchDepth',1,'Name',nm{1})));
  end

  fprintf('\n=== COMPILE + FULL ANCHOR CHAIN ===\n');
  feval(M,[],[],[],'compile');
  fprintf('FINAL_COMPILE_OK\n');
  chain={'Dual Port RAM1','Dual Port RAM2','rd_sel_mux','data_delay1','From17','Delay4', ...
         'gb_cat512','gb_reg512','gb_pipe512','gb_mux512','seqhdr96','gb_seq512f','seqctr','elemctr'};
  for i=1:numel(chain)
    h=find_system(M,'SearchDepth',1,'Name',chain{i}); if isempty(h), continue; end
    b=[M '/' chain{i}];
    try st=get_param(b,'CompiledSampleTime'); dt=get_param(b,'CompiledPortDataTypes');
      stst=''; if isnumeric(st), stst=mat2str(st); else stst='(nonnum/cell)'; end
      fprintf('  %-16s OUT=%s ST=%s\n', chain{i}, strjoin(string(dt.Outport),','), stst);
    catch e, fprintf('  %-16s ERR %s\n', chain{i}, e.message); end
  end
  % the gbe tx_data input port ST specifically (port index for tx_data)
  ge=find_system(M,'SearchDepth',1,'Name','onehundred_gbe');
  if ~isempty(ge)
    dt=get_param(ge{1},'CompiledPortDataTypes');
    fprintf('  onehundred_gbe INPUTS=%s\n', strjoin(string(dt.Inport),','));
  end
  feval(M,[],[],[],'term');
  fprintf('=== A2VERIFY_DONE ===\n');
catch e
  disp('MATLAB_ERROR:'); disp(getReport(e));
  try, feval('manas2el',[],[],[],'term'); catch, end
end
bdclose('all'); disp('MY_DONE');
