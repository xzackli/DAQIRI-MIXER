% a2_step2b.m — 2-pass read framing: fire the readout TWICE per spectrum so 2 packets emit
% (packet0=elem0 via DPRAM1, packet1=elem1 via DPRAM2), elemctr toggling per eof, read-select mux
% already in place. Counter5/gb_modctr/gb_wctr reset per window (rst=on) so NO width change, NO wrap.
% Mechanism: add a 2nd trigger edge so Logical1 (OR) fires twice per spectrum. Compile, check anchor.
try
  DIR='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe'; M='manas2el';
  load_system([DIR '/' M '.slx']);
  B=@(n)[M '/' n]; PH=@(n)get_param(B(n),'PortHandles');

  % Current trigger: Logical2 = Logical1 AND first_sync; Logical1 = edge_detect6 OR edge_detect7.
  %   edge_detect7 <- Relational4 (c3_lo8 == cns_mux_en1=127).  Fires once per spectrum (write-word 127).
  % ADD a 2nd condition: Relational_e2 (c3_lo8 == 63) -> edge_detect_e2 -> widen Logical1 to 3-input OR.
  %   => the window opens at write-word 63 AND 127 = TWICE per spectrum -> 2 packets, elemctr toggles.
  %   (63/127 are within the 0..127 spectrum; each opens an independent self-resetting 1032 window.)

  % new constant cns_mux_en1b = 63
  add_block(B('cns_mux_en1'), B('cns_mux_en1b'),'Position',[get_pos(M,'cns_mux_en1')]+[0 120 0 120],'MakeNameUnique','on');
  set_param(B('cns_mux_en1b'),'const','63','n_bits','8');
  % new relational (a=b) c3_lo8 == 63
  add_block(B('Relational4'), B('Relational_e2'),'Position',[get_pos(M,'Relational4')]+[0 120 0 120],'MakeNameUnique','on');
  add_line(M, PH('c3_lo8').Outport(1),       PH('Relational_e2').Inport(1),'autorouting','on');
  add_line(M, PH('cns_mux_en1b').Outport(1), PH('Relational_e2').Inport(2),'autorouting','on');
  % new edge_detect (copy edge_detect7)
  add_block(B('edge_detect7'), B('edge_detect_e2'),'Position',[get_pos(M,'edge_detect7')]+[0 120 0 120],'MakeNameUnique','on');
  add_line(M, PH('Relational_e2').Outport(1), PH('edge_detect_e2').Inport(1),'autorouting','on');
  % widen Logical1 OR from 2 to 3 inputs, wire edge_detect_e2 to its new input 3
  set_param(B('Logical1'),'inputs','3');
  add_line(M, PH('edge_detect_e2').Outport(1), PH('Logical1').Inport(3),'autorouting','on');

  save_system(M);
  fprintf('=== B_EDIT_OK, compiling (2-pass trigger) ===\n');
  feval(M,[],[],[],'compile');
  fprintf('B_COMPILE_OK\n');
  for nm={'Logical1','Logical2','Relational_e2','edge_detect_e2','pulse_ext4','Counter5','elemctr','rd_sel_mux','Delay4','gb_mux512','gb_eofand'}
    h=find_system(M,'SearchDepth',1,'Name',nm{1}); if isempty(h), b=find_system(M,'Name',nm{1}); if isempty(b), continue; end; b=b{1}; else b=[M '/' nm{1}]; end
    try dt=get_param(b,'CompiledPortDataTypes'); st=get_param(b,'CompiledSampleTime');
      stst=''; if isnumeric(st), stst=mat2str(st); else stst='(nonnum)'; end
      fprintf('  %s IN=%s OUT=%s ST=%s\n', nm{1}, strjoin(string(dt.Inport),','), strjoin(string(dt.Outport),','), stst);
    catch e, fprintf('  %s ERR %s\n', nm{1}, e.message); end
  end
  % onehundred_gbe input ST (the anchor end)
  ge=find_system(M,'SearchDepth',1,'Name','onehundred_gbe');
  if ~isempty(ge), st=get_param(ge{1},'CompiledSampleTime'); if isnumeric(st), fprintf('  onehundred_gbe ST=%s\n', mat2str(st)); else fprintf('  onehundred_gbe ST=(cell)\n'); end; end
  feval(M,[],[],[],'term');
  save_system(M);
  fprintf('=== A2STEP2B_DONE ===\n');
catch e
  disp('MATLAB_ERROR_B:'); disp(getReport(e));
  try, feval('manas2el',[],[],[],'term'); catch, end
end
bdclose('all'); disp('MY_DONE');

function p=get_pos(M,nm)
  p=get_param([M '/' nm],'Position');
end
