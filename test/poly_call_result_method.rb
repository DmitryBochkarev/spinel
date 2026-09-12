# Regression (#4395): a poly `.call` result is typed poly (the slot may hold a
# Proc, whose return is dynamic), so `o.method(:sym)` on that result can no
# longer resolve a concrete target. Before the poly `.call` result was typed
# dynamic, the receiver kept the user `call` method's return type and the bind
# resolved; that was unsound when the slot held a Proc, and the dynamic type
# made the bind's `(void *)(<poly expr>)` self slot fail to compile
# ("cannot convert to a pointer type"). A poly receiver has never had a
# callable address to bind, so the bind now raises CRuby's NoMethodError
# instead of failing the C build. A concrete receiver still binds and calls.
#
# The snapshot is hand-written: the poly case diverges from CRuby only by
# raising (a documented limitation), so it cannot come from reference Ruby.

class Obj
  def foo(x) = x + 1
end

class Number
  def call = Obj.new
end

slots = [Number.new]
o = slots[0].call
begin
  m = o.method(:foo)
  puts m.call(5)
rescue NoMethodError => e
  puts "poly_bind: #{e.class}"
end

# A concrete receiver keeps working.
o2 = Obj.new
m2 = o2.method(:foo)
puts m2.call(5)

# A poly class value: the same decline, not a broken build.
kclass = [Obj, nil][0]
begin
  kclass.method(:new)
  puts "poly_class_bind: no raise"
rescue NoMethodError
  puts "poly_class_bind: NoMethodError"
end
