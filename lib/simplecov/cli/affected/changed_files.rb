# frozen_string_literal: true

require_relative "../git"

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
          changed = [] #: Array[Integer]
          rows = patch.lines.drop_while { |line| !line.start_with?("@@") }.drop(1)
          rows.chunk { |row| row.start_with?("+") }.each do |added, run|
            lines = run.map { |row| _ = row[1..] } #: Array[String]
            next changed << source.size if added && lines.grep(CODE_LINE).any? && !adds_only_methods?(lines)
            next if added

            run.each_with_index do |row, index|
              source << lines.fetch(index)
              changed << source.size if row.start_with?("-") && CODE_LINE.match?(source.last)
            end
          end
          {source: source, changed: changed}
        end

        # Judged by layout, so the added text need not parse on its own.
        def adds_only_methods?(lines)
          code = lines.grep(CODE_LINE)
          margin = code.fetch(0).delete_suffix(code.fetch(0).lstrip)
          code.all? { |line| line.match?(/\A#{margin}(?:\s|(?:\w+\s+)*def\b|end\b)/) }
        end

        def report(stderr, message)
          stderr.puts("simplecov affected: #{message}")
        end
      end
    end
  end
end
