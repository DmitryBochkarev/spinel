# Regression for the poly-slot bound-Method return kinds (#4395 review
# follow-up).
#
# A bound Method read out of a poly slot used to be callable only when its
# target returned an sp_int-register value. A String-returning method, a
# nil-returning method (whose C return is `void`), and a reference-type object
# return all declined with NoMethodError even though CRuby answers them; a
# plain `def s` returns `const char *` just like the synthesized wrapper, so it
# is boxed by the String kind too, and a Bigint return is a nullable
# `sp_Bigint *` riding the register. The typed-array adapter's statically
# dispatched `.call` handed the raw sp_int register back as an Integer instead
# of casting it to the array/string it really is, and its `.arity` was nil. A
# splatted call on a bound Method in a poly slot read the Method as an sp_Proc
# and segfaulted; the spread now dispatches on the value's class.
#
# Every printed line is CRuby-equal; the snapshot comes from reference Ruby.

class Ret
  def str(a) = a > 0 ? "pos" : "neg"
  def nul = nil
  def sum2(a, b) = a + b
end

# String return through the poly `.call`/`[]` paths and the generic trampoline
r = Ret.new
sslot = [r.method(:str)]
puts sslot[0].call(1)
puts sslot[0].call(-1)
puts sslot[0][2]
puts sslot[0].to_proc.call(1)

# nil return (the target's C return is void)
nslot = [r.method(:nul)]
puts nslot[0].call.inspect
puts nslot[0].to_proc.call.inspect

# reference-type object return: a subclass makes the class a heap reference
class ObjBase
  def initialize = @v = 5
  def v = @v
end
class ObjSub < ObjBase; end
class ObjMaker
  def make = ObjSub.new
end
oslot = [ObjMaker.new.method(:make)]
puts oslot[0].call.class
puts oslot[0].call.v
puts oslot[0].to_proc.call.class

# arbitrary-precision integer return (an sp_Bigint *)
# (the argument keeps the `.call`/`[]`/`.to_proc` arities uniform)
class BigRet
  def big(n) = 2 ** 100 + n
end
bslot = [BigRet.new.method(:big)]
puts bslot[0].call(0)
puts bslot[0].call(0).to_s.length
puts bslot[0][0]
puts bslot[0].to_proc.call(0)

# typed-array adapter static `.call`: the raw sp_int register is cast back to
# the array/string it really is, and the adapter reports CRuby's arity
ia = [1, 2]
puts ia.method(:push).call(3).inspect
puts ia.inspect
puts ia.method(:[]=).call(0, 7).inspect
puts ia.inspect
puts ia.method(:[]).call(1).inspect
puts ia.method(:[]).call(9).inspect
puts ia.method(:push).arity
puts ia.method(:[]=).arity
puts ia.method(:[]).arity
sa = ["x"]
puts sa.method(:push).call("y").inspect
puts sa.inspect
puts sa.method(:[]=).call(0, "z").inspect
puts sa.inspect
puts sa.method(:[]).call(0).inspect
puts sa.method(:[]).call(9).inspect
puts sa.method(:push).arity
puts sa.method(:[]=).arity
puts sa.method(:[]).arity
# the same adapter read back out of a poly slot also reports its arity
pslot = [sa.method(:push)]
puts pslot[0].call("w").inspect
puts pslot[0].arity.inspect

# static adapter `.call` with a runtime splat: the argument count is dynamic,
# so the adapter expands it against its fixed arity and launders each element
# (previously the splat was passed as one sp_int argument, which emitted an
# `sp_int = sp_PolyArray *` initializer and did not compile)
ia2 = [1, 2]
ia2_args = [3]
puts ia2.method(:push).call(*ia2_args).inspect
puts ia2.inspect
ia2_set = [0, 7]
puts ia2.method(:[]=).call(*ia2_set).inspect
puts ia2.inspect
sa2 = ["x"]
sa2_args = ["y"]
puts sa2.method(:push).call(*sa2_args).inspect
puts sa2.inspect
sa2_set = [0, "z"]
puts sa2.method(:[]=).call(*sa2_set).inspect
puts sa2.inspect
puts sa2.method(:[]).call(*[0]).inspect

# `Array#push` is variadic: the fixed-arity adapter must be invoked once per
# value (a single call silently dropped every value after the first)
ia3 = [1, 2]
puts ia3.method(:push).call(3, 4).inspect
puts ia3.inspect
ia4 = [1, 2]
puts ia4.method(:push).call(*[3, 4]).inspect
puts ia4.inspect
ia5 = [1, 2]
puts ia5.method(:push).call(*[3], 5).inspect
puts ia5.inspect
sa3 = ["x"]
puts sa3.method(:push).call("y", "z").inspect
puts sa3.inspect
sa4 = ["x"]
puts sa4.method(:push).call(*["y", "z"]).inspect
puts sa4.inspect

# splat on a bound Method in a poly slot: the argument count is only known at
# run time, so the spread dispatches on the value's class (a Method through
# the generic trampoline, not cast to an sp_Proc)
def top_add2(a, b) = a + b
r2 = Ret.new
tslot = [r2.method(:sum2), method(:top_add2)]
argsv = [1, 2]
puts tslot[0].call(*argsv)
puts tslot[1].call(*argsv)
puts tslot[0][*argsv]
puts tslot[1].to_proc.call(*argsv)

# A trailing runtime splat into a statically-bound fixed-arity Method now
# validates the run-time count (CRuby's ArgumentError) and fills a literal
# optional default for a short splat instead of reading past the array.
class OptSplat
  def two(a, b) = a + b
  def opt(a, b = 10) = a + b
end
op = OptSplat.new
puts op.method(:opt).call(*[1])
puts op.method(:opt).call(*[1, 2])
begin
  op.method(:two).call(*[1])
rescue => e
  puts "short: #{e.class}"
end
begin
  op.method(:two).call(*[1, 2, 3])
rescue => e
  puts "long: #{e.class}"
end
