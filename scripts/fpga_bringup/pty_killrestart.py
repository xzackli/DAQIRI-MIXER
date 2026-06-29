import os, pty, time, select
def ssh_pw(user, pw, cmd, wait=30):
    argv=['ssh','-tt','-o','StrictHostKeyChecking=no','-o','PreferredAuthentications=password',
          '-o','ConnectTimeout=8','-o','NumberOfPasswordPrompts=1','%s@192.168.2.101'%user, cmd]
    pid, fd = os.forkpty()
    if pid==0: os.execvp('ssh', argv); os._exit(1)
    out=b''; sent=False; t0=time.time()
    while time.time()-t0 < wait:
        try: r,_,_=select.select([fd],[],[],1)
        except OSError: break
        if r:
            try: data=os.read(fd,2048)
            except OSError: break
            if not data: break
            out+=data
            if b'assword:' in out and not sent and b'[sudo]' not in out:
                os.write(fd,(pw+'\n').encode()); sent=True
    try: os.waitpid(pid,0)
    except OSError: pass
    return out.decode('latin1','ignore')
cmd=("echo casper | sudo -S pkill -9 tcpborphserver3 2>/dev/null; sleep 2; "
     "echo casper | sudo -S systemctl restart tcpborphserver 2>&1; sleep 4; "
     "echo NEWPID=$(pgrep tcpborphserver3); ss -ltn 2>/dev/null | grep 7147 || echo no7147")
print(ssh_pw('casper','casper',cmd)[-400:])
