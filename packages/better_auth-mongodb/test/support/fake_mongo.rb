# frozen_string_literal: true

module BetterAuthMongoAdapterTestSupport
  class FakeMongoDatabase
    def initialize
      @collections = {}
    end

    def collection(name)
      @collections[name.to_s] ||= FakeMongoCollection.new(self)
    end

    def collections
      @collections.values
    end
  end

  class FakeMongoCollection
    attr_reader :documents
    attr_reader :insert_options
    attr_reader :aggregate_pipelines
    attr_reader :find_one_and_update_calls
    attr_reader :update_many_calls
    attr_reader :delete_one_calls
    attr_reader :delete_many_calls
    attr_reader :indexes

    InsertResult = Struct.new(:inserted_id)
    UpdateResult = Struct.new(:modified_count)
    DeleteResult = Struct.new(:deleted_count)

    def initialize(database)
      @database = database
      @documents = []
      @insert_options = []
      @aggregate_pipelines = []
      @find_one_and_update_calls = []
      @update_many_calls = []
      @delete_one_calls = []
      @delete_many_calls = []
      @indexes = FakeMongoIndexes.new
    end

    def insert_one(document, options = {})
      @insert_options << options
      if transaction_session(options)
        transaction_session(options).insert(self, document)
        return InsertResult.new(document.fetch("_id"))
      end

      @documents << deep_dup(document)
      InsertResult.new(document.fetch("_id"))
    end

    def aggregate(pipeline, options = {})
      @aggregate_pipelines << [deep_dup(pipeline), options]
      Cursor.new(apply_pipeline(visible_documents(options), pipeline))
    end

    def find_one_and_update(filter, update, options = {})
      @find_one_and_update_calls << [deep_dup(filter), deep_dup(update), options]
      document = writable_documents(options).find { |entry| matches_filter?(entry, filter) }
      return nil unless document

      document.merge!(deep_dup(update.fetch("$set")))
      deep_dup(document)
    end

    def update_many(filter, update, options = {})
      @update_many_calls << [deep_dup(filter), deep_dup(update), options]
      count = 0
      writable_documents(options).each do |document|
        next unless matches_filter?(document, filter)

        document.merge!(deep_dup(update.fetch("$set")))
        count += 1
      end
      UpdateResult.new(count)
    end

    def delete_one(filter, options = {})
      @delete_one_calls << [deep_dup(filter), options]
      documents = writable_documents(options)
      index = documents.index { |document| matches_filter?(document, filter) }
      documents.delete_at(index) if index
      DeleteResult.new(index ? 1 : 0)
    end

    def delete_many(filter, options = {})
      @delete_many_calls << [deep_dup(filter), options]
      documents = writable_documents(options)
      before = documents.length
      documents.reject! { |document| matches_filter?(document, filter) }
      DeleteResult.new(before - documents.length)
    end

    def all_documents
      @documents.map { |document| deep_dup(document) }
    end

    def replace_documents(documents)
      @documents = documents.map { |document| deep_dup(document) }
    end

    class Cursor
      def initialize(documents)
        @documents = documents
      end

      def to_a
        @documents.map { |document| Marshal.load(Marshal.dump(document)) }
      end
    end

    class FakeMongoIndexes
      attr_reader :create_one_calls

      def initialize
        @create_one_calls = []
      end

      def create_one(keys, options = {})
        @create_one_calls << [deep_dup(keys), deep_dup(options)]
      end

      private

      def deep_dup(value)
        Marshal.load(Marshal.dump(value))
      end
    end

    private

    def visible_documents(options)
      session = transaction_session(options)
      documents = session ? session.documents_for(self) : @documents

      documents.map { |document| deep_dup(document) }
    end

    def writable_documents(options)
      session = transaction_session(options)
      return @documents unless session

      session.documents_for(self)
    end

    def transaction_session(options)
      session = options[:session] || options["session"]
      return nil unless session&.transaction_started?

      session
    end

    def apply_pipeline(input, pipeline)
      pipeline.reduce(input) do |documents, stage|
        if stage.key?("$match")
          documents.select { |document| matches_filter?(document, stage.fetch("$match")) }
        elsif stage.key?("$lookup")
          apply_lookup(documents, stage.fetch("$lookup"))
        elsif stage.key?("$unwind")
          apply_unwind(documents, stage.fetch("$unwind"))
        elsif stage.key?("$project")
          apply_project(documents, stage.fetch("$project"))
        elsif stage.key?("$sort")
          field, direction = stage.fetch("$sort").first
          sorted = documents.sort_by { |document| sortable_value(document[field]) }
          (direction == -1) ? sorted.reverse : sorted
        elsif stage.key?("$skip")
          documents.drop(stage.fetch("$skip"))
        elsif stage.key?("$limit")
          documents.first(stage.fetch("$limit"))
        elsif stage.key?("$count")
          [{stage.fetch("$count") => documents.length}]
        else
          documents
        end
      end
    end

    def apply_lookup(documents, lookup)
      foreign_documents = @database.collection(lookup.fetch("from")).documents
      documents.map do |document|
        matches = if lookup.key?("pipeline")
          local_value = document[lookup.fetch("let").fetch("localFieldValue").delete_prefix("$")]
          lookup.fetch("pipeline").reduce(foreign_documents.map { |entry| deep_dup(entry) }) do |result, stage|
            if stage.key?("$match") && stage.fetch("$match").key?("$expr")
              left, right = stage.dig("$match", "$expr", "$eq")
              field = left.delete_prefix("$")
              expected = (right == "$$localFieldValue") ? local_value : right
              result.select { |entry| values_equal?(entry[field], expected) }
            elsif stage.key?("$limit")
              result.first(stage.fetch("$limit"))
            else
              result
            end
          end
        else
          local_value = document[lookup.fetch("localField")]
          foreign_documents
            .select { |entry| values_equal?(entry[lookup.fetch("foreignField")], local_value) }
            .map { |entry| deep_dup(entry) }
        end
        document.merge(lookup.fetch("as") => matches)
      end
    end

    def apply_unwind(documents, unwind)
      field = unwind.fetch("path").delete_prefix("$")
      documents.flat_map do |document|
        value = document[field]
        if value.is_a?(Array) && !value.empty?
          value.map { |entry| document.merge(field => entry) }
        elsif unwind.fetch("preserveNullAndEmptyArrays", false)
          [document.merge(field => nil)]
        else
          []
        end
      end
    end

    def apply_project(documents, project)
      documents.map do |document|
        project.each_with_object({}) do |(field, enabled), projected|
          projected[field] = document[field] if enabled == 1 && document.key?(field)
        end
      end
    end

    def matches_filter?(document, filter)
      return true if filter.empty?

      filter.all? do |field, expected|
        case field
        when "$and"
          expected.all? { |entry| matches_filter?(document, entry) }
        when "$or"
          expected.any? { |entry| matches_filter?(document, entry) }
        when "$nor"
          expected.none? { |entry| matches_filter?(document, entry) }
        when "$expr"
          expected.fetch("$eq") == [1, 0]
        else
          current = document[field.to_s]
          matches_value?(current, expected)
        end
      end
    end

    def matches_value?(current, expected)
      if expected.is_a?(Hash)
        expected.all? do |operator, value|
          case operator
          when "$in"
            value.any? { |entry| values_equal?(current, entry) }
          when "$nin"
            value.none? { |entry| values_equal?(current, entry) }
          when "$ne"
            !values_equal?(current, value)
          when "$gt"
            !current.nil? && current > value
          when "$gte"
            !current.nil? && current >= value
          when "$lt"
            !current.nil? && current < value
          when "$lte"
            !current.nil? && current <= value
          when "$not"
            !matches_value?(current, value)
          else
            false
          end
        end
      elsif expected.is_a?(Regexp)
        current.to_s.match?(expected)
      else
        values_equal?(current, expected)
      end
    end

    def values_equal?(left, right)
      left == right || left.to_s == right.to_s
    end

    def sortable_value(value)
      return "" if value.nil?
      return value.to_s if defined?(BSON::ObjectId) && value.is_a?(BSON::ObjectId)

      value
    end

    def deep_dup(value)
      Marshal.load(Marshal.dump(value))
    end
  end

  class FakeMongoClient
    attr_reader :sessions

    def initialize
      @sessions = []
    end

    def start_session
      FakeMongoSession.new.tap { |session| sessions << session }
    end
  end

  class FakeMongoSession
    attr_reader :started, :committed, :aborted, :ended

    def initialize
      @started = false
      @committed = false
      @aborted = false
      @ended = false
      @collection_states = {}
    end

    def start_transaction
      @started = true
    end

    def commit_transaction
      @collection_states.each do |collection, documents|
        collection.replace_documents(documents)
      end
      @collection_states.clear
      @committed = true
      @started = false
    end

    def abort_transaction
      @collection_states.clear
      @aborted = true
      @started = false
    end

    def end_session
      @ended = true
    end

    def transaction_started?
      started
    end

    def documents_for(collection)
      @collection_states[collection] ||= collection.all_documents
    end

    def insert(collection, document)
      documents_for(collection) << Marshal.load(Marshal.dump(document))
    end

    def pending_documents_for(collection)
      documents_for(collection).map { |document| Marshal.load(Marshal.dump(document)) }
    end
  end
end
