def square(x) = x * x
arr = [method(:square)]
m = arr[0]
p m.call(9)
p m.arity
h = { sq: method(:square) }
p h[:sq].call(6)
def g(a, *b) = a
gm = [method(:g)][0]
p gm.arity
# A rest parameter cannot ride the legacy sp_int poly-call cast: the callee's
# trailing rest array has no slot in the cast, and the prologue roots the
# garbage register it would receive. The poly path therefore declines with
# NoMethodError (see poly_call_legacy_abi_gate.rb) instead of returning a.
begin
  p gm.call(1, 2, 3)
rescue NoMethodError
  puts "rest Method call declined"
end
class C
  def dbl(x) = x + x
end
cm = [C.new.method(:dbl)][0]
p cm.call(21)
