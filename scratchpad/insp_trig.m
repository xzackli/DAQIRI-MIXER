% insp_trig.m — trigger machinery that opens the readout window (how often / what gates it)
try
  DIR='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe'; M='manas2el';
  load_system([DIR '/' M '.slx']);
  names={'Logical2','Logical1','Relational1','Relational3','Relational4','c3_lo8','Counter3', ...
         'cns_mux_en1','cns_mux_en2','cns_mux_en3','pulse_ext3','pulse_ext4','Mux4', ...
         'edge_detect2','data_delay4','From_first_sync2','first_sync','Goto_sync_gen2', ...
         'gb_seq512f','seqz96','seq32be','seqz384','seq_b0','seq_b1','seq_b2','seq_b3','seqctr'};
  for i=1:numel(names)
    nm=names{i}; h=find_system(M,'SearchDepth',1,'Name',nm);
    if isempty(h), fprintf('[no %s]\n', nm); continue; end
    b=[M '/' nm]; pc=get_param(b,'PortConnectivity');
    mt=''; try mt=get_param(b,'MaskType'); catch, end
    fprintf('--- %s (BT=%s MT=%s) ---\n', nm, get_param(b,'BlockType'), mt);
    for k=1:numel(pc), p=pc(k);
      s=''; for j=1:numel(p.SrcBlock), if p.SrcBlock(j)>0, s=[s get_param(p.SrcBlock(j),'Name') ':' num2str(p.SrcPort(j)) ' ']; end; end
      d=''; for j=1:numel(p.DstBlock), if p.DstBlock(j)>0, d=[d get_param(p.DstBlock(j),'Name') ' ']; end; end
      fprintf('   p[%s] src<%s> dst<%s>\n', p.Type, strtrim(s), strtrim(d));
    end
    % mask for relational/pulse_ext/logical/const
    if any(strcmp(mt,{'pulse_ext'})) || contains(get_param(b,'BlockType'),'S-Function')
      try mn=get_param(b,'MaskNames'); mv=get_param(b,'MaskValues');
        kk=''; for q=1:numel(mn), if any(strcmp(mn{q},{'pulse_length','pulse_len','const','n_bits','mode','latency','logical_function','inputs'})), kk=[kk sprintf('%s=%s ',mn{q},mv{q})]; end; end
        if ~isempty(kk), fprintf('     {%s}\n', kk); end
      catch, end
    end
  end
  % pulse_ext internal pulse length param name
  fprintf('\n=== pulse_ext4 internals ===\n');
  pe=find_system([M '/pulse_ext4'],'LookUnderMasks','all','Type','Block');
  for i=1:numel(pe), fprintf('  %s BT=%s\n', pe{i}, get_param(pe{i},'BlockType')); end
  fprintf('pulse_ext4 MASK:\n'); mn=get_param([M '/pulse_ext4'],'MaskNames'); mv=get_param([M '/pulse_ext4'],'MaskValues');
  for k=1:numel(mn), fprintf('   %s=%s\n', mn{k}, mv{k}); end
  fprintf('pulse_ext3 MASK:\n'); mn=get_param([M '/pulse_ext3'],'MaskNames'); mv=get_param([M '/pulse_ext3'],'MaskValues');
  for k=1:numel(mn), fprintf('   %s=%s\n', mn{k}, mv{k}); end
  disp('=== TRIG_DONE ===');
catch e
  disp('MATLAB_ERROR:'); disp(getReport(e));
end
bdclose('all'); disp('MY_DONE');
