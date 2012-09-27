module Crystal
  class ASTNode
    attr_accessor :type
  end

  class Call
    attr_accessor :target_def
  end

  class Def
    attr_accessor :owner
    attr_accessor :instances

    def add_instance(a_def)
      @instances ||= {}
      @instances[a_def.args.map(&:type)] = a_def
    end

    def lookup_instance(arg_types)
      @instances && @instances[arg_types]
    end
  end

  def infer_type(node)
    mod = Crystal::Module.new
    node.accept TypeVisitor.new(mod, node)
    mod
  end

  class TypeVisitor < Visitor
    attr_accessor :mod

    def initialize(mod, root)
      @mod = mod
      @root = root
      @scopes = [{vars: {}}]
    end

    def visit_bool(node)
      node.type = mod.bool
    end

    def visit_int(node)
      node.type = mod.int
    end

    def visit_float(node)
      node.type = mod.float
    end

    def visit_char(node)
      node.type = mod.char
    end

    def visit_assign(node)
      node.value.accept self

      if node.target.is_a?(InstanceVar)
        scope[:type].instance_vars[node.target.name] = node.type 
        node.type = node.target.type = node.value.type
      else
        type = lookup_var node.target.name
        if type
          type.add node.value.type
        else
          type = UnionType.new(node.value.type)
        end

        node.type = node.target.type = type
        define_var node.target
      end

      false
    end

    def visit_var(node)
      node.type = lookup_var node.name
    end

    def visit_instance_var(node)
      node.type = scope[:type].instance_vars[node.name]
    end

    def end_visit_expressions(node)
      if node.expressions.empty?
        node.type = mod.void
      else
        node.type = node.expressions.last.type
      end
    end

    def visit_def(node)
      class_def = node.parent.parent
      if class_def
        mod.types[class_def.name].defs[node.name] = node
      else
        mod.defs[node.name] = node
      end
      false
    end

    def visit_call(node)
      if node.obj.is_a?(Const) && node.name == 'new'
        type = mod.types[node.obj.name] or compile_error_on_node "uninitialized constant #{node.obj.name}", node.obj
        node.type = type.clone
        return false
      end

      if node.obj
        node.obj.accept self
        scope = node.obj.type
      else
        scope = mod
      end

      if scope == :unknown
        node.type = :unknown
        return false
      end

      untyped_def = scope.defs[node.name]

      unless untyped_def
        error = node.obj || node.has_parenthesis ? "undefined method" : "undefined local variable or method"
        error << " '#{node.name}'"
        error << " for #{node.obj.type.name}" if node.obj
        compile_error error, node.line_number, node.name_column_number, node.name.length
      end

      if node.args.length != untyped_def.args.length
        compile_error "wrong number of arguments for '#{node.name}' (#{node.args.length} for #{untyped_def.args.length})", node.line_number, node.name_column_number, node.name.length
      end

      node.args.each do |arg|
        arg.accept self
      end

      types = node.args.map(&:type)
      if types.include?(:unknown)
        node.type = :unknown
        return false
      end

      typed_def = untyped_def.lookup_instance(types)
      if typed_def && typed_def.body.type == :unknown && @scopes.any? { |s| s[:obj] == untyped_def }
        node.target_def = typed_def
        node.type = typed_def.body.type
        return
      end

      if !typed_def || typed_def.body.type == :unknown
        if untyped_def.is_a?(FrozenDef)
          error = "can't call "
          error << "#{scope.name}#" unless scope.is_a?(Module)
          error << "#{node.name} with types [#{types.map(&:name).join ', '}]"
          compile_error error, node.line_number, node.name_column_number, node.name.length
        end

        typed_def ||= untyped_def.clone
        typed_def.owner = node.obj.type if node.obj
        typed_def.body.type = :unknown

        with_new_scope(node.line_number, untyped_def, scope) do
          if node.obj
            self_var = Var.new("self")
            self_var.type = UnionType.new(node.obj.type)
            define_var self_var
          end

          typed_def.args.each_with_index do |arg, i|
            typed_def.args[i].type = UnionType.new(node.args[i].type)
            define_var typed_def.args[i]
          end

          untyped_def.add_instance typed_def

          typed_def.body.accept self
          while typed_def.body.type.is_a?(::Array)
            typed_def.body.type = Type.unmerge(typed_def.body.type, :unknown)
            typed_def.body.accept self
          end
        end
      end

      node.target_def = typed_def
      node.type = typed_def.body.type

      false
    end

    def visit_class_def(node)
      mod.types[node.name] ||= ObjectType.new node.name
      true
    end

    def end_visit_if(node)
      node.type = node.then.type
      node.type = Type.merge(node.type, node.else.type) if node.else.any?
    end

    def end_visit_while(node)
      node.type = mod.void
    end

    def define_var(var)
      @scopes.last[:vars][var.name] = var.type
    end

    def lookup_var(name)
      @scopes.last[:vars][name]
    end

    def with_new_scope(line, obj, type)
      scope[:line] = line
      @scopes.push({vars: {}, obj: obj, type: type})
      yield
      @scopes.pop
    end

    def scope
      @scopes.last
    end

    def compile_error_on_node(message, node)
      compile_error message, node.line_number, node.column_number, node.name.length
    end

    def compile_error(message, line, column, length)
      str = "Error: #{message}"
      str << " in '#{scope[:obj].name}'" if scope[:obj]
      str << "\n\n"
      str << @root.source_code.lines.at(line - 1).chomp
      str << "\n"
      str << (' ' * (column - 1))
      str << '^'
      str << ('~' * (length - 1))
      str << "\n"
      str << "\n"
      @scopes.reverse_each do |scope|
        str << "in line #{scope[:line] || line}"
        str << ": '#{scope[:obj].name}'\n" if scope[:obj]
      end
      raise Crystal::Exception.new(str.strip)
    end
  end
end