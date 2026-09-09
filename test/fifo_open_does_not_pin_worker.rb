# `File.open` on a FIFO waits in the kernel for the other end, with no
# descriptor to wait on. A green thread is pinned to its OS worker, so that one
# syscall stalled every green thread pinned there, including the one counting a
# Thread#join timeout down: the first arm here printed nothing at all before
# the fix, not even the join's answer, and the process never terminated (#4394).
#
# Every arm is a shape whose answer the blocking open could not produce. The
# regular-file arm is the control: it does not go through the FIFO path at all
# and has to read exactly as it always did.

dir = "/tmp/sp_fifo_test_#{Process.pid}"
Dir.mkdir(dir)

def mkfifo(path)
  system("mkfifo #{path}") or raise "mkfifo failed"
  path
end

# --- 1. a reader with no writer: the join times out and the program ends ---

lonely = mkfifo(File.join(dir, "lonely"))
reader = Thread.new do
  File.open(lonely, "r") { |f| f.each_line { |l| l } }
end
sleep 0.1
puts "join #{reader.join(0.3).inspect}"
puts "status #{reader.status.inspect}"

# --- 2. a reader and a writer pass lines through: the bytes still arrive ---

pipe = mkfifo(File.join(dir, "pipe"))
got = []
rd = Thread.new do
  File.open(pipe, "r") { |f| f.each_line { |l| got << l.chomp } }
end
wr = Thread.new do
  File.open(pipe, "w") { |f| 3.times { |i| f.puts "line#{i}" } }
end
wr.join
rd.join
puts "read #{got.inspect}"

# --- 3. the writer opens FIRST, with no reader yet: it waits this side of
#        the kernel and the reader that arrives later unblocks it ---

early = mkfifo(File.join(dir, "early"))
w2 = Thread.new do
  File.open(early, "w") { |f| f.puts "late reader" }
end
sleep 0.1
line = nil
r2 = Thread.new do
  File.open(early, "r") { |f| line = f.gets }
end
w2.join
r2.join
puts "late #{line.to_s.chomp.inspect}"

# --- 4. control: a regular file is not a FIFO and opens as it always did ---

plain = File.join(dir, "plain.txt")
File.write(plain, "ordinary\n")
puts "plain #{File.read(plain).chomp.inspect}"
puts "missing #{begin; File.open(File.join(dir, "absent")); "no raise"; rescue => e; e.class.to_s; end}"

[lonely, pipe, early, plain].each { |p| File.delete(p) rescue nil }
Dir.rmdir(dir) rescue nil
puts "end"
