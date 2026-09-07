# A string handed to a method and RETAINED in an ivar that is mutated in place
# has to stay the caller's string. The byref machinery only covered a callee
# that mutates the PARAMETER itself; one that merely stores it and mutates it
# later, through the ivar, left the caller holding a value copy and the two
# drifted apart (#4363). Both directions matter: the callee's mutation must
# reach the caller's name, and the caller's must reach the ivar.

class Holder
  attr_reader :bt
  def initialize(bt)
    @bt = bt
  end
  def bump
    @bt << "!"
  end
end

a = +"aaa"
h = Holder.new(a)
h.bump
p [h.bt, a]
a << "?"
p [h.bt, a]

# the same through a plain method rather than the constructor
class Sink
  attr_reader :s
  def initialize
    @s = +""
  end
  def take(x)
    @s = x
  end
  def bump
    @s << "!"
  end
end

b = +"bbb"
k = Sink.new
k.take(b)
k.bump
p [k.s, b]
b << "?"
p [k.s, b]

# a fresh string with no caller alias still works, and stays independent
g = Holder.new(+"ggg")
g.bump
p g.bt

# two holders over the same string see each other
c = +"ccc"
h1 = Holder.new(c)
h2 = Holder.new(c)
h1.bump
p [h1.bt, h2.bt, c]

# The mutators whose names are Array's and Hash's as much as String's --
# `[]=`, `insert`, `slice!`, `setbyte` -- are in-place once the slot's type
# says String, and the shim emits them on the handle. Statement position and
# expression position (a method's last expression) go through different
# emitters, so both are exercised.
class Edits
  attr_reader :bt
  def initialize(bt)
    @bt = bt
  end
  def splice
    @bt[0, 3] = "XYZ"
    nil
  end
  def ins
    @bt.insert(1, "-")
    nil
  end
  def sl
    @bt.slice!(0, 1)
    nil
  end
  def sb
    @bt.setbyte(0, 90)
    nil
  end
  def splice_tail
    @bt[0, 1] = "q"
  end
  def ins_tail
    @bt.insert(0, "w")
  end
end

d = +"aaaaaa"
e = Edits.new(d)
e.splice
p [e.bt, d]
e.ins
p [e.bt, d]
e.sl
p [e.bt, d]
e.sb
p [e.bt, d]
e.splice_tail
p [e.bt, d]
e.ins_tail
p [e.bt, d]
d << "="
p [e.bt, d]

# a reader in ARGUMENT position hands out the handle, not a safe copy, so the
# receiving holder and the source object keep one string between them
class Src
  attr_reader :bytes
  def initialize
    @bytes = +"src"
  end
end

s = Src.new
r = Holder.new(s.bytes)
r.bump
p [r.bt, s.bytes]

# The chain carries however deep it runs: a parameter passed on through
# another method before it is stored has to arrive as the handle too, or the
# name the outermost caller holds goes its own way.
class Keep
  attr_reader :s
  def initialize
    @s = +""
  end
  def hold(x)      # a name of its own: the callee is resolved by unique name,
    @s = x         # and `take` above already claims that one
  end
  def bump
    @s << "!"
  end
end

def hand_on(k, y)
  k.hold(y)
end

t = +"ttt"
kk = Keep.new
hand_on(kk, t)
kk.bump
p [kk.s, t]
t << "?"
p [kk.s, t]

# A slot mutated only from OUTSIDE its class records nothing in the mutation
# census, which keys on calls whose receiver is an ivar read. Being a shared
# handle already is evidence enough for the parameter written into it.
class Outside
  attr_reader :s
  def initialize(x)
    @s = x
  end
end

o = +"ooo"
w = Outside.new(o)
w.s << "!"
p [w.s, o]
o << "?"
p [w.s, o]

# Identity, not only visibility: two names for one shared string answer
# equal? true, read through a reader on either side. The mark that makes a
# reader hand out the handle is also how the node's type is read, and the
# emitters pick their arm from the receiver's type -- so the demand travels in
# its own array, and the receiver still dispatches as the String it is.
i = +"iii"
h3 = Holder.new(i)
h3.bump
p [h3.bt.equal?(i), i.equal?(h3.bt), h3.bt.equal?(h3.bt)]

# NOT covered, and left out on purpose: one parameter stored into TWO ivars
# where only one is mutated. The mutated slot becomes a handle; the other has
# no evidence of its own and stays a value, so the second name does not see the
# mutation. That needs "a handle assigned to an ivar makes that ivar a handle",
# which is a rule that does not exist yet.
