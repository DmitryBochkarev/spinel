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
#
# Not exercised here, because it is a separate defect and still open: two call
# sites whose blocks answer DIFFERENT types. A yielding method whose tail is a
# begin/ensure has its return type pinned by the first call site, so a second
# call reads the first one's slot. Minimal:
#   def run; begin; yield 7; ensure; nil; end; end
#   p run { |x| x == 7 }   #=> true
#   p run { |x| x * 3 }    #=> true, where CRuby says 21
# The same shape without the ensure is already right, which is what says the
# ensure path is where the type gets pinned.
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
