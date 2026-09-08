# A program that never exits, which is the case the atexit dump cannot serve:
# a server is killed rather than returned from. The Makefile signals this one
# twice and then kills it with SIGKILL, so a report that exists at the end can
# only have come from a signal -- atexit never ran.
i = 0
total = 0
while true
  s = "item-#{i}"
  a = [s, s]
  total += s.length + a.length
  i += 1
end
