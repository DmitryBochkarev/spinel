# Regression: the NO-user-`call` poly `.call` fast path and the poly `[]`
# runtime arms must apply the same per-position legacy sp_int ABI gate as the
# shadowed pre-arm. This file deliberately defines no user class `call`, so
# the fast path in emit_call_body is selected -- poly_call_legacy_abi_gate.rb
# covers the user-`call` pre-arm.
#
# The gate must not be all-or-nothing: a mixed int+pointer target is callable
# when each argument class matches its parameter (the call site knows each
# argument's class, the target stamps a per-position type signature, so a
# String parameter does not accept an IntArray). An
# attr/Struct accessor Method's synthesized __bam_ wrapper carries its bound
# receiver in the leading self slot, so that receiver must not be counted as a
# positional parameter. A StrArray adapter launders its String element through
# the sp_int slot and is stamped with the pointer class at that position. A
# signature/arity mismatch declines (NoMethodError) rather than reading the
# wrong C type. A top-level Method has no self, so the `[]` arms must call it
# self-less. A rest parameter ALWAYS declines on both paths: the callee
# signature's trailing sp_PolyArray* has no slot in the static cast, and the
# prologue roots the garbage register it would receive (see
# poly_call_legacy_abi_gate.rb and issue_3231.rb).
#
# The snapshot is hand-written: the declining cases diverge from CRuby only by
# raising (a documented limitation), so it cannot come from reference Ruby.

def expect_nome(label)
  yield
  puts "#{label}: no raise"
rescue NoMethodError
  puts "#{label}: NoMethodError"
end

class Base
  def mixed(i, s) = i + s.length
  def str_method(s) = s.length
  def iarr_method(a) = a.length
  def opt(a, b = 10) = a + b
  def two_args(a, b) = a + b
  def three_args(a, b, c) = a + b + c
  # A crash regression (see the corresponding case in the legacy gate): the
  # fast path must decline before this allocating body runs.
  def rest_unused(a, *r)
    x = "abc"
    i = 0
    while i < 100_000
      y = [x, x, x]
      i += y.length
    end
    a
  end
  def rest_anon(a, *) = a
  def self.cmethod(a) = self.name.length + a
end

# A descendant makes the class method's C signature lead with its receiving
# class (cmethod_takes_self_cls), which the legacy cast cannot supply.
class Derived < Base; end

# Seed the pointer parameter so the emitted signature is sp_String *; without
# a call site the analyzer leaves `s` untyped (sp_int), which is a different,
# already-declined case.
Base.new.str_method("seed")
Base.new.mixed(0, "seed")
Base.new.iarr_method([1, 2, 3])

# mixed int+pointer: each call argument class matches its parameter
puts [Base.new.method(:mixed)][0].call(2, "b")
# all-pointer target
puts [Base.new.method(:str_method)][0].call("hello")
# arity mismatch declines
expect_nome("arity") { [Base.new.method(:two_args)][0].call(1) }
# a rest parameter always declines (crash regression above)
expect_nome("rest_unused") { [Base.new.method(:rest_unused)][0].call(1, 2, 3) }
expect_nome("rest_anon")   { [Base.new.method(:rest_anon)][0].call(1, 2, 3) }
expect_nome("rest_aref")   { [Base.new.method(:rest_unused)][0][5] }
expect_nome("rest_slice")  { [Base.new.method(:rest_unused)][0][1, 2] }
# a class method whose C signature needs its receiving class declines
expect_nome("cmethod") { [Base.method(:cmethod)][0].call(5) }

class C
  attr_accessor :x
  def initialize = @x = 5
end
c = C.new
puts [c.method(:x)][0].call
puts [c.method(:x=)][0].call(7)
puts c.x

S = Struct.new(:a, :b)
s = S.new(1, 5)
puts [s.method(:a)][0].call
puts [s.method(:b=)][0].call(9)
puts s.b

# A typed-array adapter's Ruby return must be boxed by its recorded kind, not
# mis-tagged as an Integer: push answers the array, StrArray []= the string.
a = ["x"]
puts [a.method(:push)][0].call("y").inspect
puts a.inspect
puts [a.method(:[]=)][0].call(0, "z").inspect
puts a.inspect
ia = [1, 2]
puts [ia.method(:push)][0].call(3).inspect
puts ia.inspect

# A StrArray `[]` wrapper returns a String through the sp_int register; the
# stamped String return kind boxes it (an out-of-range read answers nil).
sg = ["x", "z"]
puts [sg.method(:[])][0].call(0)
puts [sg.method(:[])][0].call(9).inspect

# The `[]` slice/index arms must honour the stamped arity too
expect_nome("slice_arity") { [Base.new.method(:three_args)][0][3, 4] }
expect_nome("index_arity") { [Base.new.method(:two_args)][0][5] }

# The pointer positions must agree by type, not merely by pointer-ness.
expect_nome("ptr_mismatch")  { [Base.new.method(:str_method)][0].call([1, 2, 3]) }
expect_nome("ptr_mismatch2") { [Base.new.method(:iarr_method)][0].call("hello") }

# An UnboundMethod read out of a container is not callable.
um = Base.new.method(:two_args).unbind
umslot = [um]
expect_nome("unbound_call")  { umslot[0].call(1, 2) }
expect_nome("unbound_aref")  { umslot[0][5] }

# An optional parameter is callable at full arity only.
puts [Base.new.method(:opt)][0].call(1, 2)
puts [Base.new.method(:opt)][0][3, 4]
expect_nome("optional_short") { [Base.new.method(:opt)][0].call(1) }

# A typed-array adapter Method must report no stamped arity (#4395).
pa = ["x"].method(:push)
pslot = [pa]
puts "adapter_arity: #{pslot[0].arity.inspect}"

# A self-less top-level Method must be called without a self argument
def top_add(a, b) = a + b
def top_one(a) = a + 1
puts [method(:top_add)][0][1, 2]
puts [method(:top_one)][0][5]

# `@table[i][j]` dispatch table narrowed to int
class Table
  def initialize
    @ops = [method(:top_one)]
  end
  def run(i, j) = @ops[i][j]
end
puts Table.new.run(0, 5)
