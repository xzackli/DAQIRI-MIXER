% insp_c5.m — Counter5 + pulse_ext internals: exact ranges to judge the 2-pass feasibility
try
  DIR='/home/zackli/src/tutorials_devel/rfsoc/tut_onehundred_gbe'; M='manas2el';
  load_system([DIR '/' M '.slx']);
  for nm={'Counter5','gb_modctr','gb_wctr','Counter3'}
    b=[M '/' nm{1}];
    fprintf('=== %s full mask ===\n', nm{1});
    mn=get_param(b,'MaskNames'); mv=get_param(b,'MaskValues');
    for k=1:numel(mn), fprintf('   %s = %s\n', mn{k}, mv{k}); end
  end
  % pulse_ext4 internal Counter3 + Relational (what sets the window length & range)
  fprintf('\n=== pulse_ext4/Counter3 mask ===\n');
  b=[M '/pulse_ext4/Counter3']; mn=get_param(b,'MaskNames'); mv=get_param(b,'MaskValues');
  for k=1:numel(mn), fprintf('   %s = %s\n', mn{k}, mv{k}); end
  fprintf('=== pulse_ext4/Relational5 mask ===\n');
  b=[M '/pulse_ext4/Relational5']; mn=get_param(b,'MaskNames'); mv=get_param(b,'MaskValues');
  for k=1:numel(mn), fprintf('   %s = %s\n', mn{k}, mv{k}); end
  fprintf('=== pulse_ext4/Constant5 mask ===\n');
  b=[M '/pulse_ext4/Constant5']; mn=get_param(b,'MaskNames'); mv=get_param(b,'MaskValues');
  for k=1:numel(mn), fprintf('   %s = %s\n', mn{k}, mv{k}); end
  % compiled width of Counter5 output (addr width into DPRAM addrb)
  feval(M,[],[],[],'compile');
  for nm={'Counter5','gb_modctr','gb_wctr'}
    b=[M '/' nm{1}]; dt=get_param(b,'CompiledPortDataTypes');
    fprintf('  %s OUT=%s\n', nm{1}, strjoin(string(dt.Outport),','));
  end
  feval(M,[],[],[],'term');
  disp('=== C5_DONE ===');
catch e
  disp('MATLAB_ERROR:'); disp(getReport(e));
  try, feval('manas2el',[],[],[],'term'); catch, end
end
bdclose('all'); disp('MY_DONE');
