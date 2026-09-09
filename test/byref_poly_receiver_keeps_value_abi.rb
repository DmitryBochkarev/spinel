# A POLY receiver reaches a method through the cls_id switch, and that switch
# hoists its arguments once -- by the argument's own type, for every arm to
# share. It has no callee to ask, so it passes the value where a byref arm
# wants the slot, and the C build stops with
#   expected 'const char **' but argument is of type 'const char *'
#
# The old uniqueness rule hid this by accident: two classes defining one name
# was exactly what it refused, and a poly dispatch needs two. Making the group
# agree (df30ed28) removed the accident and left the dispatch unable to call
# what it now agreed about. So a name a poly receiver can reach keeps the
# value ABI, which is what it had before.
#
# The answer below is therefore NOT CRuby's -- CRuby prints "pf1;f2;". That is
# the same data-dependent hole the docs' aliasing promise still covers, and it
# is the design question, not this. What this pins is that the program BUILDS.
def frag_into(io, n)
  io << "f#{n};"
  nil
end

class A
  def go(b)
    frag_into(b, 1)
  end
end

class B
  def go(b)
    frag_into(b, 2)
  end
end

list = [A.new, B.new]
buf = String.new("p")
list.each { |o| o.go(buf) }
p buf

# a statically resolved call to the same shape still takes the ABI
def wrap_into(io)
  frag_into(io, 9)
  nil
end
direct = String.new("d")
wrap_into(direct)
p direct
