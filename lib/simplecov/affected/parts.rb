# frozen_string_literal: true

require "fileutils"
require_relative "sidecar"
require_relative "merge"

module SimpleCov
  module Affected
    #
    # Each process of a run writes its own recording to
    # `coverage/.affected-parts/<run id>/<pid>.json`, and the process that
    # owns the final result folds them into the sidecar. A part is written
    # when the process collects its own coverage, which is before it stores
    # its resultset, so by the time the final process has waited for every
    # worker's resultset every part is on disk.
    #
    # One directory per run keeps a sibling run that shares the coverage
    # directory (a second suite started at the same time) out of this run's
    # merge, and a directory a crashed run left behind is cleared once it is
    # older than `merge_timeout`.
    #
    module Parts
      DIR = ".affected-parts"
      LOCK = ".affected.lock"

      extend self

      def write(coverage_path, run_id, pid, document)
        Sidecar.write(File.join(run_dir(coverage_path, run_id), "#{pid}.json"), document)
      end

      # Folds this run's parts into the sidecar under a lock, because two
      # suites that finish at the same moment would otherwise each read the
      # sidecar before the other wrote it, and one run's records would be lost.
      def finish(coverage_path, run_id, root, timeout:)
        dir = run_dir(coverage_path, run_id)
        parts = Dir.glob(File.join(dir, "*.json")).sort.filter_map { |path| Sidecar.read(path) }
        locked(coverage_path) do
          sidecar = Sidecar.path(coverage_path)
          Sidecar.write(sidecar, Merge.onto(Sidecar.read(sidecar), Merge.combine(parts), root)) unless parts.empty?
        end
        FileUtils.rm_rf(dir)
        clear_abandoned(coverage_path, timeout)
      end

      def run_dir(coverage_path, run_id)
        File.join(coverage_path, DIR, run_id.to_s.gsub(/[^\w.-]/, "_"))
      end

      def locked(coverage_path)
        FileUtils.mkdir_p(coverage_path)
        File.open(File.join(coverage_path, LOCK), File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def clear_abandoned(coverage_path, timeout)
        cutoff = Time.now - timeout
        Dir.glob(File.join(coverage_path, DIR, "*")).each do |dir|
          FileUtils.rm_rf(dir) if File.mtime(dir) < cutoff
        end
        Dir.rmdir(File.join(coverage_path, DIR)) if Dir.empty?(File.join(coverage_path, DIR))
      rescue SystemCallError
        nil
      end
    end
  end
end
