% a2_step2.m — (A) element index into header byte52; (B) 2-pass read framing for 2 packets/snapshot.
% Compile after EACH. Confirm anchor tx_data path ST=[1000000 0]. If (B) breaks anchor or forces a
% width change, REVERT (B) and keep (A)+Step1 as the clean deliverable.
try
  DIR='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe'; M='manas2el';
  load_system([DIR '/' M '.slx']);
  B=@(n)[M '/' n]; PH=@(n)get_param(B(n),'PortHandles');

  % ============ (A) ELEMENT INDEX @ payload byte52 ============
  % gb_seq512f = Concat(seqz96[96b,HI] ++ seq32be[32b] ++ seqz384[384b,LO]).
  %   LO 384b = bytes0-47=0; seq32be = bytes48-51 (BE); seqz96 = bytes52-63 = 0.
  %   byte52 = the LOWEST 8 bits of the seqz96 field. Replace seqz96 with Concat(z88[88b,HI]++elem8[8b,LO]).
  % elem8 = zero-extend elemctr(1b) to 8b via a Convert/Concat with 7 zero bits.
  add_block(B('seqz384'), B('elem_z7'),'Position',[300 2300 340 2320],'MakeNameUnique','on'); % a const
  set_param(B('elem_z7'),'const','0','n_bits','7','arith_type','Unsigned','bin_pt','0');
  add_block(B('seq32be'), B('elem8'),'Position',[360 2300 400 2360],'MakeNameUnique','on'); % a Concat
  set_param(B('elem8'),'num_inputs','2');   % hi=elem_z7[7b], lo=elemctr[1b] => 8b, value 0 or 1 at byte52
  add_line(M, PH('elem_z7').Outport(1), PH('elem8').Inport(1),'autorouting','on'); % hi 7b zero
  add_line(M, PH('elemctr').Outport(1), PH('elem8').Inport(2),'autorouting','on'); % lo 1b elem
  % z88 const
  add_block(B('seqz96'), B('seqz88'),'Position',[300 2360 340 2380],'MakeNameUnique','on');
  set_param(B('seqz88'),'const','0','n_bits','88','arith_type','Unsigned','bin_pt','0');
  % new seqhdr96 = Concat(seqz88[88b HI] ++ elem8[8b LO]) = 96b, elem at LO byte = byte52
  add_block(B('gb_seq512f'), B('seqhdr96'),'Position',[400 2300 440 2380],'MakeNameUnique','on');
  set_param(B('seqhdr96'),'num_inputs','2');
  add_line(M, PH('seqz88').Outport(1), PH('seqhdr96').Inport(1),'autorouting','on'); % hi 88b
  add_line(M, PH('elem8').Outport(1),  PH('seqhdr96').Inport(2),'autorouting','on'); % lo 8b (elem@byte52)
  % rewire gb_seq512f.in1 (was seqz96) <- seqhdr96
  lh = get_param(B('gb_seq512f'),'LineHandles');
  if lh.Inport(1) > 0, delete_line(lh.Inport(1)); end
  add_line(M, PH('seqhdr96').Outport(1), PH('gb_seq512f').Inport(1),'autorouting','on');

  save_system(M);
  fprintf('=== A_EDIT_OK, compiling (element header) ===\n');
  feval(M,[],[],[],'compile');
  fprintf('A_COMPILE_OK\n');
  for nm={'seqhdr96','elem8','gb_seq512f','gb_mux512','Delay4','rd_sel_mux'}
    b=[M '/' nm{1}];
    try dt=get_param(b,'CompiledPortDataTypes'); st=get_param(b,'CompiledSampleTime');
      stst=''; if isnumeric(st), stst=mat2str(st); else stst='(nonnum)'; end
      fprintf('  %s IN=%s OUT=%s ST=%s\n', nm{1}, strjoin(string(dt.Inport),','), strjoin(string(dt.Outport),','), stst);
    catch e, fprintf('  %s ERR %s\n', nm{1}, e.message); end
  end
  feval(M,[],[],[],'term');
  save_system(M);
  fprintf('=== A2STEP2A_DONE ===\n');
catch e
  disp('MATLAB_ERROR_A:'); disp(getReport(e));
  try, feval('manas2el',[],[],[],'term'); catch, end
end
bdclose('all'); disp('MY_DONE');
