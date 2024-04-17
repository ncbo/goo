module Goo
  module Base

    class Where

      AGGREGATE_PATTERN = Struct.new(:pattern,:aggregate)

      attr_accessor :where_options_load
      include Goo::SPARQL::Processor

      def initialize(klass,*match_patterns)
        if Goo.queries_debug? && Thread.current[:ncbo_debug].nil?
          Thread.current[:ncbo_debug] = {}
        end
        @klass = klass
        @pattern = match_patterns.first.nil? ? nil : Pattern.new(match_patterns.first)
        @models = nil
        @include = []
        @include_embed = {}
        @result = nil
        @filters = nil
        @ids = nil
        @aggregate = nil
        @where_options_load = nil
        @count = nil
        @page_i = nil
        @page_size = nil
        @index_key = nil
        @order_by = nil
        @indexing = false
        @read_only = false
        @rules = true
        @do_count = true
        @pre_count = nil
        @query_options = nil
        @no_graphs = false

        #cache of retrieved predicates for unmapped queries
        #reused across pages
        @predicates = nil
      end

      def equivalent_predicates
        @equivalent_predicates
      end

      def includes_aliasing
        @include.each do |attr|
          return true if @klass.alias?(attr)
        end
        return false
      end

      def closure(eq_has)
        begin
          changed = false
          copy = {}
          eq_has.each do |x,y|
            copy[x] = y.dup
          end
          copy.each do |p,values|
            values.each  do |y|
              next if copy[y].nil?
              copy[y].each do |z|
                unless values.include?(z)
                  eq_has[p] << z
                  changed = true
                end
              end
            end
          end
        end while(changed)
      end

      def no_graphs
        @no_graphs = true
        return self
      end

      def retrieve_equivalent_predicates()
        return @equivalent_predicates unless @equivalent_predicates.nil?

        equivalent_predicates = nil
        if @include.first == :unmapped || includes_aliasing()
          if @where_options_load && @where_options_load[:collection]
            graph = @where_options_load[:collection].map { |x| x.id }
          else
            #TODO review this case
            raise ArgumentError, "Unmapped wihout collection not tested"
          end
          equivalent_predicates = Goo::SPARQL::Queries.sub_property_predicates(graph)
          #TODO compute closure
          equivalent_predicates_hash = {}
          equivalent_predicates.each do |down,up|
            (equivalent_predicates_hash[up.to_s] ||= Set.new) << down.to_s
          end
          equivalent_predicates_hash.delete(Goo.vocabulary(:rdfs)[:label].to_s)
          closure(equivalent_predicates_hash)
          equivalent_predicates_hash.each do |k,v|
            equivalent_predicates_hash[k] << k
          end
        end
        return equivalent_predicates_hash
      end

      def unmmaped_predicates()
        return @predicates unless @predicates.nil?

        predicates = nil
        if @include.first == :unmapped
          if @where_options_load[:collection]
            graph = @where_options_load[:collection].map { |x| x.id }
          else
            #TODO review this case
            raise ArgumentError, "Unmapped wihout collection not tested"
          end
          predicates = Goo::SPARQL::Queries.graph_predicates(graph)
          if predicates.length == 0
            raise ArgumentError, "Empty graph. Unable to load predicates"
          end
        end
        return predicates
      end

      def process_query(count=false)
        process_query_call(count = count)
      end

      def disable_rules
        @rules = false
        self
      end

      def cache_key_for_index(index_key)
        return "goo:#{@klass.name}:#{index_key}"
      end

      def index_as(index_key,max=nil)
        @indexing = true
        @read_only = true
        raise ArgumentError, "Need redis configuration to index" unless Goo.redis_client
        rclient = Goo.redis_client
        if @include.length > 0
          raise ArgumentError, "Index is performend on Where objects without attributes included"
        end
        page_i_index = 1
        page_size_index = 400
        temporal_key = "goo:#{@klass.name}:#{index_key}:tmp"
        final_key = cache_key_for_index(index_key)
        count = 0
        start = Time.now
        stop = false
        begin
          page = self.page(page_i_index,page_size_index).all
          count += page.length
          ids = page.map { |x| x.id }
          rclient.pipelined do
            ids.each do |id|
              rclient.rpush temporal_key, id.to_s
            end
          end
          page_i_index += 1
          puts "Indexed #{count}/#{page.aggregate} - #{Time.now - start} sec."
          stop = !max.nil? && (count > max)
        end while (page.next? && !stop)
        rclient.rename temporal_key, final_key
        puts "Indexed #{rclient.llen(final_key)} at #{final_key}"
        return rclient.llen(final_key)
      end

      def all
        if @result.nil? && @klass.inmutable? && @klass.inm_instances
          if @pattern.nil? && @filters.nil?
            @result = @klass.inm_instances.values
          end
        end
        process_query unless @result
        @result
      end
      alias_method :to_a, :all

      def each(&block)
        process_query unless @result
        @result.each do |r|
          yield r
        end
      end

      def length
        unless @result
          res = process_query(count=true)
          return res.length if res.is_a?Array
          return res
        end
        return @result.length
      end

      def count
        unless @result
          res = process_query(count=true)
          return res.length if res.is_a?Array
          return res
        end
        return @result.count
      end

      def empty?
        process_query unless @result
        return @result.empty?
      end

      def first
        process_query unless @result
        @result.first
      end

      def last
        process_query unless @result
        @result.last
      end

      def page_count_set(c)
        @pre_count = c
        self
      end

      def page(i,size=nil)
        @page_i = i
        if size
          @page_size = size
        elsif @page_size.nil?
          @page_size = 50
        end
        @result = nil
        self
      end

      def no_count
        @do_count = false
        self
      end

      def include(*options)
        if options.instance_of?(Array) && options.first.instance_of?(Array)
          options = options.first
        end
        options.each do |opt|
          if opt.instance_of?(Symbol)
            if @klass.handler?(opt)
              raise ArgumentError, "Method based attribute cannot be included"
            end
          end
          if opt.instance_of?(Hash)
            opt.each do |k,v|
              if @klass.handler?(k)
                raise ArgumentError, "Method based attribute cannot be included"
              end
            end
          end
          @include << opt if opt.instance_of?(Symbol)
          @include_embed.merge!(opt) if opt.instance_of?(Hash)
        end
        @include = [:unmapped] if @include.include? :unspecified
        self
      end

      def models(models)
        @models = models
        self
      end

      def and(*options)
        and_match = options.first
        @pattern = @pattern.join(and_match)
        self
      end

      def or(*options)
        or_match = options.first
        @pattern = @pattern.union(or_match)
        self
      end

      def order_by(*opts)
        @order_by = opts
        self
      end

      def in(*opts)
        opts = opts.flatten
        if opts && opts.length > 0
          opts = opts.select { |x| !x.nil? }
          if opts.length > 0
            (@where_options_load ||= {})[:collection] = opts
          end
        end
        self
      end

      def query_options(opts)
        @query_options = opts
        self
      end

      def ids(ids)
        if ids
          @ids = ids
        end
        self
      end

      def filter(filter)
        (@filters ||= []) << filter
        self
      end

      def aggregate(agg,pattern)
        (@aggregate ||= []) << AGGREGATE_PATTERN.new(pattern,agg)
        self
      end

      def nil?
        self.first.nil?
      end

      def with_index(index_key)
        @index_key = index_key
        self
      end

      def read_only
        @read_only = true
        self
      end
    end
  end
end
