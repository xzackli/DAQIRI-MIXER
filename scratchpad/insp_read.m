% insp_read.m — DPRAM mask, read-side framing, FFT stream1 output Delays, Delay4 read tap
try
  DIR='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe'; M='manas2el';
  load_system([DIR '/' M '.slx']);

  % full DPRAM mask
  fprintf('=== Dual Port RAM1 MASK ===\n');
  b=[M '/Dual Port RAM1']; nm=get_param(b,'MaskNames'); vv=get_param(b,'MaskValues');
  for k=1:numel(nm)
    if any(strcmp(nm{k},{'depth','init_a','init_b','latency','write_mode_A','write_mode_B','optimize','explicit_period','period','distributed_mem','initVector'}))
      fprintf('  %s = %s\n', nm{k}, vv{k});
    end
  end
  fprintf('  BlockType=%s RefBlock=%s\n', get_param(b,'BlockType'), get_param(b,'ReferenceBlock'));

  % position of key blocks (so I can place new ones without overlap)
  fprintf('\n=== POSITIONS ===\n');
  for nm={'Dual Port RAM1','Delay4','From17','Counter5','pulse_ext4','complex_convert','complex_convert1','bus_create','Mux1','Delay7','Delay8','Goto6','Goto7','From14','From12','gb_wctr','gb_mux512','seqctr','gb_seq512f','data_delay1'}
    h=find_system(M,'SearchDepth',1,'Name',nm{1});
    if isempty(h), fprintf('  [no %s]\n', nm{1}); continue; end
    fprintf('  %s @ %s\n', nm{1}, mat2str(get_param([M '/' nm{1}],'Position')));
  end

  % which FFT delays feed stream1 bins? FFT out ports 4,5 are dangling. Find what taps fft0/fft1 (Delay7/8) to mirror.
  fprintf('\n=== Delay7 / Delay8 (stream0 bin taps) detail ===\n');
  for nm={'Delay7','Delay8','Goto6','Goto7'}
    b2=[M '/' nm{1}]; pc=get_param(b2,'PortConnectivity');
    fprintf('--- %s (BT=%s) ---\n', nm{1}, get_param(b2,'BlockType'));
    for k=1:numel(pc), p=pc(k);
      s=''; for j=1:numel(p.SrcBlock), if p.SrcBlock(j)>0, s=[s get_param(p.SrcBlock(j),'Name') ':' num2str(p.SrcPort(j)) ' ']; end; end
      d=''; for j=1:numel(p.DstBlock), if p.DstBlock(j)>0, d=[d get_param(p.DstBlock(j),'Name') ' ']; end; end
      fprintf('   p[%s] src<%s> dst<%s>\n', p.Type, strtrim(s), strtrim(d));
    end
  end
  % Delay7/Delay8 mask (latency) + complex_convert mask
  for nm={'Delay7','complex_convert'}
    b2=[M '/' nm{1}];
    fprintf('--- %s mask ---\n', nm{1});
    try mn=get_param(b2,'MaskNames'); mv=get_param(b2,'MaskValues'); for k=1:numel(mn), fprintf('   %s=%s\n',mn{k},mv{k}); end; catch, fprintf('  (no mask)\n'); end
  end

  % read-side framing block masks + connectivity
  fprintf('\n=== READ FRAMING ===\n');
  for nm={'Counter5','pulse_ext4','pulse_ext3','gb_modctr','gb_wctr','gb_streq','gb_iseof','gb_inwin','gb_isw0','gb_eofand','gb_vand','gb_selinv','Delay4','From17','data_delay1','gb_seq512f','seqctr'}
    h=find_system(M,'SearchDepth',1,'Name',nm{1}); if isempty(h), fprintf('[no %s]\n',nm{1}); continue; end
    b2=[M '/' nm{1}]; pc=get_param(b2,'PortConnectivity');
    fprintf('--- %s (BT=%s MT=%s) ---\n', nm{1}, get_param(b2,'BlockType'), getm(b2));
    for k=1:numel(pc), p=pc(k);
      s=''; for j=1:numel(p.SrcBlock), if p.SrcBlock(j)>0, s=[s get_param(p.SrcBlock(j),'Name') ':' num2str(p.SrcPort(j)) ' ']; end; end
      d=''; for j=1:numel(p.DstBlock), if p.DstBlock(j)>0, d=[d get_param(p.DstBlock(j),'Name') ' ']; end; end
      fprintf('   p[%s] src<%s> dst<%s>\n', p.Type, strtrim(s), strtrim(d));
    end
  end
  disp('=== READ_DONE ===');
catch e
  disp('MATLAB_ERROR:'); disp(getReport(e));
end
bdclose('all'); disp('MY_DONE');

function mt=getm(b)
  mt=''; try mt=get_param(b,'MaskType'); catch, end
end
