# frozen_string_literal: true

module BetterAuth
  class DatabaseHooks
    Scope = Data.define(:adapter, :transaction_adapter, :pending_hooks)
    SCOPE_KEY = :better_auth_database_hook_scope
    private_constant :Scope, :SCOPE_KEY

    attr_reader :options

    def self.with_adapter_scope
      pending_hooks = []
      with_scope(Scope.new(nil, nil, pending_hooks)) { yield }
    ensure
      pending_hooks.each(&:call)
    end

    def self.transaction(adapter)
      scope = Thread.current[SCOPE_KEY]
      return yield scope.transaction_adapter if scope&.adapter.equal?(adapter)

      pending_hooks = []
      begin
        adapter.transaction do |transaction_adapter|
          transaction_adapter ||= adapter
          with_scope(Scope.new(adapter, transaction_adapter, pending_hooks)) { yield transaction_adapter }
        end
      ensure
        pending_hooks.each(&:call)
      end
    end

    def self.with_scope(scope)
      previous = Thread.current[SCOPE_KEY]
      Thread.current[SCOPE_KEY] = scope
      yield
    ensure
      Thread.current[SCOPE_KEY] = previous
    end
    private_class_method :with_scope

    def initialize(adapter, options)
      @adapter = adapter
      @options = options
    end

    def adapter
      scope = Thread.current[SCOPE_KEY]
      scope&.adapter.equal?(@adapter) ? scope.transaction_adapter : @adapter
    end

    def create(data, model, custom: nil, context: nil)
      context ||= Endpoint::Context.current
      run_before(model, :create, data, context) do |actual_data|
        created = custom ? custom.call(actual_data) : adapter.create(model: model, data: actual_data, force_allow_id: true)
        run_after(model, :create, created, context)
        created
      end
    end

    def update(data, where, model, custom: nil, context: Endpoint::Context.current)
      run_before(model, :update, data, context) do |actual_data|
        updated = custom ? custom.call(actual_data) : adapter.update(model: model, where: where, update: actual_data)
        run_after(model, :update, updated, context)
        updated
      end
    end

    def update_many(data, where, model, custom: nil, context: Endpoint::Context.current)
      run_before(model, :update, data, context) do |actual_data|
        updated = custom ? custom.call(actual_data) : adapter.update_many(model: model, where: where, update: actual_data)
        run_after(model, :update, updated, context)
        updated
      end
    end

    def delete(where, model, custom: nil, context: Endpoint::Context.current, veto_error: nil)
      entity = delete_snapshots(where, model, limit: 1, strict: !!veto_error).first
      if entity && delete_vetoed?(model, entity, context)
        raise Error, veto_error if veto_error
        return nil
      end

      deleted = if custom
        custom.call(where)
      elsif entity
        adapter.delete(model: model, where: where)
      end
      raise Error, veto_error if veto_error && deleted == false
      run_after(model, :delete, entity, context) if entity
      deleted
    end

    def delete_many(where, model, custom: nil, context: Endpoint::Context.current, veto_error: nil)
      entities = delete_snapshots(where, model, strict: !!veto_error)
      if entities.any? { |entity| delete_vetoed?(model, entity, context) }
        raise Error, veto_error if veto_error
        return nil
      end

      deleted = custom ? custom.call(where) : adapter.delete_many(model: model, where: where)
      raise Error, veto_error if veto_error && deleted == false
      entities.each { |entity| run_after(model, :delete, entity, context) }
      deleted
    end

    def consume_one(model, snapshot, context: Endpoint::Context.current)
      return nil if delete_vetoed?(model, snapshot, context)

      consumed = yield
      run_after(model, :delete, consumed, context) if consumed
      consumed
    end

    private

    def delete_vetoed?(model, entity, context)
      hooks_for(model, :delete, :before).any? { |hook| hook.call(entity, context) == false }
    end

    def delete_snapshots(where, model, strict:, limit: nil)
      adapter.find_many(model: model, where: where, limit: limit)
    rescue
      raise if strict
      []
    end

    def run_before(model, action, data, context)
      data = stringify_keys(data)
      actual_data = data
      hooks_for(model, action, :before).each do |hook|
        result = hook.call((action == :create) ? actual_data : data, context)
        return nil if result == false

        hook_data = result.is_a?(Hash) ? (result[:data] || result["data"]) : nil
        actual_data = actual_data.merge(stringify_keys(hook_data)) if hook_data
      end
      yield actual_data
    end

    def run_after(model, action, data, context)
      scope = Thread.current[SCOPE_KEY]
      hooks_for(model, action, :after).each do |hook|
        if scope
          callback = -> { hook.call(data, context) }
          callback = context.context.bind_runtime(&callback) if context.is_a?(Endpoint::Context)
          scope.pending_hooks << callback
        else
          run_inline_after(hook, data, context)
        end
      end
    end

    def run_inline_after(hook, data, context)
      hook.call(data, context)
    rescue
      # The upstream async-storage fallback also retries a rejected inline hook.
      hook.call(data, context)
    end

    def hooks_for(model, action, phase)
      all_hooks.filter_map do |hooks|
        model_hooks = hooks[model.to_sym] || hooks[model.to_s]
        action_hooks = model_hooks&.fetch(action, nil) || model_hooks&.fetch(action.to_s, nil)
        action_hooks&.fetch(phase, nil) || action_hooks&.fetch(phase.to_s, nil)
      end
    end

    def all_hooks
      direct = if options.database_hooks.nil?
        []
      elsif options.database_hooks.is_a?(Array)
        options.database_hooks
      else
        [options.database_hooks]
      end
      plugin_hooks = options.plugins.filter_map do |plugin|
        init_options = plugin.dig(:options, :database_hooks) || plugin.dig("options", "databaseHooks")
        plugin[:database_hooks] || plugin["databaseHooks"] || init_options
      end
      plugin_hooks + direct
    end

    def stringify_keys(data)
      return {} unless data

      data.each_with_object({}) do |(key, value), result|
        result[Schema.storage_key(key)] = value
      end
    end
  end
end
