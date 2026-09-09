# What makes a mark more expensive: who ALLOCATED the graph, or who marks it?
#
# #4384 ends with a per-object trace cost that rises with the worker count over
# a graph that did not grow -- the root walk is 0.000 s at every worker count,
# so it is the trace itself. This program separates the two candidates. Both
# arms build the same graph and hold it live while every worker allocates
# garbage around it, so the collections that follow mark identical objects with
# an identical pool. Only the number of workers that laid the graph down
# differs:
#
#   LOCALITY_BUILD=1   one green thread allocates the whole graph
#   LOCALITY_BUILD=N   N green threads allocate 1/N of it each
#
# The answer, measured with ns/object = mark seconds / objects marked (Apple
# M-series, 6 performance cores, both budgets pinned, two passes per cell):
#
#   W     BUILD=1   BUILD=8
#   1      4.20      4.30      <- the control: 8 green threads on ONE worker
#   2      4.31      5.34
#   4      3.82      5.53
#   8      4.04      5.71
#   12     3.57      5.46
#
# BUILD=1 is flat across the ladder; the rise is only in the arm where more
# than one worker allocated. The W=1 row is what makes that a statement about
# workers rather than about the graph: BUILD=8 there still builds eight
# separate lists from eight green threads, and costs what BUILD=1 costs,
# because one worker's free list served all of them.
#
# Holding the pool at W=8 and varying only the builders shows it is a STEP and
# not a gradient -- 3.74, 5.56, 5.62, 5.78, 5.74 ns/object at 1, 2, 4, 8 and 16
# builders. The first extra allocator costs 49%; the next fourteen cost
# nothing. One free list against more than one.
#
# TO RUN THE LADDER, with the two controls that make it mean anything -- both
# of which silently invalidate it, and neither of which warns:
#
#   for W in 1 2 4 8 12; do
#     LOCALITY_BUILD=$B LOCALITY_NODES=400000 LOCALITY_ROUNDS=20000 \
#     SPINEL_WORKERS=$W SPINEL_GC_OBJ_BUDGET=fixed SPINEL_GC_STR_BUDGET=fixed \
#     SPINEL_GC_THRESHOLD_OBJ_KB=$((65536/W)) SPINEL_GC_THRESHOLD_STR_KB=$((65536/W)) \
#     SPINEL_GC_PHASES=1 ./gc_locality_build
#   done
#
#   1. THE PINNED FLOOR MUST SIT ABOVE THE LIVE SET. With OBJ_BUDGET=fixed the
#      threshold never re-aims, so a floor under the live set trips on every
#      allocation and the run livelocks -- tens of thousands of collections
#      where it should take dozens, with nothing said about it. At
#      LOCALITY_NODES=400000 the graph is ~35 MB, so 64 MB aggregate is a
#      floor and 32 MB is a livelock.
#   2. THE OBJECT FLOOR IS MULTIPLIED AT THE FIRST Thread.new, NOT AT BOOT.
#      A graph built before any thread exists is allocated under a different
#      budget from one built after, which is exactly what separates the arms.
#      Both arms therefore build from inside threads, and the warm-up thread
#      below runs first so the pool and the multiply already exist when either
#      one starts.
#
# The defaults here are sized for the gate, not for the ladder: small enough
# to run with the suite, large enough to collect. The checksum is the same in
# every arm and at every worker count -- a graph built by N workers is the
# graph built by one -- which is what gc-locality-test asserts.

BUILD_THREADS = (ENV["LOCALITY_BUILD"] || "1").to_i
CHURN_THREADS = (ENV["LOCALITY_CHURN"] || "4").to_i
NODES = (ENV["LOCALITY_NODES"] || "60000").to_i
CHURN_ROUNDS = (ENV["LOCALITY_ROUNDS"] || "3000").to_i

class Node
  attr_reader :id, :text
  attr_accessor :next_node
  def initialize(id, text)
    @id = id
    @text = text
    @next_node = nil
  end
end

# Creates the worker pool and runs the floor multiply BEFORE either arm
# allocates, so the two arms are allocated under the same budget. See (2).
Thread.new { 1 }.join

def build_slice(lo, hi)
  head = nil
  i = hi - 1
  while i >= lo
    n = Node.new(i, "node-#{i}-#{i * 2654435761 % 1000003}")
    n.next_node = head
    head = n
    i -= 1
  end
  head
end

per = (NODES + BUILD_THREADS - 1) / BUILD_THREADS
slices = (0...BUILD_THREADS).map do |t|
  lo = t * per
  hi = lo + per
  hi = NODES if hi > NODES
  Thread.new(lo, hi) { |a, b| build_slice(a, b) }
end.map(&:value)

GRAPH = slices   # held live for the whole churn phase below

sum = 0
count = 0
GRAPH.each do |head|
  n = head
  while n
    sum = (sum * 31 + n.id + n.text.bytesize) % 1000000007
    count += 1
    n = n.next_node
  end
end
puts "graph: nodes=#{count} checksum=#{sum}"

# Garbage on every worker, so the collections that mark GRAPH happen with the
# whole pool running. Nothing here is retained.
churn = (0...CHURN_THREADS).map do |t|
  Thread.new(t) do |tid|
    acc = 0
    CHURN_ROUNDS.times do |r|
      buf = +""
      200.times { |k| buf << "t#{tid}-r#{r}-k#{k}-" }
      junk = (0...40).map { |k| Node.new(k, "g#{r}-#{k}") }
      acc = (acc + buf.bytesize + junk.size) % 1000003
      Thread.pass if (r & 15) == 15
    end
    acc
  end
end
total = 0
churn.each { |th| total += th.value }
puts "churn: #{total}"
