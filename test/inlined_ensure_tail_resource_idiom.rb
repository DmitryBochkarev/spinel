# The resource idiom: a class method that builds an object, hands it to a
# block, and closes it in an ensure. Two things about it were wrong when the
# method was inlined at its call site.
#
# 1. A value-type class's local was declared `sp_Handle lv_h = NULL;` -- the
#    shared initial-value helper answered the blanket NULL for every object
#    type, where declare_local has always had a value-object arm. C rejects
#    that initializer and the build stopped.
# 2. The `return` the ensure defers came back as a raw C `return` from the
#    CALLER's function -- an sp_RbVal returned out of `main`. It has to funnel
#    through the inline exit, the one every return at ensure-depth zero
#    already takes.
# 3. Two call sites whose blocks answered DIFFERENT types read the first
#    site's slot: the ensure frame carries the value in a slot of its own and
#    that slot settled at the first site analyzed. The rule that already
#    widens a diverging yield to poly covered the yield written to a local;
#    a yield leaving through an ensure is the same position one frame in.
class Handle
  def self.open(name)
    h = new(name)
    return h unless block_given?
    begin
      yield h
    ensure
      h.close
    end
  end

  def initialize(name)
    @name = name
    @closed = false
  end

  def name
    @name
  end

  def close
    @closed = true
    nil
  end

  def closed?
    @closed
  end
end

p Handle.open("a") { |h| h.name }
p Handle.open("b") { |h| h.name.upcase }

# Blocks of different types at different call sites of the same method.
p Handle.open("c") { |h| h.name.length }
p Handle.open("d") { |h| h.closed? }

# The blockless form still answers the object, and the ensure did not run.
h = Handle.open("e")
p h.name
p h.closed?

# The ensure runs on the way out, including when the block raises.
seen = nil
begin
  Handle.open("f") do |x|
    seen = x
    raise "boom"
  end
rescue RuntimeError => e
  puts e.message
end
p seen.closed?

# NOT here, and it did not work before this change either: a non-local
# `return` from inside the block AT ONE SITE while ANOTHER site of the same
# method answers a different type. The two together still fail to build.
# Loudly, which is the difference that matters -- the wrong-value case above
# is the one that used to pass silently.
