import json,os,pty,subprocess,termios,time,select,fcntl,struct,tempfile,signal
import sys
binary=os.path.abspath(sys.argv[1]) if len(sys.argv)>1 else os.path.abspath('.build/debug/midnight-studio')
with tempfile.TemporaryDirectory(prefix='studio-smoke-') as root:
 for stop in (b'q',b'\x03'):
  master,slave=pty.openpty();before=termios.tcgetattr(slave)
  fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,100,0,0))
  proc=subprocess.Popen([binary,'--model-root',root,'--state-directory',root],stdin=slave,stdout=slave,stderr=slave,env={**os.environ,'TERM':'xterm-256color'})
  out=b'';deadline=time.monotonic()+10
  while b'midnight studio' not in out and time.monotonic()<deadline:
   if select.select([master],[],[],.1)[0]:out+=os.read(master,65536)
  assert b'midnight studio' in out, out.decode(errors='replace')
  fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',5,20,0,0));os.kill(proc.pid,signal.SIGWINCH)
  os.write(master,b'\x1b[B\x1b[A');time.sleep(.1);os.write(master,stop)
  deadline=time.monotonic()+10
  while proc.poll() is None and time.monotonic()<deadline:
   if select.select([master],[],[],.1)[0]:out+=os.read(master,65536)
  if proc.poll() is None:
   proc.kill(); raise RuntimeError("Studio did not exit")
  while select.select([master],[],[],.1)[0]:out+=os.read(master,65536)
  assert proc.returncode==0,proc.returncode
  assert b'\x1b[?1049l' in out,'alternate screen not restored'
  assert termios.tcgetattr(slave)==before,'terminal attributes not restored'
  os.close(master);os.close(slave)
  print('PTY smoke passed:', 'quit' if stop==b'q' else 'Ctrl-C')
 plain=subprocess.run([binary,'models','--model-root',root,'--state-directory',root],capture_output=True,check=True)
 assert json.loads(plain.stdout)==[],plain.stdout
 assert b'\x1b' not in plain.stdout
 print('JSON catalog command passed')
