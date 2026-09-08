# Spinel bundled `fileutils` -- plain Ruby over Dir and File.
#
# Nothing here is carried C. Every method is a walk and a path calculation on
# primitives spinel already answers (Dir.mkdir / .rmdir / .entries / .exist?,
# File.directory? / .symlink? / .delete / .rename / .utime, IO.copy_stream),
# which is why this is a .rb and not a binding.
#
# What is absent is absent the way a subset is:
#
# * no `verbose:` reporting and no `noop:`. Both are accepted and ignored, so
#   a caller that passes them keeps working; what they ask for is a running
#   commentary and a dry run, and a compiler that inlines these has neither a
#   $stderr convention nor a reason to build the plan without executing it.
# * no `preserve:` on cp/mv, no `dereference_root:`, no `secure:` on rm_r
# * no ln_sf, no install, no chown, no cp_lr
# * no FileUtils::Verbose / ::NoWrite / ::DryRun modules
#
# Every method takes a single path or a list of them, as CRuby's do, and
# returns what CRuby's return (mkdir_p and friends answer the list they were
# given; rm_rf answers it too).
module FileUtils
  module_function

  # CRuby accepts a String, a Pathname, or an Array of either. `to_s` covers
  # the Pathname case without naming the class, which would drag the pathname
  # package into every program that requires this one.
  def fu_list(arg)
    arg.is_a?(Array) ? arg.map { |x| x.to_s } : [arg.to_s]
  end

  # mkdir_p makes every missing component, and is NOT an error when the
  # directory is already there -- that is the whole difference from Dir.mkdir
  # and the reason nearly every caller wants this one.
  def mkdir_p(list, mode: nil, verbose: nil, noop: nil)
    fu_list(list).each do |path|
      next if path.empty?
      # Walk down from the root building each missing component. Splitting on
      # "/" keeps a leading "/" as an empty first element, which is what makes
      # an absolute path rebuild as absolute.
      parts = path.split("/")
      acc = path.start_with?("/") ? "" : nil
      parts.each do |part|
        next if part.empty?
        acc = acc.nil? ? part : "#{acc}/#{part}"
        next if Dir.exist?(acc)
        # A racing process may have created it between the test and the call,
        # and a plain file sitting in the way is an error CRuby also raises.
        begin
          Dir.mkdir(acc)
        rescue SystemCallError
          raise unless Dir.exist?(acc)
        end
      end
      File.chmod(mode, path) if mode
    end
    fu_list(list)
  end

  def makedirs(list, mode: nil, verbose: nil, noop: nil)
    mkdir_p(list, mode: mode)
  end

  def mkpath(list, mode: nil, verbose: nil, noop: nil)
    mkdir_p(list, mode: mode)
  end

  def mkdir(list, mode: nil, verbose: nil, noop: nil)
    fu_list(list).each do |path|
      Dir.mkdir(path)
      File.chmod(mode, path) if mode
    end
    fu_list(list)
  end

  def rmdir(list, parents: nil, verbose: nil, noop: nil)
    fu_list(list).each { |path| Dir.rmdir(path) }
    fu_list(list)
  end

  # rm removes files, never directories: a directory here is an error, as it
  # is in CRuby. rm_f swallows every error, which is what `force: true` means.
  def rm(list, force: nil, verbose: nil, noop: nil)
    fu_list(list).each do |path|
      begin
        File.delete(path)
      rescue StandardError
        raise unless force
      end
    end
    fu_list(list)
  end

  def rm_f(list, verbose: nil, noop: nil)
    rm(list, force: true)
  end

  def remove(list, force: nil, verbose: nil, noop: nil)
    rm(list, force: force)
  end

  def remove_file(path, force = false)
    rm([path.to_s], force: force)
    nil
  end

  # rm_r walks a tree bottom-up. A SYMLINK to a directory is removed as a
  # link, not followed -- following it would delete a tree outside the one
  # named, which is the accident this check exists to prevent.
  def rm_r(list, force: nil, verbose: nil, noop: nil, secure: nil)
    fu_list(list).each { |path| fu_rm_tree(path, force ? true : false) }
    fu_list(list)
  end

  def rm_rf(list, verbose: nil, noop: nil, secure: nil)
    rm_r(list, force: true)
  end

  def rmtree(list, verbose: nil, noop: nil, secure: nil)
    rm_r(list, force: true)
  end

  def remove_entry(path, force = false)
    fu_rm_tree(path.to_s, force ? true : false)
    nil
  end

  def remove_entry_secure(path, force = false)
    fu_rm_tree(path.to_s, force ? true : false)
    nil
  end

  def fu_rm_tree(path, force)
    if File.symlink?(path) || !File.directory?(path)
      begin
        File.delete(path)
      rescue StandardError
        raise unless force
        return nil
      end
      return nil
    end
    entries = begin
      Dir.entries(path)
    rescue StandardError
      raise unless force
      return nil
    end
    entries.each do |e|
      next if e == "." || e == ".."
      fu_rm_tree("#{path}/#{e}", force)
    end
    begin
      Dir.rmdir(path)
    rescue StandardError
      raise unless force
    end
    nil
  end

  # cp copies file contents. A destination that is an existing DIRECTORY takes
  # the source's basename inside it, which is what makes `cp(files, dir)` work.
  def cp(src, dest, preserve: nil, verbose: nil, noop: nil)
    fu_list(src).each { |s| fu_copy_file(s, fu_dest_path(s, dest.to_s)) }
    nil
  end

  def copy(src, dest, preserve: nil, verbose: nil, noop: nil)
    cp(src, dest)
  end

  def cp_r(src, dest, preserve: nil, verbose: nil, noop: nil, dereference_root: nil, remove_destination: nil)
    fu_list(src).each { |s| fu_copy_tree(s, fu_dest_path(s, dest.to_s)) }
    nil
  end

  def fu_dest_path(src, dest)
    Dir.exist?(dest) ? "#{dest}/#{File.basename(src)}" : dest
  end

  def fu_copy_file(src, dest)
    IO.copy_stream(src, dest)
    nil
  end

  def fu_copy_tree(src, dest)
    if File.directory?(src) && !File.symlink?(src)
      Dir.mkdir(dest) unless Dir.exist?(dest)
      Dir.entries(src).each do |e|
        next if e == "." || e == ".."
        fu_copy_tree("#{src}/#{e}", "#{dest}/#{e}")
      end
    else
      fu_copy_file(src, dest)
    end
    nil
  end

  # mv renames when it can. Across filesystems rename(2) answers EXDEV, and
  # there the move is a copy followed by a delete -- without the fallback,
  # moving out of /tmp onto another mount raised where CRuby succeeds.
  def mv(src, dest, force: nil, verbose: nil, noop: nil, secure: nil)
    fu_list(src).each do |s|
      d = fu_dest_path(s, dest.to_s)
      begin
        File.rename(s, d)
      rescue StandardError
        fu_copy_tree(s, d)
        fu_rm_tree(s, true)
      end
    end
    nil
  end

  def move(src, dest, force: nil, verbose: nil, noop: nil, secure: nil)
    mv(src, dest, force: force)
  end

  # touch creates what is missing and updates the times of what is not.
  def touch(list, mtime: nil, nocreate: nil, verbose: nil, noop: nil)
    t = mtime || Time.now
    fu_list(list).each do |path|
      if File.exist?(path)
        File.utime(t, t, path)
      else
        next if nocreate
        File.open(path, "w") { |f| }
      end
    end
    fu_list(list)
  end

  def ln_s(src, dest, force: nil, verbose: nil, noop: nil)
    fu_list(src).each do |s|
      d = fu_dest_path(s, dest.to_s)
      begin
        File.delete(d)
      rescue StandardError
        # nothing there to unlink, which is the ordinary case
      end if force
      File.symlink(s, d)
    end
    nil
  end

  def symlink(src, dest, force: nil, verbose: nil, noop: nil)
    ln_s(src, dest, force: force)
  end

  def ln(src, dest, force: nil, verbose: nil, noop: nil)
    fu_list(src).each { |s| File.link(s, fu_dest_path(s, dest.to_s)) }
    nil
  end

  def link(src, dest, force: nil, verbose: nil, noop: nil)
    ln(src, dest, force: force)
  end

  def chmod(mode, list, verbose: nil, noop: nil)
    fu_list(list).each { |path| File.chmod(mode, path) }
    fu_list(list)
  end

  def chmod_R(mode, list, verbose: nil, noop: nil, force: nil)
    fu_list(list).each { |path| fu_chmod_tree(mode, path) }
    fu_list(list)
  end

  def fu_chmod_tree(mode, path)
    File.chmod(mode, path)
    return nil unless File.directory?(path) && !File.symlink?(path)
    Dir.entries(path).each do |e|
      next if e == "." || e == ".."
      fu_chmod_tree(mode, "#{path}/#{e}")
    end
    nil
  end

  def cd(dir, verbose: nil, &block)
    Dir.chdir(dir.to_s, &block)
  end

  def chdir(dir, verbose: nil, &block)
    Dir.chdir(dir.to_s, &block)
  end

  def pwd
    Dir.pwd
  end

  def getwd
    Dir.pwd
  end

  def identical?(a, b)
    return false unless File.exist?(a.to_s) && File.exist?(b.to_s)
    File.read(a.to_s) == File.read(b.to_s)
  end

  def compare_file(a, b)
    identical?(a, b)
  end

  def uptodate?(new, old_list)
    return false unless File.exist?(new.to_s)
    t = File.mtime(new.to_s)
    fu_list(old_list).each do |o|
      next unless File.exist?(o)
      return false if File.mtime(o) > t
    end
    true
  end
end
