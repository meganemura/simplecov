# frozen_string_literal: true

require "prism"

module SimpleCov
  module CLI
    module Affected
      module Units
        # Walks a tree once and lists its units in source order, parents before
        # children, each named after its scope and its call.
        class Collector < Prism::Visitor
          def initialize
            super
            @units = [] #: Array[Unit]
            @scope = [] #: Array[String]
            @stack = [] #: Array[Unit]
            @labels = [] #: Array[String]
            @seen = Hash.new(0) #: Hash[String, Integer]
          end

          def collect(program)
            program.accept(self)
            @units
          end

          def visit_class_node(node)
            within_scope(node.constant_path.slice) { super }
          end

          def visit_module_node(node)
            within_scope(node.constant_path.slice) { super }
          end

          def visit_singleton_class_node(node)
            within_scope("<< #{node.expression.slice}") { super }
          end

          def visit_def_node(node)
            within_unit(node, "#{node.receiver ? "." : "#"}#{node.name}") { super }
          end

          # A block takes its name from the call it is passed to, so the label is
          # pushed for the call's own children and popped after them.
          def visit_call_node(node)
            @labels.push(call_label(node))
            super
          ensure
            @labels.pop
          end

          def visit_block_node(node)
            within_unit(node, "/#{@labels.last || "block"}") { super }
          end

          def visit_lambda_node(node)
            within_unit(node, "/->") { super }
          end

          private

          def within_scope(name)
            @scope.push(name)
            yield
          ensure
            @scope.pop
          end

          def within_unit(node, label)
            entry = entry_line(node)
            return yield unless entry

            @stack.push(add(node, label, entry))
            begin
              yield
            ensure
              @stack.pop
            end
          end

          def add(node, label, entry)
            parent = @stack.last
            base = "#{parent ? parent.id : @scope.join("::")}#{label}"
            count = (@seen[base] += 1)
            location = node.location
            unit = Unit.new((count > 1) ? "#{base}~#{count}" : base, node.is_a?(Prism::DefNode), parent,
              location.end_line, entry, location.start_offset, location.end_offset, "", "")
            @units << unit
            unit
          end

          # The line every entry into the unit runs first, when it lies below the
          # opening line. On the opening line itself a call cannot be told from the
          # definition, so such a node is no unit.
          def entry_line(node)
            body = node.body
            body = body.statements if body.is_a?(Prism::BeginNode)
            return nil unless body

            line = body.body.fetch(0).location.start_line
            line if line > node.location.start_line
          end

          # `describe "GET"` and `it "parses"` stay apart by their first literal
          # argument, which repeats far less often than the bare call name.
          def call_label(node)
            case (first = node.arguments&.arguments&.first)
            when Prism::StringNode, Prism::SymbolNode then "#{node.name}(#{first.slice})"
            else node.name.to_s
            end
          end
        end
      end
    end
  end
end
