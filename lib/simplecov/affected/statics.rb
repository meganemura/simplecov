# frozen_string_literal: true

require_relative "tokens"

module SimpleCov
  module Affected
    #
    # The statements of one source that run once, as the file loads, so that
    # no test's lines show them running: constants, class and module headers,
    # macros (`attr_reader :name`, `validates :email`), endless and empty
    # defs, and requires. Each is keyed by the name it defines, with a digest
    # per key; a change to a key's digests changes what every reader of that
    # name gets. A statement that defines no name (`include Comparable`,
    # `private`) is keyed by the class or module it sits in, or by the file
    # outside any.
    #
    # Code inside a unit (a def, block, or lambda whose body starts below its
    # opening line, the units of `simplecov affected`) is left to the units:
    # it shows up in a static's text only as a marker, so editing a method
    # body changes no key.
    #
    # Two kinds of def never run a line of their own on a call, because their
    # body sits on the opening line or there is none: `def name = value` and a
    # def whose body is empty. They are keyed by their name, like a constant,
    # and also by their class, because a library may call them by a name the
    # project never writes (Scientist calls `enabled?`). The methods Ruby and
    # the standard library call without the project spelling the name out
    # (`initialize`, `==`, `each`, `to_s`, ...) are keyed by their class for
    # the same reason.
    #
    class Statics
      HOOKS = %w[
        initialize initialize_copy initialize_dup initialize_clone
        method_missing respond_to_missing? respond_to?
        to_s inspect to_str to_ary to_a to_h to_hash to_proc to_int to_sym to_io to_path
        call each hash eql? == === =~ <=> coerce freeze dup clone
        marshal_dump marshal_load _dump _load encode_with init_with
        inherited included extended prepended method_added const_missing
        as_json to_json to_param to_partial_path to_key
      ].to_set.freeze
      REQUIRES = %w[require require_relative load].freeze
      WRITES = %i[
        constant_write_node constant_or_write_node constant_and_write_node constant_operator_write_node
        constant_path_write_node constant_path_or_write_node constant_path_and_write_node
        constant_path_operator_write_node instance_variable_write_node instance_variable_or_write_node
        instance_variable_and_write_node instance_variable_operator_write_node class_variable_write_node
        class_variable_or_write_node class_variable_and_write_node class_variable_operator_write_node
      ].to_set.freeze
      UNITS = %i[def_node block_node lambda_node].freeze

      # The key for statements of a file outside any class or module, which is
      # also how a test reaches a file: it ran something in it.
      def self.path_key(path)
        "path:#{path}"
      end

      # A unit is what `simplecov affected` calls one: entering it runs a line
      # below its opening line, which line coverage reports.
      def self.unit?(node)
        return false unless UNITS.include?(node.type)

        body = node.body
        body = body.statements if body.is_a?(Prism::BeginNode)
        return false unless body.is_a?(Prism::StatementsNode)

        body.body.fetch(0).location.start_line > node.location.start_line
      end

      attr_reader :names, :mentions, :requires

      # nil for a source that does not parse: it cannot load either.
      def self.parse(source, path)
        result = Prism.parse(source)
        new(result, source, path) unless result.failure?
      end

      def initialize(result, source, path)
        @source = source.b
        result.comments.each { |comment| @source.bytesplice(comment.location.start_offset, comment.location.length, " " * comment.location.length) }
        @path = path
        @sums = Hash.new { |hash, key| hash[key] = Set.new } #: Hash[String, Set[String]]
        @mentions = Hash.new { |hash, key| hash[key] = Set.new } #: Hash[String, Set[String]]
        @anonymous = Hash.new { |hash, key| hash[key] = [] } #: Hash[String, Array[String]]
        @requires = [] #: Array[[String, String]]
        walk(body(result.value.statements), [])
        @anonymous.each { |key, texts| @sums[key] << Tokens.digest(texts.join("\n")) }
        @names = @sums.transform_values { |sums| sums.to_a.sort }
      end

      private

      def body(node)
        case node
        when nil then []
        when Prism::StatementsNode then node.body
        else [node]
        end
      end

      def add(key, sum, node = nil)
        @sums[key] << sum
        @mentions[key].merge(Tokens.of(node)) if node
      end

      def anonymous(scope, node, text = elide(node))
        key = scope.last || Statics.path_key(@path)
        @anonymous[key] << text
        @mentions[key].merge(Tokens.of(node)) if node
      end

      def walk(statements, scope)
        statements.each { |node| statement(node, scope) }
      end

      def statement(node, scope)
        case node
        when Prism::IfNode, Prism::UnlessNode then branches(node, scope)
        when Prism::BeginNode
          walk(body(node.statements), scope)
          anonymous(scope, nil, "begin-rescue") if node.rescue_clause || node.ensure_clause
        when Prism::DefNode then define(node, scope)
        when Prism::ClassNode, Prism::ModuleNode then namespace(node, scope)
        when Prism::SingletonClassNode then walk(body(node.body), scope)
        when Prism::CallNode then call(node, scope)
        else
          WRITES.include?(node.type) ? write(node, scope) : anonymous(scope, node)
        end
      end

      def branches(node, scope)
        anonymous(scope, node.predicate)
        walk(body(node.statements), scope)
        alternative = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
        alternative = alternative.statements if alternative.is_a?(Prism::ElseNode)
        alternative.is_a?(Prism::IfNode) ? statement(alternative, scope) : walk(body(alternative), scope)
      end

      def namespace(node, scope)
        name = node.constant_path.slice.split("::").last.to_s
        superclass = node.superclass if node.is_a?(Prism::ClassNode)
        add(name, Tokens.digest(superclass ? "class #{node.constant_path.slice} < #{superclass.slice}" : node.type.to_s))
        @mentions[name].merge(Tokens.words(superclass.slice)) if superclass
        walk(body(node.body), scope + [name])
      end

      # A block that is a static's value (`Point = Struct.new(:x) do ... end`)
      # is that static's scope.
      def write(node, scope)
        name = node.respond_to?(:name) ? node.name.to_s.delete("@") : node.target.slice.split("::").last.to_s
        add(name, Tokens.digest("#{scope.join("::")}|#{elide(node)}"), node)
        value = node.value
        block = value.block if value.is_a?(Prism::CallNode)
        walk(body(block.body), scope + [name]) if block.is_a?(Prism::BlockNode)
      end

      def define(node, scope)
        name = node.name.to_s
        if node.equal_loc || node.body.nil?
          sum = Tokens.digest(elide(node))
          add(name, sum, node)
          anonymous(scope, nil, "def #{name} #{sum}")
        elsif HOOKS.include?(name)
          anonymous(scope, nil, "def #{name}")
        else
          add(name, "def")
        end
      end

      def call(node, scope)
        arguments = node.arguments&.arguments || []
        feature = arguments.first if node.receiver.nil? && REQUIRES.include?(node.name.to_s)
        return @requires << [node.name.to_s, feature.unescaped] if feature.is_a?(Prism::StringNode)

        defs = arguments.grep(Prism::DefNode) #: Array[Prism::DefNode]
        symbols = arguments.grep(Prism::SymbolNode) #: Array[Prism::SymbolNode]
        if !defs.empty?
          defs.each do |definition|
            define(definition, scope)
            add(definition.name.to_s, Tokens.digest(elide(node)), node)
          end
        elsif !symbols.empty?
          symbols.each do |symbol|
            others = (symbols - [symbol]).map { |other| [other.location.start_offset, other.location.end_offset, ""] } #: Array[[Integer, Integer, String]]
            add(Tokens.setter(symbol.unescaped.to_s.scrub), Tokens.digest(elide(node, others)), node)
          end
        else
          receiver = node.receiver
          name = node.name.to_s
          if receiver.is_a?(Prism::SelfNode) && name.end_with?("=") && !name.eql?("[]=")
            add(name.delete_suffix("="), Tokens.digest(elide(node)), node)
          elsif receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
            add(receiver.slice.split("::").last.to_s, Tokens.digest(elide(node)), node)
          else
            anonymous(scope, node)
          end
        end
      end

      # The node's text with each unit nested in it, and each of `cuts`,
      # replaced by a marker. Called with a node, since a text without one is
      # passed in.
      def elide(node, cuts = [])
        cuts = cuts.dup
        stack = node.compact_child_nodes
        until stack.empty?
          child = stack.shift
          if Statics.unit?(child)
            cuts << [child.location.start_offset, child.location.end_offset, child.is_a?(Prism::DefNode) ? "def #{child.name}" : "{}"]
          else
            stack.concat(child.compact_child_nodes)
          end
        end
        text = +""
        cursor = node.location.start_offset
        # The cuts never overlap: the walk stops at each unit it cuts, and a
        # symbol cut is a direct argument of the node.
        cuts.sort_by(&:first).each do |from, to, marker|
          text << @source.byteslice(cursor, from - cursor).to_s << marker
          cursor = to
        end
        text << @source.byteslice(cursor, node.location.end_offset - cursor).to_s
      end
    end
  end
end
