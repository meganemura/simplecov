# frozen_string_literal: true

require "open3"

module SimpleCov
  module CLI
    # The git plumbing the change-aware subcommands share: safe capture, the
    # repository toplevel, ref hygiene, and the default base ref.
    module Git
      extend self

      # [stdout, first stderr line, success]. A spawn failure reads as an
      # unsuccessful run whose stdout is nil, so callers can tell "git ran and
      # refused" from "git never ran".
      def capture(*argv)
        stdout, stderr, status = Open3.capture3("git", *argv)
        [stdout, stderr.lines.first.to_s.strip, status.success?]
      rescue => e
        [nil, e.message, false]
      end

      # `git diff` of the working tree against the merge base of `base`, with the
      # output pinned against a user's git config so it can't skew the numbers,
      # run code, or throw off a parse: `--no-ext-diff` / `--no-textconv` (either
      # runs a configured command, and the latter also renumbers lines),
      # `--no-color`, `core.quotePath=false` (emit non-ASCII paths literally, so
      # they still match report keys), `--inter-hunk-context=0` (never merge
      # hunks over unchanged lines, which would read those lines as touched), and
      # fixed `b/` prefixes (so `diff.noprefix` can't fool a path strip).
      # `options` go before the base and `paths` after `--`.
      def diff(root, base, options, paths = [])
        capture("-C", root, "-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
          "--inter-hunk-context=0", "--dst-prefix=b/", *options, "--merge-base", base, "--", *paths)
      end

      def toplevel
        stdout, _detail, success = capture("rev-parse", "--show-toplevel")
        (_ = stdout).chomp if success
      end

      # A git ref can never begin with "-", so one that does would be read by git
      # as an option instead of a revision.
      def option_like_ref?(ref)
        ref.start_with?("-")
      end

      # The branch origin's HEAD points at, so master and trunk repositories work
      # bare, falling back to main where no origin HEAD is recorded.
      def default_base
        stdout, _detail, success = capture("symbolic-ref", "--short", "refs/remotes/origin/HEAD")
        success ? (_ = stdout).chomp.delete_prefix("origin/") : "main"
      end
    end
  end
end
