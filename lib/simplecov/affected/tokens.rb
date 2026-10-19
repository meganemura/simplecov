# frozen_string_literal: true

require "digest"

module SimpleCov
  module Affected
    #
    # The names a piece of Ruby mentions, read off its syntax tree rather than
    # its text, so a local variable called `query` is not the method `query`,
    # and a word inside a string still counts, because `send("query")` and
    # `public_send(:query)` name a method no call site spells out.
    #
    module Tokens
      WORD = /[A-Za-z_][A-Za-z0-9_]*[?!]?/
      # Names start with a letter or underscore; operators do not.
      WORD_START = /\A[A-Za-z_]/
      LOCAL = /local_variable|parameter_node\z/
      NAMES = %i[name read_name write_name].freeze
      NESTED = %i[def_node block_node lambda_node].freeze

      extend self

      # A digest of code with blank lines and indentation left out.
      def digest(text)
        Digest::SHA256.hexdigest(text.each_line.map(&:strip).reject(&:empty?).join("\n"))[0, 16] || ""
      end

      # `limit=` names `limit`; `==` and `[]=` stay operators.
      def setter(name)
        name.sub(/(?<=\w)=\z/, "")
      end

      # Scanned as bytes: a string literal may hold bytes that are no valid
      # UTF-8 (`"\xFF"`), and a name is ASCII either way.
      def words(text)
        text.b.scan(WORD).to_set { |word| word.to_s.delete_suffix("=").force_encoding(Encoding::UTF_8) }
      end

      # The tokens of `node`'s own code. A def, block, or lambda nested in it is
      # code of its own, of which only a def's name is kept; `stop` narrows
      # that to the nested nodes it answers true for.
      def of(node, stop: ->(nested) { NESTED.include?(nested.type) })
        found = Set.new #: Set[String]
        stack = [[node, true]] #: Array[[untyped, bool]]
        until stack.empty?
          current, top = stack.pop
          mention(current, found)
          next unless top || !stop.call(current)

          current.compact_child_nodes.each { |child| stack << [child, false] }
        end
        found
      end

      private

      def mention(node, found)
        type = node.type
        if type.equal?(:symbol_node)
          found << setter(node.unescaped.to_s.scrub)
        elsif type.equal?(:string_node) || type.equal?(:x_string_node)
          found.merge(words(node.unescaped.to_s))
        elsif !LOCAL.match?(type.to_s)
          NAMES.each do |reader|
            value = node.public_send(reader) if node.respond_to?(reader)
            found << setter(value.to_s.delete("@$")) if value.is_a?(Symbol)
          end
        end
      end
    end
  end
end
