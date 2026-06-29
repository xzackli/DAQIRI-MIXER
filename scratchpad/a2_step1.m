% a2_step1.m — Approach 2: tap stream1 FFT bins, build DPRAM1 (copy), read-select mux into Delay4
% Also add elemctr (mod-2 read-pass parity). Compile, confirm anchor tx_data ST=[1000000 0].
try
  DIR='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe'; M='manas2el';
  load_system([DIR '/' M '.slx']);
  B=@(n)[M '/' n];
  PH=@(n)get_param(B(n),'PortHandles');
  add_b=@(src,nm,pos)add_block(src,B(nm),'Position',pos,'MakeNameUnique','on');

  % ---------- 1. tap stream1 FFT output bins (ports 4,5 = fft out p4,p5; dangling) ----------
  % mirror Delay7(fft p2)->Goto6(fft0), Delay8(fft p3)->Goto7(fft1)
  % add Delay7b(fft p4)->Goto(fft2), Delay8b(fft p5)->Goto(fft3)
  add_block(B('Delay7'), B('Delay7b'), 'Position',[1870 938 1885 952],'MakeNameUnique','on');
  add_block(B('Delay8'), B('Delay8b'), 'Position',[1870 988 1885 1002],'MakeNameUnique','on');
  add_block('built-in/Goto', B('Goto_fft2'),'Position',[1955 938 2010 952],'MakeNameUnique','on');
  add_block('built-in/Goto', B('Goto_fft3'),'Position',[1955 988 2010 1002],'MakeNameUnique','on');
  set_param(B('Goto_fft2'),'GotoTag','fft2'); set_param(B('Goto_fft3'),'GotoTag','fft3');
  % FFT out ports: p1->Delay6/Goto9, p2->Delay7, p3->Delay8, p4=stream1 bin0, p5=stream1 bin1, p6=ovf
  fph=PH('fft_wideband_real');
  add_line(M, fph.Outport(4), PH('Delay7b').Inport(1), 'autorouting','on');
  add_line(M, fph.Outport(5), PH('Delay8b').Inport(1), 'autorouting','on');
  add_line(M, PH('Delay7b').Outport(1), PH('Goto_fft2').Inport(1), 'autorouting','on');
  add_line(M, PH('Delay8b').Outport(1), PH('Goto_fft3').Inport(1), 'autorouting','on');

  % ---------- 2. complex_convert2/3 + bus_create2 (stream1 32b, mirror stream0) ----------
  add_block('built-in/From', B('From_fft2'),'Position',[2945 1258 3000 1272],'MakeNameUnique','on');
  add_block('built-in/From', B('From_fft3'),'Position',[2945 1328 3000 1342],'MakeNameUnique','on');
  set_param(B('From_fft2'),'GotoTag','fft2'); set_param(B('From_fft3'),'GotoTag','fft3');
  add_block(B('complex_convert'),  B('complex_convert2'),'Position',[3035 1255 3080 1275],'MakeNameUnique','on');
  add_block(B('complex_convert1'), B('complex_convert3'),'Position',[3035 1325 3080 1345],'MakeNameUnique','on');
  add_block(B('bus_create'), B('bus_create2'),'Position',[3155 1261 3205 1339],'MakeNameUnique','on');
  add_line(M, PH('From_fft2').Outport(1), PH('complex_convert2').Inport(1),'autorouting','on');
  add_line(M, PH('From_fft3').Outport(1), PH('complex_convert3').Inport(1),'autorouting','on');
  add_line(M, PH('complex_convert2').Outport(1), PH('bus_create2').Inport(1),'autorouting','on');
  add_line(M, PH('complex_convert3').Outport(1), PH('bus_create2').Inport(2),'autorouting','on');

  % ---------- 3. DPRAM1 = byte-exact copy of Dual Port RAM1 (proven geometry, NO change) ----------
  add_block(B('Dual Port RAM1'), B('Dual Port RAM2'),'Position',[4470 1780 4545 1945],'MakeNameUnique','on');
  % wire DPRAM2 write: addra=Counter3 (shared), dina=stream1 data (bus_create2 path mirroring data_delay3),
  %   wea=valid_delay4 (shared), addrb=Counter5(shared), dinb/web = same constants as DPRAM1.
  % Build a stream1 write data path mirroring Mux1->valid_delay2->data_delay3 but simplest: route bus_create2
  %   straight through copies of valid_delay2b/data_delay3b for matched latency.
  add_block(B('valid_delay2'), B('valid_delay2b'),'Position',[3380 1285 3400 1315],'MakeNameUnique','on');
  add_block(B('data_delay3'),  B('data_delay3b'), 'Position',[3470 1285 3490 1315],'MakeNameUnique','on');
  add_line(M, PH('bus_create2').Outport(1), PH('valid_delay2b').Inport(1),'autorouting','on');
  add_line(M, PH('valid_delay2b').Outport(1), PH('data_delay3b').Inport(1),'autorouting','on');
  % DPRAM2 ports: 1=addra,2=dina,3=wea,4=addrb,5=dinb,6=web
  pc1 = get_param(B('Dual Port RAM1'),'PortConnectivity');  % to find the dinb/web const sources
  % addra <- Counter3
  add_line(M, PH('Counter3').Outport(1), PH('Dual Port RAM2').Inport(1),'autorouting','on');
  % dina <- data_delay3b
  add_line(M, PH('data_delay3b').Outport(1), PH('Dual Port RAM2').Inport(2),'autorouting','on');
  % wea <- valid_delay4
  add_line(M, PH('valid_delay4').Outport(1), PH('Dual Port RAM2').Inport(3),'autorouting','on');
  % addrb <- Counter5
  add_line(M, PH('Counter5').Outport(1), PH('Dual Port RAM2').Inport(4),'autorouting','on');
  % dinb,web <- copies of Constant10, Constant7 (the DPRAM1 dinb/web consts)
  add_block(B('Constant10'), B('Constant10b'),'Position',[4350 1850 4380 1870],'MakeNameUnique','on');
  add_block(B('Constant7'),  B('Constant7b'), 'Position',[4350 1890 4380 1910],'MakeNameUnique','on');
  add_line(M, PH('Constant10b').Outport(1), PH('Dual Port RAM2').Inport(5),'autorouting','on');
  add_line(M, PH('Constant7b').Outport(1),  PH('Dual Port RAM2').Inport(6),'autorouting','on');

  % ---------- 4. elemctr = mod-2 read-pass parity (toggle on gb_eofand) ----------
  add_block(B('seqctr'), B('elemctr'),'Position',[2700 4680 2750 4720],'MakeNameUnique','on');
  % seqctr is Free Running Up; make elemctr count 0..1 (mod 2). set cnt_to=1, cnt_type Free Running, width small.
  set_param(B('elemctr'),'cnt_type','Free Running','cnt_to','1','operation','Up','start_count','0', ...
            'n_bits','1','arith_type','Unsigned','bin_pt','0','rst','on','en','on');
  % en = gb_eofand (1 pulse/packet), rst = same as seqctr (cnt_rst). Reuse seq_rst_from copy.
  add_block(B('seq_rst_from'), B('elem_rst_from'),'Position',[2600 4660 2660 4675],'MakeNameUnique','on');
  add_line(M, PH('elem_rst_from').Outport(1), PH('elemctr').Inport(1),'autorouting','on');  % rst
  add_line(M, PH('gb_eofand').Outport(1),     PH('elemctr').Inport(2),'autorouting','on');  % en
  % NOTE: elemctr LSB toggles each packet: packet0 elem=0(DPRAM0), packet1 elem=1(DPRAM1)

  % ---------- 5. read-select mux: pick DPRAM1.B (elem0) or DPRAM2.B (elem1) into Delay4 ----------
  % Delay4 currently <- From17 <- Goto(tx_data_inp) <- data_delay1 <- DPRAM1.B
  % Build a 2:1 Mux selected by elemctr feeding the SAME read tap. Simplest: mux DPRAM1.B vs DPRAM2.B
  %   right at the read, before data_delay1.  data_delay1 in <- DPRAM1.B(port2). Re-tap.
  add_block('xbsIndex_r4/Mux', B('rd_sel_mux'),'Position',[4640 1640 4670 1760],'MakeNameUnique','on');
  set_param(B('rd_sel_mux'),'inputs','2','en','off','latency','0');
  % delete existing line DPRAM1.B -> data_delay1
  ln = get_param(B('data_delay1'),'LineHandles');
  if ln.Inport(1) > 0, delete_line(ln.Inport(1)); end
  % mux: sel=elemctr, d0=DPRAM1.B, d1=DPRAM2.B
  add_line(M, PH('elemctr').Outport(1),         PH('rd_sel_mux').Inport(1),'autorouting','on');  % sel
  add_line(M, PH('Dual Port RAM1').Outport(2),  PH('rd_sel_mux').Inport(2),'autorouting','on');  % d0 elem0
  add_line(M, PH('Dual Port RAM2').Outport(2),  PH('rd_sel_mux').Inport(3),'autorouting','on');  % d1 elem1
  add_line(M, PH('rd_sel_mux').Outport(1),      PH('data_delay1').Inport(1),'autorouting','on');

  save_system(M);
  fprintf('=== EDIT_OK, compiling ===\n');
  feval(M,[],[],[],'compile');
  fprintf('COMPILE_OK\n');
  for nm={'rd_sel_mux','Delay4','gb_mux512','Dual Port RAM1','Dual Port RAM2','bus_create2','elemctr'}
    h=find_system(M,'SearchDepth',1,'Name',nm{1}); if isempty(h), continue; end
    b=[M '/' nm{1}];
    try dt=get_param(b,'CompiledPortDataTypes'); st=get_param(b,'CompiledSampleTime');
      stst = ''; if isnumeric(st), stst=mat2str(st); else, stst='(nonnum)'; end
      fprintf('  %s IN=%s OUT=%s ST=%s\n', nm{1}, strjoin(string(dt.Inport),','), strjoin(string(dt.Outport),','), stst);
    catch e, fprintf('  %s ST-ERR %s\n', nm{1}, e.message); end
  end
  feval(M,[],[],[],'term');
  save_system(M);
  fprintf('=== A2STEP1_DONE ===\n');
catch e
  disp('MATLAB_ERROR:'); disp(getReport(e));
  try, feval('manas2el',[],[],[],'term'); catch, end
end
bdclose('all'); disp('MY_DONE');
