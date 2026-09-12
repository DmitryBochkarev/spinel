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

# The count guards raise CRuby's ArgumentError (both engines); record the
# class so a silently-dropped or zero-filled argument shows up as ": no raise".
def expect_raise(label)
  yield
  puts "#{label}: no raise"
rescue => e
  puts "#{label}: #{e.class}"
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

# A typed-array adapter Method reports the CRuby arity of the Array op it
# stands in for (-1), not a nil placeholder (#4395).
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

# A splatted Method call wider than the 16-slot proc ABI declines rather than
# truncating to the first 16 arguments: the spread helper has no register for
# the surplus, and CRuby itself raises ArgumentError for the identical count.
class Wide
  def m16(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
    a1 + a16
  end
end
wide_args = (1..20).to_a
expect_nome("splat_over") { [Wide.new.method(:m16)][0].call(*wide_args) }
# ... and the same through the Method#to_proc wrapper: the generic trampoline
# must see the overlong count, not a clamped 16, or it silently truncates.
expect_nome("toproc_splat_over") { [Wide.new.method(:m16)][0].to_proc.call(*wide_args) }

# A pointer argument to a scalar (int-inferred) parameter declines on both the
# static and the spread path: the generic Method trampoline has only the raw
# sp_int slots and would otherwise read the String pointer as an Integer.
class ScalarArg
  def add1(x) = x + 1
end
puts ScalarArg.new.add1(5)
expect_nome("ptr_arg")   { [ScalarArg.new.method(:add1)][0].call("s") }
ptr_args = ["s"]
expect_nome("ptr_splat") { [ScalarArg.new.method(:add1)][0].call(*ptr_args) }

# A rest parameter reached by a trailing runtime splat declines on the static
# bound-Method path too: the splat's surplus would land in the trailing
# sp_PolyArray* slot as an sp_int and the callee prologue would root it.
rest_runtime_args = [1, 2, 3]
expect_nome("rest_splat_static") { Base.new.method(:rest_unused).call(*rest_runtime_args) }

# A statically-bound fixed-arity Method given a runtime splat must validate
# the run-time count: previously a short splat filled the missing slots and a
# long one dropped the surplus.
expect_raise("static_splat_short") { Base.new.method(:two_args).call(*[1]) }
expect_raise("static_splat_long")  { Base.new.method(:two_args).call(*[1, 2, 3]) }
expect_raise("static_call_over")   { Wide.new.method(:m16).call(*wide_args) }
expect_raise("static_toproc_over") { Wide.new.method(:m16).to_proc.call(*wide_args) }

# A parameter default that reads an earlier parameter is evaluated at the call
# site; the bound-Method path must alias the earlier argument so `a` resolves
# (it used to emit the callee's `lv_a`, a C compile failure).
class RefDefault
  def m(a, b = a + 5) = [a, b]
end
puts RefDefault.new.method(:m).call(1).inspect
ref_arg = [1]
puts RefDefault.new.method(:m).call(*ref_arg).inspect

# A typed-array adapter's synthesized C function has a fixed parameter count:
# supplying fewer leaves its later parameters reading an undefined register
# (a garbage element written into the array) where CRuby raises ArgumentError.
adapt = [1, 2]
expect_raise("adapter_set_short")  { adapt.method(:[]=).call(0) }
expect_raise("adapter_set_splat")  { adapt.method(:[]=).call(*[0]) }
empty_args = []
expect_raise("adapter_set_empty")  { adapt.method(:[]=).call(*empty_args) }
sadapt = ["x"]
expect_raise("sadapter_set_short") { sadapt.method(:[]=).call(0) }

# A rest target whose optionals before the rest are omitted cannot be expanded
# into the fixed cast (the omitted registers and the rest pointer are never
# passed): decline like the poly-slot route instead of calling out of bounds.
class RestOpt
  def m(a, b = 2, *r) = a + b
end
expect_nome("rest_opt_short") { RestOpt.new.method(:m).call(1) }
puts RestOpt.new.method(:m).call(1, 9).inspect
