# The message for a constant path defined nowhere names the path AS WRITTEN.
# It used to name the last two components only -- the arms that resolve a
# qualified constant key on the parent's LEAF name (the ffi and platform
# tables are built that way), and the message reused it. So a program that
# wrote `OpenSSL::SSL::VERIFY_NONE` was told about `SSL::VERIFY_NONE`, a
# string that occurs nowhere in it, which is what the reader greps for.
#
# The expectation is NOT CRuby's: CRuby names the FIRST component that failed
# to resolve ("uninitialized constant A"), because it walks the path at run
# time and stops where it stops. spinel resolves the whole path at build time
# and has no such stopping point, so it names what was written. The same
# divergence is already pinned by const_path_unresolved_require.rb.
begin
  p A::B::C::D
rescue NameError => e
  puts e.message
end

begin
  p Foo::Bar::BAZ
rescue NameError => e
  puts e.message
end

# Object is still dropped: its constants are the top-level ones.
begin
  p Object::AlsoMissing
rescue NameError => e
  puts e.message
end
puts "after"
