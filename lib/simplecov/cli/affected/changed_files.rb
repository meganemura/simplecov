# frozen_string_literal: true

require_relative "../git"
require_relative "../../static_coverage_extractor"

module SimpleCov
  module CLI
    module Affected
      # The change as git sees it, as `{root:, changed:}`: the files that differ
      # between the merge base of the given ref and the working tree, so commits
      # that landed on the base after the branch point stay out while uncommitted
      # work stays in, unioned with untracked files, since a brand-new spec exists
      # in no diff. Everything runs against the repository toplevel rather than the
      # cwd, so a subdirectory run selects over the whole change. NUL separation
      # keeps exotic filenames literal instead of quoted.
      module ChangedFiles
        extend self

        def call(base, stderr)
          return report(stderr, "invalid base ref #{base.inspect}") if Git.option_like_ref?(base)

          root = repository_toplevel(stderr)
          return nil unless root

          diff = list("diff", ["-C", root, "diff", "--name-only", "-z", "--merge-base", base, "--"], stderr)
          return nil unless diff

          untracked = list("ls-files", ["-C", root, "ls-files", "--others", "--exclude-standard", "-z"], stderr)
          untracked && {root: root, changed: (diff + untracked).uniq}
        end

        # nil stdout from `Git.capture` means git never ran; a run that failed
        # means the cwd is outside a working tree.
        def repository_toplevel(stderr)
          stdout, detail, success = Git.capture("rev-parse", "--show-toplevel")
          return (_ = stdout).chomp if success
          return report(stderr, "cannot run git (#{detail})") if stdout.nil?

          report(stderr, "not inside a git working tree")
        end

        def list(command, argv, stderr)
          git_output(command, argv, stderr)&.split("\0")
        end

        # git's own first stderr line is relayed on failure, so a bad ref or an old
        # git names itself.
        def git_output(command, argv, stderr)
          stdout, detail, success = Git.capture(*argv)
          return stdout if success
          return report(stderr, "cannot run git (#{detail})") if stdout.nil?

          report(stderr, "`git #{command}` failed: #{detail}")
        end

        # Read on the base side, because a report's line numbers predate the change.
        # An added line counts as a change to the base line above it.
        def report_lines_changed(root, base, path, stderr)
          argv = ["-C", root, "diff", "--unified=#{WHOLE_FILE_CONTEXT}", "--no-color", "--no-ext-diff", "--merge-base", base,
            "--", ":(literal)#{path}"]
          patch = git_output("diff", argv, stderr)
          patch && parse_report_lines_changed(patch)
        end

        WHOLE_FILE_CONTEXT = 2_147_483_647
        CODE_LINE = /\A\s*[^\s#]/
        DEF_LINE = /\A\s*(?:\w+\s+)*def\b/

        def parse_report_lines_changed(patch)
          source = [] #: Array[String]
          head = [] #: Array[String]
          changed = [] #: Array[Integer]
          additions = [] #: Array[[Integer, Range[Integer]]]
          rows = patch.lines.drop_while { |line| !line.start_with?("@@") }.drop(1).grep_v(/\A\\/)
          rows.chunk { |row| row.start_with?("+") }.each do |added, run|
            lines = run.map { |row| _ = row[1..] } #: Array[String]
            if added
              additions << [source.size, (head.size + 1)..(head.size + lines.size)] if lines.grep(CODE_LINE).any?
              next head.concat(lines)
            end

            run.each_with_index do |row, index|
              source << lines.fetch(index)
              next changed << source.size if row.start_with?("-") && CODE_LINE.match?(source.last)

              head << lines.fetch(index) unless row.start_with?("-")
            end
          end
          methods = method_lines(head.join)
          additions.each { |line, added| changed << line unless adds_only_methods?(added, methods, head) }
          {source: source, changed: changed.sort}
        end

        # The line spans of every method the file defines after the change, or nil
        # when Prism cannot load or the file does not parse.
        def method_lines(source)
          return nil unless StaticCoverageExtractor.prism_loaded?

          result = Prism.parse(source)
          return nil if result.failure?

          nodes = [result.value] #: Array[Prism::Node]
          spans = [] #: Array[Range[Integer]]
          while (node = nodes.pop)
            spans << (node.location.start_line..node.location.end_line) if node.is_a?(Prism::DefNode)
            nodes.concat(node.compact_child_nodes)
          end
          spans
        end

        # Code added only as whole new methods changes nothing that ran while the
        # file loaded, apart from the def lines that name them.
        def adds_only_methods?(added, methods, head)
          return false unless methods

          added.all? do |number|
            !CODE_LINE.match?(head.fetch(number - 1)) || methods.any? { |span| span.cover?(number) && added.cover?(span) }
          end
        end

        def report(stderr, message)
          stderr.puts("simplecov affected: #{message}")
        end
      end
    end
  end
end
