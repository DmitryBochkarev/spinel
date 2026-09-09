# SPINEL_GC_OBJ_BUDGET=walk prices the object collection budget off everything
# a mark walks -- objects plus strings -- instead of the object heap alone.
# Single-threaded on purpose: the pool-wide floor (256 KB x workers) is what
# the budget has to clear before the retune is visible at all, and with one
# worker that floor is 256 KB rather than megabytes. It also takes the worker
# count out of the numbers, which is what made a threaded version of this
# check compare two different moments and flake.
held = []
20000.times { |i| held << ("held-" * 40 + i.to_s) }

total = 0
4000.times do |k|
  a = []
  40.times { |i| a << [i, i + 1] }
  total += a.length
end
puts "#{total} #{held.length}"
