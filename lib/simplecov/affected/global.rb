# frozen_string_literal: true

module SimpleCov
  module Affected
    #
    # The files a glob of `affected_global` stands for, the same way when a
    # run records them and when the selection compares them: project files
    # only, root-relative, sorted.
    #
    module Global
      extend self

      def files(root, glob, project)
        Dir.glob(glob, base: root).select { |path| File.file?(File.join(root, path)) && project.project_file(File.join(root, path)) }.sort
      end
    end
  end
end
